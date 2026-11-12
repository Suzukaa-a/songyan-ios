import Foundation
import ScriptAddonKit
import SwiftUI

/// Host app model for user scripts, the same addon kind the keyboard lists as tools.
/// It keeps the byte-exact script file and a versioned local state JSON in the shared
/// App Group container (the extension reads the same files later), keeps secrets in the
/// Keychain, and runs the editor's try box through the shared C runtime.
@MainActor
final class ScriptAddonCenter: ObservableObject {
    struct Draft: Identifiable, Equatable {
        let id: String
        let source: Data
        let sourceURL: URL?
        let declarations: ScriptDeclarations
    }

    struct RuntimeUnavailable: Error {}

    @Published private(set) var addons: [ScriptAddonStore.Addon] = []
    @Published var pending: Draft?
    @Published var errorMessage: String?
    @Published var notice: String?

    private let store: ScriptAddonStore
    private let secrets: any ScriptSecretStore
    private let bridge = ScriptAddonBridge()
    /// Limits and the one-time download transport are injected by the app; until the
    /// measured values exist nothing can be imported or run (no guessed numbers).
    var limits: ScriptAddonLimits?
    var download: ((URL) async throws -> Data)?
    var hostSupportsAudio = false

    /// The one instance the settings screen shows. The limits are the measured provisional
    /// contract values from the shared runtime, the same ones the extension uses.
    static let shared = ScriptAddonCenter()

    init(
        root: URL? = ScriptAddonCenter.sharedRoot(),
        secrets: any ScriptSecretStore = KeychainScriptSecretStore(
            service: "app.songyan.script", accessGroup: KeyboardRecipeStore.groupID)
    ) {
        self.store = ScriptAddonStore(root: root ?? Self.fallbackRoot())
        self.secrets = secrets
        limits = ScriptAddonLimits(
            maximumSourceBytes: 262_144, maximumInputTextBytes: 65_536, sourceBytes: 262_144,
            heapBytes: 8_388_608, durationMilliseconds: 4_000, requestCount: 1,
            responseBytes: 65_536)
        download = Self.downloadOverHTTPS
        reload()
    }

    /// A linked script comes from the user's own HTTPS URL; nothing else is fetched.
    private static func downloadOverHTTPS(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Storage location

    static func sharedRoot() -> URL? {
        guard let container = KeyboardRecipeStore.sharedContainerURL() else { return nil }
        return container.appendingPathComponent(
            "Library/Application Support/ScriptAddons",
            isDirectory: true)
    }

    private static func fallbackRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScriptAddons", isDirectory: true)
    }

