import Foundation

// MARK: - Keyboard layouts (physical keycaps and logical keys, independent of engine data)

/// Physical layouts. A layout says nothing about the input scheme typed on it; which
/// schemes can run on it follows from `keyFold`.
public enum KeyboardLayoutKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case qwerty26
    case merged14
    case merged18
    case phone9

    public var id: String { rawValue }

    /// How the keys cover the 26 letters. Scheme compatibility is decided from this, never from the layout's name.
    public enum KeyFold: Sendable {
        /// One letter per key.
        case identity
        /// Neighbouring letters share a key that sends the group's first letter.
        case letterGroups
        /// Letters share the telephone digit keys 2–9.
        case phoneDigits
    }

    public var keyFold: KeyFold {
        switch self {
        case .qwerty26: return .identity
        case .merged14, .merged18: return .letterGroups
        case .phone9: return .phoneDigits
        }
    }

    /// The letter fold a generated adapter applies for this layout; nil for 26-key.
    public var compactFold: CompactFold? {
        switch self {
        case .qwerty26: return nil
        case .merged14: return .merged14
        case .merged18: return .merged18
        case .phone9: return .phone9
        }
    }

    public var shortTitle: String {
        switch self {
        case .qwerty26: return "26键"
        case .merged14: return "14键"
        case .merged18: return "18键"
        case .phone9: return "9键"
        }
    }

    /// User-facing "keyboard layout" name (same wording in Host and keyboard; see `UserTerminology`).
    /// The words live in the package catalog, like the other ordinary interface copy.
    public var userTitle: String {
        switch self {
        case .qwerty26: return String(localized: "core.layout.qwertyTitle", bundle: .module)
        case .merged14: return String(localized: "core.layout.merged14Title", bundle: .module)
        case .merged18: return String(localized: "core.layout.merged18Title", bundle: .module)
        case .phone9: return String(localized: "core.layout.phone9Title", bundle: .module)
        }
    }

    /// Folded layouts (merged letters, phone digits): the engine preedit is the folded code,
    /// so unconfirmed segments must be shown as the candidate's real spelling.
    /// This is the sole front-end criterion for requesting candidate spelling from the engine;
    /// native code does no alphabet guessing.
    public var requiresSpellingDisplay: Bool { keyFold != .identity }

    public var detail: String {
        switch self {
        case .qwerty26: return String(localized: "core.layout.qwertyDetail", bundle: .module)
        case .merged14: return String(localized: "core.layout.merged14Detail", bundle: .module)
        case .merged18: return String(localized: "core.layout.merged18Detail", bundle: .module)
        case .phone9: return String(localized: "core.layout.phone9Detail", bundle: .module)
        }
    }
}

/// Which key each code lands on in a compact layout: every code maps to the code (or digit) its
/// key sends. Adapter generation, identifiers and binding checks read this one value, so a new
/// letter-group layout needs no new code paths.
public struct CompactFold: Hashable, Sendable {
    /// Identifier suffix of generated adapters: the key count for the bundled folds (`14`, `18`,
    /// `9`), and the key count plus `u` and a hash of the mapping for a layout's own grouping
    /// (`14u1a2b3c4d`), so two groupings never share a companion.
    public let id: String
    /// The folded codes, in a fixed order.
    public let source: String
    /// What the key of each `source` code sends, position by position.
    public let target: String

    /// What an exact pick of a merged key's own letter sends. A tap sends that same
    /// letter for the whole group, so the exact pick needs a code of its own; the
    /// generated adapter maps the token onto that letter only. The other letters of a
    /// group are never sent by a tap and type themselves. Tokens stay clear of a–z,
    /// digits (alias and 9-key codes) and the pass-through punctuation `;'/``.
    public let exactTokens: [Character: Character]

    private static let exactTokenPool = Array("!#%*+<>@^_|~")

    public init(id: String, source: String, target: String) {
        guard let fold = Self(checkedID: id, source: source, target: target) else {
            preconditionFailure("fold source and target must align, with no more merged keys than exact tokens")
        }
        self = fold
    }

    /// Nil when `source` and `target` do not align or more keys are merged than there are exact tokens.
    private init?(checkedID id: String, source: String, target: String) {
        guard source.count == target.count else { return nil }
        let shared = Set(zip(source, target).filter { $0 != $1 }.map(\.1))
        let leaders = source.filter { shared.contains($0) }
        guard leaders.count <= Self.exactTokenPool.count else { return nil }
        self.id = id
        self.source = source
        self.target = target
        exactTokens = Dictionary(uniqueKeysWithValues: zip(leaders, Self.exactTokenPool))
    }

