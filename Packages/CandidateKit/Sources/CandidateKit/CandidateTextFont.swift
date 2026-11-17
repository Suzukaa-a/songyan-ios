import KeyboardCore
import SwiftUI

/// Fonts for text the keyboard draws itself. The candidate area injects the skin's font family and weight
/// as values (it does not link SkinKit), so the same two strings have to produce the same face here.
///
/// `family` may also be an imported-font family (`ImportedFontFamily`): that font is drawn as it is, so
/// the skin's weight does not apply, and the font's own cascade covers characters it lacks.
enum CandidateTextFont {
    static func swiftUI(size: Double, family: String, weight: String) -> Font {
        if let imported = ImportedFontFamily.ctFont(family: family, size: size) { return Font(imported) }
        let uiWeight: Font.Weight = weight == "semibold" ? .semibold : weight == "regular" ? .regular : .medium
        switch family {
        case "rounded": return .system(size: size, weight: uiWeight, design: .rounded)
        case "serif": return .system(size: size, weight: uiWeight, design: .serif)
        case "monospaced": return .system(size: size, weight: uiWeight, design: .monospaced)
        default: return .system(size: size, weight: uiWeight)
        }
    }

    #if canImport(UIKit)
        /// Same face as `KeyboardAppearance.uiFont`, so a candidate/cell keeps the skin's font when it is
        /// drawn by `CandidateLanguageText` instead of SwiftUI `Text`.
        static func uiFont(size: Double, family: String, weight: String) -> UIFont {
            let key = "\(family)|\(weight)|\(size)" as NSString
            if let cached = cache.object(forKey: key) { return cached }
            if let imported = ImportedFontFamily.ctFont(family: family, size: size) {
                // CTFont and UIFont are toll-free bridged.
                let font = (imported as AnyObject) as! UIFont
                cache.setObject(font, forKey: key)
                return font
            }
            let uiWeight: UIFont.Weight =
                weight == "semibold" ? .semibold : weight == "regular" ? .regular : .medium
            let base = UIFont.systemFont(ofSize: size, weight: uiWeight)
            let design: UIFontDescriptor.SystemDesign =
                family == "rounded"
                ? .rounded : family == "serif" ? .serif : family == "monospaced" ? .monospaced : .default
            let font = UIFont(
                descriptor: base.fontDescriptor.withDesign(design) ?? base.fontDescriptor, size: size)
            cache.setObject(font, forKey: key)
            return font
        }

        // NSCache is internally synchronized; it is only a face lookup, not user data.
        nonisolated(unsafe) private static let cache = NSCache<NSString, UIFont>()

        /// Distance from the top of a one-line label frame to its first baseline: the expanded
        /// candidate rows align their badge to this, as they did to the `Text` this replaces.
        static func firstBaseline(size: Double, family: String, weight: String) -> CGFloat {
            uiFont(size: size, family: family, weight: weight).ascender
        }
    #endif
}
