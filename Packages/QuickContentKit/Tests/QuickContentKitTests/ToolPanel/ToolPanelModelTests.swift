import Foundation
import QuickContentKit
import XCTest

final class ToolPanelModelTests: XCTestCase {
    private func editor(
        selected: String? = nil, beforeCursor: String? = nil,
        document: String? = "doc-a", isEmpty: Bool? = false
    ) -> ToolPanelEditorSnapshot {
        ToolPanelEditorSnapshot(
            selectedText: selected, textBeforeCursor: beforeCursor,
            documentIdentifier: document, documentIsEmpty: isEmpty)
    }

    // MARK: - Source choice

    func testSelectionIsTheSourceWhenTextIsSelected() {
        let model = ToolPanelModel(editor: editor(selected: "软件", beforeCursor: "前文软件"))
        XCTAssertEqual(model.source, .selection)
        XCTAssertEqual(model.prepared?.text, "软件")
        XCTAssertEqual(model.prepared?.anchor?.location, .selection)
        XCTAssertEqual(model.prepared?.anchor?.documentIdentifier, "doc-a")
    }

    func testWithoutSelectionTheParagraphBeforeTheCursorIsUsed() {
        let model = ToolPanelModel(editor: editor(beforeCursor: "上一段\n软件很好用"))
        XCTAssertEqual(model.source, .paragraphBeforeCursor)
        XCTAssertEqual(model.prepared?.text, "软件很好用")
        XCTAssertEqual(model.prepared?.anchor?.location, .paragraphBeforeCursor)
    }

    func testAnEmptyEditorHasNothingToProcess() {
        let model = ToolPanelModel(editor: editor(selected: nil, beforeCursor: nil, isEmpty: true))
        XCTAssertEqual(model.source, .selection)
        XCTAssertNil(model.prepared)
        XCTAssertEqual(model.availability(of: .selection), .nothingSelected)
        XCTAssertEqual(model.availability(of: .paragraphBeforeCursor), .noTextBeforeCursor)
        XCTAssertEqual(model.availability(of: .clipboard), .clipboardHasNoText)
    }

    func testTheClipboardIsTheSourceWhenTheFieldHasNoText() {
        let model = ToolPanelModel(
            editor: editor(selected: nil, beforeCursor: nil, isEmpty: true), clipboardText: "剪贴板文字")
        XCTAssertEqual(model.source, .clipboard)
        XCTAssertEqual(model.prepared?.text, "剪贴板文字")
        XCTAssertNil(model.prepared?.anchor)
    }

    func testChoosingAnUnavailableSourceKeepsTheCurrentSource() {
        var model = ToolPanelModel(editor: editor(selected: "选", beforeCursor: "前文"))
        XCTAssertFalse(model.choose(.clipboard))
        XCTAssertEqual(model.source, .selection)
        XCTAssertEqual(model.availability(of: .clipboard), .clipboardHasNoText)
    }

    func testChoosingTheClipboardReplacesTheProcessedText() {
        var model = ToolPanelModel(editor: editor(selected: "选", beforeCursor: "前文"))
        XCTAssertTrue(model.choose(.clipboard, clipboardText: "剪贴板"))
        XCTAssertEqual(model.source, .clipboard)
        XCTAssertEqual(model.prepared?.text, "剪贴板")
    }

    func testAParagraphThatIsTooLongKeepsTheTextNearestTheCursor() {
        let long = String(repeating: "a", count: 1500)
        let model = ToolPanelModel(editor: editor(beforeCursor: long))
        XCTAssertEqual(model.prepared?.text, String(long.suffix(ToolPanelText.maximumCharacters)))
        XCTAssertEqual(model.prepared?.wasTruncated, true)
    }

    func testALongSelectionKeepsItsHeadOnly() {
        let long = String(repeating: "b", count: 1200)
        let model = ToolPanelModel(editor: editor(selected: long))
        XCTAssertEqual(model.prepared?.text, String(long.prefix(ToolPanelText.maximumCharacters)))
        XCTAssertEqual(model.prepared?.wasTruncated, true)
    }

    // MARK: - Replacement boundaries

    func testAnUnchangedSelectionMayBeReplaced() {
        let snapshot = editor(selected: "软件")
        let model = ToolPanelModel(editor: snapshot)
        XCTAssertEqual(
            model.replacementDecision(current: snapshot),
            .replace(
                ToolPanelAnchor(
                    location: .selection, text: "软件", documentIdentifier: "doc-a")))
    }

    func testAnUnchangedParagraphMayBeReplaced() {
        let snapshot = editor(beforeCursor: "前文\n软件")
        let model = ToolPanelModel(editor: snapshot)
        XCTAssertEqual(model.prepared?.text, "软件")
        XCTAssertEqual(
            model.replacementDecision(current: snapshot),
            .replace(
                ToolPanelAnchor(
                    location: .paragraphBeforeCursor, text: "软件",
                    documentIdentifier: "doc-a")))
    }

    func testAParagraphIsNotOfferedWhileTextIsSelected() {
        let model = ToolPanelModel(editor: editor(selected: " ", beforeCursor: "前文\n软件"))
        XCTAssertNil(model.prepared?.anchor)
        XCTAssertEqual(model.availability(of: .paragraphBeforeCursor), .noTextBeforeCursor)
    }