    /// The characters the layout can physically send.
    public var keysSent: Set<Character> { Set(target) }

    /// Telephone digits rather than letter groups.
    public var isPhoneDigits: Bool { target.allSatisfy(\.isNumber) }

    public var map: [Character: Character] {
        Dictionary(uniqueKeysWithValues: zip(source, target))
    }

    /// The key count this fold is offered as: `14` for `14` and for `14u1a2b3c4d`.
    public var keyCount: String { String(id.prefix { $0 != "u" }) }

    /// One of the three bundled folds, whose companions are named by the key count alone.
    public var isBuiltin: Bool { id.allSatisfy(\.isNumber) }

    /// The mapping as a registry stores it: the codes, a newline, what each one's key sends.
    public var encoded: String { source + "\n" + target }

    /// The fold `encoded` wrote for a `kind` layout; nil for anything else.
    public static func decode(kind: KeyboardLayoutKind, encoded: String) -> CompactFold? {
        let parts = encoded.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == parts[1].count, !parts[0].isEmpty else { return nil }
        return of(kind: kind, map: Dictionary(zip(parts[0], parts[1]), uniquingKeysWith: { first, _ in first }))
    }

    /// The fold of a layout whose keys send `map` (each code a key covers, letter, stroke or mark,
    /// to the character its key sends) on a `kind` layout. Every merged layout follows one rule,
    /// 9 keys included: a key sends either one of its own codes or a digit 2-9, and all keys send
    /// the same sort. Whether the codes cover what an input method spells with is the companion
    /// generator's question. The bundled mapping gives the bundled fold, so existing companions keep
    /// their names; any other gives a fold of its own. Nil when the mapping breaks the rule, or merges
    /// more keys than there are exact tokens.
    public static func of(kind: KeyboardLayoutKind, map: [Character: Character]) -> CompactFold? {
        guard let builtin = kind.compactFold, !map.isEmpty else { return nil }
        let sent = Set(map.values)
        let digits = sent.allSatisfy { ("2"..."9").contains($0) }
        let own = sent.allSatisfy { map[$0] == $0 }
        guard digits || own else { return nil }
        if map == builtin.map { return builtin }
        let source = String(map.keys.sorted())
        let target = String(source.map { map[$0]! })
        let hash = CRC32.checksum(Array((source + "\u{0}" + target).utf8))
        return CompactFold(checkedID: builtin.id + "u" + String(format: "%08x", hash), source: source, target: target)
    }

    public static let merged14 = CompactFold(
        id: "14", source: "qwertyuiopasdfghjklzxcvbnm",
        target: "qqeettuuooaaddggjjlzzccbbm")
    public static let merged18 = CompactFold(
        id: "18", source: "qwertyuiopasdfghjklzxcvbnm",
        target: "qwwrryuiipassffhjjlzxxvbbm")
    public static let phone9 = CompactFold(
        id: "9", source: "abcdefghijklmnopqrstuvwxyz",
        target: "22233344455566677778889999")
}

/// The CRC-32 (IEEE) of a byte string, the same checksum `java.util.zip.CRC32` gives, so a
/// grouping gets the same fold id on both platforms.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

/// The bundled input schemes. Both are plain 26-key schemes; every compact layout runs on a
/// companion made by the same generator as for installed schemes, so layouts stay scheme-neutral.
public enum BuiltinTemplateSchemas {
    public static let quanpin = "songyan_quanpin"
    public static let flypy = "songyan_flypy"
    public static let sourceSchemaIDs = [quanpin, flypy]
    /// Same as `schema/name` in the YAML; a companion shows its source's name.
    public static let names = [quanpin: "内置全拼", flypy: "内置小鹤双拼"]

    /// What the interface calls a bundled scheme or one of its companions while it carries its
    /// bundled name (or none). The YAML keeps the Simplified Chinese name the engine and saved
    /// choices know; the words follow the app language. A name the user gave it (a dictionary
    /// built on it) is theirs and stays.
    public static func localizedName(for id: String, name: String = "") -> String? {
        let source = sourceSchemaIDs.contains(id) ? id : adapters.first { $0.schemaID == id }?.sourceSchemaID
        guard let source, name.isEmpty || name == id || name == source || name == names[source] else { return nil }
        switch source {
        case quanpin: return String(localized: "core.builtin.quanpinName", bundle: .module)
        case flypy: return String(localized: "core.builtin.flypyName", bundle: .module)
        default: return nil
        }
    }