    func reload() {
        do {
            addons = try store.list()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Scripts that declared audio are kept but shown unavailable on a host without it.
    func isAvailable(_ addon: ScriptAddonStore.Addon) -> Bool {
        let needsAudio = (try? declarations(for: addon.state.id).needsAudio) ?? false
        return hostSupportsAudio || !needsAudio
    }

    func declarations(for id: String) throws -> ScriptDeclarations {
        try bridge.parseDeclarations(source: store.scriptBytes(id: id))
    }

    func needsReconfirmation(_ addon: ScriptAddonStore.Addon) -> Bool {
        (try? store.needsReconfirmation(id: addon.state.id, declarations: declarations(for: addon.state.id))) ?? true
    }

    // MARK: - Add flows

    /// Pasted text, in-app editor content and imported files all reach this one place.
    @discardableResult
    func stage(source: Data, sourceURL: URL? = nil) -> Bool {
        guard let limits else {
            errorMessage = Self.limitsMissing
            return false
        }
        guard source.count <= limits.maximumSourceBytes else {
            errorMessage = String(localized: "\u{811A}\u{672C}\u{6587}\u{4EF6}\u{592A}\u{5927}")
            return false
        }
        do {
            let declarations = try bridge.parseDeclarations(source: source)
            pending = Draft(
                id: UUID().uuidString, source: source, sourceURL: sourceURL, declarations: declarations)
            return true
        } catch let ScriptAddonBridge.BridgeError.header(message, line) {
            errorMessage = line > 0 ? "\(message)\u{FF08}\u{7B2C} \(line) \u{884C}\u{FF09}" : message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func importFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            stage(source: try Data(contentsOf: url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Links are downloaded once at import time; manual update checks reuse the same path.
    func importLink(_ url: URL) {
        guard let download, let limits else {
            errorMessage = Self.limitsMissing
            return
        }
        Task {
            do {
                let data = try await download(url)
                guard data.count <= limits.maximumSourceBytes else {
                    errorMessage = String(localized: "\u{811A}\u{672C}\u{6587}\u{4EF6}\u{592A}\u{5927}")
                    return
                }
                stage(source: data, sourceURL: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Confirms the declarations the page showed, writes the script bytes and stores any
    /// entered secrets in the Keychain. Secrets never enter the script or the JSON state.
    func confirm(
        _ draft: Draft, name: String?, settings: [String: String], secretValues: [String: String]
    ) {
        do {
            var state = ScriptAddonState(
                id: draft.id, order: addons.count, sourceURL: draft.sourceURL?.absoluteString,
                scriptDigest: "", scriptByteCount: 0)
            state.settings = settings
            state.secretKeys = draft.declarations.secrets.map(\.key)
            state.confirmedDigest = try draft.declarations.confirmationDigest()
            _ = try store.add(
                id: draft.id, script: draft.source, state: state,
                maximumSourceBytes: limits?.maximumSourceBytes ?? draft.source.count)
            for (key, value) in secretValues {
                try secrets.setSecret(value, for: key, scriptID: draft.id)
            }
            pending = nil
            reload()
            notice = String(localized: "\u{5DF2}\u{6DFB}\u{52A0}\u{811A}\u{672C}")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelPending() {
        pending = nil
    }

    // MARK: - List actions

    func setEnabled(_ enabled: Bool, addon: ScriptAddonStore.Addon) {
        do {
            try store.setEnabled(enabled, id: addon.state.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reorder(from source: IndexSet, to destination: Int) {
        var ids = addons.map(\.state.id)
        ids.move(fromOffsets: source, toOffset: destination)
        do {
            try store.reorder(ids)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(addon: ScriptAddonStore.Addon) {
        do {
            try secrets.deleteAllSecrets(scriptID: addon.state.id)
            try store.delete(id: addon.state.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportData(addon: ScriptAddonStore.Addon) -> Data? {
        try? store.exportData(id: addon.state.id)
    }

    func addonSource(_ addon: ScriptAddonStore.Addon) -> String {
        (try? String(decoding: store.scriptBytes(id: addon.state.id), as: UTF8.self)) ?? ""
    }

    /// A manual update check: the fetched file goes through the same header parser, and a
    /// changed site, setting, secret or audio requirement puts the addon back to the
    /// confirmation page instead of silently replacing it.
    func checkForUpdate(addon: ScriptAddonStore.Addon) {
        guard let sourceURL = addon.state.sourceURL.flatMap(URL.init(string:)),
            let download
        else {
            notice = String(
                localized: "\u{8FD9}\u{4E2A}\u{811A}\u{672C}\u{6CA1}\u{6709}\u{6765}\u{6E90}\u{94FE}\u{63A5}")
            return
        }
        Task {
            do {
                let data = try await download(sourceURL)
                let declarations = try bridge.parseDeclarations(source: data)
                if try store.needsReconfirmation(id: addon.state.id, declarations: declarations) {
                    pending = Draft(
                        id: addon.state.id, source: data, sourceURL: sourceURL,
                        declarations: declarations)
                } else {
                    _ = try store.replaceScript(
                        id: addon.state.id, script: data,
                        maximumSourceBytes: limits?.maximumSourceBytes ?? data.count)
                    reload()
                    notice = String(localized: "\u{811A}\u{672C}\u{5DF2}\u{66F4}\u{65B0}")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// In-app editing goes through the confirmation page as well: a changed declaration
    /// set has to be confirmed again before the new bytes are kept.
    func saveEdited(addon: ScriptAddonStore.Addon, source: Data) {
        stage(source: source, sourceURL: addon.state.sourceURL.flatMap(URL.init(string:)))
    }

    // MARK: - Settings and secrets

    func settingValue(_ key: String, addon: ScriptAddonStore.Addon) -> String {
        addon.state.settings[key] ?? ""
    }

    func secretValue(_ key: String, addon: ScriptAddonStore.Addon) -> String {
        (try? secrets.secret(for: key, scriptID: addon.state.id)) ?? ""
    }

    func saveSettings(
        addon: ScriptAddonStore.Addon, settings: [String: String], secrets values: [String: String]
    ) {
        do {
            for (key, value) in settings {
                try store.updateSetting(key: key, value: value, id: addon.state.id)
            }
            for (key, value) in values {
                if value.isEmpty {
                    try self.secrets.deleteSecret(for: key, scriptID: addon.state.id)
                } else {
                    try self.secrets.setSecret(value, for: key, scriptID: addon.state.id)
                }
            }
            reload()
            notice = String(localized: "\u{8BBE}\u{7F6E}\u{5DF2}\u{4FDD}\u{5B58}")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Try run

    func tryRun(addon: ScriptAddonStore.Addon, inputText: String) -> ScriptAddonBridge.TryRunResult? {
        guard let limits, limits.isRunnable else {
            errorMessage = Self.limitsMissing
            return nil
        }
        do {
            let declarations = try declarations(for: addon.state.id)
            var settings = addon.state.settings
            for secret in declarations.secrets {
                if let value = try? secrets.secret(for: secret.key, scriptID: addon.state.id) {
                    settings[secret.key] = value
                }
            }
            let settingsJSON = try JSONSerialization.data(
                withJSONObject: settings, options: [.sortedKeys])
            return try bridge.tryRun(
                source: store.scriptBytes(id: addon.state.id), inputText: inputText,
                settingsJSON: String(decoding: settingsJSON, as: UTF8.self), limits: limits,
                onLog: { _ in })
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Empty-page resources

    static func bundledResource(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "ScriptAddons")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }
    static func aiGuide() -> String {
        bundledResource("ai-guide", "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? String(localized: "\u{627E}\u{4E0D}\u{5230}\u{7ED9} AI \u{7684}\u{8BF4}\u{660E}")
    }

    static func minimalExample() -> String {
        bundledResource("minimal", "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? ""
    }

    static let limitsMissing = String(
        localized: "\u{811A}\u{672C}\u{8FD0}\u{884C}\u{9650}\u{989D}\u{8FD8}\u{6CA1}\u{914D}\u{7F6E}\u{597D}")
}

#if DEBUG
    extension ScriptAddonCenter {
        /// Simulator-only smoke test for the try-run path: parses the bundled minimal
        /// example, runs it once through the shared C runtime and writes the outcome to
        /// the app's temporary directory so an automated check can read it. The limits
        /// below are self-test numbers, not production values.
        static func runTryRunSelfTest() -> String {
            let limits = ScriptAddonLimits(
                maximumSourceBytes: 64 * 1024, maximumInputTextBytes: 4 * 1024,
                sourceBytes: 64 * 1024, heapBytes: 8 * 1024 * 1024,
                durationMilliseconds: 2_000, requestCount: 4, responseBytes: 256 * 1024)
            let bridge = ScriptAddonBridge()
            var lines: [String] = []
            do {
                guard
                    let sourceURL = ScriptAddonCenter.bundledResource("minimal", "js"),
                    let source = try? Data(contentsOf: sourceURL)
                else {
                    lines.append("error: bundled minimal.js missing")
                    return finish(lines)
                }
                let declarations = try bridge.parseDeclarations(source: source)
                lines.append("declarations: name=\(declarations.name) api=\(declarations.apiVersion)")
                let result = try bridge.tryRun(
                    source: source, inputText: "Hello", settingsJSON: "{}", limits: limits,
                    onLog: { _ in })
                lines.append("outputs=\(result.outputs)")
                lines.append("logs=\(result.logs)")
                if let message = result.errorMessage { lines.append("error=\(message)") }
                if let line = result.errorLine { lines.append("errorLine=\(line)") }
            } catch {
                lines.append("threw: \(error)")
            }
            return finish(lines)
        }

        private static func finish(_ lines: [String]) -> String {
            let text = lines.joined(separator: "\n")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("script-addon-selftest.txt")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            NSLog("SONGYAN_SCRIPT_ADDON_SELFTEST %@", text)
            return text
        }
    }
#endif
