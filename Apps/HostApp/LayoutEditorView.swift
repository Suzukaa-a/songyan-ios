import KeyboardCore
import LayoutKit
import SwiftUI
import UIKit

/// Value-only draft: no engine/session, no writes until save succeeds.
struct LayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = LayoutManager.shared
    @State private var draft: LayoutDefinition
    @State private var selected: LayoutKeyPath = .row(0, key: 0)
    /// Whether this machine's keyboard draws a globe key; settled once at launch.
    private let needsGlobe: Bool
    /// The split view edits the keys as they are when the keyboard splits; the other view the whole rows.
    @State private var splitView = false
    @State private var splitSelected = SplitKeyAddress(row: 0, key: 0)
    @State private var error: String?
    @State private var confirmingDiscard = false
    @State private var saving = false
    @StateObject private var inheritedQuickSymbols = T9QuickSymbolModel()
    @State private var quickSymbolsLoaded = false
    @StateObject private var widthValidity = WidthFieldValidity()
    /// Layout at open time: used to detect unsaved changes (confirm before cancel/swipe-down dismissal).
    private let original: LayoutDefinition
    /// Receives what was written: the edited layout, or the new copy from 另存为副本.
    private let onSaved: ((LayoutDefinition) -> Void)?

    init(layout: LayoutDefinition, onSaved: ((LayoutDefinition) -> Void)? = nil) {
        // The bottom row opens as the keys the keyboard draws, so it can be edited like any row;
        // saving it unchanged keeps the layout following the keyboard's own row.
        let needsGlobe = KeyboardPreviewPreferences.cached.needsInputModeSwitchKey
        let editable = LayoutBottomRow.editable(layout).forSystemSwitch(shown: needsGlobe)
        self.needsGlobe = needsGlobe
        original = editable
        self.onSaved = onSaved
        _draft = State(initialValue: editable)
    }
    private var hasChanges: Bool { draft != original }

    var body: some View {
        Form {
            Section(String(localized: "布局")) {
                TextField(
                    String(localized: "名称"), text: Binding(get: { draft.name }, set: { draft = draft.renamed($0) }))
            }
            Section(String(localized: "候选栏")) {
                Toggle(
                    String(localized: "显示候选栏"),
                    isOn: Binding(
                        get: { draft.effectiveCandidateArea.candidates },
                        set: { enabled in
                            draft = draft.settingCandidateArea(
                                .init(
                                    candidates: enabled,
                                    reading: enabled && draft.effectiveCandidateArea.reading))
                        })
                )
                .disabled(draft.sendsEngineCode)
                Toggle(
                    String(localized: "拼音提示行"),
                    isOn: Binding(
                        get: { draft.effectiveCandidateArea.reading },
                        set: { enabled in
                            draft = draft.settingCandidateArea(
                                .init(
                                    candidates: draft.effectiveCandidateArea.candidates, reading: enabled))
                        })
                )
                .disabled(!draft.effectiveCandidateArea.candidates || PhoneKeypadStructure.matches(draft))
            }
            if !PhoneKeypadStructure.matches(draft) {
                Section(String(localized: "键盘排列")) {
                    Picker(
                        String(localized: "键盘排列"),
                        selection: Binding(
                            get: { splitView },
                            set: { showSplit in
                                splitView = showSplit
                                selected = .row(0, key: 0)
                                splitSelected = SplitKeyAddress(row: 0, key: 0)
                            })
                    ) {
                        Text("不拆分").tag(false)
                        Text("拆分时").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("layoutEditor.arrangement")
                }
            }
            if splitView && !PhoneKeypadStructure.matches(draft) {
                splitSections
            } else {
                if PhoneKeypadStructure.matches(draft) { nineKeySections }
                wholeSections
            }
            KeyboardSplitEditor(
                rows: draft.rows, split: Binding(get: { draft.split }, set: { draft = replacingSplit($0) }),
                activationOnly: true)
            Section {
                Button(String(localized: "另存为副本")) { save(asCopy: true) }
            }
            .disabled(saving)
        }
        .disabled(saving)
        .environment(\.widthFieldValidity, widthValidity)
        .navigationBarBackButtonHidden(saving)
        .navigationTitle(String(localized: "编辑键盘布局"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "取消")) { if hasChanges { confirmingDiscard = true } else { dismiss() } }
                    .disabled(saving)
                    .accessibilityIdentifier("layoutEditor.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "保存布局")) { save(asCopy: false) }
                    .disabled(saving)
                    .accessibilityIdentifier("layoutEditor.save")
            }
        }
        .confirmationDialog(String(localized: "放弃未保存的更改？"), isPresented: $confirmingDiscard, titleVisibility: .visible)
        {
            Button(String(localized: "放弃更改"), role: .destructive) { dismiss() }
            Button(String(localized: "继续编辑"), role: .cancel) {}
        }
        .interactiveDismissDisabled(hasChanges || saving)
        .task {
            if PhoneKeypadStructure.matches(draft) {
                await inheritedQuickSymbols.reload().value
                quickSymbolsLoaded = true
            }
        }
        .alert(
            UserTerminology.keyboardLayout, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    /// The main layout keeps a way to the next keyboard on a machine that needs one: its last globe
    /// key moves but its action stays.
    private func isProtectedGlobe(_ key: LayoutKey) -> Bool {
        needsGlobe && draft.rows.flatMap(\.keys).isLastGlobe(key)
    }

    @ViewBuilder
    private var wholeSections: some View {
        Section(String(localized: "点键编辑")) {
            KeyboardPreviewView(layout: draft, onSelectKey: { selected = $0 })
        }
        // The selected key's fields sit right under the preview that selects it.
        if let key = draft.key(at: selected) {
            // The quick-symbol cycle replaces the first key's tap; its face, width and long press still apply.
            let cyclesQuickSymbols = selected == .row(0, key: 0) && BuiltinLayouts.usesPhone9QuickSymbols(draft)
            // The bottom row types no letters: a letter key there would make it a letter row.
            let inBottomRow = bottomIndex != nil && selectedRow == bottomIndex
            // Main-layout function keys draw custom titles at runtime too.
            LayoutKeyFields(
                key: key, allowsCode: !inBottomRow, allowsTitleMode: true,
                editsAction: !cyclesQuickSymbols && !isProtectedGlobe(key)
            ) { updated in
                draft = draft.replacingKey(at: selected, with: updated)
            }
            .id(selected)
        }
        SelectedRowKeyActions(
            rows: rowsBinding, selected: $selected, bottomRow: bottomIndex, protectsGlobe: needsGlobe)
        KeyboardRowsEditor(rows: letterRowsBinding, selected: $selected)
        if let bottomIndex {
            KeyboardBottomRowEditor(
                keys: Binding(
                    get: { draft.rows[bottomIndex].keys },
                    set: { draft = LayoutBottomRow.replacing($0, in: draft) }),
                row: bottomIndex, selected: $selected, offersGlobe: needsGlobe)
        }
        if draft.hasExplicitSplit && !PhoneKeypadStructure.matches(draft) {
            Section {
                Text("拆分时的键盘有自己的一套按键，这里的改动不会同步过去。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var nineKeySections: some View {
        Section {
            Picker(
                String(localized: "首键"),
                selection: Binding(
                    get: { BuiltinLayouts.usesPhone9QuickSymbols(draft) ? T9FirstKeyBehavior.quickSymbols : .custom },
                    set: { draft = draft.settingT9FirstKeyBehavior($0) }
                )
            ) {
                Text("快捷符号与分词").tag(T9FirstKeyBehavior.quickSymbols)
                Text("自定义按键").tag(T9FirstKeyBehavior.custom)
            }
            TextField(
                String(localized: "默认快捷符号"),
                text: Binding(
                    get: { draft.t9QuickSymbols ?? inheritedQuickSymbols.symbols },
                    set: { draft = draft.settingT9QuickSymbols($0) }
                ), axis: .vertical
            )
            .lineLimit(1...3)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(!quickSymbolsLoaded)
            .accessibilityIdentifier("t9QuickSymbols.editor")
            let values = BuiltinLayouts.t9QuickSymbolValues(
                for: draft, inherited: inheritedQuickSymbols.symbols, ascii: false)
            LabeledContent(String(localized: "侧键"), value: values.prefix(3).joined(separator: " "))
            if BuiltinLayouts.usesPhone9QuickSymbols(draft) {
                LabeledContent(String(localized: "首键连续点按"), value: values.dropFirst(3).joined(separator: " "))
            }
            Button(String(localized: "恢复默认快捷符号")) { draft = draft.settingT9QuickSymbols("") }
                .accessibilityIdentifier("t9QuickSymbols.restore")
            Toggle(
                String(localized: "自定义侧栏"),
                isOn: Binding(
                    get: { draft.auxiliaryAreas != BuiltinLayouts.phone9.auxiliaryAreas },
                    set: { custom in
                        draft = replacingAuxiliaryAreas(
                            custom ? frozenPhoneRails() : BuiltinLayouts.phone9.auxiliaryAreas)
                    }
                )
            )
            .disabled(!quickSymbolsLoaded)
        } header: {
            Text("九键")
        } footer: {
            Text("快捷符号随布局保存。自定义侧栏后，在预览中轻点侧键可编辑。")
        }
    }

    private func frozenPhoneRails() -> [LayoutAuxiliaryArea] {
        let chinese = BuiltinLayouts.t9QuickSymbolValues(
            for: draft, inherited: inheritedQuickSymbols.symbols, ascii: false)
        let ascii = BuiltinLayouts.t9QuickSymbolValues(
            for: draft, inherited: inheritedQuickSymbols.symbols, ascii: true)
        let keys = zip(chinese.prefix(3), ascii.prefix(3)).map { value, asciiValue in
            LayoutKey(
                label: value, action: .init(.literal, value: value, asciiValue: asciiValue), titleMode: .automatic)
        }
        return [
            .init(position: .leading, role: .punctuation, keys: keys),
            .init(
                position: .trailing, role: .editing,
                keys: PhoneKeypadRailPolicy.declaredKeys(in: BuiltinLayouts.phone9, position: .trailing)),
        ]
    }

    private func replacingAuxiliaryAreas(_ areas: [LayoutAuxiliaryArea]?) -> LayoutDefinition {
        LayoutDefinition(
            id: draft.id, name: draft.name, input: draft.input, rows: draft.rows,
            auxiliaryAreas: areas, note: draft.note, longPressDelay: draft.longPressDelay,
            candidateArea: draft.candidateArea, split: draft.split,
            t9FirstKeyBehavior: draft.t9FirstKeyBehavior, t9QuickSymbols: draft.t9QuickSymbols)
    }

    private var splitDefaultBreaks: [Int]? { BuiltinLayouts.handSplit(for: draft)?.rowBreaks }

    @ViewBuilder
    private var splitSections: some View {
        SplitArrangementEditor(
            layout: Binding(get: { draft }, set: { draft = $0 }), selected: $splitSelected,
            defaultBreaks: splitDefaultBreaks,
            setSplit: { draft = replacingSplit($0) })
        if let key = draft.splitKey(at: splitSelected, defaultBreaks: splitDefaultBreaks) {
            LayoutKeyFields(key: key, allowsTitleMode: true) { updated in
                draft = draft.replacingSplitKey(at: splitSelected, with: updated, defaultBreaks: splitDefaultBreaks)
            }
            .id(splitSelected)
        }
    }

    private var rowsBinding: Binding<[LayoutRow]> {
        Binding(get: { draft.rows }, set: { draft = replacingRows($0) })
    }

    /// The bottom row has its own section; the nine-key pad keeps its bottom row with the others.
    private var bottomIndex: Int? {
        PhoneKeypadStructure.matches(draft) ? nil : LayoutBottomRow.index(draft)
    }

    private var selectedRow: Int? {
        if case .row(let row, _) = selected { return row }
        return nil
    }

    /// The rows above the bottom row; adding or moving rows never moves the bottom row.
    private var letterRowsBinding: Binding<[LayoutRow]> {
        Binding(
            get: { bottomIndex.map { Array(draft.rows.prefix($0)) } ?? draft.rows },
            set: { rows in
                draft = replacingRows(bottomIndex.map { rows + [draft.rows[$0]] } ?? rows)
            })
    }

    private func save(asCopy: Bool) {
        guard !saving else { return }
        guard !widthValidity.isInvalid else {
            error = String(localized: "有按键宽度没填对，请改成大于 0 的数字，或者留空。")
            return
        }
        saving = true
        // End marked input before taking the value snapshot used for saving.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            await Task.yield()
            var snapshot = LayoutBottomRow.storable(
                asCopy ? BuiltinLayouts.persistingHandCuts(in: draft).copy() : draft)
            // Key edits can leave the 9-key shape, which hides the 九键 section; its settings no longer apply.
            if !PhoneKeypadStructure.matches(snapshot) {
                snapshot = snapshot.settingT9FirstKeyBehavior(nil).settingT9QuickSymbols(nil)
            }
            defer { saving = false }
            if await manager.saveDraft(snapshot) {
                onSaved?(snapshot)
                dismiss()
            } else {
                error = manager.lastError
                manager.clearError()
            }
        }
    }

    private func replacingRows(_ rows: [LayoutRow]) -> LayoutDefinition {
        // A saved split arrangement keeps one entry per row as rows are added, removed or moved.
        draft.replacingRowsFollowingSplit(rows)
    }

    private func replacingSplit(_ split: LayoutSplitConfiguration?) -> LayoutDefinition {
        LayoutDefinition(
            id: draft.id, name: draft.name, input: draft.input, rows: draft.rows,
            auxiliaryAreas: draft.auxiliaryAreas, note: draft.note,
            longPressDelay: draft.longPressDelay, candidateArea: draft.candidateArea, split: split,
            t9FirstKeyBehavior: draft.t9FirstKeyBehavior, t9QuickSymbols: draft.t9QuickSymbols)
    }
}

struct LayoutKeyFields: View {
    let key: LayoutKey
    var allowsCode = true
    /// Page function keys can follow the live keyboard state instead of a fixed title.
    var allowsTitleMode = false
    /// Row and footer keys size by relative width; rail keys size by relative height.
    var widthLabel = String(localized: "宽度比例")
    /// Category keys only type text, so their action list leaves out every function key.
    var allowsFunctionActions = true
    /// Only a page's keys may jump to another layout's page, never a main layout's.
    var allowsJump = false
    var editsAction = true
    let update: (LayoutKey) -> Void

    var body: some View {
        Section(String(localized: "所选按键 · \(key.label)")) {
            LabeledContent(String(localized: "按键文字")) {
                TextField(
                    String(localized: "主标题"),
                    text: Binding(
                        get: { key.label }, set: { update(key.editingLabel($0, allowsTitleMode: allowsTitleMode)) })
                )
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("layoutEditor.key.label")
                .multilineTextAlignment(.trailing)
            }
            if allowsTitleMode && key.supportsLiveTitle {
                Picker(
                    String(localized: "标题内容"),
                    selection: Binding(
                        get: { key.displayedTitleMode },
                        set: { update(key.settingTitleMode($0)) })
                ) {
                    Text("跟随功能").tag(LayoutKeyTitleMode.automatic)
                    Text("自定义").tag(LayoutKeyTitleMode.custom)
                }
            }
            LabeledContent(String(localized: "副标题")) {
                TextField(
                    String(localized: "可选"),
                    text: Binding(
                        get: { key.secondaryLabel ?? "" },
                        set: { update(key.settingSecondaryLabel($0.isEmpty ? nil : $0)) })
                )
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("layoutEditor.key.secondaryLabel")
                .multilineTextAlignment(.trailing)
            }
            OptionalWidthField(
                title: widthLabel,
                value: Binding(get: { key.width }, set: { update(key.settingWidth($0)) }))
            if editsAction {
                LayoutActionFields(
                    action: key.action, allowsCode: allowsCode, allowsFunctionActions: allowsFunctionActions,
                    allowsJump: allowsJump
                ) { action in
                    update(key.editingAction(action, allowsTitleMode: allowsTitleMode))
                }
            }
        }
        Section {
            ForEach((key.longPress ?? []).indices, id: \.self) { index in
                longPressOption(index)
            }
            Button(String(localized: "添加长按项")) {
                let options =
                    (key.longPress ?? []) + [
                        LayoutOption(label: "。", action: LayoutAction(.literal, value: "。"))
                    ]
                update(key.settingLongPress(options))
            }
            .disabled((key.longPress?.count ?? 0) >= LayoutResourceBudget.alternatesPerKey)
        } header: {
            Text("长按列表")
        } footer: {
            if let note = longPressNote {
                Text(note)
            }
        }
    }

    /// One short line only where a long press had a native gesture: filling the list replaces it.
    private var longPressNote: String? {
        let hasOptions = !(key.longPress ?? []).isEmpty
        switch key.action.type {
        case .space:
            return hasOptions
                ? String(localized: "长按只弹这些选项，不再移动光标。")
                : String(localized: "留空时，长按仍是移动光标。")
        case .globe:
            return hasOptions
                ? String(localized: "长按只弹这些选项，不再打开系统键盘列表。")
                : String(localized: "留空时，长按仍是系统键盘列表。")
        case .languageSwitch:
            return hasOptions
                ? String(localized: "长按只弹这些选项，不再选择输入方式。")
                : String(localized: "留空时，长按仍是选择输入方式。")
        case .shift, .modeSwitch:
            return hasOptions ? String(localized: "长按只弹这些选项。") : nil
        default:
            return nil
        }
    }

    @ViewBuilder
    private func longPressOption(_ index: Int) -> some View {
        let options = key.longPress ?? []
        if options.indices.contains(index) {
            let option = options[index]
            VStack(alignment: .leading) {
                TextField(
                    String(localized: "长按项标题"),
                    text: Binding(
                        get: { option.label },
                        set: { text in
                            replaceOption(index, with: LayoutOption(label: text, action: option.action))
                        })
                )
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                LayoutActionFields(
                    action: option.action, allowsCode: allowsCode,
                    title: String(localized: "选中后")
                ) { action in
                    replaceOption(index, with: LayoutOption(label: option.label, action: action))
                }
                HStack {
                    Button(String(localized: "上移")) { moveOption(index, by: -1) }.disabled(index == 0)
                    Button(String(localized: "下移")) { moveOption(index, by: 1) }.disabled(index >= options.count - 1)
                    Spacer()
                    Button(String(localized: "移除"), role: .destructive) {
                        var updated = options
                        updated.remove(at: index)
                        update(key.settingLongPress(updated.isEmpty ? nil : updated))
                    }
                }.buttonStyle(.borderless)
            }
        }
    }

    private func replaceOption(_ index: Int, with option: LayoutOption) {
        guard var options = key.longPress, options.indices.contains(index) else { return }
        options[index] = option
        update(key.settingLongPress(options))
    }

    private func moveOption(_ index: Int, by offset: Int) {
        guard var options = key.longPress, options.indices.contains(index + offset) else { return }
        options.swapAt(index, index + offset)
        update(key.settingLongPress(options))
    }
}

private struct LayoutActionFields: View {
    let action: LayoutAction
    var allowsCode = true
    var allowsFunctionActions = true
    var allowsJump = false
    /// What the picker is called: a key does it on tap, a long-press option once chosen.
    var title = String(localized: "轻点后")
    let update: (LayoutAction) -> Void

    private var kinds: [LayoutAction.Kind] {
        LayoutAction.Kind.editorChoices(
            allowsCode: allowsCode, allowsFunctionActions: allowsFunctionActions, allowsJump: allowsJump,
            stored: action.type)
    }

    private func actionTitle(_ kind: LayoutAction.Kind) -> String {
        switch kind {
        case .code: return String(localized: "输入字母")
        case .literal: return String(localized: "输入文字")
        case .space: return String(localized: "空格")
        case .enter: return String(localized: "回车")
        case .backspace: return String(localized: "退格")
        case .globe: return UserTerminology.globeKey
        case .modeSwitch: return String(localized: "切换键盘布局")
        case .shift: return String(localized: "大小写")
        case .pageSwitch: return String(localized: "切换页面")
        case .layoutPageSwitch: return String(localized: "跳转到…")
        case .languageSwitch: return UserTerminology.languageKey
        case .symbolLock: return String(localized: "符号锁定")
        case .symbolLibrary: return KeyLabelPolicy.symbolLibraryAccessibilityLabel()
        case .clearInput: return String(localized: "重输")
        // Kana gestures only come from the Japanese twelve-key board; the editor shows a stored
        // one when an edited copy is opened, it never offers them for an ordinary key.
        case .kana: return String(localized: "layout.action.kanaRow")
        case .kanaModifier: return String(localized: "layout.action.kanaModifier")
        case .cursorLeft: return String(localized: "kana.cursorLeft")
        }
    }

    private func defaultAction(_ kind: LayoutAction.Kind) -> LayoutAction {
        switch kind {
        case .code: return LayoutAction(.code, value: "a")
        case .literal: return LayoutAction(.literal, value: "。")
        case .pageSwitch: return .pageSwitch(.numeric)
        case .layoutPageSwitch: return .layoutPageSwitch(LayoutAction.PageJump.all[0])
        case .languageSwitch: return .languageSwitch()
        // A kana row id is required by validation; the first grid row is the harmless default a
        // future picker would land on.
        case .kana: return .kana(LayoutAction.kanaRowIDs[0])
        default: return LayoutAction(kind)
        }
    }

    /// "9 键 · 123": the layout by its user-visible name, then the page.
    static func jumpTargetName(_ target: LayoutAction.PageJump) -> String {
        let layout = KeyboardLayoutKind(rawValue: target.layout.rawValue)?.userTitle ?? target.layout.rawValue
        return "\(layout) · \(target.pageLabel)"
    }

    var body: some View {
        Picker(
            title,
            selection: Binding(get: { action.type }, set: { update(defaultAction($0)) })
        ) {
            ForEach(kinds, id: \.self) { kind in
                Text(actionTitle(kind)).tag(kind)
            }
        }
        if action.type == .languageSwitch {
            Picker(
                String(localized: "按键行为"),
                selection: Binding(
                    get: { action.languageSwitchBehavior },
                    set: { update(.languageSwitch($0)) })
            ) {
                Text("跟随页面").tag(Optional<LayoutAction.LanguageSwitchBehavior>.none)
                Text("切换中英符号").tag(Optional(LayoutAction.LanguageSwitchBehavior.symbols))
                Text("回到字母页").tag(Optional(LayoutAction.LanguageSwitchBehavior.letters))
            }
        }
        if action.type == .pageSwitch {
            Picker(
                String(localized: "目标页面"),
                selection: Binding(
                    get: { action.pageSwitchTarget ?? .numeric },
                    set: { update(.pageSwitch($0)) })
            ) {
                Text("字母页").tag(LayoutAction.PageTarget.letters)
                Text("123 页").tag(LayoutAction.PageTarget.numeric)
                Text("符号页").tag(LayoutAction.PageTarget.symbols)
            }
        }
        if action.type == .layoutPageSwitch {
            Picker(
                String(localized: "跳转到"),
                selection: Binding(
                    get: { action.layoutPageJump ?? LayoutAction.PageJump.all[0] },
                    set: { update(.layoutPageSwitch($0)) })
            ) {
                ForEach(LayoutAction.PageJump.all, id: \.self) { target in
                    Text(Self.jumpTargetName(target)).tag(target)
                }
            }
            Text("轻点后换用这个键盘布局。正在使用的输入方式不支持它时，这个键不显示。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if action.type == .code {
            TextField(
                String(localized: "一个英文字符"),
                text: Binding(
                    get: { action.value ?? "" }, set: { update(LayoutAction(.code, value: $0)) }),
                axis: .vertical
            )
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("layoutEditor.key.actionValue")
        }
        if action.type == .literal {
            LabeledContent(action.asciiValue == nil ? String(localized: "输入文字") : String(localized: "中文符号")) {
                TextField(
                    action.asciiValue == nil ? String(localized: "要输入的文字") : String(localized: "中文符号时输入"),
                    text: Binding(
                        get: { action.value ?? "" },
                        set: { update(LayoutAction(.literal, value: $0, asciiValue: action.asciiValue)) }),
                    axis: .vertical
                )
                .keyboardType(.default)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("layoutEditor.key.actionValue")
                .multilineTextAlignment(.trailing)
            }
            // One optional field is both the pair switch and the ASCII-side value: typing fills it,
            // clearing writes nil back to a fixed literal. A pair only ever stores non-empty text.
            LabeledContent(String(localized: "英文符号")) {
                TextField(
                    String(localized: "可选"),
                    text: Binding(
                        get: { action.asciiValue ?? "" },
                        set: { update(action.settingAsciiValue($0.isEmpty ? nil : $0)) }),
                    axis: .vertical
                )
                .keyboardType(.default)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("layoutEditor.key.actionASCIIValue")
                .multilineTextAlignment(.trailing)
            }
        }
    }
}
