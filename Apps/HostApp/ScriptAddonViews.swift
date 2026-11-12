import ScriptAddonKit
import SwiftUI

enum ScriptAddonURLValidation {
    static func isValidHTTPS(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
            url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty
        else { return false }
        return true
    }
}

@MainActor
private func scriptName(_ center: ScriptAddonCenter, _ addon: ScriptAddonStore.Addon) -> String {
    (try? center.declarations(for: addon.state.id).name)
        ?? String(localized: "未命名脚本")
}

@MainActor
private func scriptDescription(
    _ center: ScriptAddonCenter, _ addon: ScriptAddonStore.Addon
) -> String? {
    (try? center.declarations(for: addon.state.id))?.summary
}

@MainActor
private func scriptConnectHosts(
    _ center: ScriptAddonCenter, _ addon: ScriptAddonStore.Addon
) -> [String] {
    (try? center.declarations(for: addon.state.id).connectHosts) ?? []
}

@MainActor
private func scriptNeedsAudio(
    _ center: ScriptAddonCenter, _ addon: ScriptAddonStore.Addon
) -> Bool {
    (try? center.declarations(for: addon.state.id).needsAudio) ?? false
}

/// The confirmation page every addition passes through: what the script is called, what
/// text it can read, which sites it may connect to and which settings it expects. A link
/// import or an update that changes any of those asks again here.
struct ScriptAddonConfirmationView: View {
    @ObservedObject var center: ScriptAddonCenter
    let draft: ScriptAddonCenter.Draft
    @Environment(\.dismiss) private var dismiss
    @State private var settings: [String: String] = [:]
    @State private var secrets: [String: String] = [:]
    @State private var showAudioDetails = false

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "脚本")) {
                    // The name is a script declaration, not a local label: renaming it here
                    // would disagree with the header the keyboard runs.
                    LabeledContent(String(localized: "名字"), value: draft.declarations.name)
                }
                Section(String(localized: "它能读到什么")) {
                    LabeledContent(
                        String(localized: "文字"),
                        value: String(localized: "选中的文字，没有选中时是光标前的一段"))
                    if draft.declarations.needsAudio {
                        LabeledContent(
                            String(localized: "录音"), value: String(localized: "录音不可用"))
                        Button(String(localized: "了解详情")) { showAudioDetails = true }
                            .font(.footnote)
                    } else {
                        LabeledContent(
                            String(localized: "录音"),
                            value: String(localized: "不使用麦克风"))
                    }
                }
                Section(String(localized: "会连这些网站")) {
                    if draft.declarations.connectHosts.isEmpty {
                        Text(String(localized: "不联网"))
                    } else {
                        ForEach(draft.declarations.connectHosts, id: \.self) { host in
                            Text(host).font(.system(.body, design: .monospaced))
                        }
                    }
                }
                if !draft.declarations.settings.isEmpty {
                    Section(String(localized: "设置")) {
                        ForEach(draft.declarations.settings, id: \.key) { setting in
                            ScriptSettingField(
                                setting: setting,
                                value: Binding(
                                    get: { settings[setting.key] ?? "" },
                                    set: { settings[setting.key] = $0 }))
                        }
                    }
                }
                if !draft.declarations.secrets.isEmpty {
                    Section(String(localized: "密钥")) {
                        ForEach(draft.declarations.secrets, id: \.key) { secret in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(secret.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                SecureField(
                                    "",
                                    text: Binding(
                                        get: { secrets[secret.key] ?? "" },
                                        set: { secrets[secret.key] = $0 })
                                )
                                .textContentType(.password)
                                .accessibilityLabel(secret.label)
                            }
                        }
                        Text(String(localized: "密钥保存到钥匙串，不写进脚本文件"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(
                Text(
                    draft.isReplacement
                        ? String(localized: "确认更新")
                        : String(localized: "确认添加"))
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
                    Button(String(localized: "取消")) {
                        center.cancelPending()
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    center.confirm(draft, settings: settings, secretValues: secrets)
                    dismiss()
                } label: {
                    Text(
                        draft.isReplacement
                            ? String(localized: "更新") : String(localized: "添加")
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!invalidURLSettingKeys.isEmpty)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .alert(String(localized: "录音不可用"), isPresented: $showAudioDetails) {
                Button(String(localized: "好")) {}
            } message: {
                Text(ScriptAddonCenter.audioUnavailableNote)
            }
        }
    }

    private var invalidURLSettingKeys: [String] {
        draft.declarations.settings.compactMap { setting in
            guard setting.kind == .url else { return nil }
            let value = settings[setting.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty || ScriptAddonURLValidation.isValidHTTPS(value) ? nil : setting.key
        }
    }
}

/// One editable setting with a label that stays visible after the field is filled.
struct ScriptSettingField: View {
    let setting: ScriptDeclarations.Setting
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(setting.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: $value)
                .textFieldStyle(.roundedBorder)
                .keyboardType(setting.kind == .url ? .URL : .default)
                .textInputAutocapitalization(setting.kind == .url ? .never : .sentences)
                .autocorrectionDisabled(setting.kind == .url)
                .accessibilityLabel(setting.label)
            if setting.kind == .url, !value.isEmpty,
                !ScriptAddonURLValidation.isValidHTTPS(value)
            {
                Text(String(localized: "请输入有效的 HTTPS 链接"))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// One stored script's detail page: identity, what it can read and connect to, its settings
/// and secrets (a child page), and the actions that change it.
struct ScriptAddonDetailView: View {
    @ObservedObject var center: ScriptAddonCenter
    let addon: ScriptAddonStore.Addon
    @Environment(\.dismiss) private var dismiss
    @State private var declarations: ScriptDeclarations?
    @State private var showAudioDetails = false
    @State private var showDelete = false
    @State private var editing = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(declarations?.name ?? String(localized: "未命名脚本"))
                        .font(.title2.weight(.semibold))
                    if let summary = declarations?.summary, !summary.isEmpty {
                        Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Toggle(
                    isOn: Binding(
                        get: { addon.state.enabled },
                        set: { center.setEnabled($0, addon: addon) })
                ) {
                    Text(String(localized: "启用"))
                }
                .accessibilityValue(
                    addon.state.enabled
                        ? String(localized: "已启用") : String(localized: "已停用")
                )
                .accessibilityLabel(
                    String(
                        format: String(localized: "启用 %@"),
                        declarations?.name ?? addon.state.id))
            }
            if center.needsReconfirmation(addon) {
                Section {
                    Label {
                        Text(String(localized: "脚本要求有变化，需要重新确认"))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                    Button(String(localized: "重新确认")) { center.reconfirm(addon: addon) }
                }
            }
            Section(String(localized: "它能读到什么")) {
                LabeledContent(
                    String(localized: "文字"),
                    value: String(localized: "选中的文字，没有选中时是光标前的一段"))
                if declarations?.needsAudio == true {
                    LabeledContent(String(localized: "录音"), value: String(localized: "录音不可用"))
                    Button(String(localized: "了解详情")) { showAudioDetails = true }
                        .font(.footnote)
                } else {
                    LabeledContent(String(localized: "录音"), value: String(localized: "不使用麦克风"))
                }
            }
            Section(String(localized: "会连这些网站")) {
                if let hosts = declarations?.connectHosts, !hosts.isEmpty {
                    ForEach(hosts, id: \.self) { host in
                        Text(host).font(.system(.body, design: .monospaced))
                    }
                } else {
                    Text(String(localized: "不联网"))
                }
            }
            Section {
                NavigationLink {
                    ScriptAddonSettingsView(center: center, addon: addon)
                } label: {
                    LabeledContent(
                        String(localized: "设置与密钥"),
                        value: settingsSummary)
                }
                .accessibilityHint(String(localized: "输入此脚本需要的设置和密钥"))
            }
            Section {
                Button(String(localized: "编辑脚本")) { editing = true }
                if center.updatingID == addon.state.id {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(String(localized: "检查更新"))
                    }
                    .font(.footnote)
                } else {
                    Button(String(localized: "检查更新")) { center.checkForUpdate(addon: addon) }
                }
                if let data = center.exportData(addon: addon) {
                    ShareLink(item: scriptFile(data, title: declarations?.name ?? addon.state.id)) {
                        Text(String(localized: "导出脚本"))
                    }
                }
                Button(String(localized: "移除脚本"), role: .destructive) { showDelete = true }
            }
        }
        .navigationTitle(declarations?.name ?? String(localized: "脚本"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { declarations = try? center.declarations(for: addon.state.id) }
        .onChange(of: center.addons) { declarations = try? center.declarations(for: addon.state.id) }
        .sheet(isPresented: $editing) {
            ScriptAddonEditorView(center: center, addon: addon)
        }
        .alert(String(localized: "录音不可用"), isPresented: $showAudioDetails) {
            Button(String(localized: "好")) {}
        } message: {
            Text(ScriptAddonCenter.audioUnavailableNote)
        }
        .confirmationDialog(
            String(localized: "移除脚本"),
            isPresented: $showDelete
        ) {
            Button(String(localized: "删除"), role: .destructive) {
                center.delete(addon: addon)
                dismiss()
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "脚本的设置和密钥也会一起删除，且无法撤销。"))
        }
    }

    private var settingsSummary: String {
        let settingsCount = declarations?.settings.count ?? 0
        let secretCount = declarations?.secrets.count ?? 0
        if settingsCount == 0, secretCount == 0 {
            return String(localized: "不需要设置")
        }
        return String(
            format: String(localized: "%lld 项设置 · %lld 个密钥"), settingsCount, secretCount)
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
        Form {
            if let declarations {
                if declarations.settings.isEmpty, declarations.secrets.isEmpty {
                    ContentUnavailableView(
                        String(localized: "不需要设置"),
                        systemImage: "slider.horizontal.3")
                }
                if !declarations.settings.isEmpty {
                    Section(String(localized: "设置")) {
                        ForEach(declarations.settings, id: \.key) { setting in
                            ScriptSettingField(
                                setting: setting,
                                value: Binding(
                                    get: { settings[setting.key] ?? "" },
                                    set: { settings[setting.key] = $0 }))
                        }
                    }
                }
                if !declarations.secrets.isEmpty {
                    Section(String(localized: "密钥")) {
                        ForEach(declarations.secrets, id: \.key) { secret in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(secret.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                SecureField(
                                    "",
                                    text: Binding(
                                        get: { secrets[secret.key] ?? "" },
                                        set: { secrets[secret.key] = $0 })
                                )
                                .textContentType(.password)
                                .accessibilityLabel(secret.label)
                            }
                        }
                        Text(String(localized: "密钥保存到钥匙串，不写进脚本文件"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "脚本设置"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "完成")) { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                center.saveSettings(addon: addon, settings: settings, secrets: secrets)
                dismiss()
            } label: {
                Text(String(localized: "保存")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!hasChanges)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .onAppear {
            declarations = try? center.declarations(for: addon.state.id)
            settings = addon.state.settings
            for secret in declarations?.secrets ?? [] {
                secrets[secret.key] = center.secretValue(secret.key, addon: addon)
            }
        }
    }

    private var hasChanges: Bool {
        if settings != addon.state.settings { return true }
        for secret in declarations?.secrets ?? [] {
            let original = center.secretValue(secret.key, addon: addon)
            if (secrets[secret.key] ?? "") != original { return true }
        }
        return false
    }
}

/// Editor plus the try box. A new script is staged for confirmation on save; an existing
/// one goes through the same page because editing can change its declarations.
struct ScriptAddonEditorView: View {
    @ObservedObject var center: ScriptAddonCenter
    let addon: ScriptAddonStore.Addon?
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var loadedSource = ""
    @State private var inputText = ""
    @State private var result: ScriptAddonBridge.TryRunResult?
    @State private var error: String?
    @State private var running = false
    @State private var runTask: Task<Void, Never>?
    @State private var showDiscard = false
    @State private var copied = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var trimmedSource: String {
        source.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var hasUnsavedChanges: Bool { source != loadedSource }
    private var canSubmit: Bool { !trimmedSource.isEmpty && !running }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        editor
                        resultSection
                    }
                    .padding()
                }
                Divider()
                tryBox
            }
            .navigationTitle(
                Text(
                    addon == nil
                        ? String(localized: "新建脚本")
                        : String(localized: "编辑脚本"))
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) {
                        if hasUnsavedChanges { showDiscard = true } else { dismiss() }
                    }
                }
            }
            .onAppear {
                load()
                #if DEBUG
                    // Screenshot probe only; Release has no auto-run path.
                    if ProcessInfo.processInfo.environment["SONGYAN_SCRIPT_VISUAL_RUN"] == "1" {
                        run()
                    }
                #endif
            }
            .onDisappear { runTask?.cancel() }
            .confirmationDialog(
                String(localized: "放弃未保存的修改？"),
                isPresented: $showDiscard
            ) {
                Button(String(localized: "放弃"), role: .destructive) { dismiss() }
                Button(String(localized: "继续编辑"), role: .cancel) {}
            }
            .alert(
                center.errorMessage ?? "",
                isPresented: Binding(
                    get: { center.errorMessage != nil },
                    set: { if !$0 { center.errorMessage = nil } })
            ) {
                Button(String(localized: "好")) { center.errorMessage = nil }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $source)
                    .font(.system(.body, design: .monospaced))
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .frame(minHeight: 240)
                    .scrollContentBackground(.hidden)
                if trimmedSource.isEmpty {
                    Text(String(localized: "在这里粘贴或编写脚本"))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                }
            }
            if trimmedSource.isEmpty {
                Button(String(localized: "插入最小示例")) {
                    source = ScriptAddonCenter.minimalExample()
                    loadedSource = source
                }
                .font(.footnote)
                Text(String(localized: "脚本以 // @api 1 开头"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result {
                if !result.logs.isEmpty {
                    Text(String(localized: "日志"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(result.logs.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }
                if !result.outputs.isEmpty {
                    Text(String(localized: "结果"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(result.outputs.enumerated()), id: \.offset) { _, output in
                        Text(output.isEmpty ? String(localized: "（没有返回内容）") : output)
                            .font(.system(.body, design: .monospaced))
                    }
                    Button(copied ? String(localized: "已复制") : String(localized: "复制结果")) {
                        UIPasteboard.general.string = result.outputs.joined(separator: "\n")
                        copied = true
                    }
                    .font(.footnote)
                }
                if let message = result.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                if let line = result.errorLine {
                    Text(
                        String(
                            format: String(localized: "出错行号：%lld"), line)
                    )
                    .font(.footnote).foregroundStyle(.red)
                }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var tryBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize >= .accessibility1 {
                TextField(String(localized: "试打文字"), text: $inputText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(String(localized: "保存")) { save() }
                        .disabled(trimmedSource.isEmpty || running)
                    if running {
                        ProgressView()
                        Text(String(localized: "运行中…")).font(.caption)
                        Button(String(localized: "取消")) { cancelRun() }
                    } else {
                        Button(String(localized: "试运行")) { run() }
                            .disabled(trimmedSource.isEmpty)
                    }
                }
            } else {
                HStack {
                    TextField(String(localized: "试打文字"), text: $inputText)
                        .textFieldStyle(.roundedBorder)
                    if running {
                        ProgressView()
                        Text(String(localized: "运行中…")).font(.caption).foregroundStyle(.secondary)
                        Button(String(localized: "取消")) { cancelRun() }
                    } else {
                        Button(String(localized: "保存")) { save() }
                            .disabled(trimmedSource.isEmpty)
                        Button(String(localized: "试运行")) { run() }
                            .disabled(trimmedSource.isEmpty)
                    }
                }
            }
        }
        .padding()
    }

    private func save() {
        let data = Data(source.utf8)
        center.errorMessage = nil
        if let addon {
            center.saveEdited(addon: addon, source: data)
        } else if center.stage(source: data) {
            // The confirmation page opens next.
        } else {
            return
        }
        if center.errorMessage == nil { dismiss() }
    }

    private func load() {
        guard let addon else { return }
        source = center.addonSource(addon)
        loadedSource = source
    }

    /// Runs the text currently in the editor, not the saved copy, so a new script can be
    /// tried before it is added and an edited body is tested as written. The engine runs off
    /// the main thread; the cancel button stops it between engine steps.
    private func run() {
        guard !running, !trimmedSource.isEmpty else { return }
        running = true
        result = nil
        error = nil
        copied = false
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
            center.errorMessage = nil
            running = false
            if let error { UIAccessibility.post(notification: .announcement, argument: error) }
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

func scriptFile(_ data: Data, title: String) -> URL {
    let safe = title.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(safe.isEmpty ? "script" : safe)
        .appendingPathExtension("js")
    try? data.write(to: url, options: .atomic)
    return url
}
