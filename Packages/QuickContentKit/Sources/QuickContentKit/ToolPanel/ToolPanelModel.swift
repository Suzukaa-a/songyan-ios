import Foundation

/// What the keyboard can read from the focused field when the tool panel opens.
///
/// Explicit values only: the panel logic never asks UIKit for a proxy, so the same rules can be
/// tested without a host and cannot accidentally read text at a different moment than the preview
/// was built from.
public struct ToolPanelEditorSnapshot: Equatable, Sendable {
    /// The selected text, nil when nothing is selected.
    public let selectedText: String?
    /// The text before the cursor, nil when the host withholds it.
    public let textBeforeCursor: String?
    /// Memory-only identity of the writable document; nil when no target can be written.
    public let documentIdentifier: String?
    /// The host's own answer for an empty field; nil when it does not say.
    public let documentIsEmpty: Bool?

    /// Whether the cursor is a caret. A paragraph is removed with backwards deletes, and the first
    /// one would only consume a selection, so a paragraph is never anchored over a selection.
    public var hasEmptySelection: Bool { selectedText?.isEmpty != false }

    public init(
        selectedText: String? = nil,
        textBeforeCursor: String? = nil,
        documentIdentifier: String? = nil,
        documentIsEmpty: Bool? = nil
    ) {
        self.selectedText = selectedText
        self.textBeforeCursor = textBeforeCursor
        self.documentIdentifier = documentIdentifier
        self.documentIsEmpty = documentIsEmpty
    }
}

/// Where a replacement may be applied: the exact text and the document it came from.
///
/// The text travels with the anchor because "replace" must delete precisely what the preview
/// showed, and only when the field still holds it.
public struct ToolPanelAnchor: Equatable, Sendable {
    public enum Location: Equatable, Sendable {
        case selection
        case paragraphBeforeCursor
    }

    public let location: Location
    public let text: String
    public let documentIdentifier: String?

    public init(location: Location, text: String, documentIdentifier: String?) {
        self.location = location
        self.text = text
        self.documentIdentifier = documentIdentifier
    }
}

extension ToolPanelAnchor {
    /// Whether `current` still holds exactly the text this anchor points at, in the same document.
    ///
    /// The host repeats this check right before writing, so a field that changed between the panel's
    /// check and the write is never overwritten.
    public func matches(_ current: ToolPanelEditorSnapshot) -> Bool {
        guard let expected = documentIdentifier, current.documentIdentifier == expected else {
            return false
        }
        switch location {
        case .selection:
            return ToolPanelText.usableText(current.selectedText) == text
        case .paragraphBeforeCursor:
            guard current.hasEmptySelection else { return false }
            // A long paragraph was processed from its tail; compare against the same bounded
            // window, not the whole paragraph.
            guard let paragraph = ToolPanelText.paragraphBeforeCursor(current.textBeforeCursor)
            else { return false }
            return ToolPanelText.boundedSuffix(paragraph).text == text
        }
    }
}

/// Why a replacement is no longer safe. The panel keeps the insert and copy actions; only the
/// replace action is withdrawn, and this value names the reason for the one-line notice.
public enum ToolPanelReplacementBlock: Equatable, Sendable {
    /// The processed text did not come from the field (clipboard content), so there is nothing to
    /// replace.
    case noEditorAnchor
    /// Only the head of a long selection was processed; replacing the whole selection would drop
    /// the part that never reached the tool.
    case sourceWasTruncated
    /// The field text the preview was built from changed while the panel was open.
    case textChanged
    /// The keyboard is now editing another document.
    case documentChanged
    /// No writable target could be read at the moment of the write.
    case documentUnavailable
}

public enum ToolPanelReplacementDecision: Equatable, Sendable {
    case replace(ToolPanelAnchor)
    case insertOnly(ToolPanelReplacementBlock)
}

/// The actions the panel offers for a finished result. Copy never touches the field.
public enum ToolPanelWriteOption: Equatable, Sendable {
    case replace
    case insert
    case copy
}

