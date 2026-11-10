import CoreText
import Foundation
import KeyboardCore

/// The language attribute on text the keyboard draws: candidates, the composition badge and keycap faces.
///
/// The same character (直, 骨, 海) takes different glyph forms in Japanese, Traditional and Simplified
/// Chinese. CoreText uses the text-run language to select localized glyph forms. The keyboard keeps
/// that attribute on the text measured and drawn by `CandidateLanguageText`.
public enum CandidateTextLanguage {
    /// CoreText's documented language attribute.
    public static let attributeName = NSAttributedString.Key(kCTLanguageAttributeName as String)

    /// `text` marked as `language` for its whole length.
    public static func attributed(
        _ text: String, language: InputLanguage
    ) -> NSMutableAttributedString {
        let string = NSMutableAttributedString(string: text)
        apply(to: string, language: language)
        return string
    }

    /// Marks the whole string as `language`; an empty string simply receives no run.
    public static func apply(to string: NSMutableAttributedString, language: InputLanguage) {
        guard string.length > 0 else { return }
        string.addAttribute(
            attributeName, value: language.rawValue,
            range: NSRange(location: 0, length: string.length))
    }
}
