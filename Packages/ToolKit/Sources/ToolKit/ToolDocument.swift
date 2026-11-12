/// Length rules shared with the Android model: UTF-16 code units, and truncation
/// keeps the end of the source range without splitting a surrogate pair.
public enum ToolTextUnits {
    public static func count(_ text: String) -> Int {
        text.utf16.count
    }

    /// The longest suffix with at most maximumUnits code units. A cut that would
    /// split a surrogate pair drops one more unit, so the result stays valid text.
    public static func suffix(_ text: String, maximumUnits: Int) -> String {
        guard maximumUnits > 0 else { return "" }
        let units = Array(text.utf16)
        guard units.count > maximumUnits else { return text }
        var start = units.count - maximumUnits
        if units[start] >= 0xDC00, units[start] <= 0xDFFF {
            start += 1
        }
        return String(decoding: units[start...], as: UTF16.self)
    }
}

/// What the host's single document gateway can do. A gateway that cannot replace
/// an arbitrary sub-range cannot write the tail of a selection: iOS's insertText
/// replaces the whole selection, so the host must say so instead of guessing.
public struct ToolDocumentCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The gateway can replace the processed tail of the caret-preceding text
    /// (for example delete those characters, then insert the result). Replacing
    /// only the tail of a selection is a different, unsupported operation.
    public static let replacePrecedingTail = ToolDocumentCapabilities(rawValue: 1 << 0)

    /// The gateway can insert while a selection is active without replacing the
    /// selected text. This is independent of replacing a preceding tail.
    public static let insertPreservingSelection = ToolDocumentCapabilities(rawValue: 1 << 1)
}

/// How the focused field may be used. Password and no-text fields never expose
/// their content, and a password field never takes a write.
public enum ToolDocumentPrivacy: String, Equatable, Sendable {
    case normal
    case noPersonalizedLearning
    case password
    case noText
}

/// Opaque identity of the editor the keyboard is bound to. It changes when the
/// user moves to another field, so an async result can never be written back
/// into a different one.
public struct ToolDocumentID: Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// What the keyboard can read at one moment. The keyboard builds this through
/// its single document gateway, so a password field never exposes text here.
public struct ToolDocumentSnapshot: Equatable, Sendable {
    public let documentID: ToolDocumentID
    public let privacy: ToolDocumentPrivacy
    public let selectedText: String?
    public let textBeforeCaret: String?

    public init(
        documentID: ToolDocumentID, privacy: ToolDocumentPrivacy, selectedText: String?,
        textBeforeCaret: String?
    ) {
        self.documentID = documentID
        self.privacy = privacy
        self.selectedText = selectedText
        self.textBeforeCaret = textBeforeCaret
    }

    public var isSecureEntry: Bool { privacy == .password }
    public var withholdsText: Bool { privacy == .password || privacy == .noText }
}

/// The text one run receives and the range a result replaces.
public struct ToolInput: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        case selection
        case precedingSegment
    }

    public let text: String
    public let scope: Scope

    /// True when only the end of the source range is processed.
    public let isTruncated: Bool

    public init(text: String, scope: Scope, isTruncated: Bool) {
        self.text = text
        self.scope = scope
        self.isTruncated = isTruncated
    }

    /// UTF-16 code units the result replaces at the end of the source range.
    public var unitCount: Int { ToolTextUnits.count(text) }
}

public enum ToolInputUnavailableReason: Error, Equatable, Sendable {
    case secureEntry
    case noText
}

public enum ToolInputSelection {
    /// Selection first; without one, the caret-preceding text. Both are capped by
    /// the caller's limit and keep their end, and a capped text reports truncation
    /// so the preview can say only the tail was processed.
    public static func select(
        from document: ToolDocumentSnapshot, limits: ToolLimits
    ) -> Result<ToolInput, ToolInputUnavailableReason> {
        if document.isSecureEntry { return .failure(.secureEntry) }
        if document.withholdsText { return .failure(.noText) }
        if let selected = document.selectedText, !selected.isEmpty {
            return capped(selected, scope: .selection, limits: limits)
        }
        guard let before = document.textBeforeCaret, !before.isEmpty else {
            return .failure(.noText)
        }
        return capped(before, scope: .precedingSegment, limits: limits)
    }

    private static func capped(
        _ text: String, scope: ToolInput.Scope, limits: ToolLimits
    ) -> Result<ToolInput, ToolInputUnavailableReason> {
        let units = ToolTextUnits.count(text)
        guard units > limits.maximumInputUnits else {
            return .success(ToolInput(text: text, scope: scope, isTruncated: false))
        }
        let tail = ToolTextUnits.suffix(text, maximumUnits: limits.maximumInputUnits)
        guard !tail.isEmpty else { return .failure(.noText) }
        return .success(ToolInput(text: tail, scope: scope, isTruncated: true))
    }
}
