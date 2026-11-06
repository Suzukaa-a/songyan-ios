import Foundation

/// Data only: actions are dispatched by the keyboard host, never evaluated as scripts.
public struct LayoutAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case code, literal, space, backspace, enter, globe, modeSwitch
        /// Page-level controls. The host dispatches them itself; they never become an engine
        /// key action, so no engine case is added for a new kind.
        case shift, pageSwitch, languageSwitch, symbolLock, clearInput
        /// Opens a non-letter page of another keyboard layout and makes that layout the running one.
        /// A kind of its own (not a `pageSwitch` value) so a decoder that predates it rejects the
        /// file instead of opening a page of the wrong layout.
        case layoutPageSwitch
        /// One tap key of the Japanese twelve-key kana grid, addressed by its row id (`a`, `ka`,
        /// …, `punctuation`). The kana handler sends the row's romaji spelling to the engine as
        /// one batch, so the value names a row rather than a single engine key: a decoder that
        /// predates this kind rejects the board instead of drawing a kana cap as a letter.
        case kana
        /// The Japanese twelve-key modifier (小゛゜): the kana renderer applies it to the kana just
        /// typed in the live composition, so the key carries no value and sends no key of its own.
        case kanaModifier
        /// Moves the composition caret left through the engine's own Left key; nothing is typed.
        case cursorLeft
    }

    /// The only page a `.pageSwitch` key may open.
    public enum PageTarget: String, Codable, CaseIterable, Sendable {
        case letters, numeric, symbols
    }

    /// Where a `.layoutPageSwitch` key goes: the 123 or symbol page of one keyboard layout. A layout's
    /// letter page is no target; its 123 / symbol page is the one its pairing chooses for the running
    /// input method. Wire form: `"<layout>:<page>"`, e.g. `"phone9:numeric"`.
    public struct PageJump: Hashable, Sendable {
        public let layout: LayoutInput.Builtin
        public let page: PageTarget

        /// Nil for the letter page: it is not a jump target.
        public init?(layout: LayoutInput.Builtin, page: PageTarget) {
            guard Self.pages.contains(page) else { return nil }
            self.layout = layout
            self.page = page
        }

        public var wire: String { layout.rawValue + ":" + page.rawValue }

        /// The pages a jump may open, in the order an editor lists them.
        public static let pages: [PageTarget] = [.numeric, .symbols]

        /// Every target, layout by layout.
        public static let all: [PageJump] = LayoutInput.Builtin.allCases.flatMap { layout in
            pages.compactMap { PageJump(layout: layout, page: $0) }
        }

        /// Nil for anything but exactly one known layout and one non-letter page (case-sensitive).
        public init?(wire: String?) {
            guard let wire else { return nil }
            let parts = wire.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let layout = LayoutInput.Builtin(rawValue: String(parts[0])),
                let page = PageTarget(rawValue: String(parts[1]))
            else { return nil }
            self.init(layout: layout, page: page)
        }
    }

    /// Explicit behavior of an authored language key. No value keeps the page-following default.
    public enum LanguageSwitchBehavior: String, Codable, CaseIterable, Sendable {
        /// Switch only the panel's symbol language; the page does not change.
        case symbols
        /// Return to the main letter keyboard, keeping the Chinese/English input state.
        case letters
    }

    public let type: Kind
    public let value: String?
    /// ASCII counterpart of a bilingual literal (Chinese is `value`, ASCII is this). Nil keeps
    /// the literal fixed; only `.literal` may carry it.
    public let asciiValue: String?

    public init(_ type: Kind, value: String? = nil, asciiValue: String? = nil) {
        self.type = type
        self.value = value
        self.asciiValue = asciiValue
    }

    /// Every row id a `.kana` key may carry: one per tap glyph of the Japanese twelve-key grid,
    /// in draw order. The flick and toggle targets of a row belong to the kana input model, not to
    /// layout data, so the ids name rows rather than individual kana.
    public static let kanaRowIDs: [String] = [
        "a", "ka", "sa", "ta", "na", "ha", "ma", "ya", "ra", "wa", "punctuation",
    ]

    /// The tap key of one kana12 grid row.
    public static func kana(_ rowID: String) -> LayoutAction {
        LayoutAction(.kana, value: rowID)
    }

    /// The kana12 modifier key (小゛゜).
    public static let kanaModifier = LayoutAction(.kanaModifier)

    /// The kana12 composition caret-left key.
    public static let cursorLeft = LayoutAction(.cursorLeft)

    /// Whether the key reaches the engine as input instead of being dispatched by the host alone:
    /// a Latin code key, or a kana row key the kana handler spells out for the engine.
    public var isEngineInput: Bool { type == .code || type == .kana }

    /// The page a `.pageSwitch` key opens, or nil for every other kind.
    public var pageSwitchTarget: PageTarget? {
        guard type == .pageSwitch, let value else { return nil }
        return PageTarget(rawValue: value)
    }

    public static func pageSwitch(_ target: PageTarget) -> LayoutAction {
        LayoutAction(.pageSwitch, value: target.rawValue)
    }

    /// Where a `.layoutPageSwitch` key goes, or nil for every other kind.
    public var layoutPageJump: PageJump? {
        guard type == .layoutPageSwitch else { return nil }
        return PageJump(wire: value)
    }

    public static func layoutPageSwitch(_ target: PageJump) -> LayoutAction {
        LayoutAction(.layoutPageSwitch, value: target.wire)
    }

    /// Whether a key with this action is drawn when only `layouts` can be switched to. A jump to
    /// any other layout is left out, the way a globe key is left out without a system switch.
    public func isUsableJump(among layouts: Set<LayoutInput.Builtin>) -> Bool {
        guard type == .layoutPageSwitch else { return true }
        guard let jump = layoutPageJump else { return false }
        return layouts.contains(jump.layout)
    }

    /// The value a literal key shows and types for the current punctuation state. A nil pair is
    /// fixed text; a bilingual pair resolves without rebuilding any authored face metadata.
    public func literalValue(usesASCIIPunctuation: Bool) -> String? {
        guard type == .literal else { return nil }
        if usesASCIIPunctuation, let asciiValue { return asciiValue }
        return value
    }

    /// Replaces only the ASCII counterpart, keeping the kind and the Chinese value.
    public func settingAsciiValue(_ asciiValue: String?) -> LayoutAction {
        LayoutAction(type, value: value, asciiValue: asciiValue)
    }

    /// The explicit behavior authored on a language key, or nil when the key follows the page.
    public var languageSwitchBehavior: LanguageSwitchBehavior? {
        guard type == .languageSwitch, let value else { return nil }
        return LanguageSwitchBehavior(rawValue: value)
    }

    /// Builds a language key with an explicit behavior; nil keeps the page-following default.
    public static func languageSwitch(_ behavior: LanguageSwitchBehavior? = nil) -> LayoutAction {
        LayoutAction(.languageSwitch, value: behavior?.rawValue)
    }

    public func validate() throws {
        guard type == .literal || asciiValue == nil else {
            throw LayoutError.invalid(
                String(localized: "layout.error.asciiOnlyLiteral", bundle: .module))
        }
        switch type {
        case .code:
            // The current engine interface accepts one logical ASCII key at a time.
            guard let value, value.utf8.count == 1,
                let byte = value.utf8.first, (33...126).contains(byte)
            else {
                throw LayoutError.invalid(
                    String(localized: "layout.error.codeValue", bundle: .module))
            }
        case .literal:
            guard let value, !value.isEmpty else {
                throw LayoutError.invalid(String(localized: "layout.error.literalEmpty", bundle: .module))
            }
            if let asciiValue, asciiValue.isEmpty {
                throw LayoutError.invalid(
                    String(localized: "layout.error.asciiValueEmpty", bundle: .module))
            }
        case .modeSwitch:
            guard value == nil || value == "nextLayout" else {
                throw LayoutError.invalid(
                    String(localized: "layout.error.modeSwitchValue", bundle: .module))
            }
        case .pageSwitch:
            guard let value, PageTarget(rawValue: value) != nil else {
                throw LayoutError.invalid(
                    String(localized: "layout.error.pageSwitchTarget", bundle: .module))
            }
        case .layoutPageSwitch:
            guard layoutPageJump != nil else {
                throw LayoutError.invalid(
                    String(localized: "layout.error.pageJumpTarget", bundle: .module))
            }
        case .languageSwitch:
            guard value.map({ LanguageSwitchBehavior(rawValue: $0) != nil }) ?? true else {
                throw LayoutError.invalid(
                    String(localized: "layout.error.languageSwitchValue", bundle: .module))
            }
        case .kana:
            guard let value, Self.kanaRowIDs.contains(value) else {
                throw LayoutError.invalid(String(localized: "layout.error.kanaRow", bundle: .module))
            }
        case .shift, .symbolLock, .clearInput, .space, .backspace, .enter, .globe, .kanaModifier,
            .cursorLeft:
            guard value == nil else {
                throw LayoutError.invalid(
                    String(localized: "layout.error.functionKeyValue", bundle: .module))
            }
        }
    }
}