    /// The generated companions shipped in the bundle. Ids follow
    /// `CompactSchemaAdapter.identifier`; the PackageManager tests regenerate the files and
    /// check them against this table.
    public static let adapters: [KeyboardResourceSet.EncodingAdapter] = [
        .init(
            sourceSchemaID: quanpin, schemaID: "keyboard_47246213a538cb99d374_14", layout: .merged14,
            schemaName: names[quanpin]),
        .init(
            sourceSchemaID: quanpin, schemaID: "keyboard_47246213a538cb99d374_18", layout: .merged18,
            schemaName: names[quanpin]),
        .init(
            sourceSchemaID: quanpin, schemaID: "keyboard_47246213a538cb99d374_9", layout: .phone9,
            schemaName: names[quanpin]),
        .init(
            sourceSchemaID: flypy, schemaID: "keyboard_3d7821f984693864ae91_14", layout: .merged14,
            schemaName: names[flypy]),
        .init(
            sourceSchemaID: flypy, schemaID: "keyboard_3d7821f984693864ae91_18", layout: .merged18,
            schemaName: names[flypy]),
        .init(
            sourceSchemaID: flypy, schemaID: "keyboard_3d7821f984693864ae91_9", layout: .phone9,
            schemaName: names[flypy]),
    ]

    public static var layoutEntries: [KeyboardResourceSet.LayoutEntry] {
        sourceSchemaIDs.map { .init(layout: .qwerty26, schemaID: $0) }
    }

    /// The engine schema running `sourceID` on `layout`.
    public static func engineSchemaID(source sourceID: String, layout: KeyboardLayoutKind) -> String? {
        guard sourceSchemaIDs.contains(sourceID) else { return nil }
        return KeyboardResourceSet.engineSchemaID(
            source: sourceID, layout: layout, adapters: adapters, bindings: layoutEntries)
    }

    public static func layout(forSchemaID schemaID: String) -> KeyboardLayoutKind? {
        if sourceSchemaIDs.contains(schemaID) { return .qwerty26 }
        return adapters.first { $0.schemaID == schemaID }?.layout
    }

    /// Engine schema for a layout when no resource set maps it: the first scheme, as the
    /// built-in resource set picks without a selection.
    public static func defaultSchemaID(for layout: KeyboardLayoutKind) -> String? {
        engineSchemaID(source: quanpin, layout: layout)
    }
}

// MARK: - Key actions and keycaps

public enum KeyAction: Equatable, Sendable {
    /// Input logical code (single character: a letter or digit; the representative letter on 14-key).
    case code(String)
    /// Digit/symbol key that commits text directly (e.g. "，" "1" "@").
    /// See InputSession.insertLiteral: bypasses the engine and composition; during composition it confirms first, then commits.
    case literal(String)
    /// Explicit alphabetic alternate (e.g. á): English Shift applies; DIY literal stays verbatim.
    case letterVariant(String)
    /// Space: commits a space when idle; confirms/selects via the engine during composition.
    case space
    /// Backspace.
    case backspace
    /// Return: confirms during composition, otherwise sends a newline.
    case enter
    /// Switch keyboard (globe key: system input-method list).
    case switchKeyboard
    /// Cycle through the built-in layouts (quick schema switching in the experimental keyboard).
    case cycleLayout

    public static func == (lhs: KeyAction, rhs: KeyAction) -> Bool {
        switch (lhs, rhs) {
        case let (.code(a), .code(b)): return a == b
        case let (.literal(a), .literal(b)): return a == b
        case let (.letterVariant(a), .letterVariant(b)): return a == b
        case (.space, .space), (.backspace, .backspace), (.enter, .enter),
            (.switchKeyboard, .switchKeyboard), (.cycleLayout, .cycleLayout):
            return true
        default: return false
        }
    }
}

/// A keycap (size and labels). `width` is a relative unit for flex layout.
public struct KeyCap: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String  // primary label (letter/symbol/text)
    public let subtitle: String?  // secondary label (small text, e.g. shuangpin final hint, 9-key letters)
    public let action: KeyAction
    public let width: Int  // relative width unit (1 = regular key)

    public init(
        id: String, title: String, subtitle: String? = nil,
        action: KeyAction, width: Int = 1
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.width = width
    }
}

public struct KeyboardRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let caps: [KeyCap]

    public init(id: String, caps: [KeyCap]) {
        self.id = id
        self.caps = caps
    }
}

// MARK: - Layout table

