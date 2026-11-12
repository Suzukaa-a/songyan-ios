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
        /// Non-nil when the draft updates the script with this id instead of adding a new one.
        let replacing: String?

        var isReplacement: Bool { replacing != nil }
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
    func stage(source: Data, sourceURL: URL? = nil, replacing: String? = nil) -> Bool {
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
                id: replacing ?? UUID().uuidString, source: source, sourceURL: sourceURL,
                declarations: declarations, replacing: replacing)
            return true
        } catch let ScriptAddonBridge.BridgeError.header(message, line) {
            errorMessage =
                line > 0
                ? message + String(format: String(localized: "\u{FF08}\u{7B2C} %lld \u{884C}\u{FF09}"), line) : message
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
    /// Confirms the declarations the page showed. A new script is added; a draft that
    /// updates an existing id keeps that addon's enabled/order/settings/secret keys and only
    /// moves the bytes and the confirmation digest forward.
    func confirm(_ draft: Draft, settings: [String: String], secretValues: [String: String]) {
        do {
            let digest = try draft.declarations.confirmationDigest()
            let maximum = limits?.maximumSourceBytes ?? draft.source.count
            if let replacing = draft.replacing {
                _ = try store.replace(
                    id: replacing, script: draft.source, maximumSourceBytes: maximum,
                    confirmedDigest: digest, settings: settings,
                    secretKeys: draft.declarations.secrets.map(\.key))
            } else {
                var state = ScriptAddonState(
                    id: draft.id, order: addons.count,
                    sourceURL: draft.sourceURL?.absoluteString, scriptDigest: "",
                    scriptByteCount: 0)
                state.settings = settings
                state.secretKeys = draft.declarations.secrets.map(\.key)
                state.confirmedDigest = digest
                _ = try store.add(
                    id: draft.id, script: draft.source, state: state,
                    maximumSourceBytes: maximum)
            }
            for (key, value) in secretValues {
                try secrets.setSecret(value, for: key, scriptID: draft.id)
            }
            pending = nil
            reload()
            notice =
                draft.isReplacement
                ? String(localized: "\u{811A}\u{672C}\u{5DF2}\u{66F4}\u{65B0}")
                : String(localized: "\u{5DF2}\u{6DFB}\u{52A0}\u{811A}\u{672C}")
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
                        declarations: declarations, replacing: addon.state.id)
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

    /// In-app editing replaces the same addon. When the declarations (sites/settings/secrets/
    /// audio) are unchanged the new bytes are applied immediately; a changed declaration set
    /// goes through the confirmation page, which keeps the old local state.
    func saveEdited(addon: ScriptAddonStore.Addon, source: Data) {
        do {
            let declarations = try bridge.parseDeclarations(source: source)
            let digest = try declarations.confirmationDigest()
            if digest == addon.state.confirmedDigest,
                let maximum = limits?.maximumSourceBytes ?? Optional(source.count)
            {
                _ = try store.replace(
                    id: addon.state.id, script: source, maximumSourceBytes: maximum,
                    confirmedDigest: digest)
                reload()
                notice = String(localized: "\u{811A}\u{672C}\u{5DF2}\u{4FDD}\u{5B58}")
                return
            }
            pending = Draft(
                id: addon.state.id, source: source,
                sourceURL: addon.state.sourceURL.flatMap(URL.init(string:)),
                declarations: declarations, replacing: addon.state.id)
        } catch let ScriptAddonBridge.BridgeError.header(message, line) {
            errorMessage =
                line > 0
                ? message + String(format: String(localized: "\u{FF08}\u{7B2C} %lld \u{884C}\u{FF09}"), line) : message
        } catch {
            errorMessage = error.localizedDescription
        }
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

    func clearNotice() {
        notice = nil
    }

    /// iOS cannot record; an audio script is kept (importable, shareable) but the keyboard
    /// shows it as unavailable, so the Host app says that before the user taps add.
    func availabilityNote(_ addon: ScriptAddonStore.Addon) -> String? {
        guard !hostSupportsAudio, (try? declarations(for: addon.state.id).needsAudio) == true
        else { return nil }
        return Self.audioUnavailableNote
    }

    static let audioUnavailableNote = String(
        localized:
            "\u{672C}\u{673A}\u{4E0D}\u{63D0}\u{4F9B}\u{5F55}\u{97F3}\u{FF0C}\u{58F0}\u{97F3}\u{811A}\u{672C}\u{53EA}\u{80FD}\u{5BFC}\u{5165}\u{FF0C}\u{952E}\u{76D8}\u{91CC}\u{4F1A}\u{6807}\u{4E3A}\u{4E0D}\u{53EF}\u{7528}"
    )

    /// Runs the editor's current source (not the saved bytes) off the main thread. A new,
    /// unsaved script runs with no settings; an existing addon contributes its settings and
    /// Keychain secrets. Cancelling stops the engine loop and returns nil without an error.
    func tryRun(
        source: Data, addon: ScriptAddonStore.Addon?, inputText: String
    ) async -> ScriptAddonBridge.TryRunResult? {
        guard let limits, limits.isRunnable else {
            errorMessage = Self.limitsMissing
            return nil
        }
        do {
            let declarations = try bridge.parseDeclarations(source: source)
            var settings = addon?.state.settings ?? [:]
            if let id = addon?.state.id {
                for secret in declarations.secrets {
                    if let value = try? secrets.secret(for: secret.key, scriptID: id) {
                        settings[secret.key] = value
                    }
                }
            }
            var settingsJSON: String?
            if !settings.isEmpty {
                let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
                settingsJSON = String(decoding: data, as: UTF8.self)
            }
            let cancellation = ScriptAddonBridge.RunCancellation()
            let bridge = self.bridge
            let text = inputText
            let payload = settingsJSON
            return try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try bridge.tryRun(
                        source: source, inputText: text, settingsJSON: payload,
                        limits: limits, cancellation: cancellation, onLog: { _ in })
                }.value
            } onCancel: {
                cancellation.cancel()
            }
        } catch is CancellationError {
            return nil
        } catch ScriptAddonBridge.BridgeError.cancelled {
            return nil
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

        /// Simulator smoke test for the host add flow that the settings screen drives:
        /// stage the bundled example, confirm it, toggle it and run it through the same
        /// center and store the screen uses. Writes the outcome to the app's temporary
        /// directory; the numbers are the production limits.
        static func runCenterSelfTest() -> String {
            var lines: [String] = []
            let root =
                FileManager.default.temporaryDirectory
                .appendingPathComponent("center-selftest-\(UUID().uuidString)", isDirectory: true)
            let center = ScriptAddonCenter(root: root)
            guard
                let sourceURL = ScriptAddonCenter.bundledResource("minimal", "js"),
                let source = try? Data(contentsOf: sourceURL)
            else {
                lines.append("error: bundled minimal.js missing")
                return writeCenterSelfTest(lines)
            }
            lines.append("staged=\(center.stage(source: source))")
            guard let draft = center.pending else {
                lines.append("error: no pending draft after staging")
                return writeCenterSelfTest(lines)
            }
            lines.append("draft id=\(draft.id) name=\(draft.declarations.name)")
            center.confirm(draft, settings: [:], secretValues: [:])
            lines.append("addons=\(center.addons.count) pending=\(center.pending != nil)")
            guard let addon = center.addons.first else {
                lines.append("error: no addon after confirming")
                return writeCenterSelfTest(lines)
            }
            lines.append("enabled=\(addon.state.enabled)")
            center.setEnabled(false, addon: addon)
            lines.append("after disable=\(center.addons.first?.state.enabled ?? false)")
            center.setEnabled(true, addon: addon)
            lines.append("after enable=\(center.addons.first?.state.enabled ?? false)")
            if let addon = center.addons.first {
                if let result = center.tryRun(addon: addon, inputText: "Hello") {
                    lines.append("outputs=\(result.outputs)")
                } else {
                    lines.append("tryRun=nil error=\(center.errorMessage ?? "none")")
                }
            }
            return writeCenterSelfTest(lines)
        }

        private static func writeCenterSelfTest(_ lines: [String]) -> String {
            let text = lines.joined(separator: "\n") + "\n"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("center-selftest.txt")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            NSLog("SONGYAN_SCRIPT_CENTER_SELFTEST %@", text)
            return text
        }
    }
#endif