public struct LayoutOption: Codable, Equatable, Sendable {
    public let label: String
    public let action: LayoutAction
    public init(label: String, action: LayoutAction) {
        self.label = label
        self.action = action
    }
}

/// How a key face derives its title. Nil draws the stored label, which is what every key of a
/// main layout file does.
public enum LayoutKeyTitleMode: String, Codable, Sendable {
    /// The host draws the control's live native face (Return title/state, Shift icon, language,
    /// lock, page target, space, delete). The stored label is the editor/accessibility fallback.
    case automatic
    /// The author's stored label is shown on every control, whatever the live state says.
    case custom
}

public struct LayoutKey: Codable, Equatable, Sendable {
    public internal(set) var label: String
    public internal(set) var secondaryLabel: String?
    /// Positive relative weight. In a key row or the footer it is a relative width; in a leading
    /// or trailing rail it is a relative vertical span. Omitted means 1.
    public internal(set) var width: Double?
    public internal(set) var action: LayoutAction
    public internal(set) var longPress: [LayoutOption]?
    /// Nil draws the stored label; see `LayoutKeyTitleMode`.
    public internal(set) var titleMode: LayoutKeyTitleMode?
    public var widthWeight: Double { width ?? 1 }

    public init(
        label: String, secondaryLabel: String? = nil, width: Double? = nil,
        action: LayoutAction, longPress: [LayoutOption]? = nil,
        titleMode: LayoutKeyTitleMode? = nil
    ) {
        self.label = label
        self.secondaryLabel = secondaryLabel
        self.width = width
        self.action = action
        self.longPress = longPress
        self.titleMode = titleMode
    }

