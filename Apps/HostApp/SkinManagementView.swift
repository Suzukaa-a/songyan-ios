import AppearanceKit
import CandidateKit
import KeyboardCore
import LayoutKit
import SkinKit
import SwiftUI
import UniformTypeIdentifiers

enum AppearancePreviewLoader {
    /// Reads the selected keyboard and its saved composition together for appearance previews.
    static func load() async throws -> (layouts: [LayoutDefinition], selectedID: String) {
        try await KeyboardResourceReadQueue.async {
            let activation = try KeyboardRecipeStore.activation()
            let registry = try LayoutStore(directoryURL: RimePaths.layoutStoreReadLocation().url).load()
            let key = KeyboardCompositionKey(
                inputMethodID: activation?.selectedSchemaID ?? "songyan_quanpin",
                layout: (activation?.selectedLayout ?? .qwerty26).builtinLayout)
            // An older catalog can lack a bundled preset the composition still selects.
            let layouts = registry.usableLayouts { _ in true }
            // The same pairing rule the keyboard and 我的键盘 use: an unsaved traditional keyboard
            // previews its own board instead of the 26-key default.
            let selected = HostLayoutAvailability.effectiveMainLayoutID(
                schemaID: key.inputMethodID, layout: KeyboardLayoutKind(key.layout),
                board: activation?.selectedBoard, descriptors: activation?.schemas ?? [], in: registry)
            return (layouts, layouts.contains { $0.id == selected } ? selected : layouts.first?.id ?? selected)
        }
    }

}

