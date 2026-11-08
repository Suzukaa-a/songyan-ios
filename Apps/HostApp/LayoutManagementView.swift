import KeyboardCore
import LayoutKit
import SwiftUI
import UniformTypeIdentifiers

/// Layout management: layouts a keyboard pairs with first, then the rest (custom ones swipe to remove),
/// bundled presets an older catalog left out can be added, JSON import/export.
/// A layout only describes key positions; it is not an input scheme/dictionary.
struct LayoutManagementView: View {
    var keyboardNames = KeyboardNames()
    @ObservedObject private var manager = LayoutManager.shared
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var importedDraft: LayoutDefinition?
    @State private var savedFromSheet = false
    @State private var toast: String?
    @State private var pendingRemoval: [LayoutDefinition] = []

    var body: some View {
        List {
            storageSection
            pairedSection
            otherSection
            builtinSection
        }
        .navigationTitle(UserTerminology.keyboardLayout)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingImporter = true
                } label: {
                    Label(String(localized: "导入"), systemImage: "square.and.arrow.down")
                }
                .disabled(manager.isImporting)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    do { importedDraft = try await manager.readImport(url) } catch is CancellationError {} catch {
                        importError = LayoutManager.friendly(error, context: .imported)
                    }
                }
            } else if case .failure(let error) = result {
                importError = error.localizedDescription
            }
        }
        .alert(UserTerminology.keyboardLayout, isPresented: errorBinding) {
            Button(String(localized: "好"), role: .cancel) {
                manager.clearError()
                importError = nil
            }
        } message: {
            Text(importError ?? manager.lastError ?? "")
        }
        .onAppear { manager.reload() }
        .sheet(
            item: $importedDraft,
            onDismiss: {
                if savedFromSheet {
                    savedFromSheet = false
                    toast = String(localized: "已保存")
                }
            }
        ) { draft in
            NavigationStack { LayoutEditorView(layout: draft) { _ in savedFromSheet = true } }
        }
        .savedToast($toast)
        .confirmationDialog(removalTitle, isPresented: removalBinding, titleVisibility: .visible) {
            Button(String(localized: "移除布局"), role: .destructive) {
                let ids = pendingRemoval.map(\.id)
                pendingRemoval = []
                Task { for id in ids { await manager.remove(id) } }
            }
        } message: {
            Text("移除后要重新导入才能再用。")
        }
    }

    private var removalTitle: String {
        pendingRemoval.count == 1
            ? String(localized: "移除「\(pendingRemoval[0].name)」？")
            : String(localized: "移除 \(pendingRemoval.count) 个布局？")
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })
    }

    // MARK: - Storage location

    /// Shown only when something needs attention: an import in progress, or layouts the keyboard
    /// cannot read. While the location is still being resolved nothing is claimed.
    @ViewBuilder private var storageSection: some View {
        let sharedFailed = manager.location.map { !$0.isShared } ?? false
        if manager.isImporting || sharedFailed {
            Section {
                if manager.isImporting {
                    ProgressView(String(localized: "正在读取布局…"))
                }
                if sharedFailed {
                    Label(String(localized: "键盘暂时读不到这些布局，它们只保存在当前 App 里。"), systemImage: "exclamationmark.triangle")
                }
            }
        }
    }

    // MARK: - Layouts

    /// Keyboards that open on this layout: saved pairings plus every keyboard in 我的键盘, whose
    /// default layout counts even without a saved pairing.
    private func users(of layoutID: String) -> [KeyboardCompositionKey] {
        manager.registry.keyboards(usingLayout: layoutID, among: keyboardNames.active)
    }

    @ViewBuilder private var pairedSection: some View {
        let layouts = manager.registry.layouts.filter { !users(of: $0.id).isEmpty }
        if !layouts.isEmpty {
            Section(String(localized: "正在被键盘使用")) {
                ForEach(layouts) { layout in row(for: layout, isPaired: true) }
            }
        }
    }

    @ViewBuilder private var otherSection: some View {
        let others = manager.registry.layouts.filter { users(of: $0.id).isEmpty }
        if !others.isEmpty {
            Section(String(localized: "其他布局")) {
                ForEach(others) { layout in row(for: layout, isPaired: false) }
                    .onDelete { offsets in
                        // Confirm first: a removed layout can only be re-imported. Staged by value so
                        // indices cannot drift while the dialog is up.
                        pendingRemoval = offsets.compactMap { others.indices.contains($0) ? others[$0] : nil }
                    }
            }
        }
    }

    @ViewBuilder private var builtinSection: some View {
        let missing = BuiltinLayouts.all.filter { builtin in
            !manager.registry.layouts.contains { $0.id == builtin.id }
        }
        if !missing.isEmpty {
            Section {
                ForEach(missing) { builtin in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(builtin.name).font(.body)
                            Text(
                                KeyboardLayoutKind(rawValue: builtin.input.builtinLayout?.rawValue ?? "").map {
                                    UserTerminology.layoutName($0)
                                } ?? ""
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: "添加")) { Task { await manager.addBuiltin(builtin) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("内置布局")
            } footer: {
                Text("要换输入方式，请到「我的键盘」。")
            }
        }
    }

    // MARK: - Row

    private func row(for layout: LayoutDefinition, isPaired: Bool) -> some View {
        NavigationLink {
            LayoutDetailView(layoutID: layout.id, keyboardNames: keyboardNames)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(layout.listName).font(.body)
                Text(rowSubtitle(layout, isPaired: isPaired))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let usage = usage(layout) {
                    Text(usage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        // Bundled presets are the default main layouts, and a paired layout says so in its row;
        // neither can be swiped away.
        .deleteDisabled(isBuiltin(layout) || usage(layout) != nil)
    }

    private func rowSubtitle(_ layout: LayoutDefinition, isPaired: Bool) -> String {
        let source = isBuiltin(layout) ? String(localized: "内置") : String(localized: "自定义")
        let keyForm = keyFormDescription(layout)
        let mapping = layout.input.schemaID == nil || isPaired ? "" : String(localized: " · 仅限指定输入方式")
        return "\(source) · \(keyForm)\(mapping)"
    }

    /// Layout descriptions use the unified "keyboard layout" term and do not equate skins with encodings.
    private func keyFormDescription(_ layout: LayoutDefinition) -> String {
        let keyCount = layout.rows.reduce(0) { $0 + $1.keys.count }
        if let kind = KeyboardLayoutKind(rawValue: layout.input.builtinLayout?.rawValue ?? "") {
            return UserTerminology.layoutName(kind)
        }
        return String(localized: "\(layout.rows.count) 行 \(keyCount) 键")
    }

    private func isBuiltin(_ layout: LayoutDefinition) -> Bool {
        BuiltinLayouts.all.contains { $0.id == layout.id }
    }

    private func usage(_ layout: LayoutDefinition) -> String? {
        keyboardNames.usage(users(of: layout.id))
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { manager.lastError != nil || importError != nil },
            set: {
                if !$0 {
                    manager.clearError()
                    importError = nil
                }
            })
    }
}

/// Layout detail and entry to the visual editor.
struct LayoutDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = LayoutManager.shared
    @AppStorage(HostAppKeys.developerOptionsEnabled) private var developerOptions = false
    let layoutID: String
    var keyboardNames = KeyboardNames()

    @State private var confirmingRemoval = false
    @State private var confirmingPresetRestore = false

    @State private var exportDocument: LayoutJSONDocument?
    @State private var exporting = false
    @State private var exportError: String?
    @State private var editingDraft: LayoutDefinition?
    @State private var savedFromSheet = false
    @State private var toast: String?

    private var layout: LayoutDefinition? {
        manager.registry.layout(id: layoutID)
    }

    private var usage: String? {
        keyboardNames.usage(manager.registry.keyboards(usingLayout: layoutID, among: keyboardNames.active))
    }

    var body: some View {
        List {
            if let layout {
                Section(String(localized: "布局")) {
                    LabeledRow(label: String(localized: "名称"), value: layout.listName)
                    if developerOptions { LabeledRow(label: "ID", value: layout.id) }
                    LabeledRow(label: String(localized: "输入"), value: inputText(layout))
                    LabeledRow(
                        label: String(localized: "来源"),
                        value: isBuiltin(layout) ? String(localized: "内置") : String(localized: "自定义导入"))
                    LabeledRow(
                        label: String(localized: "按键"),
                        value: String(localized: "\(layout.rows.count) 行 · \(keyCount(layout)) 个"))
                    if let note = layout.displayNote, !note.isEmpty {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(String(localized: "编辑键位与副键")) { editingDraft = layout }
                    Button(String(localized: "复制为新布局并编辑")) {
                        editingDraft = BuiltinLayouts.persistingHandCuts(in: layout).copy()
                    }
                    if let preset = BuiltinLayouts.all.first(where: { $0.id == layout.id }), preset != layout {
                        Button(String(localized: "恢复预设")) { confirmingPresetRestore = true }
                    }
                    Button {
                        guard let data = manager.exportData(for: layout.id) else { return }
                        exportDocument = LayoutJSONDocument(data: data)
                        exporting = true
                    } label: {
                        Label(String(localized: "导出"), systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("编辑")
                }

                if !isBuiltin(layout) {
                    Section {
                        Button(String(localized: "移除布局"), role: .destructive) { confirmingRemoval = true }
                            .disabled(usage != nil)
                    } footer: {
                        if let usage { Text(usage + String(localized: "，换掉后才能移除。")) }
                    }
                }
            } else {
                Text("布局不存在或已被移除。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(layout?.name ?? String(localized: "布局"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            String(localized: "移除「\(layout?.name ?? String(localized: "这个布局"))」？"),
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button(String(localized: "移除布局"), role: .destructive) {
                Task {
                    await manager.remove(layoutID)
                    if manager.registry.layout(id: layoutID) == nil { dismiss() }
                }
            }
        } message: {
            Text("移除后要重新导入才能再用。")
        }
        .confirmationDialog(
            String(localized: "恢复预设？"), isPresented: $confirmingPresetRestore, titleVisibility: .visible
        ) {
            Button(String(localized: "恢复预设"), role: .destructive) {
                if let preset = BuiltinLayouts.all.first(where: { $0.id == layoutID }) {
                    Task { _ = await manager.saveDraft(preset) }
                }
            }
        } message: {
            Text("你对这个布局的修改会被清除。")
        }
        .sheet(
            item: $editingDraft,
            onDismiss: {
                if savedFromSheet {
                    savedFromSheet = false
                    toast = String(localized: "已保存")
                }
            }
        ) { draft in
            NavigationStack { LayoutEditorView(layout: draft) { _ in savedFromSheet = true } }
        }
        .savedToast($toast)
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: layout?.id ?? "layout"
        ) { result in
            if case .failure(let error) = result {
                exportError = String(localized: "键盘布局没有导出：\(error.localizedDescription)")
            }
        }
        .alert(UserTerminology.keyboardLayout, isPresented: exportErrorBinding) {
            Button(String(localized: "好"), role: .cancel) {
                manager.clearError()
                exportError = nil
            }
        } message: {
            Text(exportError ?? manager.lastError ?? "")
        }
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(
            get: { exportError != nil || manager.lastError != nil },
            set: {
                if !$0 {
                    exportError = nil
                    manager.clearError()
                }
            })
    }

    private func inputText(_ layout: LayoutDefinition) -> String {
        if let schema = layout.input.schemaID {
            return developerOptions ? String(localized: "仅限输入方式 \(schema)") : String(localized: "仅限指定输入方式")
        }
        if let kind = KeyboardLayoutKind(rawValue: layout.input.builtinLayout?.rawValue ?? "") {
            return UserTerminology.layoutName(kind)
        }
        return "—"
    }

    private func keyCount(_ layout: LayoutDefinition) -> Int {
        layout.rows.reduce(0) { $0 + $1.keys.count }
    }

    private func isBuiltin(_ layout: LayoutDefinition) -> Bool {
        BuiltinLayouts.all.contains { $0.id == layout.id }
    }
}

/// FileDocument wrapper: hands the layout JSON to the system export to Files.
struct LayoutJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension LayoutDefinition {
    /// The name layout lists show: a bundled layout is worded in the UI language while its shipped
    /// name is unchanged; every other layout keeps the name it was saved with.
    var listName: String {
        UserTerminology.layoutListName(
            id: id, name: name, shippedName: BuiltinLayouts.all.first { $0.id == id }?.name)
    }
}

extension KeyboardPageDefinition {
    /// The name page lists show, by the same rule as `LayoutDefinition.listName`.
    var listName: String {
        UserTerminology.pageListName(id: id, name: name, shippedName: KeyboardPagePresets.preset(id: id)?.name)
    }
}
