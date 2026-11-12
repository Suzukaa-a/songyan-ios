import ToolKit
import XCTest

final class ToolInputSelectionTests: XCTestCase {

    private let limits = ToolLimits(
        maximumInputUnits: 4, runTimeout: 1, undoWindow: nil, maximumResults: 4)

    private func document(
        selected: String? = nil, before: String? = nil, privacy: ToolDocumentPrivacy = .normal
    ) -> ToolDocumentSnapshot {
        ToolDocumentSnapshot(
            documentID: ToolDocumentID(rawValue: "field-1"), privacy: privacy,
            selectedText: selected, textBeforeCaret: before)
    }

    func testSelectionIsPreferred() throws {
        let input = try ToolInputSelection.select(
            from: document(selected: "sel", before: "prefix"), limits: limits
        ).get()
        XCTAssertEqual(input.text, "sel")
        XCTAssertEqual(input.scope, .selection)
        XCTAssertFalse(input.isTruncated)
    }

    func testFallsBackToCaretPrecedingText() throws {
        let input = try ToolInputSelection.select(from: document(before: "abcd"), limits: limits)
            .get()
        XCTAssertEqual(input.text, "abcd")
        XCTAssertEqual(input.scope, .precedingSegment)
        XCTAssertFalse(input.isTruncated)
    }

    func testSelectionIsCappedLikeTheFallback() throws {
        let input = try ToolInputSelection.select(
            from: document(selected: "abcdefgh"), limits: limits
        ).get()
        XCTAssertEqual(input.text, "efgh", "the end nearest the caret is processed")
        XCTAssertEqual(input.scope, .selection)
        XCTAssertTrue(input.isTruncated)
        XCTAssertEqual(input.unitCount, 4)
    }

    func testFallbackKeepsTheEndAndReportsTruncation() throws {
        let input = try ToolInputSelection.select(from: document(before: "abcdefgh"), limits: limits)
            .get()
        XCTAssertEqual(input.text, "efgh")
        XCTAssertTrue(input.isTruncated)
    }

    func testLengthsAreUTF16CodeUnits() throws {
        let input = try ToolInputSelection.select(
            from: document(selected: "\u{1F600}"), limits: limits
        ).get()
        XCTAssertEqual(input.unitCount, 2, "one emoji is two UTF-16 code units on both platforms")
        XCTAssertEqual(ToolTextUnits.count("a\u{1F600}"), 3)
    }

    func testSurrogatePairIsNeverSplit() {
        let tight = ToolLimits(
            maximumInputUnits: 1, runTimeout: 1, undoWindow: nil, maximumResults: 4)
        XCTAssertEqual(
            ToolInputSelection.select(from: document(selected: "\u{1F600}"), limits: tight),
            .failure(.noText))
    }

    func testEmptyAnnotationsAreUnavailable() {
        XCTAssertEqual(
            ToolInputSelection.select(from: document(), limits: limits), .failure(.noText))
        XCTAssertEqual(
            ToolInputSelection.select(from: document(selected: "", before: ""), limits: limits),
            .failure(.noText))
    }

    func testPasswordAndNoTextFieldsAreUnavailable() {
        XCTAssertEqual(
            ToolInputSelection.select(
                from: document(selected: "secret", before: "secret", privacy: .password),
                limits: limits),
            .failure(.secureEntry))
        XCTAssertEqual(
            ToolInputSelection.select(
                from: document(selected: "text", before: "text", privacy: .noText), limits: limits),
            .failure(.noText))
    }
}
