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
    /// A keyboard that names its layout has pages of its own; one saved before that shares the
    /// pairing stored under its shape.
    var compositionKey: KeyboardCompositionKey {
        KeyboardCompositionKey(inputMethodID: inputMethodID, layout: layout.builtinLayout, layoutID: board)
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
    /// A layout made from the key profile, installed into the catalog when its keyboard is added.
    enum GeneratedKind: Equatable {
        case keys26, strokes
    }

    /// One layout an input method can be given as a keyboard in 我的键盘.
    struct ApplicableLayout: Equatable {
        let shape: KeyboardLayoutKind
        let layoutID: String
        /// The codes the scheme needs that the layout has no key for, in the scheme's order.
        var missingCodes: [String] = []
        /// Set for a layout made from the key profile.
        var generated: GeneratedKind?
    }

    /// The layouts an input method can be typed on, each one a keyboard 我的键盘 can add. `shapes` are
    /// the shapes the source can run the input method on; folded shapes only for a scheme spelled
    /// syllable by syllable (its profile, read from `descriptors`). Per shape: the family's own boards, or
    /// the shape's shipped layout when the family has none, then the user's layouts made for that shape
    /// (and for this input method, when they name one). On the 26-key shape the profile adds the layouts
    /// it asks for: the stroke pad, and the 26-key board with the missing codes, which a syllabic scheme
    /// only gets as an extra choice. Every surface that offers keyboards asks here.
    static func applicableLayouts(
        schemaID: String, shapes: [KeyboardLayoutKind],
        descriptors: [KeyboardSchemaDescriptor], in registry: LayoutRegistry
    ) -> [ApplicableLayout] {
        let family = family(schemaID: schemaID, descriptors: descriptors)
        let availability = policy(schemaID: schemaID, descriptors: descriptors)
        let profile = descriptors.first { $0.id == schemaID }?.profile
        let shipped = Set(BuiltinLayouts.all.map(\.id))
        var result: [ApplicableLayout] = []
        for shape in KeyboardLayoutKind.allCases
        where shapes.contains(shape) && InputLayoutPolicy.allows(kind: shape, family: family)
            && (shape == .qwerty26 || profile?.allowsFolding != false)
        {
            let key = KeyboardCompositionKey(inputMethodID: schemaID, layout: shape.builtinLayout)
            let candidates = registry.mainLayoutCandidates(for: key, availability: availability).map(\.id)
            let familyBoards = shape == .qwerty26 ? InputLayoutPolicy.boards(of: family) : []
            let boards = familyBoards.filter(candidates.contains)
            let preset = BuiltinLayouts.preset(for: shape.builtinLayout).id
            let own = boards.isEmpty ? [preset].filter(candidates.contains) : boards
            var entries: [ApplicableLayout] = (own + candidates.filter { !shipped.contains($0) }).compactMap { id in
                let missing =
                    profile.flatMap { profile in
                        registry.resolvedLayout(id: id).map {
                            // A missing delimiter or auxiliary key is normal on a plain board: not worth a warning.
                            LayoutCodeCoverage.missingToReport(
                                $0, kind: shape.builtinLayout, needed: profile.codes, optional: profile.optionalCodes)
                        }
                    } ?? []
                // A 26-key layout with no key for a code the speller needs cannot type the scheme at all.
                if shape == .qwerty26, let profile, let layout = registry.resolvedLayout(id: id),
                    !LayoutCodeCoverage.missingRequired(
                        layout, needed: profile.codes, optional: profile.optionalCodes
                    ).isEmpty
                {
                    return nil
                }
                return ApplicableLayout(shape: shape, layoutID: id, missingCodes: missing)
            }
            // A family with physical boards of its own keeps them; nothing is generated beside them.
            if shape == .qwerty26, let profile, familyBoards.isEmpty {
                entries = withGenerated(schemaID: schemaID, entries: entries, profile: profile)
            }
            result += entries
        }
        return result
    }

    private static func withGenerated(
        schemaID: String, entries: [ApplicableLayout], profile: SchemaKeyProfile
    ) -> [ApplicableLayout] {
        guard profile.kind != .unknown else { return entries }
        let keys26ID = GeneratedLayouts.keys26ID(schemaID: schemaID)
        let strokesID = GeneratedLayouts.strokesID(schemaID: schemaID)
        func generated(_ id: String, _ kind: GeneratedKind) -> ApplicableLayout {
            var entry =
                entries.first { $0.layoutID == id } ?? ApplicableLayout(shape: .qwerty26, layoutID: id)
            entry.generated = kind
            entry.missingCodes = []
            return entry
        }
        let wantsKeys26 = !LayoutCodeCoverage.missing(BuiltinLayouts.qwerty26, needed: profile.codes).isEmpty
        let wantsStrokes = profile.kind == .strokes && !profile.strokes.isEmpty
        let keys26 = wantsKeys26 ? generated(keys26ID, .keys26) : nil
        let strokes = wantsStrokes ? generated(strokesID, .strokes) : nil
        let own = Set([keys26, strokes].compactMap { $0?.layoutID })
        let rest = entries.filter { !own.contains($0.layoutID) }
        if let strokes { return [strokes] + rest + [keys26].compactMap { $0 } }
        if profile.kind == .shapeCode { return [keys26].compactMap { $0 } + rest }
        return rest + [keys26].compactMap { $0 }
    }

    /// The name a keyboard that is not added yet goes by in a list of choices: its layout's name, where a
    /// generated layout not in the catalog yet is named as it will be stored.
    static func choiceTitle(
        _ keyboard: PublishedKeyboard, descriptors: [KeyboardSchemaDescriptor], in registry: LayoutRegistry
    ) -> String {
        let id = keyboard.board ?? ""
        if registry.resolvedLayout(id: id) == nil,
            let generated = generatedDefinition(layoutID: id, schemaID: keyboard.schemaID, descriptors: descriptors)
        {
            return generated.name
        }
        return layoutName(
            schemaID: keyboard.schemaID, layout: keyboard.layout, board: keyboard.board,
            descriptors: descriptors, in: registry) ?? UserTerminology.layoutName(keyboard.layout)
    }

    /// The layout a generated keyboard types on, made from its scheme's profile; nil when the scheme
    /// has none or the id is not one of its generated layouts.
    static func generatedDefinition(
        layoutID: String, schemaID: String, descriptors: [KeyboardSchemaDescriptor]
    ) -> LayoutDefinition? {
        guard let profile = descriptors.first(where: { $0.id == schemaID })?.profile else { return nil }
        switch layoutID {
        case GeneratedLayouts.keys26ID(schemaID: schemaID):
            return GeneratedLayouts.keys26(
                schemaID: schemaID,
                name: UserTerminology.keys26Name(
                    adding: LayoutCodeCoverage.missing(BuiltinLayouts.qwerty26, needed: profile.codes)),
                codes: profile.codes)
        case GeneratedLayouts.strokesID(schemaID: schemaID):
            return GeneratedLayouts.strokes(
                schemaID: schemaID, name: UserTerminology.strokePadName,
                strokes: profile.strokes.map { ($0.code, $0.label) })
        default: return nil
        }
    }

    /// The name a keyboard's layout adds to its title (see `UserKeyboard.layoutName`), resolved
    /// against the layout it really types on.
    static func layoutName(
        schemaID: String, layout: KeyboardLayoutKind, board: String?,
        descriptors: [KeyboardSchemaDescriptor], in registry: LayoutRegistry
    ) -> String? {
        let id = effectiveMainLayoutID(
            schemaID: schemaID, layout: layout, board: board, descriptors: descriptors, in: registry)
        let savedName = registry.resolvedLayout(id: id).map {
            GeneratedLayouts.addedCodes($0).map(UserTerminology.keys26Name(adding:)) ?? $0.name
        }
        return UserKeyboard.layoutName(board: board, mainLayoutID: id, savedName: savedName)
    }

    /// A keyboard to add that does not name its layout yet, as the record 我的键盘 writes for it: the
    /// layout it would open on, by ID.
    static func namingLayout(
        _ keyboard: PublishedKeyboard, descriptors: [KeyboardSchemaDescriptor], in registry: LayoutRegistry
    ) -> PublishedKeyboard {
        guard keyboard.board == nil else { return keyboard }
        return PublishedKeyboard(
            schemaID: keyboard.schemaID, layout: keyboard.layout,
            board: effectiveMainLayoutID(
                schemaID: keyboard.schemaID, layout: keyboard.layout, descriptors: descriptors, in: registry))
    }

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
                        physicalLayoutName: keyboard.layoutName(
                            mainLayoutID: mainLayout?.id, savedName: mainLayout?.shownName)))
                Text("页面与布局单独保存到库中；选好后轻点「保存搭配」。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let libraryNotice {
                    Label(libraryNotice, systemImage: "checkmark.circle").font(.footnote)
                }
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
        .loadingOverlay(!initialized)
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
