import KeyboardCore
import LayoutKit
import SwiftUI

extension KeyboardLayoutKind {
    /// Every keyboard shape has a bundled main layout of the same shape.
    var builtinLayout: LayoutInput.Builtin {
        switch self {
        case .qwerty26: return .qwerty26
        case .merged14: return .merged14
        case .merged18: return .merged18
        case .phone9: return .phone9
        }
    }

    init(_ builtin: LayoutInput.Builtin) {
        switch builtin {
        case .qwerty26: self = .qwerty26
        case .merged14: self = .merged14
        case .merged18: self = .merged18
        case .phone9: self = .phone9
        }
    }
}

extension UserKeyboard {
    var compositionKey: KeyboardCompositionKey {
        KeyboardCompositionKey(inputMethodID: inputMethodID, layout: layout.builtinLayout)
    }
}

/// The shared input-language physical-layout rules for one input method, using the descriptor
/// snapshot of the keyboard's own source (never the first matching ID across all sources). An
/// unknown fact stays generic and keeps today's behaviour.
enum HostLayoutAvailability {
    /// The declared alphabet of this source's descriptor when known; id-only otherwise.
    static func family(schemaID: String, descriptors: [KeyboardSchemaDescriptor]) -> InputSchemeFamily {
        InputLayoutPolicy.family(schemaID: schemaID, descriptors: descriptors)
    }

    /// Whether the shape may be used by this input method. A stale published keyboard outside the
    /// rule is reported as unavailable instead of being resolved to a layout the family forbids.
    static func allows(
        kind: KeyboardLayoutKind, schemaID: String, descriptors: [KeyboardSchemaDescriptor]
    ) -> Bool {
        InputLayoutPolicy.allows(kind: kind, family: family(schemaID: schemaID, descriptors: descriptors))
    }

    static func policy(schemaID: String, descriptors: [KeyboardSchemaDescriptor]) -> LayoutAvailability {
        let family = family(schemaID: schemaID, descriptors: descriptors)
        return LayoutAvailability(
            allows: { definition, _ in
                InputLayoutPolicy.allows(physicalLayoutID: definition.id, family: family)
            },
            preferredMainLayoutID: { _ in InputLayoutPolicy.preferredPhysicalLayoutID(family: family) })
    }

    /// The main layout the keyboard really uses: its saved pairing when this family may still use
    /// it, otherwise the family's own board. Every Host surface that names, previews or switches a
    /// pairing resolves it here, so a newly added traditional keyboard is never read as the 26-key
    /// default. A fallback is runtime-only: the saved pairing is never rewritten.
    static func effectiveMainLayoutID(
        schemaID: String, layout: KeyboardLayoutKind, board: String? = nil,
        descriptors: [KeyboardSchemaDescriptor], in registry: LayoutRegistry
    ) -> String {
        registry.usableMainLayoutID(
            for: KeyboardCompositionKey(inputMethodID: schemaID, layout: layout.builtinLayout),
            board: board, availability: policy(schemaID: schemaID, descriptors: descriptors))
    }
}

extension HostLayoutAvailability {
    /// The keyboards an input scheme can use, named as 我的键盘 titles its rows: a shipped board by its own name
    /// (an input method with several boards lists each), any other keyboard by its shape.
    static func keyboardNames(
        for keyboards: [PublishedKeyboard], descriptors: [KeyboardSchemaDescriptor], in registry: LayoutRegistry
    ) -> [String] {
        var names: [String] = []
        func add(_ name: String) {
            if !names.contains(name) { names.append(name) }
        }
        for keyboard in keyboards {
            guard allows(kind: keyboard.layout, schemaID: keyboard.schemaID, descriptors: descriptors) else { continue }
            let shape = UserTerminology.layoutName(keyboard.layout)
            let family = family(schemaID: keyboard.schemaID, descriptors: descriptors)
            let boards =
                keyboard.layout == .qwerty26
                ? InputLayoutPolicy.boards(of: family).filter { registry.resolvedLayout(id: $0) != nil } : []
            if boards.count > 1 {
                for board in boards { add(UserTerminology.builtinLayoutName(physicalLayoutID: board) ?? shape) }
            } else {
                let id = effectiveMainLayoutID(
                    schemaID: keyboard.schemaID, layout: keyboard.layout, descriptors: descriptors, in: registry)
                add(UserTerminology.builtinLayoutName(physicalLayoutID: id) ?? shape)
            }
        }
        return names
    }
}