    /// Field-preserving edits: editors must not rebuild a key and silently drop `titleMode`.
    public func title(_ label: String) -> LayoutKey {
        with {
            $0.label = label
            $0.titleMode = .custom
        }
    }

    /// Replaces the stored title only; unlike `title(_:)` it leaves `titleMode` alone.
    func settingLabel(_ label: String) -> LayoutKey { with { $0.label = label } }

    public func settingTitleMode(_ mode: LayoutKeyTitleMode?) -> LayoutKey { with { $0.titleMode = mode } }

    public func settingSecondaryLabel(_ label: String?) -> LayoutKey { with { $0.secondaryLabel = label } }

    public func settingWidth(_ width: Double?) -> LayoutKey { with { $0.width = width } }

    public func settingAction(_ action: LayoutAction) -> LayoutKey { with { $0.action = action } }

    public func settingLongPress(_ options: [LayoutOption]?) -> LayoutKey { with { $0.longPress = options } }

    private func with(_ change: (inout LayoutKey) -> Void) -> LayoutKey {
        var key = self
        change(&key)
        return key
    }
}

public struct LayoutRow: Codable, Equatable, Sendable {
    public let keys: [LayoutKey]
    public init(keys: [LayoutKey]) { self.keys = keys }
}

/// A schemaID is a reference to an installed Rime schema, not a translator implementation.
public struct LayoutInput: Codable, Equatable, Sendable {
    public enum Builtin: String, Codable, Sendable, CaseIterable {
        case qwerty26, merged14, merged18, phone9
    }
    public let schemaID: String?
    public let builtinLayout: Builtin?
    public init(schemaID: String? = nil, builtinLayout: Builtin? = nil) {
        self.schemaID = schemaID
        self.builtinLayout = builtinLayout
    }
}

