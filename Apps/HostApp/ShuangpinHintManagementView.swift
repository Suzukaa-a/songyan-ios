import KeyboardCore
import LayoutKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One hint preset file, for export and import.
struct ShuangpinHintFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Shuangpin hints over the standard 26-key letters page: one switch, a selected preset, DIY
/// editing, link/file import and export.
///
/// A display layer only; it never changes key positions, key actions or the engine.
struct ShuangpinHintManagementView: View {
    @StateObject private var manager = ShuangpinHintManager.shared
    /// Local switch state: the toggle responds immediately and reverts if the write fails.
    @State private var enabledDraft = false
    @State private var editing: ShuangpinHintPreset?
    @State private var importingFile = false
    @State private var enteringLink = false
    @State private var linkAddress = ""
    @State private var linkError: String?
    @State private var pendingRemoval: ShuangpinHintPreset?
    @State private var exportDocument = ShuangpinHintFileDocument(data: Data())
    @State private var exportName = "hints"
    @State private var exporting = false
    @State private var confirmsReset = false
    @State private var importingLink = false
    @State private var linkRequest = UUID()
    @State private var linkTask: Task<Void, Never>?

    var body: some View {
        List {
            switchSection
            if manager.canEdit {
                presetSection
                addSection
            }
            messageSection
        }
        .navigationTitle(String(localized: "双拼提示"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { manager.reload() }
        .sheet(item: $editing) { preset in
            NavigationStack { ShuangpinHintEditorView(preset: preset) }
        }
        .sheet(isPresented: $enteringLink) { linkSheet }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                Task { await manager.importPreset(fileAt: url) }
            case .failure:
                linkError = String(localized: "无法读取所选文件，请重新选择。")
            }
        }
        .fileExporter(
            isPresented: $exporting, document: exportDocument, contentType: .json,
            defaultFilename: exportName
        ) { result in
            if case .failure = result { linkError = String(localized: "导出失败，请重试。") }
        }
        .confirmationDialog(String(localized: "恢复默认双拼提示？"), isPresented: $confirmsReset, titleVisibility: .visible) {
            Button(String(localized: "恢复默认设置"), role: .destructive) {
                Task { await manager.resetToDefault() }
            }
        } message: {
            Text("自定义提示将全部删除，双拼提示会关闭。你可以先导出当前文件。")
        }
        .confirmationDialog(removalTitle, isPresented: removalBinding, titleVisibility: .visible) {
            Button(String(localized: "删除"), role: .destructive) {
                guard let preset = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await manager.removePreset(id: preset.id) }
            }
        }
    }

    // MARK: - Switch

    private var switchSection: some View {
        Section {
            Toggle(String(localized: "在字母键上显示双拼提示"), isOn: $enabledDraft)
                .disabled(!manager.canToggleHints)
                .accessibilityIdentifier("shuangpinHints.enabled")
                .onChange(of: enabledDraft) { _, value in
                    guard value != manager.isEnabled else { return }
                    Task {
                        if !(await manager.setEnabled(value)) { enabledDraft = manager.isEnabled }
                    }
                }
                .onChange(of: manager.isEnabled) { _, value in enabledDraft = value }
                .onAppear { enabledDraft = manager.isEnabled }
            if let preset = manager.snapshot?.activePreset {
                Label(String(localized: "当前提示：\(preset.name)"), systemImage: "textformat")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            storageLine
        } header: {
            Text("显示")
        } footer: {
            Text("请选择与你使用的双拼输入方式相符的提示。")
        }
    }

    private var storageLine: some View {
        Group {
            if manager.isLoading {
                Label(String(localized: "正在检查…"), systemImage: "clock")
            } else if let location = manager.location, !location.isShared {
                Label(String(localized: "键盘暂时读不到这些设置，提示不会显示。"), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Presets

    private var presetSection: some View {
        Section {
            ForEach(manager.presets) { preset in
                presetRow(preset)
            }
        } header: {
            Text("提示预设")
        } footer: {
            Text("轻点一个预设即可使用；「小鹤双拼提示」是内置预设，可复制后修改。")
        }
    }

    private func presetRow(_ preset: ShuangpinHintPreset) -> some View {
        Button {
            Task { await manager.select(preset.id) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name).foregroundStyle(.primary)
                    Text(
                        manager.snapshot?.isBuiltin(preset) == true
                            ? String(localized: "内置 · \(preset.letterCount) 个字母有提示")
                            : String(localized: "\(preset.letterCount) 个字母有提示")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if manager.selectedPresetID == preset.id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                exportName = preset.id
                exportDocument = ShuangpinHintFileDocument(data: manager.exportData(for: preset.id) ?? Data())
                exporting = true
            } label: {
                Label(String(localized: "导出"), systemImage: "square.and.arrow.up")
            }
            Button {
                editing = preset.copy(name: String(localized: "\(preset.name) 副本"))
            } label: {
                Label(String(localized: "复制"), systemImage: "plus.square.on.square")
            }
            Button {
                editing =
                    manager.snapshot?.isBuiltin(preset) == true
                    ? preset.copy(name: String(localized: "\(preset.name) 副本")) : preset
            } label: {
                Label(String(localized: "编辑"), systemImage: "pencil")
            }
            if manager.snapshot?.isBuiltin(preset) != true {
                Button(role: .destructive) {
                    pendingRemoval = preset
                } label: {
                    Label(String(localized: "删除"), systemImage: "trash")
                }
            }
        }
    }

    private var removalTitle: String {
        pendingRemoval.map { String(localized: "删除提示预设「\($0.name)」？") }
            ?? String(localized: "删除提示预设？")
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    // MARK: - Add / import

    private var addSection: some View {
        Section {
            Button {
                editing = ShuangpinHintPreset(
                    id: UUID().uuidString.lowercased(),
                    name: String(localized: "我的提示"), hints: [:])
            } label: {
                Label(String(localized: "新建提示预设"), systemImage: "plus")
            }
            Button {
                linkAddress = ""
                linkError = nil
                enteringLink = true
            } label: {
                Label(String(localized: "从链接导入"), systemImage: "link")
            }
            Button {
                importingFile = true
            } label: {
                Label(String(localized: "从文件导入"), systemImage: "square.and.arrow.down")
            }
            Button {
                exportName = "hints"
                exportDocument = ShuangpinHintFileDocument(data: manager.exportAllData() ?? Data())
                exporting = true
            } label: {
                Label(String(localized: "导出全部设置"), systemImage: "square.and.arrow.up")
            }
        }
    }

    private var linkSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://", text: $linkAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let linkError { Text(linkError).foregroundStyle(.red).font(.footnote) }
                    if importingLink { ProgressView(String(localized: "正在下载…")) }
                } footer: {
                    Text("请输入提示文件的链接。")
                }
                .disabled(importingLink)
            }
            .interactiveDismissDisabled(importingLink)
            .navigationTitle(String(localized: "从链接导入"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) {
                        linkRequest = UUID()
                        linkTask?.cancel()
                        importingLink = false
                        enteringLink = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "导入")) { importLink() }
                        .disabled(importingLink || linkAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("shuangpinHints.importLink")
                }
            }
        }
    }

    private func importLink() {
        guard !importingLink else { return }
        let request = UUID()
        let address = linkAddress
        linkRequest = request
        linkError = nil
        importingLink = true
        linkTask = Task { @MainActor in
            let succeeded = await manager.importPreset(address: address)
            guard linkRequest == request, !Task.isCancelled else { return }
            importingLink = false
            if succeeded { enteringLink = false } else { linkError = manager.lastError }
        }
    }

    // MARK: - Messages

    private var messageSection: some View {
        Section {
            if let error = manager.lastError {
                Text(error).foregroundStyle(.red).font(.footnote)
                Button(String(localized: "重试")) { manager.reload() }
                if manager.canRecover {
                    if let file = manager.recoveryFileURL {
                        ShareLink(String(localized: "导出当前文件"), item: file)
                    }
                    Button(String(localized: "恢复默认设置"), role: .destructive) { confirmsReset = true }
                        .disabled(manager.isBusy)
                        .font(.footnote)
                }
            } else if let message = manager.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if let linkError, !enteringLink { Text(linkError).foregroundStyle(.red).font(.footnote) }
        }
    }
}