/// Names the keyboards a layout or page is paired with. 我的键盘 knows the names of its keyboards;
/// any other keyboard is named from its input method and shape.
struct KeyboardNames {
    var known: [String: String] = [:]
    /// The keyboards in 我的键盘 (saved or selected); a layout they open on counts as used even
    /// when they have no saved pairing.
    var active: [KeyboardCompositionKey] = []

    func title(_ key: KeyboardCompositionKey) -> String {
        if let name = known[key.rawValue] { return name }
        let layout = UserTerminology.layoutName(KeyboardLayoutKind(key.layout))
        guard let method = UserTerminology.inputMethodName(schemaID: key.inputMethodID, schemas: nil) else {
            return layout
        }
        return "\(method) · \(layout)"
    }

    /// "正在被「…」使用", or nil when no keyboard uses it.
    func usage(_ keys: [KeyboardCompositionKey]) -> String? {
        UserTerminology.usedByKeyboards(keys.map(title))
    }
}

struct KeyboardCompositionView: View {
    let keyboard: UserKeyboard
    let keyboardNames: KeyboardNames
    /// The schema facts of the keyboard's own source; empty means unknown and stays generic.
    let sourceSchemas: [KeyboardSchemaDescriptor]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = LayoutManager.shared
    @State private var draft: KeyboardComposition
    @State private var baseline: KeyboardComposition
    @State private var editingPage: KeyboardPageDefinition?
    @State private var editingMain: LayoutDefinition?
    @State private var saving = false
    @State private var preparingPage = false
    @State private var initialized = false
    @State private var alert: CompositionAlert?
    @State private var confirmingDiscard = false
    @State private var libraryNotice: String?

    private struct CompositionAlert {
        let title: String
        let message: String
    }

    init(
        keyboard: UserKeyboard, keyboardNames: KeyboardNames = KeyboardNames(),
        sourceSchemas: [KeyboardSchemaDescriptor] = []
    ) {
        self.keyboard = keyboard
        self.keyboardNames = keyboardNames
        self.sourceSchemas = sourceSchemas
        let registry = LayoutManager.shared.registry
        var composition = registry.composition(for: keyboard.compositionKey)
        // A board keyboard never edits the pairing's main layout, so its draft keeps it as saved.
        if keyboard.board == nil,
            HostLayoutAvailability.allows(
                kind: keyboard.layout, schemaID: keyboard.inputMethodID, descriptors: sourceSchemas)
        {
            // A saved pairing this family may not use falls back to a legal existing layout at
            // runtime; the stored pairing and the user's layouts are left untouched.
            let availability = HostLayoutAvailability.policy(
                schemaID: keyboard.inputMethodID, descriptors: sourceSchemas)
            composition.mainLayoutID = registry.usableMainLayoutID(
                for: keyboard.compositionKey, availability: availability)
        }
        _draft = State(initialValue: composition)
        _baseline = State(initialValue: composition)
    }

    private var availability: LayoutAvailability {
        HostLayoutAvailability.policy(schemaID: keyboard.inputMethodID, descriptors: sourceSchemas)
    }

    /// A stale published keyboard may name a shape its family no longer offers: the page says so
    /// instead of resolving a "usable" layout inside a forbidden shape.
    private var keyboardIsAvailable: Bool {
        HostLayoutAvailability.allows(
            kind: keyboard.layout, schemaID: keyboard.inputMethodID, descriptors: sourceSchemas)
    }

