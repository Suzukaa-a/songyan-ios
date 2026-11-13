import KeyboardCore
import LayoutKit
import SwiftUI
import UIKit

/// Value-only page draft: edits stay in memory until save succeeds. Opening the editor materialises
/// the legacy page (function keys become authored chrome, categories come from the symbol library)
/// under the same id and name, and that materialised value is the dirty baseline, so opening and
/// cancelling never writes and never asks to discard changes that were not made.
struct KeyboardPageEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = LayoutManager.shared
    /// Whether this machine's keyboard draws a globe key; settled once at launch.
    private let needsGlobe: Bool
    @State private var draft: KeyboardPageDefinition
    @State private var selected: KeyboardPageKeyPath = .row(0, key: 0)
    /// Which branch the preview draws; a view of the page, never saved with it.
    @State private var previewMarks: KeyboardNumericMarks
    private enum EditorSection: CaseIterable, Hashable {
        case keys
        case arrangement

        var title: String {
            switch self {
            case .keys: return String(localized: "按键")
            case .arrangement: return String(localized: "页面")
            }
        }
    }

    @State private var editorSection: EditorSection = .keys
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDiscard = false
    @StateObject private var widthValidity = WidthFieldValidity()
    private let original: KeyboardPageDefinition
    var onSaved: ((KeyboardPageDefinition) -> Void)?
    let inheritedSplit: LayoutSplitConfiguration?
    /// The inherited split carries the bundled layout's hand cuts, so the English page takes them too.
    let usesHandCuts: Bool
    let isPhoneLayout: Bool
    /// The shape of the keyboard this page is paired with, so the preview takes its width.
    let mainLayout: KeyboardLayoutKind?

    init(
        page: KeyboardPageDefinition, inheritedSplit: LayoutSplitConfiguration? = nil,
        usesHandCuts: Bool = false, isPhoneLayout: Bool = false, mainLayout: KeyboardLayoutKind? = nil,
        onSaved: ((KeyboardPageDefinition) -> Void)? = nil
    ) {
        let needsGlobe = KeyboardPreviewPreferences.cached.needsInputModeSwitchKey
        let materialized = page.materialized().forSystemSwitch(shown: needsGlobe)
        self.needsGlobe = needsGlobe
        original = materialized
        _draft = State(initialValue: materialized)
        _previewMarks = State(initialValue: materialized.defaultSymbolMarks ?? .chinese)
        _selected = State(initialValue: materialized.firstKeyPath ?? .row(0, key: 0))
        self.onSaved = onSaved
        self.inheritedSplit = inheritedSplit
        self.usesHandCuts = usesHandCuts
        self.isPhoneLayout = isPhoneLayout
        self.mainLayout = mainLayout
    }

    private var categorized: Bool { draft.symbolPresentation == .categorized }

    /// Only pages that own bilingual rows have an initial symbol branch to author.
    private var showsInitialSymbolChoice: Bool {
        if draft.kind == .numeric { return true }
        return draft.kind == .symbols && draft.symbolPresentation != .categorized
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "编辑内容"), selection: $editorSection) {
                    ForEach(EditorSection.allCases, id: \.self) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section {
                if showsInitialSymbolChoice {
                    Picker(String(localized: "预览符号"), selection: $previewMarks) {
                        Text("中文").tag(KeyboardNumericMarks.chinese)
                        Text("英文").tag(KeyboardNumericMarks.ascii)
                    }
                    .pickerStyle(.segmented)
                }
                KeyboardPagePreviewView(
                    page: draft, inheritedSplit: inheritedSplit, usesHandCuts: usesHandCuts,
                    isPhoneLayout: isPhoneLayout,
                    mainLayout: mainLayout, skin: AppearanceManager.shared.applied.skin,
                    previewMarks: showsInitialSymbolChoice ? previewMarks : nil,
                    onSelectKey: {
                        selected = $0
                        editorSection = .keys
                    },
                    selectedPageKey: selected)
            } header: {
                Text("预览")
            } footer: {
                Text("轻点预览中的按键即可编辑。")
            }
            // The selected key's fields and position sit right under the preview that selects it.
            if editorSection == .keys {
                selectedKeyFields
                if !categorized {
                    SelectedRowKeyActions(rows: rowsBinding, selected: selectedRowBinding)
                }
                if draft.key(at: selected) != nil {
                    keyPositionSection
                }
            }
            if editorSection == .arrangement {
                Section(draft.kind.title) {
                    LabeledContent(String(localized: "名称")) {
                        TextField(String(localized: "名称"), text: $draft.name).multilineTextAlignment(.trailing)
                    }
                    if showsInitialSymbolChoice {
                        // Nil follows the input language; an explicit choice pins the branch the page opens in.
                        Picker(
                            String(localized: "初始符号"),
                            selection: Binding(
                                get: { draft.defaultSymbolMarks },
                                set: {
                                    draft.defaultSymbolMarks = $0
                                    if let marks = $0 { previewMarks = marks }
                                })
                        ) {
                            Text("跟随输入").tag(Optional<KeyboardNumericMarks>.none)
                            Text("中文").tag(Optional(KeyboardNumericMarks.chinese))
                            Text("英文").tag(Optional(KeyboardNumericMarks.ascii))
                        }
                    }
                }
                if needsGlobe, draft.chrome != nil, !draft.hasInputModeSwitchKey {
                    Section {
                        Button(String(localized: "添加\(UserTerminology.globeKey)"), systemImage: "globe") {
                            addInputModeSwitchKey()
                        }
                        .disabled(!draft.canAppendKey(to: .chrome(.bottom)))
                    }
                }
                if categorized {
                    KeyboardCategoryEditorView(
                        categories: Binding(get: { draft.categories ?? [] }, set: { draft.categories = $0 }),
                        inheritedSplit: .resolving(page: draft.split, main: inheritedSplit), mainLayout: mainLayout)
                } else {
                    KeyboardRowsEditor(rows: rowsBinding, selected: selectedRowBinding)
                }
                if draft.chrome != nil {
                    KeyboardChromeKeysEditor(
                        chrome: Binding(
                            get: { draft.chrome ?? KeyboardPageChrome() },
                            set: { chrome in draft = draft.settingChrome(chrome).settingSplitAdjusted(draft.split) }),
                        selected: $selected, allowsLeading: !categorized)
                }
                // The footer cut lives at index rows.count, so its authored row joins the cut list.
                KeyboardSplitEditor(
                    rows: draft.splitRows, rowTitles: splitEditorRowTitles,
                    split: Binding(get: { draft.split }, set: { draft = draft.settingSplit($0) }),
                    allowsInheritance: true)
            }
        }
        .disabled(saving)
        .environment(\.widthFieldValidity, widthValidity)
        .navigationTitle(String(localized: "编辑页面"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(draft != original || saving)
        .interactiveDismissDisabled(draft != original || saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "取消")) { if draft != original { confirmingDiscard = true } else { dismiss() } }
                    .disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "保存页面")) { save() }.disabled(saving)
            }
        }
        .confirmationDialog(String(localized: "放弃未保存的更改？"), isPresented: $confirmingDiscard, titleVisibility: .visible)
        {
            Button(String(localized: "放弃更改"), role: .destructive) { dismiss() }
            Button(String(localized: "继续编辑"), role: .cancel) {}
        }
        .alert(
            String(localized: "页面没有保存"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button(String(localized: "好"), role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var rowsBinding: Binding<[LayoutRow]> {
        Binding(
            get: { draft.rows },
            set: { rows in
                draft.rows = rows
                draft = draft.settingSplitAdjusted(draft.split)
            })
    }

    private var splitEditorRowTitles: [String] {
        var titles = draft.rows.indices.map { String(localized: "第 \($0 + 1) 行") }
        if let bottom = draft.chrome?.bottom, !bottom.isEmpty { titles.append(String(localized: "底行")) }
        return titles
    }

    /// Adds a globe key. A page may go without one: the author decides.
    private func addInputModeSwitchKey() {
        guard let chrome = draft.chrome, draft.canAppendKey(to: .chrome(.bottom)) else { return }
        let globe = LayoutKey(label: "🌐", action: LayoutAction(.globe), titleMode: .automatic)
        // Where the default footer keeps it: immediately left of the space bar.
        let index = chrome.bottom.firstIndex { $0.action.type == .space } ?? 0
        var bottom = chrome.bottom
        bottom.insert(globe, at: index)
        draft = draft.settingChrome(chrome.settingKeys(bottom, in: .bottom)).settingSplitAdjusted(draft.split)
        selected = .chrome(.bottom, key: index)
    }

    // MARK: - Selected key

    private var selectedRowBinding: Binding<LayoutKeyPath> {
        Binding(
            get: {
                if case .row(let row, let key) = selected { return .row(row, key: key) }
                return .row(-1, key: -1)
            },
            set: { path in
                if case .row(let row, let key) = path { selected = .row(row, key: key) }
            })
    }

    @ViewBuilder
    private var selectedKeyFields: some View {
        if let key = draft.key(at: selected) {
            LayoutKeyFields(
                key: key, allowsCode: false, allowsTitleMode: true,
                widthLabel: isRailSelection ? String(localized: "高度比例") : String(localized: "宽度比例"),
                allowsJump: selected.allowsJumpKey
            ) { updated in
                draft = draft.replacingKey(at: selected, with: updated)
            }
            .id(selected)
        }
    }

    /// One place for ordering, copying, deleting and moving the selected key between areas.
    @ViewBuilder
    private var keyPositionSection: some View {
        let current = selected.region
        let targets = draft.editableKeyRegions.filter { $0 != current }
        Section(String(localized: "按键位置")) {
            if case .chrome(let region, let index) = selected {
                HStack {
                    Button(isRail(region) ? String(localized: "上移") : String(localized: "前移")) {
                        apply(draft.reorderingChromeKey(at: selected, by: -1))
                    }
                    .disabled(index == 0)
                    Spacer()
                    Button(isRail(region) ? String(localized: "下移") : String(localized: "后移")) {
                        apply(draft.reorderingChromeKey(at: selected, by: 1))
                    }
                    .disabled(index >= (draft.chrome?.keys(in: region).count ?? 0) - 1)
                }
                Button(String(localized: "复制按键")) { apply(draft.duplicatingChromeKey(at: selected)) }
                    .disabled(!draft.canAppendKey(to: current))
                Button(String(localized: "删除按键"), role: .destructive) { removeSelectedChromeKey() }
            }
            if !targets.isEmpty {
                Menu(String(localized: "移到其他区域")) {
                    ForEach(targets, id: \.self) { target in
                        Button(title(target)) { apply(draft.movingKey(at: selected, to: target)) }
                            .disabled(!draft.canMoveKey(at: selected, to: target))
                    }
                }
                Menu(String(localized: "复制到其他区域")) {
                    ForEach(targets, id: \.self) { target in
                        Button(title(target)) { apply(draft.copyingKey(at: selected, to: target)) }
                            .disabled(!draft.canCopyKey(at: selected, to: target))
                    }
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private func title(_ region: KeyboardPageKeyRegion) -> String {
        switch region {
        case .rows: return String(localized: "按键区")
        case .chrome(.bottom): return String(localized: "底行")
        case .chrome(.leading): return String(localized: "左侧栏")
        case .chrome(.trailing): return String(localized: "右侧栏")
        }
    }

    private var isRailSelection: Bool {
        guard case .chrome(let region, _) = selected else { return false }
        return isRail(region)
    }

    private func isRail(_ region: KeyboardPageChrome.Region) -> Bool {
        region == .leading || region == .trailing
    }

    private func apply(_ edit: (page: KeyboardPageDefinition, path: KeyboardPageKeyPath)?) {
        guard let edit else { return }
        draft = edit.page
        selected = edit.path
    }

    private func removeSelectedChromeKey() {
        guard case .chrome = selected, let updated = draft.removingKey(at: selected) else { return }
        draft = updated
        if let next = updated.selectionAfterRemoving(selected) { selected = next }
    }

    // MARK: - Save

    private func save() {
        guard !widthValidity.isInvalid else {
            error = String(localized: "有按键宽度没填对，请改成大于 0 的数字，或者留空。")
            return
        }
        saving = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            await Task.yield()
            let snapshot = draft
            defer { saving = false }
            if await manager.savePage(snapshot) {
                onSaved?(snapshot)
                dismiss()
            } else {
                error = manager.lastError
                manager.clearError()
            }
        }
    }
}
