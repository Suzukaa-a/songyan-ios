import Foundation

/// Bounds and text extraction shared by the tool panel and its tests.
///
/// Every bound here is about what the user sees: the panel shows the exact text a tool will
/// receive, so the same rules decide the preview, the run input and the replacement anchor.
public enum ToolPanelText {
    /// Longest text one run processes, in characters (M-D3: a paragraph is capped at 1000).
    /// The runner has its own, larger safety limit; the panel stays below it so the preview is what
    /// the tool actually works on.
    public static let maximumCharacters = 1000

    /// The paragraph that ends at the cursor: the characters after the last line break.
    ///
    /// nil when there is no text there (start of the field, right after a line break), because a
    /// tool that receives nothing cannot offer a meaningful result.
    public static func paragraphBeforeCursor(_ textBeforeCursor: String?) -> String? {
        guard let text = textBeforeCursor, !text.isEmpty else { return nil }
        let paragraph: Substring
        if let lastBreak = text.lastIndex(where: { $0.isNewline }) {
            paragraph = text[text.index(after: lastBreak)...]
        } else {
            paragraph = text[...]
        }
        // A paragraph of nothing but spaces leaves a tool nothing to change; the field's own
        // spaces are not text the user asked to transform.
        guard
            !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return String(paragraph)
    }

    /// Keeps the head of `text`. Used for a selection: when a tool output is
    /// inserted, the inserted text is what the user just looked at.
    public static func boundedPrefix(
        _ text: String, limit: Int = maximumCharacters
    ) -> (text: String, wasTruncated: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }

    /// Keeps the tail of `text`, the part nearest the cursor. Used for the paragraph before the
    /// cursor: replacing it deletes back from the cursor, so only this part can be replaced exactly.
    public static func boundedSuffix(
        _ text: String, limit: Int = maximumCharacters
    ) -> (text: String, wasTruncated: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.suffix(limit)), true)
    }

    /// Text worth processing: not empty. Surrounding whitespace stays part of the returned text so
    /// an anchor matches exactly the characters a replacement deletes.
    public static func usableText(_ text: String?) -> String? {
        guard let text, !text.isEmpty,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }
}