/// DIY editor for one preset: a name and one hint per letter of the standard letters page.
///
/// A rejected preset keeps the sheet open with the reason, so a failed save never looks saved.
struct ShuangpinHintEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = ShuangpinHintManager.shared
    @State private var draft: ShuangpinHintPreset
    @State private var error: String?
    @State private var saving = false

    init(preset: ShuangpinHintPreset) {
        _draft = State(initialValue: preset)
    }

    var body: some View {
        Form {
            Section(String(localized: "名称")) {
                TextField(String(localized: "预设名称"), text: $draft.name)
                    .accessibilityIdentifier("shuangpinHints.editor.name")
            }
            ForEach(Array(ShuangpinHintPreset.letterRows.enumerated()), id: \.offset) { index, row in
                Section(String(localized: "第 \(index + 1) 行")) {
                    ForEach(row.map(String.init), id: \.self) { letter in
                        HStack {
                            Text(letter)
                                .font(.body.monospaced())
                                .frame(width: 24, alignment: .leading)
                            TextField(String(localized: "提示（可留空）"), text: binding(for: letter))
                                .keyboardType(.asciiCapable)
                                .accessibilityIdentifier("shuangpinHints.editor.key.\(letter)")
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .navigationTitle(draft.name.isEmpty ? String(localized: "提示预设") : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "取消")) { dismiss() }.disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "保存")) { save() }.disabled(saving)
                    .accessibilityIdentifier("shuangpinHints.savePreset")
            }
        }
    }

    private func binding(for letter: String) -> Binding<String> {
        Binding(
            get: { draft.hints[letter] ?? "" },
            set: { value in
                let trimmed = value
                if trimmed.isEmpty { draft.hints.removeValue(forKey: letter) } else { draft.hints[letter] = trimmed }
            })
    }

    private func save() {
        guard !saving else { return }
        saving = true
        error = nil
        // Finish marked input before capturing the draft to persist.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            await Task.yield()
            defer { saving = false }
            let replacing = manager.snapshot?.preset(id: draft.id) != nil
            if await manager.savePreset(draft.normalized(), replacing: replacing) {
                dismiss()
            } else {
                error = manager.lastError
            }
        }
    }
}