public struct LayoutAuxiliaryArea: Codable, Equatable, Sendable {
    public enum Position: String, Codable, Sendable { case leading, trailing }
    public enum Role: String, Codable, Sendable { case punctuation, editing, disambiguation }
    public let position: Position
    public let role: Role
    public let keys: [LayoutKey]
    /// The host must hide this region unless an engine-backed disambiguation API exists.
    public var requiresEngineDisambiguation: Bool { role == .disambiguation }
    public init(position: Position, role: Role, keys: [LayoutKey] = []) {
        self.position = position
        self.role = role
        self.keys = keys
    }
}

/// Candidate surface requirements belong to the physical layout, not its name or schema.
public struct LayoutCandidateArea: Codable, Equatable, Sendable {
    public var candidates: Bool
    public var reading: Bool

    public init(candidates: Bool, reading: Bool) {
        self.candidates = candidates
        self.reading = reading
    }
}

/// The phone9 first key either uses the quick-symbol cycle or its declared action.
public enum T9FirstKeyBehavior: String, Codable, Sendable {
    case quickSymbols, custom
}

public struct LayoutDefinition: Codable, Equatable, Sendable, Identifiable {
    public internal(set) var id: String
    public internal(set) var name: String
    public let input: LayoutInput
    public internal(set) var rows: [LayoutRow]
    public internal(set) var auxiliaryAreas: [LayoutAuxiliaryArea]?
    /// Nil lets the key structure decide (see `effectiveCandidateArea`).
    public internal(set) var candidateArea: LayoutCandidateArea?
    public internal(set) var split: LayoutSplitConfiguration?
    /// Nil preserves legacy inference; ignored outside phone9.
    public internal(set) var t9FirstKeyBehavior: T9FirstKeyBehavior?
    /// Nil inherits the caller’s legacy list; empty uses builtin defaults. Ignored outside phone9.
    public internal(set) var t9QuickSymbols: String?
    public let note: String?

    /// Only the unchanged builtin prose gets a translated display; saved author notes stay literal.
    public var displayNote: String? {
        guard let builtin = BuiltinLayouts.all.first(where: { $0.id == id }), note == builtin.note else { return note }
        switch id {
        case "merged14": return String(localized: "layout.note.merged14", bundle: .module)
        case "merged18": return String(localized: "layout.note.merged18", bundle: .module)
        case "phone9": return String(localized: "layout.note.phone9", bundle: .module)
        default: return note
        }
    }
    /// Seconds until the alternate picker opens. Release commits one selected alternate only.
    public let longPressDelay: Double?
    public var effectiveLongPressDelay: Double { longPressDelay ?? 0.35 }
    public var sendsEngineCode: Bool {
        // The union of both arrangements: a key only the split halves carry still sends codes. The
        // shape recognisers (phone keypad, compact spelling, letter groups, known shells) read the
        // whole rows only, because they describe the layout as typed on one board.
        let keys =
            rows.flatMap(\.keys) + (split?.halves ?? []).flatMap(\.keys)
            + (auxiliaryAreas ?? []).flatMap(\.keys)
        return keys.contains { key in
            key.action.isEngineInput || (key.longPress ?? []).contains { $0.action.isEngineInput }
        }
    }
    public var effectiveCandidateArea: LayoutCandidateArea {
        candidateArea
            ?? LayoutCandidateArea(
                candidates: sendsEngineCode,
                reading: CompactSpellingLayout.matches(self) && !PhoneKeypadStructure.matches(self))
    }

