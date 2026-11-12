import ScriptAddonKit
import SwiftUI

/// The confirmation page every addition passes through: what the script is called, what
/// text it can read, which sites it may connect to and which settings it expects. A link
/// import or an update that changes any of those asks again here.
struct ScriptAddonConfirmationView: View {
    @ObservedObject var center: ScriptAddonCenter
    let draft: ScriptAddonCenter.Draft
    @Environment(\.dismiss) private var dismiss
    @State private var settings: [String: String] = [:]
    @State private var secrets: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "\u{540D}\u{5B57}")) {
                    // The name is a script declaration, not a local label: renaming it here
                    // would disagree with the header the keyboard runs.
                    LabeledContent(String(localized: "\u{540D}\u{5B57}"), value: draft.declarations.name)
                }
                Section(String(localized: "\u{5B83}\u{80FD}\u{8BFB}\u{5230}\u{4EC0}\u{4E48}")) {
                    LabeledContent(
                        String(localized: "\u{6587}\u{5B57}"),
                        value:
                            String(
                                localized:
                                    "\u{9009}\u{4E2D}\u{7684}\u{6587}\u{5B57}\u{FF0C}\u{6CA1}\u{6709}\u{9009}\u{4E2D}\u{65F6}\u{662F}\u{5149}\u{6807}\u{524D}\u{7684}\u{4E00}\u{6BB5}"
                            )
                    )
                    LabeledContent(
                        String(localized: "\u{5F55}\u{97F3}"),
                        value: draft.declarations.needsAudio
                            ? ScriptAddonCenter.audioUnavailableNote
                            : String(localized: "\u{4E0D}\u{4F7F}\u{7528}\u{9EA6}\u{514B}\u{98CE}"))
                }
                Section(String(localized: "\u{4F1A}\u{8FDE}\u{8FD9}\u{4E9B}\u{7F51}\u{7AD9}")) {
                    if draft.declarations.networkHosts.isEmpty {
                        Text(String(localized: "\u{4E0D}\u{8054}\u{7F51}"))
                    } else {
                        ForEach(draft.declarations.networkHosts, id: \.self) { host in
                            Text(host).font(.system(.body, design: .monospaced))
                        }
                    }
                }
                if !draft.declarations.settings.isEmpty {
                    Section(String(localized: "\u{8BBE}\u{7F6E}")) {
                        ForEach(draft.declarations.settings, id: \.key) { setting in
                            TextField(
                                setting.label,
                                text: Binding(
                                    get: { settings[setting.key] ?? "" },
                                    set: { settings[setting.key] = $0 }))
                        }
                    }
                }
                if !draft.declarations.secrets.isEmpty {
                    Section(String(localized: "\u{5BC6}\u{94A5}")) {
                        ForEach(draft.declarations.secrets, id: \.key) { secret in
                            SecureField(
                                secret.label,
                                text: Binding(
                                    get: { secrets[secret.key] ?? "" },
                                    set: { secrets[secret.key] = $0 }))
                        }
                        Text(
                            String(
                                localized:
                                    "\u{5BC6}\u{94A5}\u{4FDD}\u{5B58}\u{5230}\u{94A5}\u{5319}\u{4E32}\u{FF0C}\u{4E0D}\u{5199}\u{8FDB}\u{811A}\u{672C}\u{6587}\u{4EF6}"
                            )
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(
                Text(
                    draft.isReplacement
                        ? String(localized: "\u{786E}\u{8BA4}\u{66F4}\u{65B0}")
                        : String(localized: "\u{786E}\u{8BA4}\u{6DFB}\u{52A0}"))
            )
            .onAppear {
                // An update shows the settings/secrets the addon already has; confirming
                // merges them over the preserved state instead of replacing it.
                guard draft.isReplacement,
                    let addon = center.addons.first(where: { $0.state.id == draft.id })
                else { return }
                settings = addon.state.settings
                for secret in draft.declarations.secrets {
                    secrets[secret.key] = center.secretValue(secret.key, addon: addon)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "\u{53D6}\u{6D88}")) {
                        center.cancelPending()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        draft.isReplacement
                            ? String(localized: "\u{66F4}\u{65B0}") : String(localized: "\u{6DFB}\u{52A0}")
                    ) {
                        center.confirm(draft, settings: settings, secretValues: secrets)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// One stored script's settings and secrets. Values are saved to the versioned state JSON;
/// secrets go to the Keychain through the shared access group.
struct ScriptAddonSettingsView: View {
    @ObservedObject var center: ScriptAddonCenter
    let addon: ScriptAddonStore.Addon
    @Environment(\.dismiss) private var dismiss
    @State private var settings: [String: String] = [:]
    @State private var secrets: [String: String] = [:]
    @State private var declarations: ScriptDeclarations?

    var body: some View {
        NavigationStack {
            Form {
                if let declarations {
                    if !declarations.settings.isEmpty {
                        Section(String(localized: "\u{8BBE}\u{7F6E}")) {
                            ForEach(declarations.settings, id: \.key) { setting in
                                TextField(
                                    setting.label,
                                    text: Binding(
                                        get: { settings[setting.key] ?? "" },
                                        set: { settings[setting.key] = $0 }))
                            }
                        }
                    }
                    if !declarations.secrets.isEmpty {
                        Section(String(localized: "\u{5BC6}\u{94A5}")) {
                            ForEach(declarations.secrets, id: \.key) { secret in
                                SecureField(
                                    secret.label,
                                    text: Binding(
                                        get: { secrets[secret.key] ?? "" },
                                        set: { secrets[secret.key] = $0 }))
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text(String(localized: "\u{8BBE}\u{7F6E}")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "\u{5B8C}\u{6210}")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "\u{4FDD}\u{5B58}")) {
                        center.saveSettings(addon: addon, settings: settings, secrets: secrets)
                        dismiss()
                    }
                }
            }
            .onAppear {
                declarations = try? center.declarations(for: addon.state.id)
                settings = addon.state.settings
                for secret in declarations?.secrets ?? [] {
                    secrets[secret.key] = center.secretValue(secret.key, addon: addon)
                }
            }
        }
    }
}

/// Editor plus the try box. A new script is staged for confirmation on save; an existing
/// one goes through the same page because editing can change its declarations.
struct ScriptAddonEditorView: View {
    @ObservedObject var center: ScriptAddonCenter
    let addon: ScriptAddonStore.Addon?
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var inputText = ""
    @State private var result: ScriptAddonBridge.TryRunResult?
    @State private var error: String?
    @State private var running = false
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $source)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                Divider()
                tryBox
            }
            .navigationTitle(
                Text(
                    addon == nil
                        ? String(localized: "\u{65B0}\u{5EFA}\u{811A}\u{672C}")
                        : String(localized: "\u{7F16}\u{8F91}\u{811A}\u{672C}"))
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "\u{53D6}\u{6D88}")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "\u{4FDD}\u{5B58}")) {
                        let data = Data(source.utf8)
                        if let addon {
                            center.saveEdited(addon: addon, source: data)
                        } else if center.stage(source: data) {
                            // The confirmation page opens next.
                        }
                        dismiss()
                    }
                }
            }
            .onAppear { load() }
            .onDisappear { runTask?.cancel() }
        }
    }

    private var tryBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(String(localized: "\u{8BD5}\u{6253}\u{6587}\u{5B57}"), text: $inputText)
                    .textFieldStyle(.roundedBorder)
                if running {
                    ProgressView()
                    Button(String(localized: "\u{53D6}\u{6D88}")) { cancelRun() }
                } else {
                    Button(String(localized: "\u{8BD5}\u{8FD0}\u{884C}")) { run() }
                }
            }
            if let result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(result.logs.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced))
                        }
                        ForEach(result.outputs, id: \.self) { output in
                            Text(String(localized: "\u{8F93}\u{51FA}\u{FF1A}") + output).font(
                                .system(.caption, design: .monospaced))
                        }
                        if let message = result.errorMessage {
                            Text(message).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                        if let line = result.errorLine {
                            Text(
                                String(
                                    format: String(localized: "\u{51FA}\u{9519}\u{884C}\u{53F7}\u{FF1A}%lld"),
                                    line)
                            )
                            .font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
    }

    private func load() {
        guard let addon else { return }
        source = center.addonSource(addon)
    }

    /// Runs the text currently in the editor, not the saved copy, so a new script can be
    /// tried before it is added and an edited body is tested as written. The engine runs off
    /// the main thread; the cancel button stops it between engine steps.
    private func run() {
        guard !running else { return }
        running = true
        result = nil
        error = nil
        let source = Data(self.source.utf8)
        let addon = self.addon
        let input = inputText
        runTask = Task {
            let outcome = await center.tryRun(source: source, addon: addon, inputText: input)
            if Task.isCancelled {
                running = false
                return
            }
            result = outcome
            error = outcome == nil ? center.errorMessage : nil
            running = false
        }
    }

    private func cancelRun() {
        runTask?.cancel()
        runTask = nil
        running = false
    }
}

/// Wrapper so the editor sheet works for both a stored addon and a new draft.
struct EditorTarget: Identifiable {
    let addon: ScriptAddonStore.Addon?
    var id: String { addon?.state.id ?? "new" }
}