    private var layouts: [LayoutDefinition] {
        guard keyboardIsAvailable else { return [] }
        return manager.registry.mainLayoutCandidates(for: keyboard.compositionKey, availability: availability)
    }

    private var mainLayout: LayoutDefinition? {
        guard keyboardIsAvailable else { return nil }
        return manager.registry.resolvedLayout(
            id: keyboard.board ?? draft.mainLayoutID)
    }

    /// The hand cuts the selected main layout is drawn with, as the keyboard resolves them.
    private var mainHandSplit: LayoutSplitConfiguration? { mainLayout.flatMap(BuiltinLayouts.handSplit(for:)) }

    /// An automatic page previews against the selected main layout, so a phone keypad previews its
    /// digit pad instead of a row page it will never show.
    private var mainLayoutIsPhoneKeypad: Bool { mainLayout.map(PhoneKeypadStructure.matches) ?? false }

    /// A copy of the automatic 123 page takes the shape the selected main layout actually shows.
    private var mainNumericForm: KeyboardNumericForm { mainLayoutIsPhoneKeypad ? .phoneDigitPad : .rows }

    var body: some View {
        Form {
            Section {
                Text(
                    keyboard.title(
                        physicalLayoutName: mainLayout.flatMap {
                            UserTerminology.builtinLayoutName(physicalLayoutID: $0.id)
                        }))
                Text("页面与布局单独保存到库中；选好后轻点「保存搭配」。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let libraryNotice {
                    Label(libraryNotice, systemImage: "checkmark.circle").font(.footnote)
                }
                if !initialized { ProgressView(String(localized: "正在读取布局…")) }
                if let message = manager.lastError { Text(message).foregroundStyle(.orange) }
            }
            if keyboardIsAvailable {
                // A board keyboard types on its own board; the main layout choice belongs to the keyboard
                // without a board, so this page is pages only for it.
                if keyboard.board == nil {
                    Section(UserTerminology.mainLayout) {
                        Picker(UserTerminology.keyboardLayout, selection: $draft.mainLayoutID) {
                            ForEach(layouts) { layout in Text(layout.listName).tag(layout.id) }
                        }
                        if let layout = mainLayout {
                            DisclosureGroup(String(localized: "预览")) {
                                KeyboardPreviewView(layout: layout, skin: AppearanceManager.shared.applied.skin)
                            }
                            if let usage = keyboardNames.usage(
                                manager.registry.keyboards(usingLayout: layout.id, among: keyboardNames.active))
                            {
                                Text(usage).font(.footnote).foregroundStyle(.secondary)
                            }
                            Button(String(localized: "编辑\(UserTerminology.mainLayout)")) { editingMain = layout }
                            Button(String(localized: "复制并编辑\(UserTerminology.mainLayout)")) {
                                editingMain = BuiltinLayouts.persistingHandCuts(in: layout).copy()
                            }
                        } else {
                            Text("没有适合这个键盘的布局，请在下方「\(UserTerminology.keyboardLayout)」中添加。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(KeyboardPageKind.allCases, id: \.self) { kind in
                    pageSection(kind)
                }
                Section {
                    NavigationLink(UserTerminology.pageLibrary) {
                        KeyboardPageManagementView(keyboardNames: keyboardNames)
                    }
                    NavigationLink(UserTerminology.keyboardLayout) {
                        LayoutManagementView(keyboardNames: keyboardNames)
                    }
                }
            } else {
                Section {
                    Label(
                        String(localized: "这个键盘暂不支持当前输入方式，请改用其他键盘。"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
        .disabled(saving || preparingPage || !initialized)
        .onReceive(manager.$registry) { registry in
            guard !initialized, manager.location != nil else { return }
            var composition = registry.composition(for: keyboard.compositionKey)
            if keyboardIsAvailable, keyboard.board == nil {
                composition.mainLayoutID = registry.usableMainLayoutID(
                    for: keyboard.compositionKey, availability: availability)
            }
            draft = composition
            baseline = composition
            initialized = true
        }
        .navigationTitle(UserTerminology.pageComposition)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(draft != baseline || saving)
        .interactiveDismissDisabled(draft != baseline || saving)
        .toolbar {
            if draft != baseline || saving {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        confirmingDiscard = true
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel(String(localized: "返回"))
                    .disabled(saving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "保存搭配")) { save() }.disabled(
                    saving || !initialized || !keyboardIsAvailable || (keyboard.board == nil && layouts.isEmpty))
            }
        }
        .sheet(item: $editingPage) { page in
            NavigationStack {
                KeyboardPageEditorView(
                    page: page, inheritedSplit: mainHandSplit ?? mainLayout?.split, usesHandCuts: mainHandSplit != nil,
                    isPhoneLayout: mainLayoutIsPhoneKeypad,
                    mainLayout: keyboard.layout
                ) { saved in
                    draft.setPageID(saved.id, for: saved.kind)
                    libraryNotice = String(localized: "「\(saved.name)」已保存到页面库。")
                }
            }
        }
        .sheet(item: $editingMain) { layout in
            NavigationStack {
                // A saved copy (from either copy button) becomes this keyboard's main layout.
                LayoutEditorView(layout: layout) { saved in
                    draft.mainLayoutID = saved.id
                    libraryNotice = String(localized: "「\(saved.name)」已保存到键盘布局。")
                }
            }
        }
        .confirmationDialog(String(localized: "放弃未保存的搭配？"), isPresented: $confirmingDiscard, titleVisibility: .visible)
        {
            Button(String(localized: "放弃搭配"), role: .destructive) { dismiss() }
            Button(String(localized: "继续编辑"), role: .cancel) {}
        } message: {
            Text("已保存到库中的页面和布局会保留。")
        }
        .alert(
            alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
        ) {
            Button(String(localized: "好"), role: .cancel) { alert = nil }
        } message: {
            Text(alert?.message ?? "")
        }
    }

    private func pageSection(_ kind: KeyboardPageKind) -> some View {
        Section(kind.title) {
            Picker(
                String(localized: "页面"),
                selection: Binding(get: { draft.pageID(for: kind) }, set: { draft.setPageID($0, for: kind) })
            ) {
                ForEach(manager.registry.pages.filter { $0.kind == kind }) { page in Text(page.listName).tag(page.id) }
            }
            if let page = manager.registry.page(id: draft.pageID(for: kind)) {
                DisclosureGroup(String(localized: "预览")) {
                    KeyboardPagePreviewView(
                        page: page, inheritedSplit: mainHandSplit ?? mainLayout?.split,
                        usesHandCuts: mainHandSplit != nil,
                        isPhoneLayout: mainLayoutIsPhoneKeypad,
                        mainLayout: keyboard.layout, skin: AppearanceManager.shared.applied.skin,
                        mainDefinition: mainLayout,
                        numericPage: manager.registry.page(id: draft.numericPageID))
                }
                if let usage = keyboardNames.usage(manager.registry.keyboards(usingPage: page.id)) {
                    Text(usage).font(.footnote).foregroundStyle(.secondary)
                }
                if let note = pageNote(page) {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
                if kind == .symbols, let note = missingMarksNote(symbols: page) {
                    Text(note).font(.footnote).foregroundStyle(.orange)
                }
                if !KeyboardPagePresets.all.contains(where: { $0.id == page.id }) {
                    Button(String(localized: "编辑页面")) { openPageEditor(page) }
                }
                if page.numericPresentation == .automatic {
                    Menu {
                        // A phone main layout's automatic page is a digit pad: its keys do not
                        // depend on the punctuation width, so one copy is enough.
                        if mainNumericForm == .phoneDigitPad {
                            Button(String(localized: "复制\(UserTerminology.phoneDigitPad)")) {
                                copyPage(page, numericMarks: .chinese, numericForm: .phoneDigitPad)
                            }
                        } else {
                            Button(String(localized: "复制中文 123")) {
                                copyPage(page, numericMarks: .chinese, numericForm: .rows)
                            }
                            Button(String(localized: "复制英文 123")) {
                                copyPage(page, numericMarks: .ascii, numericForm: .rows)
                            }
                        }
                    } label: {
                        pageCopyLabel
                    }
                } else if page.symbolPresentation == .automatic {
                    Menu {
                        Button(String(localized: "复制多行符号页")) { copyPage(page, presentation: .rows) }
                        Button(String(localized: "复制分类符号页")) { copyPage(page, presentation: .categorized) }
                    } label: {
                        pageCopyLabel
                    }
                } else {
                    Button(String(localized: "复制并编辑页面")) { copyPage(page) }
                }
                if preparingPage { ProgressView(String(localized: "正在准备页面…")) }
            }
        }
    }

    private var pageCopyLabel: some View {
        Label(String(localized: "复制并编辑页面"), systemImage: "plus.square.on.square")
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    /// One line about what a page follows or how it pairs; nil when the page draws its own content.
    private func pageNote(_ page: KeyboardPageDefinition) -> String? {
        let resolution = KeyboardPageResolver.resolve(
            page: page, kind: page.kind,
            input: .init(
                usesASCIIPunctuation: false, mainLayoutIsPhoneKeypad: mainLayoutIsPhoneKeypad))
        switch resolution {
        case .automaticNumeric(.phoneDigitPad, _):
            return String(localized: "123 页是\(UserTerminology.phoneDigitPad)。")
        case .automaticNumeric(.rows, _):
            return String(localized: "标点跟着中英文切换。")
        default:
            return nil
        }
    }

    /// The everyday marks this pairing types nowhere, when the user's own symbol page would have
    /// to carry them; a built-in symbol page takes them over itself.
    private func missingMarksNote(symbols: KeyboardPageDefinition) -> String? {
        KeyboardPageMarkCoverage.pairingNote(
            letters: mainLayout, numeric: manager.registry.page(id: draft.numericPageID), symbols: symbols,
            mainLayoutIsPhoneKeypad: mainLayoutIsPhoneKeypad)
    }

    private func copyPage(
        _ page: KeyboardPageDefinition, presentation: KeyboardSymbolPresentation? = nil,
        numericMarks: KeyboardNumericMarks? = nil, numericForm: KeyboardNumericForm? = nil
    ) {
        preparingPage = true
        Task { @MainActor in
            defer { preparingPage = false }
            do {
                editingPage = try await KeyboardPageDraftFactory.copy(
                    page, presentation: presentation, numericMarks: numericMarks, numericForm: numericForm)
            } catch let failure {
                alert = CompositionAlert(title: String(localized: "页面没有复制成功"), message: LayoutManager.friendly(failure))
            }
        }
    }

    /// The editor edits authored data: opening materialises the stored page once, and a categorised
    /// page without its snapshot reads the symbol library on the background queue first.
    private func openPageEditor(_ page: KeyboardPageDefinition) {
        guard page.numericPresentation != .automatic else { return }
        preparingPage = true
        Task { @MainActor in
            defer { preparingPage = false }
            do {
                editingPage = try await KeyboardPageDraftFactory.editableDraft(
                    page, numericForm: mainNumericForm)
            } catch {
                alert = CompositionAlert(
                    title: String(localized: "页面没有打开"), message: String(localized: "分类没有读取成功，请重试。"))
            }
        }
    }

    private func save() {
        // A stale published keyboard outside the shape rule is read-only here.
        guard initialized, !saving, keyboardIsAvailable else { return }
        saving = true
        let snapshot = draft
        Task {
            defer { saving = false }
            if await manager.saveComposition(snapshot, for: keyboard.compositionKey.rawValue) {
                baseline = snapshot
                dismiss()
            } else {
                alert = CompositionAlert(
                    title: String(localized: "\(UserTerminology.pageComposition)没有保存"), message: manager.lastError ?? ""
                )
                manager.clearError()
            }
        }
    }
}
