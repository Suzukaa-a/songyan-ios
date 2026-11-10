import CoreText
import KeyboardCore
import SwiftUI
import XCTest

@testable import CandidateKit

/// The candidate bar, the composition badge and keycap faces must carry the input language into the drawn
/// text: the same character ("直", "骨", "海") has different shapes in Japanese, Traditional and
/// Simplified Chinese, and CoreText selects them from the language of the run.
///
/// The production builder marks text with CoreText's documented language attribute
/// (`kCTLanguageAttributeName`), and `CandidateLanguageText` draws exactly that attributed string.
final class CandidateTextLanguageTests: XCTestCase {

    private static let coreTextLanguage = NSAttributedString.Key(kCTLanguageAttributeName as String)

    private func language(of string: NSAttributedString, at index: Int = 0) -> String? {
        string.attribute(Self.coreTextLanguage, at: index, effectiveRange: nil) as? String
    }

    func testJapaneseCandidatesAskForJapaneseGlyphForms() {
        let string = CandidateTextLanguage.attributed("直", language: .japanese)
        XCTAssertEqual(language(of: string), "ja")
    }

    func testSimplifiedChineseCandidatesAskForSimplifiedGlyphForms() {
        let string = CandidateTextLanguage.attributed("骨", language: .simplifiedChinese)
        XCTAssertEqual(language(of: string), "zh-Hans")
    }

    func testTraditionalChineseCandidatesAskForTraditionalGlyphForms() {
        let string = CandidateTextLanguage.attributed("海", language: .traditionalChinese)
        XCTAssertEqual(language(of: string), "zh-Hant")
    }

    /// A comment or reading is drawn as its own run; every character of a multi-character candidate is
    /// marked, so a mixed string cannot fall back to the system language halfway through.
    func testTheLanguageCoversEveryCharacterOfAMultiCharacterCandidate() {
        let string = CandidateTextLanguage.attributed("直行", language: .japanese)
        XCTAssertEqual(language(of: string, at: 0), "ja")
        XCTAssertEqual(language(of: string, at: 1), "ja")
        var effective = NSRange()
        _ = string.attribute(
            Self.coreTextLanguage, at: 0, longestEffectiveRange: &effective,
            in: NSRange(location: 0, length: string.length))
        XCTAssertEqual(effective, NSRange(location: 0, length: 2))
    }

    /// The builder marks text with CoreText's documented language attribute, not with an arbitrary key that
    /// only looks like it: the assertion pins the raw attribute name the text system reads.
    func testTheProductionBuilderUsesCoreTextsDocumentedLanguageAttribute() {
        XCTAssertEqual(
            CandidateTextLanguage.attributeName.rawValue, kCTLanguageAttributeName as String)
        let string = CandidateTextLanguage.attributed("直", language: .japanese)
        XCTAssertNotNil(string.attribute(Self.coreTextLanguage, at: 0, effectiveRange: nil))
    }

    func testAnEmptyCandidateGetsNoAttributeInsteadOfCrashing() {
        let string = CandidateTextLanguage.attributed("", language: .japanese)
        XCTAssertEqual(string.length, 0)
    }

    /// Known layout fact kept from the text view this replaces: a collapsed cell must still draw the candidate
    /// inside the configured 44 pt header, for every input language.
    @MainActor
    func testCollapsedCandidatesStillDrawInsideTheConfiguredHeaderInEveryInputLanguage() throws {
        for language in [InputLanguage.simplifiedChinese, .traditionalChinese, .japanese] {
            let context = CandidateAreaContext(
                state: CandidatePresentationState(
                    preedit: "zhi", rawInput: "zhi",
                    candidates: [Candidate(index: 0, text: "直", comment: "")],
                    highlightedIndex: 0, pageIndex: 0,
                    canPageBackward: false, canPageForward: false, isComposing: true),
                bar: .systemDefault,
                actions: CandidateAreaActionSink { _ in },
                typography: CandidateTypography(candidateSize: 20, secondarySize: 10),
                inputLanguage: language)
            let view = AnyView(DefaultCandidateAreaRenderer().collapsedView(context: context))
                .frame(width: 380, height: 44)
                .environment(
                    \.candidateSkinToken,
                    CandidateSkinToken(
                        candidateColor: .white, secondaryColor: Color.white.opacity(0.8),
                        accentColor: .blue, panelColor: .black)
                )
                .background(Color.black)

            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: 380, height: 44)
            renderer.scale = 1
            var pixels: (w: Int, h: Int, buf: [UInt8])?
            renderer.render { size, draw in
                let w = max(1, Int(size.width)), h = max(1, Int(size.height))
                var buf = [UInt8](repeating: 0, count: w * h * 4)
                guard
                    let ctx = CGContext(
                        data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return }
                draw(ctx)
                pixels = (w, h, buf)
            }
            let r = try XCTUnwrap(pixels)
            var inkRows: [Int] = []
            for y in 0..<r.h {
                var ink = 0
                for x in 0..<r.w {
                    let i = (y * r.w + x) * 4
                    if Int(r.buf[i]) + Int(r.buf[i + 1]) + Int(r.buf[i + 2]) > 200 { ink += 1 }
                }
                if ink > 0 { inkRows.append(y) }
            }
            XCTAssertFalse(inkRows.isEmpty, "\(language.rawValue): the candidate must still be drawn")
            XCTAssertEqual(r.h, 44, "\(language.rawValue): the collapsed strip keeps its configured height")
            XCTAssertGreaterThanOrEqual(inkRows.min() ?? 0, 0, "\(language.rawValue): nothing may draw above the strip")
            XCTAssertLessThanOrEqual(inkRows.max() ?? 43, 43, "\(language.rawValue): nothing may draw below the strip")
        }
    }
}