public enum KeyboardLayoutTable {
    /// Letter/main rows for a layout (excluding the bottom control row).
    public static func mainRows(for layout: KeyboardLayoutKind) -> [KeyboardRow] {
        switch layout {
        case .qwerty26:
            return [
                letterRow("qwertyuiop"),
                letterRow("asdfghjkl"),
                letterRow("zxcvbnm"),
            ]
        case .merged14:
            return [
                groupRow(["qw", "er", "ty", "ui", "op"]),
                groupRow(["as", "df", "gh", "jk"]),
                groupRow(["l", "zx", "cv", "bn", "m"]),
            ]
        case .merged18:
            return [
                groupRow(["q", "we", "rt", "y", "u", "io", "p"]),
                groupRow(["a", "sd", "fg", "h", "jk", "l"]),
                groupRow(["z", "xc", "v", "bn", "m"]),
            ]
        case .phone9:
            return [
                groupRow(["1", "2", "3"], phone: true),
                groupRow(["4", "5", "6"], phone: true),
                groupRow(["7", "8", "9"], phone: true),
            ]
        }
    }

    /// Bottom control row, shared by all layouts: switch keyboard / space / backspace / return / layout cycle.
    public static func controlRow() -> KeyboardRow {
        KeyboardRow(
            id: "controls",
            caps: [
                KeyCap(
                    id: "layout", title: "布局",
                    subtitle: nil, action: .cycleLayout, width: 1),
                KeyCap(
                    id: "globe", title: "🌐",
                    subtitle: "切换", action: .switchKeyboard, width: 1),
                KeyCap(id: "space", title: "空格", action: .space, width: 4),
                KeyCap(id: "backspace", title: "⌫", action: .backspace, width: 1),
                KeyCap(id: "enter", title: "⏎", action: .enter, width: 1),
            ])
    }

    /// All rows = main rows + control row.
    public static func rows(for layout: KeyboardLayoutKind) -> [KeyboardRow] {
        mainRows(for: layout) + [controlRow()]
    }

    // MARK: Standalone English QWERTY (direct English mode only; not a KeyboardLayoutKind)

    /// Standalone 26-key QWERTY main rows for direct English mode (three letter rows; the
    /// control row is shared via `controlRow()`). Decoupled from any Chinese layout/schema:
    /// English mode uses the full 26 keys even when the Chinese layout is 14/9-key, and does
    /// not change the Chinese layout remembered by `select(layout:)` or the resource-set
    /// schema mapping.
    ///
    /// `displayShift` only affects the case of the keycap title; the action is always a
    /// lowercase `.code`. The committed case is decided by InputSession from the current
    /// Shift state in English mode (Chinese composition codes stay lowercase).
    /// Key ids don't depend on display case (e.g. `en-a`), so Shift re-renders keep SwiftUI identity.
    public static func englishRows(displayShift: ShiftState = .off) -> [KeyboardRow] {
        let shifted = displayShift.isActive
        return ["qwertyuiop", "asdfghjkl", "zxcvbnm"].enumerated().map { rowIndex, letters in
            let caps = letters.map { ch -> KeyCap in
                let lower = String(ch)
                return KeyCap(
                    id: "en-\(lower)",
                    title: shifted ? lower.uppercased() : lower,
                    action: .code(lower))
            }
            return KeyboardRow(id: "en-row-\(rowIndex)", caps: caps)
        }
    }

    // MARK: helpers

    private static func letterRow(_ letters: String) -> KeyboardRow {
        let caps = letters.map { ch -> KeyCap in
            let id = "code-\(ch)"
            return KeyCap(id: id, title: String(ch), action: .code(String(ch)))
        }
        return KeyboardRow(id: "row-\(letters.prefix(3))", caps: caps)
    }

    private static func groupRow(_ groups: [String], phone: Bool = false) -> KeyboardRow {
        let caps = groups.enumerated().map { index, g -> KeyCap in
            let id = "group-\(g)-\(index)"
            if phone {
                // Phone keys: digit as title, letters as subtitle
                let letters = phoneLetters[g] ?? ""
                return KeyCap(id: id, title: g, subtitle: letters, action: .code(g))
            }
            // 14-key cluster: sends the representative letter (first of the cluster); the subtitle lists the cluster's letters
            let rep = String(g.prefix(1))
            return KeyCap(id: id, title: rep, subtitle: g, action: .code(rep))
        }
        return KeyboardRow(id: "row-\(groups.joined().prefix(6))", caps: caps)
    }

    /// Telephone keypad letters (abc/def/ghi/jkl/mno/pqrs/tuv/wxyz).
    private static let phoneLetters: [String: String] = [
        "1": "", "2": "abc", "3": "def",
        "4": "ghi", "5": "jkl", "6": "mno",
        "7": "pqrs", "8": "tuv", "9": "wxyz",
    ]
}