/// Appearance project file document (for export/import; one file = skin + candidate-bar layout + display mode).
struct SkinFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Keyboard appearance: **one** appearance project decides both the keyboard skin and the candidate-bar layout.
///
/// Production UI has only this one list, no standalone candidate-bar entry and no standalone candidate-bar "Apply".
struct SkinManagementView: View {
    @StateObject private var manager = AppearanceManager.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var importing = false
    @State private var importError: String?
    @State private var savedDestination: AppearanceDocument?
    @State private var showsSaved = false
    @State private var scalesKeyGaps = KeyGapScalingPreferences.current
    var body: some View {
        List {
            Section {
                if let message = manager.message { Text(message).font(.footnote) }
                if let error = manager.error { Text(error).font(.footnote).foregroundStyle(.red) }
                if let degraded = manager.appliedSourceNotice {
                    Text(degraded).font(.footnote).foregroundStyle(.orange)
                }
                if manager.error != nil {
                    Button(String(localized: "重试")) { manager.reload() }
                }
                if manager.isMutating { ProgressView(String(localized: "正在保存外观…")) }
            }
            if !manager.unreadable.isEmpty {
                Section(String(localized: "无法读取的外观")) {
                    ForEach(manager.unreadable) { item in
                        NavigationLink {
                            UnreadableAppearanceView(item: item)
                        } label: {
                            Label(item.fileName, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section(String(localized: "外观")) {
                ForEach(manager.projects) { project in
                    NavigationLink {
                        AppearanceDetailView(document: project)
                    } label: {
                        let rowLayout =
                            dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout(spacing: 12))
                        rowLayout {
                            SkinThumbnailBadge(
                                document: project,
                                isDark: colorScheme == .dark
                            )
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.displayName)
                                    .font(.body.weight(.medium))
                                Text(manager.candidateSummary(for: project))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let status = manager.applicationStatus(for: project) {
                                    Label(
                                        status,
                                        systemImage: status == UserTerminology.statusInUse
                                            ? "checkmark.circle.fill" : "circle.dashed"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Button {
                importing = true
            } label: {
                Label(String(localized: "导入外观文件"), systemImage: "square.and.arrow.down")
            }
            WebEditLink()
            Section {
                Toggle(String(localized: "大屏时放大间距和字号"), isOn: $scalesKeyGaps)
                    .onChange(of: scalesKeyGaps) { KeyGapScalingPreferences.current = scalesKeyGaps }
            } footer: {
                Text(String(localized: "横屏、展开的折叠屏和 iPad 上，按键间距、字号和圆角随按键一起变大。"))
            }
            NavigationLink {
                CandidateBarStyleView()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("候选栏样式")
                    Text("行高、展开方式与间距")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let importError { Text(importError).foregroundStyle(.red) }
        }.navigationTitle(UserTerminology.keyboardAppearance)
            .onAppear { manager.reload() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let imported = try AppearanceImportSupport.decode(documentAt: result.get()).normalized()
                    importError = nil
                    Task {
                        do {
                            // Re-importing an edited file replaces the earlier copy with the same identity.
                            try await manager.save(imported, replacing: true)
                            savedDestination = imported
                            showsSaved = true
                        } catch { importError = error.localizedDescription }
                    }
                } catch { importError = error.localizedDescription }
            }
            .navigationDestination(isPresented: $showsSaved) {
                if let savedDestination {
                    AppearanceDetailView(document: savedDestination, notice: String(localized: "已保存"))
                }
            }
            .onChange(of: showsSaved) { if !showsSaved { savedDestination = nil } }
    }
}

private struct UnreadableAppearanceView: View {
    let item: UnreadableAppearance
    @ObservedObject private var manager = AppearanceManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var exporting = false
    @State private var readingExport = false
    @State private var exportDocument = SkinFileDocument(data: Data())
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var confirmingRestore = false

    var body: some View {
        Form {
            Section {
                Label(
                    String(localized: "这个外观文件无法读取。"), systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                Text(item.fileName).font(.footnote.monospaced()).textSelection(.enabled)
                DisclosureGroup(String(localized: "详细信息")) {
                    Text(item.reason).font(.footnote).textSelection(.enabled)
                }
            }
            Section(String(localized: "恢复")) {
                if let recovery = manager.recoveryDocument(for: item) {
                    Button(
                        recovery.isBuiltin
                            ? String(localized: "恢复内置外观") : String(localized: "从正在使用的外观恢复")
                    ) { confirmingRestore = true }
                }
                Button(String(localized: "从文件恢复")) { importing = true }
            }
            Section {
                Button(String(localized: "导出原文件"), systemImage: "square.and.arrow.up") {
                    readingExport = true
                    Task {
                        defer { readingExport = false }
                        do {
                            exportDocument = SkinFileDocument(data: try await manager.exportUnreadable(item))
                            exporting = true
                        } catch { self.error = String(localized: "文件没有导出，请重试。") }
                    }
                }
                Button(
                    String(localized: "删除文件"), systemImage: "trash", role: .destructive
                ) { confirmingDelete = true }
            }
            if manager.isMutating || readingExport { ProgressView(String(localized: "正在处理…")) }
            if let error = error ?? manager.error { Text(error).foregroundStyle(.red) }
        }
        .disabled(manager.isMutating || readingExport)
        .navigationTitle(String(localized: "恢复外观"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            String(localized: "恢复这个外观？"), isPresented: $confirmingRestore,
            titleVisibility: .visible
        ) {
            Button(String(localized: "恢复外观"), role: .destructive) {
                Task { if await manager.restoreUnreadable(item) { dismiss() } }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text("原文件会替换为保存的外观。")
        }
        .confirmationDialog(
            String(localized: "删除这个外观文件？"), isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除文件"), role: .destructive) {
                Task { if await manager.removeUnreadable(item) { dismiss() } }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text("删除后无法恢复。你可以先导出原文件。")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                Task { if await manager.restoreUnreadable(item, from: url) { dismiss() } }
            case .failure: error = String(localized: "文件没有打开，请重新选择。")
            }
        }
        .fileExporter(
            isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: item.fileName
        ) { result in
            if case .failure = result { error = String(localized: "文件没有导出，请重试。") }
        }
    }
}

/// Appearance detail: preview (keyboard + candidate bar shown together), apply, export.
/// The candidate-bar layout and skin belong to this one document, so there is no second "Apply" here.
struct AppearanceDetailView: View {
    private let initialDocument: AppearanceDocument
    /// `notice` is shown once when the page appears, for a save that led here.
    init(document: AppearanceDocument, notice: String? = nil) {
        initialDocument = document
        _toast = State(initialValue: notice)
    }
    @State private var toast: String?
    @ObservedObject private var manager = AppearanceManager.shared
    private var document: AppearanceDocument {
        manager.projects.first(where: { $0.id == initialDocument.id }) ?? initialDocument
    }
    private var isInUse: Bool { manager.applicationStatus(for: document) == UserTerminology.statusInUse }
    @State private var layoutID = ""
    @State private var layouts: [LayoutDefinition] = []
    @State private var dark = false
    @State private var showsExpandedCandidates = false
    @State private var exporting = false
    @State private var exportDocument = SkinFileDocument(data: Data())
    @State private var error: String?
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Form {
            Section(String(localized: "预览")) {
                if layouts.isEmpty { DelayedSpinner() }
                Picker(String(localized: "键盘布局"), selection: $layoutID) {
                    ForEach(layouts) { Text($0.name).tag($0.id) }
                }
                Toggle(String(localized: "深色预览"), isOn: $dark)
                if let layout = layouts.first(where: { $0.id == layoutID }) {
                    KeyboardPreviewView(
                        layout: layout, skin: document.skin, candidateBar: document.candidateBar, previewDark: dark)
                }
            }
            Section(String(localized: "候选栏")) {
                Toggle(String(localized: "展开预览"), isOn: $showsExpandedCandidates)
                CandidateBarPreviewView(
                    bar: document.candidateBar, skin: document.skin,
                    expanded: showsExpandedCandidates, dark: dark)
            }
            Section {
                if let status = manager.applicationStatus(for: document) {
                    Label(status, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                Button(String(localized: "导出文件"), systemImage: "square.and.arrow.up") {
                    do {
                        exportDocument = SkinFileDocument(data: try document.encoded())
                        exporting = true
                    } catch { self.error = error.localizedDescription }
                }
                if !document.isBuiltin {
                    Button(
                        String(localized: "删除外观"), systemImage: "trash", role: .destructive
                    ) { confirmingDelete = true }
                }
            }
            if let error = error ?? manager.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .confirmationDialog(
            String(localized: "删除外观「\(document.displayName)」？"), isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除外观"), role: .destructive) {
                Task { if await manager.remove(document.id) { dismiss() } }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(
                manager.applicationStatus(for: document) != nil
                    ? "将从列表中删除，键盘会继续使用当前外观。" : "删除后无法恢复。")
        }
        .disabled(manager.isMutating)
        // The preview follows the system light/dark by default, matching the keyboard's actual behavior under "Follow System".
        .onAppear { dark = colorScheme == .dark }
        .task {
            guard layouts.isEmpty else { return }
            do {
                let preview = try await AppearancePreviewLoader.load()
                guard !Task.isCancelled else { return }
                layouts = preview.layouts
                layoutID = preview.selectedID
            } catch { self.error = String(localized: "无法读取预览布局，请重新打开外观。") }
        }
        // Inside the bottom inset, so confirmations rise above the apply button instead of covering it.
        .savedToast($toast)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    guard await manager.apply(document) else { return }
                    toast = manager.message
                    manager.message = nil
                }
            } label: {
                Group {
                    if manager.isMutating {
                        ProgressView()
                    } else if isInUse {
                        Label(UserTerminology.statusInUse, systemImage: "checkmark")
                    } else {
                        Text("应用")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(manager.isLoading || manager.isMutating || isInUse)
            .accessibilityIdentifier("appearance.apply")
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        }
        .navigationTitle(document.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $exporting, document: exportDocument, contentType: .json,
            defaultFilename: "\(document.id)\(AppearanceDocument.fileExtension)"
        ) { result in
            if case .failure(let e) = result { error = e.localizedDescription }
        }
    }
}

/// Appearance files are edited in the web editor; only the host app opens it.
private struct WebEditLink: View {
    var body: some View {
        Link(destination: URL(string: "https://suzukaa-a.github.io/songyan-themes/")!) {
            Label(String(localized: "在网页上编辑外观"), systemImage: "safari")
        }
    }
}

/// Appearance thumbnail badge: a miniature keyboard visual of panel background, key color, and accent color.
struct SkinThumbnailBadge: View {
    let document: AppearanceDocument
    var isDark: Bool = false

    var body: some View {
        let appearance = KeyboardAppearance(skin: document.skin, dark: isDark)
        ZStack {
            // Stand-in for the system keyboard surface
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(appearance.previewSurface)

            // Stacked miniature keys
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(appearance.color("key"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(appearance.color("border").opacity(0.5), lineWidth: 0.5)
                        )
                        .frame(width: 14, height: 11)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(appearance.color("accent"))
                        .frame(width: 14, height: 11)
                }

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(appearance.color("key"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(appearance.color("border").opacity(0.5), lineWidth: 0.5)
                    )
                    .frame(width: 22, height: 9)
            }
        }
        .frame(width: 44, height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }
}