/// One text a tool may process: bounded, and anchored when it came from the field.
public struct ToolPanelPreparedText: Equatable, Sendable {
    public let source: ToolPanelSource
    public let text: String
    /// The source was longer than `ToolPanelText.maximumCharacters`.
    public let wasTruncated: Bool
    /// Where this text sits in the field; nil for clipboard content.
    public let anchor: ToolPanelAnchor?

    init(source: ToolPanelSource, text: String, wasTruncated: Bool, anchor: ToolPanelAnchor?) {
        self.source = source
        self.text = text
        self.wasTruncated = wasTruncated
        self.anchor = anchor
    }
}

/// Tool panel state: which source is processed, the bounded text, and whether a replacement would
/// still write exactly what the user saw.
///
/// Pure value logic. The panel owns the result preview and the run itself; this type only decides
/// the boundaries M-D3 draws around a tool's input and its one write.
public struct ToolPanelModel: Equatable, Sendable {
    public private(set) var editor: ToolPanelEditorSnapshot
    public private(set) var clipboardText: String?
    public private(set) var source: ToolPanelSource
    public private(set) var prepared: ToolPanelPreparedText?
    /// Set once a replacement was refused; the panel then offers insertion only for this result.
    public private(set) var replacementBlocked: ToolPanelReplacementBlock?

    public init(editor: ToolPanelEditorSnapshot, clipboardText: String? = nil) {
        self.editor = editor
        self.clipboardText = clipboardText
        let source = Self.defaultSource(editor: editor, clipboardText: clipboardText)
        self.source = source
        self.prepared = Self.prepare(source: source, editor: editor, clipboardText: clipboardText)
    }

    /// A host that reports text while withholding its content is a protected field. iOS itself does
    /// not route secure fields to third-party keyboards; this also covers hosts that keep the
    /// content (password managers, some web views). Fail closed: no tools rather than tools over
    /// text the keyboard cannot see.
    public var isProtectedField: Bool {
        ToolPanelPrivacy.suppressesTextTools(
            documentIsEmpty: editor.documentIsEmpty,
            contextIsAvailable: editor.textBeforeCursor != nil || editor.selectedText != nil)
    }

    /// Whether a source currently has text to process.
    public func availability(of source: ToolPanelSource) -> ToolPanelSourceUnavailable? {
        switch source {
        case .selection:
            return ToolPanelText.usableText(editor.selectedText) == nil ? .nothingSelected : nil
        case .paragraphBeforeCursor:
            guard editor.hasEmptySelection else { return .noTextBeforeCursor }
            return ToolPanelText.paragraphBeforeCursor(editor.textBeforeCursor) == nil
                ? .noTextBeforeCursor : nil
        case .clipboard:
            return ToolPanelText.usableText(clipboardText) == nil ? .clipboardHasNoText : nil
        }
    }

    /// Switches the processed text. A source with nothing to process is refused, so the panel never
    /// shows an "original" it cannot explain.
    ///
    /// Passing `clipboardText` records a fresh pasteboard read together with the choice; the caller
    /// reads the pasteboard only on this explicit tap.
    @discardableResult
    public mutating func choose(_ source: ToolPanelSource, clipboardText: String? = nil) -> Bool {
        if let clipboardText { self.clipboardText = clipboardText }
        guard
            availability(of: source) == nil,
            let prepared = Self.prepare(
                source: source, editor: editor, clipboardText: self.clipboardText)
        else { return false }
        self.source = source
        self.prepared = prepared
        replacementBlocked = nil
        return true
    }

    /// Records the clipboard answer after the user asked for it, keeping the current source when it
    /// still has text and falling back to the clipboard when the field has none.
    public mutating func updateClipboard(_ text: String?) {
        clipboardText = text
        replacementBlocked = nil
        if source == .clipboard {
            if let prepared = Self.prepare(
                source: .clipboard, editor: editor, clipboardText: text)
            {
                self.prepared = prepared
            } else {
                source = Self.defaultSource(editor: editor, clipboardText: text)
                prepared = Self.prepare(
                    source: source, editor: editor, clipboardText: text)
            }
        }
    }