    public init(
        id: String, name: String, input: LayoutInput, rows: [LayoutRow],
        auxiliaryAreas: [LayoutAuxiliaryArea]? = nil, note: String? = nil,
        longPressDelay: Double? = nil, candidateArea: LayoutCandidateArea? = nil,
        split: LayoutSplitConfiguration? = nil, t9FirstKeyBehavior: T9FirstKeyBehavior? = nil,
        t9QuickSymbols: String? = nil
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.rows = rows
        self.auxiliaryAreas = auxiliaryAreas
        self.candidateArea = candidateArea
        self.split = split
        self.t9FirstKeyBehavior = t9FirstKeyBehavior
        self.t9QuickSymbols = t9QuickSymbols
        self.note = note
        self.longPressDelay = longPressDelay
    }

    /// Caller keeps security-scoped access alive for the entire synchronous read.
    public static func read(from url: URL) throws -> Self {
        try decode(LayoutResourceBudget.read(url, maximumBytes: LayoutResourceBudget.definitionBytes))
    }

    public static func decode(_ data: Data) throws -> Self {
        try LayoutResourceBudget.check(
            data.count <= LayoutResourceBudget.definitionBytes,
            String(localized: "layout.error.fileTooLarge", bundle: .module))
        let layout = try JSONDecoder().decode(Self.self, from: data)
        try layout.validate()
        return layout
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder.layoutKitPretty()
        let data = try encoder.encode(self)
        try LayoutResourceBudget.check(
            data.count <= LayoutResourceBudget.definitionBytes,
            String(localized: "layout.error.fileTooLarge", bundle: .module))
        return data
    }

    public func validate() throws { _ = try validatedUsage() }

    /// Validates the layout once and returns what it spends, so the catalog check never walks the
    /// layout a second time.
    func validatedUsage() throws -> LayoutResourceBudget.Usage {
        let usage = try LayoutResourceBudget.usage(self)
        try split?.validate(rowKeyCounts: rows.map { $0.keys.count }, allowsHalves: true)
        if (t9FirstKeyBehavior != nil || t9QuickSymbols != nil), !PhoneKeypadStructure.matches(self) {
            throw LayoutError.invalid(
                String(localized: "layout.error.t9OnlySettings", bundle: .module))
        }
        if let symbols = t9QuickSymbols, !symbols.isEmpty {
            guard T9QuickSymbolStore.isValid(symbols), Set(symbols).count == symbols.count else {
                throw LayoutError.invalid(
                    String(localized: "layout.error.quickSymbols", bundle: .module))
            }
        }
        guard effectiveLongPressDelay.isFinite, effectiveLongPressDelay > 0 else {
            throw LayoutError.invalid(
                String(localized: "layout.error.longPressDelay", bundle: .module))
        }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw LayoutError.invalid(String(localized: "layout.error.missingName", bundle: .module))
        }
        if let schema = input.schemaID, schema.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LayoutError.invalid(String(localized: "layout.error.emptySchema", bundle: .module))
        }
        guard input.schemaID != nil || input.builtinLayout != nil else {
            throw LayoutError.invalid(String(localized: "layout.error.missingTarget", bundle: .module))
        }
        guard !rows.isEmpty, rows.allSatisfy({ !$0.keys.isEmpty }) else {
            throw LayoutError.invalid(String(localized: "layout.error.noRows", bundle: .module))
        }
        let area = effectiveCandidateArea
        if area.reading && !area.candidates {
            throw LayoutError.invalid(
                String(localized: "layout.error.readingNeedsCandidates", bundle: .module))
        }
        if area.reading && PhoneKeypadStructure.matches(self) {
            throw LayoutError.invalid(
                String(localized: "layout.error.phoneReadingSide", bundle: .module))
        }
        if !area.candidates && sendsEngineCode {
            throw LayoutError.invalid(
                String(localized: "layout.error.engineKeysNeedCandidates", bundle: .module))
        }
        for area in auxiliaryAreas ?? [] {
            // This is a dynamic engine-provided region, never static fake letter filters.
            if area.role == .disambiguation && !area.keys.isEmpty {
                throw LayoutError.invalid(
                    String(localized: "layout.error.disambiguationKeys", bundle: .module))
            }
        }
        let halfKeys = (split?.halves ?? []).flatMap(\.keys)
        for key in rows.flatMap(\.keys) + halfKeys + (auxiliaryAreas ?? []).flatMap(\.keys) {
            guard !key.label.isEmpty, key.widthWeight.isFinite, key.widthWeight > 0 else {
                throw LayoutError.invalid(String(localized: "layout.error.keyTitle", bundle: .module))
            }
            try key.action.validate()
            for option in key.longPress ?? [] {
                guard !option.label.isEmpty else {
                    throw LayoutError.invalid(String(localized: "layout.error.optionTitle", bundle: .module))
                }
                try option.action.validate()
            }
        }
        return usage
    }
}

