import Foundation
import KeyboardCore
import QuickContentKit

extension KeyboardController {
    /// Whether the toolbar offers the tools entry at all.
    ///
    /// The entry needs a host that can read and write the field, and it disappears when the host
    /// reports text while withholding it (a protected field, see `ToolPanelPrivacy`).
    public var showsTextTools: Bool {
        onReadToolTextSource != nil && !suppressesTextTools
    }

    /// A host that holds text but withholds its content is never offered text tools.
    public var suppressesTextTools: Bool {
        ToolPanelPrivacy.suppressesTextTools(
            documentIsEmpty: hostDocumentIsEmpty,
            contextIsAvailable: hostContextBeforeInput != nil)
    }

    /// A fresh read of the field for the tool panel; nil when no editable target exists.
    func readToolTextSource() -> ToolPanelEditorSnapshot? {
        onReadToolTextSource?()
    }

    /// Replaces exactly the anchored text. The host checks the anchor again, so this returns false
    /// instead of writing when the field changed between the decision and the write.
    @discardableResult
    func replaceToolAnchor(_ anchor: ToolPanelAnchor, with text: String) -> Bool {
        // A composition owns the text around the cursor; a tool never writes into it.
        guard !snapshot.isComposing else { return false }
        guard onReplaceToolAnchor?(anchor, text) == true else { return false }
        // The field changed without going through the engine. The English word being tracked
        // belonged to the text that is gone, so the next letter starts a new word.
        resetEnglishWord()
        commitSequence &+= 1
        return true
    }

    /// Copies a result through the host, which owns the pasteboard-permission fact.
    func copyToolResult(_ text: String) -> Bool {
        onCopyToolResult?(text) ?? false
    }
}