    /// Re-reads the field before a write and only allows the replacement when the anchor is still
    /// exactly what the preview showed (M-D3).
    ///
    /// `current` is a fresh read of the field; nil means it could not be read, which never proves
    /// that the text is unchanged.
    public func replacementDecision(
        current: ToolPanelEditorSnapshot?
    ) -> ToolPanelReplacementDecision {
        guard let prepared else { return .insertOnly(.documentUnavailable) }
        switch prepared.source {
        case .clipboard:
            return .insertOnly(.noEditorAnchor)
        case .selection where prepared.wasTruncated:
            return .insertOnly(.sourceWasTruncated)
        case .selection, .paragraphBeforeCursor:
            break
        }
        guard let anchor = prepared.anchor, let current else {
            return .insertOnly(.documentUnavailable)
        }
        guard let expected = anchor.documentIdentifier else {
            // The identity is what proves the field did not move under the panel.
            return .insertOnly(.documentUnavailable)
        }
        guard current.documentIdentifier == expected else {
            return .insertOnly(.documentChanged)
        }
        return anchor.matches(current) ? .replace(anchor) : .insertOnly(.textChanged)
    }

    /// Remembers a refused replacement so the panel stops offering it for this result.
    public mutating func noteReplacementBlocked(_ block: ToolPanelReplacementBlock) {
        replacementBlocked = block
    }

    // MARK: - Preparation

    private static func defaultSource(
        editor: ToolPanelEditorSnapshot, clipboardText: String?
    ) -> ToolPanelSource {
        if ToolPanelText.usableText(editor.selectedText) != nil { return .selection }
        if editor.hasEmptySelection,
            ToolPanelText.paragraphBeforeCursor(editor.textBeforeCursor) != nil
        {
            return .paragraphBeforeCursor
        }
        if ToolPanelText.usableText(clipboardText) != nil { return .clipboard }
        return .selection
    }

    private static func prepare(
        source: ToolPanelSource, editor: ToolPanelEditorSnapshot, clipboardText: String?
    ) -> ToolPanelPreparedText? {
        switch source {
        case .selection:
            guard let selected = ToolPanelText.usableText(editor.selectedText) else { return nil }
            let bounded = ToolPanelText.boundedPrefix(selected)
            return ToolPanelPreparedText(
                source: source, text: bounded.text, wasTruncated: bounded.wasTruncated,
                anchor: ToolPanelAnchor(
                    location: .selection, text: bounded.text,
                    documentIdentifier: editor.documentIdentifier))
        case .paragraphBeforeCursor:
            guard editor.hasEmptySelection,
                let paragraph = ToolPanelText.paragraphBeforeCursor(editor.textBeforeCursor)
            else { return nil }
            let bounded = ToolPanelText.boundedSuffix(paragraph)
            return ToolPanelPreparedText(
                source: source, text: bounded.text, wasTruncated: bounded.wasTruncated,
                anchor: ToolPanelAnchor(
                    location: .paragraphBeforeCursor, text: bounded.text,
                    documentIdentifier: editor.documentIdentifier))
        case .clipboard:
            guard let text = ToolPanelText.usableText(clipboardText) else { return nil }
            let bounded = ToolPanelText.boundedPrefix(text)
            return ToolPanelPreparedText(
                source: source, text: bounded.text, wasTruncated: bounded.wasTruncated, anchor: nil)
        }
    }
}

/// The toolbar's privacy rule, kept apart from the panel state because it decides whether the tool
/// entry exists at all.
public enum ToolPanelPrivacy {
    /// A host that reports text while withholding it is treated as a protected field.
    ///
    /// Fails closed: when the emptiness answer is missing (nil), the keyboard keeps offering the
    /// tools, because that case is indistinguishable from a host that simply has not reported yet.
    ///
    /// A selected range proves the host does share text with the keyboard, so a caret at the very
    /// start of the field (no text before it) with a selection is not a protected field.
    public static func suppressesTextTools(
        documentIsEmpty: Bool?, contextIsAvailable: Bool, hasSelectedText: Bool = false
    ) -> Bool {
        documentIsEmpty == false && !contextIsAvailable && !hasSelectedText
    }
}
