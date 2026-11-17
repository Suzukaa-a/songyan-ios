import CoreText
import Foundation

/// Candidates the system has no font for (CJK Extension B and later on iOS) would draw as CoreText's
/// LastResort boxes, which tell the user nothing. They are shown as their code point instead; the text
/// that is committed is never changed.
enum CandidateGlyphCoverage {
    /// Supplementary CJK ideograph blocks (Extension B through H); everything below is covered by PingFang.
    private static let rareRange: ClosedRange<UInt32> = 0x20000...0x323AF

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [UInt32: Bool] = [:]

    /// True when CoreText's cascade finds a real font for `scalar`, not the LastResort placeholder.
    static func hasGlyph(_ scalar: Unicode.Scalar, in base: CTFont) -> Bool {
        let text = String(scalar) as CFString
        let resolved = CTFontCreateForString(base, text, CFRange(location: 0, length: CFStringGetLength(text)))
        return (CTFontCopyPostScriptName(resolved) as String) != "LastResort"
    }

    /// `text` with every rare ideograph that no font covers replaced by `U+XXXXX`.
    static func displayText(_ text: String, base: CTFont) -> String {
        displayText(text) { scalar in cached(scalar) { hasGlyph(scalar, in: base) } }
    }

    /// Same replacement with the coverage question injected.
    static func displayText(_ text: String, covered: (Unicode.Scalar) -> Bool) -> String {
        guard text.unicodeScalars.contains(where: { rareRange.contains($0.value) }) else { return text }
        var out = ""
        for scalar in text.unicodeScalars {
            if rareRange.contains(scalar.value), !covered(scalar) {
                out += "U+" + String(scalar.value, radix: 16, uppercase: true)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func cached(_ scalar: Unicode.Scalar, _ compute: () -> Bool) -> Bool {
        lock.lock()
        let known = cache[scalar.value]
        lock.unlock()
        if let known { return known }
        let result = compute()
        lock.lock()
        cache[scalar.value] = result
        lock.unlock()
        return result
    }
}
