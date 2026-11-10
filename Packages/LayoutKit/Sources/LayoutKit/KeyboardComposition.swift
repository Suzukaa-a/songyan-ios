import Foundation

/// The key a pairing is stored under: `UserKeyboard.id`, i.e. `"<inputMethodID>:<builtin layout>"`.
/// The input method ID may itself contain ":", so the layout is the part after the last one.
public struct KeyboardCompositionKey: Hashable, Sendable {
    public let inputMethodID: String
    public let layout: LayoutInput.Builtin

    public init(inputMethodID: String, layout: LayoutInput.Builtin) {
        self.inputMethodID = inputMethodID
        self.layout = layout
    }

    /// Nil for a malformed key: no separator, an empty input method or an unknown layout.
    public init?(_ rawValue: String) {
        guard let separator = rawValue.lastIndex(of: ":"), separator != rawValue.startIndex,
            let layout = LayoutInput.Builtin(rawValue: String(rawValue[rawValue.index(after: separator)...]))
        else { return nil }
        self.init(inputMethodID: String(rawValue[..<separator]), layout: layout)
    }

    public var rawValue: String { inputMethodID + ":" + layout.rawValue }
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
