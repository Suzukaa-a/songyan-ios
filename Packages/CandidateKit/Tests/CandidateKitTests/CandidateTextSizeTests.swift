import XCTest

@testable import CandidateKit

final class CandidateTextSizeTests: XCTestCase {
    func testFactorsMatchAndroid() {
        XCTAssertEqual(CandidateTextSize.small.factor, 0.85)
        XCTAssertEqual(CandidateTextSize.standard.factor, 1)
        XCTAssertEqual(CandidateTextSize.large.factor, 1.15)
        XCTAssertEqual(CandidateTextSize.extraLarge.factor, 1.3)
    }

    func testStoredIdResolution() {
        XCTAssertEqual(CandidateTextSize.resolve("extra_large"), .extraLarge)
        XCTAssertEqual(CandidateTextSize.resolve("small"), .small)
        XCTAssertEqual(CandidateTextSize.resolve("huge"), .standard)
        XCTAssertEqual(CandidateTextSize.resolve(""), .standard)
        XCTAssertEqual(CandidateTextSize.resolve(nil), .standard)
    }

    func testScalesCandidateAndSecondaryTogether() {
        let scaled = CandidateTextSize.extraLarge.scaled(.init(candidateSize: 20, secondarySize: 10))
        XCTAssertEqual(scaled.candidateSize, 26, accuracy: 1e-9)
        XCTAssertEqual(scaled.secondarySize, 13, accuracy: 1e-9)
    }

    func testBarGrowsToFitLargerText() {
        // 24 * 1.3 = 31.2 -> ceil(31.2 * 1.25 + 3) = 42 > the 36 configured height.
        let size = 24 * CandidateTextSize.extraLarge.factor
        XCTAssertEqual(CandidateBarDefinition.Collapsed.effectiveHeight(36, candidateSize: size), 42)
        // A taller configured height is kept while the text still fits.
        XCTAssertEqual(CandidateBarDefinition.Collapsed.effectiveHeight(48, candidateSize: size), 48)
        // 30 * 1.3 = 39 -> ceil(51.75) = 52, past the 36...56 config clamp's smaller values.
        XCTAssertEqual(
            CandidateBarDefinition.Collapsed.effectiveHeight(40, candidateSize: 30 * 1.3), 52)
    }
}
