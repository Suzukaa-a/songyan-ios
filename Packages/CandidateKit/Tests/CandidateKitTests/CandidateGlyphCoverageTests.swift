import CoreText
import XCTest

@testable import CandidateKit

/// Rare ideographs (CJK Extension B and later) that no installed font covers must not reach the candidate
/// bar as LastResort boxes.
final class CandidateGlyphCoverageTests: XCTestCase {
    private let base = CTFontCreateWithName("Helvetica" as CFString, 20, nil)

    func testCommonCharactersResolveToARealFont() {
        XCTAssertTrue(CandidateGlyphCoverage.hasGlyph("木", in: base))
        XCTAssertTrue(CandidateGlyphCoverage.hasGlyph("不", in: base))
    }

    func testASupplementaryCharacterWithoutAFontShowsItsCodePoint() {
        let shown = CandidateGlyphCoverage.displayText("木\u{20000}", covered: { _ in false })
        XCTAssertEqual(shown, "木U+20000")
    }

    func testACoveredSupplementaryCharacterIsDrawnAsItself() {
        XCTAssertEqual(CandidateGlyphCoverage.displayText("\u{20087}", covered: { _ in true }), "\u{20087}")
    }

    func testTextBelowTheSupplementaryIdeographsIsNeverAsked() {
        let shown = CandidateGlyphCoverage.displayText(
            "木㭁😀", covered: { _ in XCTFail("asked about a common character"); return false })
        XCTAssertEqual(shown, "木㭁😀")
    }

    /// Whatever the platform ships, the text the user sees is either the character a real font draws or
    /// its code point; never a character that resolves to LastResort.
    func testDisplayTextNeverLeavesAnUndrawableCharacter() {
        for scalar in [0x20000, 0x20087, 0x2A700, 0x2B740, 0x2CEB0, 0x30000].compactMap(Unicode.Scalar.init) {
            let shown = CandidateGlyphCoverage.displayText(String(scalar), base: base)
            if shown.hasPrefix("U+") {
                XCTAssertFalse(CandidateGlyphCoverage.hasGlyph(scalar, in: base))
            } else {
                XCTAssertTrue(CandidateGlyphCoverage.hasGlyph(scalar, in: base))
            }
        }
    }
}
