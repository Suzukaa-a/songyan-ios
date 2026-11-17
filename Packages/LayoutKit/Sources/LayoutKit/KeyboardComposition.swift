import Foundation

/// The key a pairing is stored under: `UserKeyboard.id`, i.e. `"<inputMethodID>:<shape>"`, plus
/// `"#<layoutID>"` for a keyboard that names the layout it types on. The layout ID may hold any
/// character, so it is everything after the first "#"; the input method ID may itself contain
/// ":", so the shape is the part after the last one before it.
public struct KeyboardCompositionKey: Hashable, Sendable {
    public let inputMethodID: String
    public let layout: LayoutInput.Builtin
    /// The layout this keyboard types on. nil is a keyboard saved before keyboards named their
    /// layout: its main layout comes from the pairing stored under the shape.
    public let layoutID: String?

    public init(inputMethodID: String, layout: LayoutInput.Builtin, layoutID: String? = nil) {
        self.inputMethodID = inputMethodID
        self.layout = layout
        self.layoutID = layoutID.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Nil for a malformed key: no separator, an empty input method, an unknown shape or an empty
    /// layout ID after "#".
    public init?(_ rawValue: String) {
        var head = Substring(rawValue)
        var layoutID: String?
        if let mark = rawValue.firstIndex(of: "#") {
            head = rawValue[..<mark]
            layoutID = String(rawValue[rawValue.index(after: mark)...])
            guard layoutID?.isEmpty == false else { return nil }
        }
        guard let separator = head.lastIndex(of: ":"), separator != head.startIndex,
            let layout = LayoutInput.Builtin(rawValue: String(head[head.index(after: separator)...]))
        else { return nil }
        self.init(inputMethodID: String(head[..<separator]), layout: layout, layoutID: layoutID)
    }

    public var rawValue: String { shapeKey.plainRawValue + (layoutID.map { "#" + $0 } ?? "") }

    /// The key of the shape this keyboard runs on, shared by every layout of that shape. Pairings
    /// saved before keyboards named their layout live here.
    public var shapeKey: KeyboardCompositionKey {
        KeyboardCompositionKey(inputMethodID: inputMethodID, layout: layout)
    }

    private var plainRawValue: String { inputMethodID + ":" + layout.rawValue }
}

/// Indexed by `KeyboardCompositionKey.rawValue` in LayoutRegistry.
public struct KeyboardComposition: Codable, Equatable, Sendable {
    public var mainLayoutID: String
    public var symbolPageID: String
    public var numericPageID: String
    public var englishPageID: String

    /// The default pages are automatic: the symbol page follows the configured presentation
    /// and the 123 page follows the live keyboard (marks and keypad shape), so saving a pairing
    /// without touching a page never changes what those pages show.
    public init(
        mainLayoutID: String, symbolPageID: String = KeyboardPagePresets.symbolsSystem.id,
        numericPageID: String = KeyboardPagePresets.numericAutomatic.id,
        englishPageID: String = KeyboardPagePresets.englishQwerty.id
    ) {
        self.mainLayoutID = mainLayoutID
        self.symbolPageID = symbolPageID
        self.numericPageID = numericPageID
        self.englishPageID = englishPageID
    }

    public func pageID(for kind: KeyboardPageKind) -> String {
        switch kind {
        case .symbols: return symbolPageID
        case .numeric: return numericPageID
        case .english: return englishPageID
        }
    }

    public mutating func setPageID(_ id: String, for kind: KeyboardPageKind) {
        switch kind {
        case .symbols: symbolPageID = id
        case .numeric: numericPageID = id
        case .english: englishPageID = id
        }
    }
}

/// Caller-injected physical-layout availability. The host app passes the shared input-language
/// rules here; LayoutKit itself stays free of KeyboardCore and never owns a second copy of them.
public struct LayoutAvailability: Sendable {
    /// Whether a layout definition may be used for this keyboard pairing.
    public typealias Allows = @Sendable (LayoutDefinition, KeyboardCompositionKey) -> Bool
    /// A family-preferred main layout ID for this keyboard, when its definition is registered.
    public typealias PreferredMainLayoutID = @Sendable (KeyboardCompositionKey) -> String?

    public let allows: Allows
    public let preferredMainLayoutID: PreferredMainLayoutID?

    public init(
        allows: @escaping Allows,
        preferredMainLayoutID: PreferredMainLayoutID? = nil
    ) {
        self.allows = allows
        self.preferredMainLayoutID = preferredMainLayoutID
    }

    /// No restriction: today's behaviour, used by call sites without a policy owner.
    public static let unrestricted = LayoutAvailability(allows: { _, _ in true })
}