/// Stable structural address shared by the editor and engine-free preview.
public enum LayoutKeyPath: Hashable, Sendable {
    case row(Int, key: Int)
    case auxiliary(Int, key: Int)
}

public extension LayoutDefinition {
    func supportsComposition(inputMethodID: String, layout: LayoutInput.Builtin) -> Bool {
        (input.schemaID == nil || input.schemaID == inputMethodID)
            && (input.builtinLayout == nil || input.builtinLayout == layout)
    }

    func copy(name: String? = nil) -> LayoutDefinition {
        var copy = self
        copy.id = UUID().uuidString.lowercased()
        copy.name =
            name
            ?? String(
                format: String(localized: "layout.error.copySuffix", bundle: .module), self.name)
        return copy
    }

    func renamed(_ name: String) -> LayoutDefinition {
        var copy = self
        copy.name = name
        return copy
    }

    func key(at path: LayoutKeyPath) -> LayoutKey? {
        switch path {
        case .row(let row, let key):
            guard rows.indices.contains(row), rows[row].keys.indices.contains(key) else { return nil }
            return rows[row].keys[key]
        case .auxiliary(let area, let key):
            guard let areas = auxiliaryAreas, areas.indices.contains(area),
                areas[area].keys.indices.contains(key)
            else { return nil }
            return areas[area].keys[key]
        }
    }

    /// Draft mutation deliberately allows invalid intermediate values; save validates the whole draft.
    func replacingKey(at path: LayoutKeyPath, with key: LayoutKey) -> LayoutDefinition {
        guard self.key(at: path) != nil else { return self }
        var copy = self
        switch path {
        case .row(let row, let index):
            var keys = rows[row].keys
            keys[index] = key
            copy.rows[row] = LayoutRow(keys: keys)
        case .auxiliary(let area, let index):
            if let original = auxiliaryAreas?[area] {
                var keys = original.keys
                keys[index] = key
                copy.auxiliaryAreas?[area] = LayoutAuxiliaryArea(
                    position: original.position, role: original.role, keys: keys)
            }
        }
        return copy
    }

    func settingT9FirstKeyBehavior(_ behavior: T9FirstKeyBehavior?) -> LayoutDefinition {
        var copy = self
        copy.t9FirstKeyBehavior = behavior
        return copy
    }

    func settingT9QuickSymbols(_ symbols: String?) -> LayoutDefinition {
        var copy = self
        copy.t9QuickSymbols = symbols
        return copy
    }

    func settingCandidateArea(_ area: LayoutCandidateArea) -> LayoutDefinition {
        var copy = self
        copy.candidateArea = area
        return copy
    }

    func settingSplit(_ split: LayoutSplitConfiguration?) -> LayoutDefinition {
        var copy = self
        copy.split = split
        return copy
    }
}

/// Every message is written for the person editing the layout: it says what is wrong and what to
/// change, so hosts show it as is under their own title.
public enum LayoutError: Error, LocalizedError, Equatable {
    case invalid(String)
    case duplicateID(String)
    case unknownID(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .duplicateID: return String(localized: "layout.error.duplicateID", bundle: .module)
        case .unknownID: return String(localized: "layout.error.unknownID", bundle: .module)
        }
    }
}

extension JSONEncoder {
    /// Stable, human-readable on-disk JSON shared by layout and hint documents.
    static func layoutKitPretty() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
