import Foundation
import QuickContentKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One exported tool file. The bytes come from ToolStore's encoder, so re-importing the file
/// restores exactly what was exported.
struct KeyboardToolFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Settings > 键盘工具: the whole tool catalog in one list.
///
/// Enable and disable, pin at most two tools to the toolbar, reorder, delete with one undo, import
/// and export files, and create a tool by copying an example and editing its name and steps.
/// A display over KeyboardToolsCenter; no file work happens here.
struct KeyboardToolsSettingsView: View {
    @StateObject private var center = KeyboardToolsCenter.shared

    @State private var editingDraft: KeyboardToolDraft?
    @State private var pendingRemoval: ToolStoreEntry?
    @State private var importingFile = false
    @State private var exporting = false
    @State private var exportDocument = KeyboardToolFileDocument(data: Data())
    @State private var exportName = ""
    @State private var failureNote: String?

    var body: some View {
        List {
            if center.isLoading {
                Section {
                    ProgressView(copy("keyboardTools.status.loading"))
                }
            } else {
                toolsSection
                undoSection
                addSection
            }
            messageSection
        }
        .navigationTitle(copy("keyboardTools.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if center.entries.count > 1 {
                EditButton()
            }
        }
        .task { center.loadIfNeeded() }
        .sheet(item: $editingDraft) { draft in
            NavigationStack {
                KeyboardToolEditorView(draft: draft)
            }
        }
        .confirmationDialog(removalTitle, isPresented: removalBinding, titleVisibility: .visible) {
            Button(copy("keyboardTools.action.delete"), role: .destructive) {
                guard let entry = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await center.deleteTool(id: entry.id) }
            }
        } message: {
            Text(copy("keyboardTools.delete.confirmMessage"))
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                Task { await center.importTool(fileAt: url) }
            case .failure:
                failureNote = copy("keyboardTools.error.importFile")
            }
        }
        .fileExporter(
            isPresented: $exporting, document: exportDocument, contentType: .json,
            defaultFilename: exportName
        ) { result in
            if case .failure = result {
                failureNote = copy("keyboardTools.error.export")
            }
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        Section {
            if let location = center.location, !location.isShared {
                Label(copy("keyboardTools.storage.local"), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if center.entries.isEmpty {
                Text(copy("keyboardTools.empty"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(center.entries) { entry in
                row(entry)
            }
            .onMove(perform: move)
        } header: {
            Text(copy("keyboardTools.section.tools"))
        } footer: {
            Text(copy("keyboardTools.section.tools.footer"))
        }
    }

    private func row(_ entry: ToolStoreEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(center.displayName(of: entry))
                Text(detailLine(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                Task { await center.setPinned(!entry.isPinned, toolID: entry.id) }
            } label: {
                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(entry.isPinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copy(entry.isPinned ? "keyboardTools.action.unpin" : "keyboardTools.action.pin"))
            .accessibilityIdentifier("keyboardTools.pin." + entry.id)
            Toggle(
                "",
                isOn: Binding(
                    get: { entry.isEnabled },
                    set: { value in
                        Task { await center.setEnabled(value, toolID: entry.id) }
                    })
            )
            .labelsHidden()
            .accessibilityLabel(copy("keyboardTools.row.enable"))
            .accessibilityIdentifier("keyboardTools.enabled." + entry.id)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !entry.isBuiltin {
                Button(role: .destructive) {
                    pendingRemoval = entry
                } label: {
                    Label(copy("keyboardTools.action.delete"), systemImage: "trash")
                }
            }
            Button {
                exportTool(entry)
            } label: {
                Label(copy("keyboardTools.action.export"), systemImage: "square.and.arrow.up")
            }
            if entry.isBuiltin {
                Button {
                    copyExample(entry)
                } label: {
                    Label(copy("keyboardTools.action.copy"), systemImage: "plus.square.on.square")
                }
            } else {
                Button {
                    edit(entry)
                } label: {
                    Label(copy("keyboardTools.action.edit"), systemImage: "pencil")
                }
            }
        }
        .contextMenu {
            if entry.isBuiltin {
                Button {
                    copyExample(entry)
                } label: {
                    Label(copy("keyboardTools.action.copy"), systemImage: "plus.square.on.square")
                }
            } else {
                Button {
                    edit(entry)
                } label: {
                    Label(copy("keyboardTools.action.edit"), systemImage: "pencil")
                }
            }
            Button {
                exportTool(entry)
            } label: {
                Label(copy("keyboardTools.action.export"), systemImage: "square.and.arrow.up")
            }
            if !entry.isBuiltin {
                Button(role: .destructive) {
                    pendingRemoval = entry
                } label: {
                    Label(copy("keyboardTools.action.delete"), systemImage: "trash")
                }
            }
        }
    }

    private func detailLine(_ entry: ToolStoreEntry) -> String {
        let key = entry.isBuiltin ? "keyboardTools.row.builtin" : "keyboardTools.row.user"
        return String(format: copy(key), entry.definition.steps.count)
    }

    private var removalTitle: String {
        guard let pendingRemoval else { return copy("keyboardTools.action.delete") }
        return String(
            format: copy("keyboardTools.delete.confirmTitle"), center.displayName(of: pendingRemoval))
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } })
    }

    // MARK: - Undo

    @ViewBuilder private var undoSection: some View {
        if let deletion = center.undoableDeletion {
            Section {
                Button {
                    Task { await center.undoDelete() }
                } label: {
                    Label(
                        String(
                            format: copy("keyboardTools.action.undoNamed"),
                            center.displayName(of: deletion.definition)),
                        systemImage: "arrow.uturn.backward")
                }
                .accessibilityIdentifier("keyboardTools.undo")
            } footer: {
                Text(copy("keyboardTools.undoHint"))
            }
        }
    }

    // MARK: - Add

    private var addSection: some View {
        Section {
            Menu {
                ForEach(center.entries.filter(\.isBuiltin)) { entry in
                    Button(center.displayName(of: entry)) { copyExample(entry) }
                }
            } label: {
                Label(copy("keyboardTools.action.createFromExample"), systemImage: "plus.square.on.square")
            }
            .disabled(center.entries.filter(\.isBuiltin).isEmpty)
            .accessibilityIdentifier("keyboardTools.create")
            Button {
                failureNote = nil
                importingFile = true
            } label: {
                Label(copy("keyboardTools.action.import"), systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("keyboardTools.import")
        } header: {
            Text(copy("keyboardTools.section.add"))
        }
    }

    // MARK: - Messages

    private var messageSection: some View {
        Section {
            if let error = center.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button(copy("keyboardTools.action.retry")) { center.reload() }
                    .accessibilityIdentifier("keyboardTools.retry")
            } else if let message = center.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if let failureNote {
                Text(failureNote).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Actions

    private func move(from source: IndexSet, to destination: Int) {
        let entries = center.entries
        guard let from = source.first, entries.indices.contains(from) else { return }
        let target = destination > from ? destination - 1 : destination
        let id = entries[from].id
        Task { await center.moveTool(id: id, toIndex: target) }
    }

    private func edit(_ entry: ToolStoreEntry) {
        editingDraft = KeyboardToolDraft(definition: entry.definition)
    }

    private func copyExample(_ entry: ToolStoreEntry) {
        Task {
            guard let copy = await center.duplicateTool(id: entry.id) else { return }
            editingDraft = KeyboardToolDraft(definition: copy)
        }
    }

    private func exportTool(_ entry: ToolStoreEntry) {
        Task {
            guard let data = await center.exportData(id: entry.id) else { return }
            exportDocument = KeyboardToolFileDocument(data: data)
            exportName = entry.id + ".songyantool"
            exporting = true
        }
    }

    private func copy(_ key: String) -> String {
        KeyboardToolsCopy.text(key)
    }
}

/// Editor for one user tool: a name and the steps the file format has.
///
/// v1 offers no visual regular-expression debugging, only the parameters of each step; a refused
/// draft keeps the sheet open with the reason, so a failed save never looks saved.
struct KeyboardToolEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var center = KeyboardToolsCenter.shared

    @State private var draft: KeyboardToolDraft
    @State private var error: String?
    @State private var saving = false

    init(draft: KeyboardToolDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        Form {
            Section(copy("keyboardTools.editor.name")) {
                TextField(copy("keyboardTools.editor.namePlaceholder"), text: $draft.editableName)
                    .accessibilityIdentifier("keyboardTools.editor.name")
            }
            ForEach($draft.steps) { $step in
                Section {
                    stepEditor($step)
                } header: {
                    Text(stepTitle(for: step))
                }
            }
            .onDelete { draft.steps.remove(atOffsets: $0) }
            Section {
                Menu {
                    ForEach(KeyboardToolStepType.allCases) { type in
                        Button(copy("keyboardTools.step.type." + type.rawValue)) {
                            draft.addStep(type)
                        }
                    }
                } label: {
                    Label(copy("keyboardTools.action.addStep"), systemImage: "plus")
                }
                .accessibilityIdentifier("keyboardTools.addStep")
            }
            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .navigationTitle(draft.editableName.isEmpty ? copy("keyboardTools.title") : draft.editableName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(copy("keyboardTools.action.cancel")) { dismiss() }
                    .disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(copy("keyboardTools.action.save")) { save() }
                    .disabled(saving)
                    .accessibilityIdentifier("keyboardTools.save")
            }
        }
    }

    @ViewBuilder
    private func stepEditor(_ step: Binding<KeyboardToolStepDraft>) -> some View {
        switch step.wrappedValue.type {
        case .opencc:
            Picker(copy("keyboardTools.editor.opencc"), selection: step.openCCConfig) {
                ForEach(OpenCCToolConfig.allCases, id: \.self) { config in
                    Text(openCCLabel(config)).tag(config)
                }
            }
        case .replace:
            TextField(copy("keyboardTools.editor.pattern"), text: step.pattern)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField(copy("keyboardTools.editor.replacement"), text: step.replacement)
            Text(copy("keyboardTools.editor.hint.replace"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .map:
            Text(copy("keyboardTools.editor.map"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextEditor(text: step.mapLines)
                .frame(minHeight: 90)
                .font(.body.monospaced())
            Text(copy("keyboardTools.editor.hint.map"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .caseTransform:
            Picker(copy("keyboardTools.editor.case"), selection: step.caseMode) {
                Text(copy("keyboardTools.case.upper")).tag(ToolStep.CaseMode.upper)
                Text(copy("keyboardTools.case.lower")).tag(ToolStep.CaseMode.lower)
                Text(copy("keyboardTools.case.capitalize")).tag(ToolStep.CaseMode.capitalize)
            }
        case .width:
            Picker(copy("keyboardTools.editor.width"), selection: step.widthMode) {
                Text(copy("keyboardTools.width.toHalf")).tag(ToolStep.WidthMode.toHalf)
                Text(copy("keyboardTools.width.toFull")).tag(ToolStep.WidthMode.toFull)
            }
        case .template:
            TextField(copy("keyboardTools.editor.template"), text: step.pattern)
            Text(copy("keyboardTools.editor.hint.template"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func stepTitle(for step: KeyboardToolStepDraft) -> String {
        let index = draft.steps.firstIndex { $0.id == step.id } ?? 0
        return String(format: copy("keyboardTools.editor.step.title"), index + 1)
    }

    private func openCCLabel(_ config: OpenCCToolConfig) -> String {
        let key = "keyboardTools.opencc." + config.rawValue
        let label = copy(key)
        return label == key ? config.rawValue : label
    }

    private func save() {
        guard !saving else { return }
        saving = true
        error = nil
        // Finish marked text input before the draft is captured for saving.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            await Task.yield()
            defer { saving = false }
            if await center.saveDraft(draft) {
                dismiss()
            } else {
                error = center.lastError
            }
        }
    }

    private func copy(_ key: String) -> String {
        KeyboardToolsCopy.text(key)
    }
}
