import Foundation
import XCTest

@testable import CandidateKit

final class InlineReadingStripTests: XCTestCase {
    private let minCell = InlineReadingStrip.minimumCellWidth
    private let start = InlineReadingStrip.startInset

    func test_cellsAreNeverNarrowerThanTheTouchMinimum() {
        XCTAssertEqual(InlineReadingStrip.cellWidth(textWidth: 0), 48)
        XCTAssertEqual(InlineReadingStrip.cellWidth(textWidth: 20), 48)
        XCTAssertEqual(InlineReadingStrip.cellWidth(textWidth: 60), 84)
    }

    func test_noCellsTakeNoWidth() {
        XCTAssertEqual(InlineReadingStrip.sections(cellWidths: [], available: 300).width, 0)
        XCTAssertEqual(InlineReadingStrip.sections(cellWidths: [48], available: 0).width, 0)
    }

    func test_fittingCellsTakeOnlyTheirOwnWidth() {
        let sections = InlineReadingStrip.sections(cellWidths: [60, 60], available: 600)
        XCTAssertEqual(sections.width, start + 120)
        XCTAssertFalse(sections.scrolls)
    }

    func test_overflowTakesAThirdOfTheRow() {
        let widths = Array(repeating: 60.0, count: 8)
        let sections = InlineReadingStrip.sections(cellWidths: widths, available: 390)
        XCTAssertEqual(sections.width, 130)
        XCTAssertTrue(sections.scrolls)
        XCTAssertEqual(sections.maxScroll, start + 480 - 130)
    }

    func test_atLeastTwoCellsAreShownWhenThirdIsTooNarrow() {
        // A third of 300 is 100, below two 60-wide cells plus the inset.
        let widths = Array(repeating: 60.0, count: 6)
        let sections = InlineReadingStrip.sections(cellWidths: widths, available: 300)
        XCTAssertEqual(sections.width, start + 120)
    }

    func test_neverMoreThanHalfTheRow() {
        let widths = Array(repeating: 200.0, count: 4)
        let sections = InlineReadingStrip.sections(cellWidths: widths, available: 300)
        XCTAssertEqual(sections.width, 150)
    }

    func test_realisticPhoneRowKeepsHalfForCandidates() {
        let widths = Array(repeating: minCell, count: 12)
        for available in stride(from: 280.0, through: 1000.0, by: 20) {
            let sections = InlineReadingStrip.sections(cellWidths: widths, available: available)
            XCTAssertTrue(sections.width <= available / 2)
            XCTAssertTrue(sections.width >= min(start + minCell * 2, available / 2))
        }
    }

    func test_layoutMeasuresTextIntoCells() {
        let layout = InlineReadingStrip.layout(textWidths: [10, 70], available: 600)
        XCTAssertEqual(layout.cellWidths, [48, 94])
        XCTAssertEqual(layout.sections.contentWidth, start + 142)
    }

    func test_placementDefaultsToTheRow() {
        XCTAssertEqual(ReadingPlacement.resolve(nil), .row)
        XCTAssertEqual(ReadingPlacement.resolve("garbage"), .row)
        let suite = "InlineReadingStripTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ReadingPlacementStorage.read(from: defaults), .row)
    }

    func test_placementRoundTrips() {
        let suite = "InlineReadingStripTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for placement in ReadingPlacement.allCases {
            ReadingPlacementStorage.write(placement, to: defaults)
            XCTAssertEqual(ReadingPlacementStorage.read(from: defaults), placement)
        }
    }

    func test_itemsCarryTheReadingRowLabels() {
        let options = CandidateReadingRowContent.options(["ni", "mi"]).inlineItems
        XCTAssertEqual(options.map(\.label), ["ni", "mi"])
        XCTAssertEqual(options[0].accessibilityLabel, "锁定组合 ni")
        XCTAssertEqual(options[0].action, .lockSpelling("ni"))

        let locked = CandidateReadingRowContent.locked(chosen: "ni").inlineItems
        XCTAssertTrue(locked.count == 1 && locked[0].kind == .selected && locked[0].action == nil)
        XCTAssertEqual(locked[0].accessibilityLabel, "已锁定组合 ni")

        let readings = CandidateReadingRowContent.readings(selected: ["ni", "hao"], options: ["ma"]).inlineItems
        XCTAssertEqual(readings.map(\.label), ["ni hao", "ma"])
        XCTAssertEqual(readings[0].kind, .selected)
        XCTAssertEqual(readings[0].accessibilityLabel, "已选读音 ni hao")
        XCTAssertEqual(readings[1].accessibilityLabel, "选择读音 ma")
        XCTAssertEqual(readings[1].action, .selectReading("ma"))
        XCTAssertTrue(CandidateReadingRowContent.empty.inlineItems.isEmpty)
    }

    func test_candidateBarPlacementReservesNoRowHeight() {
        // The cold-start budget only reserves the row for the row placement.
        func shell(readingRow: Bool) -> Double {
            KeyboardPanelPresentationBudget(
                candidateHeight: 40, candidateSize: 21, readingRow: readingRow, candidateArea: true,
                compact: false, heightPreset: .standard
            ).shellHeight
        }
        XCTAssertLessThan(shell(readingRow: false), shell(readingRow: true))
    }
}
