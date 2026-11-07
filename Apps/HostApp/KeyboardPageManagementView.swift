import KeyboardCore
import LayoutKit
import SwiftUI

struct KeyboardPageManagementView: View {
    var keyboardNames = KeyboardNames()
    @ObservedObject private var manager = LayoutManager.shared
    @State private var editing: KeyboardPageDefinition?
    @State private var savedFromSheet = false
    @State private var toast: String?
    @State private var removing: KeyboardPageDefinition?
    @State private var restoring: KeyboardPageDefinition?
    @State private var error: String?
    @State private var busyMessage: String?

    var body: some View {
        List {
            ForEach(KeyboardPageKind.allCases, id: \.self) { kind in
                Section(kind.title) {
                    ForEach(manager.registry.pages.filter { $0.kind == kind }) { page in
                        row(page, usage: keyboardNames.usage(manager.registry.keyboards(usingPage: page.id)))
                    }
                }
            }
        }
        .disabled(busyMessage != nil)
        .overlay { if let busyMessage { ProgressView(busyMessage) } }
        .navigationTitle(UserTerminology.pageLibrary)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(
            item: $editing,
            onDismiss: {
                if savedFromSheet {
                    savedFromSheet = false
                    toast = String(localized: "已保存")
                }
            }
        ) { page in
            NavigationStack { KeyboardPageEditorView(page: page) { _ in savedFromSheet = true } }
        }
        .savedToast($toast)
        .confirmationDialog(
            String(localized: "删除「\(removing?.name ?? "")」？"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除页面"), role: .destructive) {
                guard let page = removing else { return }
                removing = nil
                Task {
                    if !(await manager.removePage(page.id)) {
                        error = manager.lastError
                        manager.clearError()
                    }
                }
            }
        }
        .confirmationDialog(
            String(localized: "恢复预设？"),
            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "恢复预设"), role: .destructive) {
                guard let preset = restoring else { return }
                restoring = nil
                busyMessage = String(localized: "正在恢复预设…")
                Task {
                    defer { busyMessage = nil }
                    if !(await manager.savePage(preset)) {
                        error = manager.lastError
                        manager.clearError()
                    }
                }
            }
        } message: {
            Text("你对这个页面的修改会被清除。")
        }
        .alert(
            UserTerminology.pageLibrary, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button(String(localized: "好"), role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// Custom pages open directly for editing; presets expose their copy choices. Secondary actions
    /// stay in an explicit menu, and a page in use cannot be deleted.
    private func row(_ page: KeyboardPageDefinition, usage: String?) -> some View {
        HStack(spacing: 12) {
            if isPreset(page) {
                Menu {
                    actions(page, usage: usage)
                } label: {
                    pageLabel(page, usage: usage)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    openEditor(page)
                } label: {
                    pageLabel(page, usage: usage)
                }
                .buttonStyle(.plain)
            }
            Menu {
                actions(page, usage: usage)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "\(page.name)的更多操作"))
        }
        .padding(.vertical, 2)
        .swipeActions {
            if !isPreset(page), usage == nil {
                Button(String(localized: "删除"), role: .destructive) { removing = page }
            }
        }
    }

    private func pageLabel(_ page: KeyboardPageDefinition, usage: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(page.name).font(.headline).foregroundStyle(.primary)
            Text(summary(page)).font(.caption).foregroundStyle(.secondary)
            if let usage { Text(usage).font(.caption).foregroundStyle(.secondary) }
            Label(
                isPreset(page) ? String(localized: "复制并编辑") : String(localized: "编辑页面"),
                systemImage: isPreset(page) ? "plus.square.on.square" : "pencil"
            )
            .font(.caption).foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func actions(_ page: KeyboardPageDefinition, usage: String?) -> some View {
        if !isPreset(page) {
            Button(String(localized: "编辑"), systemImage: "pencil") { openEditor(page) }
        }
        if page.numericPresentation == .automatic {
            Menu(String(localized: "复制并编辑"), systemImage: "plus.square.on.square") {
                Button(String(localized: "复制中文 123")) { copy(page, numericMarks: .chinese) }
                Button(String(localized: "复制英文 123")) { copy(page, numericMarks: .ascii) }
                Button(String(localized: "复制\(UserTerminology.phoneDigitPad)")) {
                    copy(page, numericMarks: .chinese, numericForm: .phoneDigitPad)
                }
            }
        } else if page.symbolPresentation == .automatic {
            Menu(String(localized: "复制并编辑"), systemImage: "plus.square.on.square") {
                Button(String(localized: "复制多行符号页")) { copy(page, presentation: .rows) }
                Button(String(localized: "复制分类符号页")) { copy(page, presentation: .categorized) }
            }
        } else {
            Button(String(localized: "复制并编辑"), systemImage: "plus.square.on.square") { copy(page) }
        }
        if let preset = KeyboardPagePresets.all.first(where: { $0.id == page.id }), preset != page {
            Button(String(localized: "恢复预设"), systemImage: "arrow.counterclockwise") { restoring = preset }
        }
        if !isPreset(page) {
            Button(String(localized: "删除"), systemImage: "trash", role: .destructive) { removing = page }
                .disabled(usage != nil)
        }
    }

    private func summary(_ page: KeyboardPageDefinition) -> String {
        if page.numericPresentation == .automatic {
            return String(localized: "标点跟着中英文，9 键是\(UserTerminology.phoneDigitPad)")
        }
        if page.numericPresentation == .keypad {
            let content = page.rows.reduce(0) { $0 + $1.keys.count }
            return String(localized: "\(UserTerminology.phoneDigitPad) · 共 \(content + page.chromeKeys.count) 个按键")
        }
        if page.usesSymbolBrowser {
            guard let categories = page.categories else {
                return page.symbolPresentation == .automatic
                    ? String(localized: "九键用分类浏览，其他布局用多行") : String(localized: "分类浏览")
            }
            return String(localized: "\(categories.count) 个分类")
        }
        let content = page.rows.reduce(0) { $0 + $1.keys.count }
        if page.chromeKeys.isEmpty {
            return String(localized: "\(page.rows.count) 行 · \(content) 个按键")
        }
        return String(localized: "\(page.rows.count) 行 · \(content) 个内容键 · \(page.chromeKeys.count) 个功能键")
    }

    private func copy(
        _ page: KeyboardPageDefinition, presentation: KeyboardSymbolPresentation? = nil,
        numericMarks: KeyboardNumericMarks? = nil, numericForm: KeyboardNumericForm? = nil
    ) {
        busyMessage = String(localized: "正在准备页面…")
        Task { @MainActor in
            defer { busyMessage = nil }
            do {
                editing = try await KeyboardPageDraftFactory.copy(
                    page, presentation: presentation, numericMarks: numericMarks, numericForm: numericForm)
            } catch let failure {
                error = LayoutManager.friendly(failure, context: .pageCopy)
            }
        }
    }

    /// Opening materialises the stored page once, so the editor edits authored data; a category page
    /// without its snapshot reads the symbol library first on the background queue.
    private func openEditor(_ page: KeyboardPageDefinition) {
        guard page.numericPresentation != .automatic else { return }
        busyMessage = String(localized: "正在准备页面…")
        Task { @MainActor in
            defer { busyMessage = nil }
            do {
                editing = try await KeyboardPageDraftFactory.editableDraft(page)
            } catch {
                self.error = String(localized: "分类没有读取成功，请重试。")
            }
        }
    }

    private func isPreset(_ page: KeyboardPageDefinition) -> Bool {
        KeyboardPagePresets.all.contains { $0.id == page.id }
    }
}