    func testAParagraphAnchorDoesNotMatchOnceTextIsSelected() {
        let model = ToolPanelModel(editor: editor(beforeCursor: "前文\n软件"))
        XCTAssertEqual(
            model.replacementDecision(current: editor(selected: "软", beforeCursor: "前文\n软件")),
            .insertOnly(.textChanged))
    }

    func testChangedSelectionTextFallsBackToInsertOnly() {
        let model = ToolPanelModel(editor: editor(selected: "软件"))
        XCTAssertEqual(
            model.replacementDecision(current: editor(selected: "軟件")),
            .insertOnly(.textChanged))
    }

    func testAChangedParagraphFallsBackToInsertOnly() {
        let model = ToolPanelModel(editor: editor(beforeCursor: "第一段\n软件"))
        XCTAssertEqual(
            model.replacementDecision(current: editor(beforeCursor: "第一段\n軟件")),
            .insertOnly(.textChanged))
    }

    func testAnotherDocumentFallsBackToInsertOnlyEvenWithTheSameText() {
        let model = ToolPanelModel(editor: editor(selected: "软件", document: "doc-a"))
        XCTAssertEqual(
            model.replacementDecision(current: editor(selected: "软件", document: "doc-b")),
            .insertOnly(.documentChanged))
    }

    func testAnUnreadableEditorFallsBackToInsertOnly() {
        let model = ToolPanelModel(editor: editor(selected: "软件"))
        XCTAssertEqual(
            model.replacementDecision(current: nil), .insertOnly(.documentUnavailable))
    }

    func testTheClipboardTextHasNoEditorAnchor() {
        let model = ToolPanelModel(
            editor: editor(selected: nil, beforeCursor: nil, isEmpty: true),
            clipboardText: "剪贴板")
        XCTAssertEqual(model.source, .clipboard)
        XCTAssertEqual(
            model.replacementDecision(current: editor(selected: nil, beforeCursor: nil, isEmpty: true)),
            .insertOnly(.noEditorAnchor))
    }

    func testAHeadTruncatedSelectionNeverReplaces() {
        let long = String(repeating: "b", count: 1200)
        let snapshot = editor(selected: long)
        let model = ToolPanelModel(editor: snapshot)
        XCTAssertEqual(
            model.replacementDecision(current: snapshot), .insertOnly(.sourceWasTruncated))
    }

    func testATruncatedParagraphStillReplacesThePartItShows() {
        let long = String(repeating: "a", count: 1500)
        let snapshot = editor(beforeCursor: long)
        let model = ToolPanelModel(editor: snapshot)
        XCTAssertEqual(
            model.replacementDecision(current: snapshot),
            .replace(
                ToolPanelAnchor(
                    location: .paragraphBeforeCursor,
                    text: String(long.suffix(ToolPanelText.maximumCharacters)),
                    documentIdentifier: "doc-a")))
    }

    func testAMissingDocumentIdentifierCannotProveTheTarget() {
        let snapshot = editor(selected: "软件", document: nil)
        let model = ToolPanelModel(editor: snapshot)
        XCTAssertEqual(
            model.replacementDecision(current: snapshot), .insertOnly(.documentUnavailable))
    }

    // MARK: - Privacy

    func testAFieldThatHoldsTextButWithholdsItIsProtected() {
        let model = ToolPanelModel(
            editor: editor(selected: nil, beforeCursor: nil, document: "doc", isEmpty: false))
        XCTAssertTrue(model.isProtectedField)
    }

    func testAnEmptyFieldIsNotProtected() {
        let model = ToolPanelModel(
            editor: editor(selected: nil, beforeCursor: nil, isEmpty: true))
        XCTAssertFalse(model.isProtectedField)
    }

    func testReadableTextIsNotProtected() {
        let model = ToolPanelModel(editor: editor(beforeCursor: "可读"))
        XCTAssertFalse(model.isProtectedField)
    }

    func testAnUnknownEmptyStateIsNotTreatedAsProtected() {
        let model = ToolPanelModel(
            editor: editor(selected: nil, beforeCursor: nil, isEmpty: nil))
        XCTAssertFalse(model.isProtectedField)
    }

    func testTheToolbarSuppressionNeedsBothFacts() {
        XCTAssertTrue(
            ToolPanelPrivacy.suppressesTextTools(documentIsEmpty: false, contextIsAvailable: false))
        XCTAssertFalse(
            ToolPanelPrivacy.suppressesTextTools(documentIsEmpty: false, contextIsAvailable: true))
        XCTAssertFalse(
            ToolPanelPrivacy.suppressesTextTools(documentIsEmpty: true, contextIsAvailable: false))
        XCTAssertFalse(
            ToolPanelPrivacy.suppressesTextTools(documentIsEmpty: nil, contextIsAvailable: false))
    }

    func testASelectionAtTheFieldStartKeepsTheToolbarEntry() {
        XCTAssertFalse(
            ToolPanelPrivacy.suppressesTextTools(
                documentIsEmpty: false, contextIsAvailable: false, hasSelectedText: true))
        XCTAssertTrue(
            ToolPanelPrivacy.suppressesTextTools(
                documentIsEmpty: false, contextIsAvailable: false, hasSelectedText: false))
    }
}
