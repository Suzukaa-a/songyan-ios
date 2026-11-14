import Foundation
import ToolKit
import XCTest

private struct FakeTool: TextTool {
    var identity = ToolIdentity(id: "fake", title: "Fake")
    var requiredCapabilities: ToolCapabilities = .text
    var runTimeout: Double?

    func run(input: ToolInput) async throws -> [String] {
        ["result:" + input.text]
    }
}

private let limits = ToolLimits(
    maximumInputUnits: 8, runTimeout: 1.0, undoWindow: 0.5, maximumResults: 4)

private func document(
    selected: String? = "abc", before: String? = "zzabc", id: String = "field-1",
    privacy: ToolDocumentPrivacy = .normal
) -> ToolDocumentSnapshot {
    ToolDocumentSnapshot(
        documentID: ToolDocumentID(rawValue: id), privacy: privacy, selectedText: selected,
        textBeforeCaret: before)
}

private func makeSession(limits sessionLimits: ToolLimits = limits) -> ToolSession {
    ToolSession(limits: sessionLimits, sessionID: UUID().uuidString)
}

private func startRun(
    _ session: inout ToolSession, document snapshot: ToolDocumentSnapshot = document(),
    tool: FakeTool = FakeTool(), host: ToolCapabilities = .text,
    documentCapabilities: ToolDocumentCapabilities = [], now: Double = 0
) -> ToolRunRequest? {
    guard
        case .run(let request) = session.start(
            tool: tool, hostCapabilities: host, document: snapshot,
            documentCapabilities: documentCapabilities, now: now)
    else { return nil }
    return request
}

private func startedSession(
    document snapshot: ToolDocumentSnapshot = document(), results: [String] = ["OUT"],
    documentCapabilities: ToolDocumentCapabilities = [], limits: ToolLimits = limits
) -> (ToolSession, ToolRunToken) {
    var session = makeSession()
    let request = startRun(
        &session, document: snapshot, documentCapabilities: documentCapabilities)!
    _ = session.complete(results, token: request.runToken, now: 0)
    return (session, request.runToken)
}

final class ToolSessionTests: XCTestCase {

    func testStartEmitsOneRunWithTheSelection() throws {
        var session = makeSession()
        let request = try XCTUnwrap(startRun(&session))
        XCTAssertEqual(request.input.text, "abc")
        XCTAssertEqual(request.input.scope, .selection)
        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(
            session.start(tool: FakeTool(), hostCapabilities: .text, document: document(), now: 1),
            .none, "a second start while running is refused")
    }

    func testHostCapabilitiesGateTheRun() {
        var missingText = makeSession()
        XCTAssertEqual(
            missingText.start(
                tool: FakeTool(), hostCapabilities: [], document: document(), now: 0), .none)
        XCTAssertEqual(missingText.phase, .failed(.unavailable(.missingCapabilities(.text))))

        var missingAudio = makeSession()
        let audioTool = FakeTool(requiredCapabilities: [.text, .audio])
        XCTAssertEqual(
            missingAudio.start(
                tool: audioTool, hostCapabilities: .text, document: document(), now: 0), .none)
        XCTAssertEqual(missingAudio.phase, .failed(.unavailable(.missingCapabilities(.audio))))
    }

    func testCancelOnlyAppliesToARunningRunAndLateResultsAreDropped() throws {
        var session = makeSession()
        let request = try XCTUnwrap(startRun(&session))
        XCTAssertEqual(session.cancel(), .cancelRun(request.runToken))
        XCTAssertEqual(session.phase, .failed(.cancelled))
        XCTAssertFalse(session.complete(["late"], token: request.runToken, now: 0))
        XCTAssertEqual(session.phase, .failed(.cancelled))

        var preview = startedSession().0
        XCTAssertEqual(preview.cancel(), .none, "closing a preview is dismiss, not cancel")
        preview.dismiss()
        XCTAssertEqual(preview.phase, .idle)
    }

    func testAToolsOwnTimeoutReplacesTheHostLimit() throws {
        var session = makeSession()
        let request = try XCTUnwrap(startRun(&session, tool: FakeTool(runTimeout: 300)))
        XCTAssertEqual(session.runTimeout, 300)
        XCTAssertEqual(session.tick(now: 299), .none)
        XCTAssertTrue(session.complete(["late but in time"], token: request.runToken, now: 299))
        XCTAssertNotNil(session.preview)
    }

    func testTimeoutEmitsCancelRunAndRetryUsesANewToken() throws {
        var session = makeSession()
        let first = try XCTUnwrap(startRun(&session, now: 10))
        XCTAssertEqual(session.tick(now: 10.9), .none)
        XCTAssertEqual(session.tick(now: 11), .cancelRun(first.runToken))
        XCTAssertEqual(session.phase, .failed(.timedOut))

        let second = try XCTUnwrap(
            session.retry(
                tool: FakeTool(), hostCapabilities: .text, document: document(), now: 12
            )
            .request)
        XCTAssertNotEqual(first.runToken, second.runToken)
        XCTAssertFalse(
            session.complete(["stale"], token: first.runToken, now: 0),
            "a retired run cannot reach the new preview")
        XCTAssertEqual(session.phase, .running)
        XCTAssertTrue(session.complete(["fresh"], token: second.runToken, now: 0))
        XCTAssertEqual(session.preview?.results, ["fresh"])
    }

    func testResultsBecomeAPreviewAndOneCanBeChosen() throws {
        var session = makeSession()
        let request = try XCTUnwrap(startRun(&session))
        XCTAssertTrue(session.complete(["first", "second"], token: request.runToken, now: 0))
        XCTAssertEqual(session.preview?.results, ["first", "second"])
        XCTAssertTrue(session.chooseResult(1))
        XCTAssertEqual(session.preview?.selectedText, "second")
        XCTAssertFalse(session.chooseResult(5))
    }

    func testNoResultsFailInsteadOfShowingAnEmptyPreview() throws {
        var session = makeSession()
        let request = try XCTUnwrap(startRun(&session))
        XCTAssertTrue(session.complete([], token: request.runToken, now: 0))
        XCTAssertEqual(session.phase, .failed(.noResult))
    }

    /// An empty string is a legal result: it clears the processed range. Only an
    /// empty list is "no result".
    func testEmptyStringIsAValidDeletionResult() throws {
        var session = makeSession()
        let request = try XCTUnwrap(startRun(&session))
        XCTAssertTrue(session.complete([""], token: request.runToken, now: 0))
        XCTAssertEqual(session.preview?.results, [""])
        guard
            case .requested(let write) = session.replace(current: document(), now: 2)
        else { return XCTFail("a deletion is a write like any other") }
        XCTAssertEqual(write.target, .processedRange)
        XCTAssertEqual(write.text, "")
        XCTAssertEqual(write.replacedUnitCount, 3)
        XCTAssertTrue(session.writeSucceeded(at: 2))
        guard
            case .requested(let undo) = session.undo(
                current: document(selected: nil, before: "zz"), writtenText: "", now: 2.1)
        else { return XCTFail("deleting is undoable") }
        XCTAssertEqual(undo.kind, .restoreText("abc"))
        XCTAssertEqual(undo.unitCount, 0, "nothing was inserted to remove")
    }

    /// Two sessions must not share run tokens, or a late result from a previous
    /// keyboard session could be accepted by the next one.
    func testRunTokensAreUniqueAcrossSessions() throws {
        var first = makeSession()
        let firstRun = try XCTUnwrap(startRun(&first))
        var second = makeSession()
        let secondRun = try XCTUnwrap(startRun(&second))
        XCTAssertNotEqual(firstRun.runToken, secondRun.runToken)
        XCTAssertFalse(
            second.complete(["late"], token: firstRun.runToken, now: 0),
            "a token from another session is not accepted")
    }

    /// Closing a panel while the tool still runs cancels the engine task.
    func testDismissWhileRunningCancelsTheRun() throws {
        var session = makeSession()
        let run = try XCTUnwrap(startRun(&session))
        XCTAssertEqual(session.dismiss(), .cancelled(run.runToken))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.complete(["late"], token: run.runToken, now: 0))
    }

    /// Undo must cover the length of the written result, not of the replaced text.
    func testUndoRangeUsesTheWrittenResultLength() throws {
        var session = makeSession()
        let run = try XCTUnwrap(startRun(&session))
        _ = session.complete(["OUTCOME"], token: run.runToken, now: 0)
        _ = session.replace(current: document(), now: 2)
        XCTAssertTrue(session.writeSucceeded(at: 2))
        guard
            case .requested(let undo) = session.undo(
                current: document(selected: nil, before: "zzOUTCOME"), writtenText: "OUTCOME", now: 2.1)
        else { return XCTFail("expected an undo") }
        XCTAssertEqual(undo.kind, .restoreText("abc"))
        XCTAssertEqual(undo.unitCount, 7, "the seven written units are what undo replaces")
    }

    func testReplaceWaitsForTheHostBeforeOfferingUndo() {
        var (session, _) = startedSession()
        XCTAssertEqual(
            session.replace(current: document(), now: 2),
            .requested(
                ToolWriteRequest(
                    documentID: ToolDocumentID(rawValue: "field-1"), target: .processedRange,
                    text: "OUT", replacedText: "abc", replacedUnitCount: 3, requiresSubrange: false)))
        guard case .writing = session.phase else { return XCTFail("expected a pending write") }
        XCTAssertFalse(session.canUndo(at: 2))

        XCTAssertTrue(session.writeSucceeded(at: 2))
        XCTAssertTrue(session.canUndo(at: 2))
        guard case .wrote(let wrote) = session.phase else { return XCTFail("expected a write") }
        XCTAssertFalse(wrote.sourceChanged)
        XCTAssertEqual(
            session.undo(
                current: document(selected: nil, before: "zzOUT"), writtenText: "OUT", now: 2.1),
            .requested(
                ToolUndoRequest(
                    documentID: ToolDocumentID(rawValue: "field-1"), kind: .restoreText("abc"),
                    unitCount: 3)))
        XCTAssertTrue(session.undoSucceeded())
        XCTAssertEqual(session.phase, .idle)
    }

    func testWriteFailureReturnsToThePreviewSoTheUserCanRetry() {
        var (session, _) = startedSession()
        _ = session.replace(current: document(), now: 2)
        XCTAssertTrue(session.writeFailed())
        guard case .previewing = session.phase else { return XCTFail("preview must come back") }
        guard case .requested = session.replace(current: document(), now: 3) else {
            return XCTFail("a second attempt is allowed")
        }
    }

    func testWriteIsRefusedForAnotherDocumentOrAPasswordField() {
        var (session, _) = startedSession()
        XCTAssertEqual(
            session.replace(current: document(id: "field-2"), now: 2), .blocked(.documentChanged))
        XCTAssertEqual(session.writeBlock, .documentChanged)
        guard case .previewing = session.phase else { return XCTFail("preview is kept") }

        XCTAssertEqual(
            session.replace(current: document(privacy: .password), now: 2),
            .blocked(.secureEntry))
        XCTAssertEqual(session.writeBlock, .secureEntry)
    }

    /// Regression: the same tail under a different selection prefix is a different
    /// selection and must not be reported as unchanged.
    func testSelectionWithTheSameTailButAnotherPrefixCountsAsChanged() {
        let longLimits = ToolLimits(
            maximumInputUnits: 8, runTimeout: 1, undoWindow: nil, maximumResults: 4)
        var session = makeSession(limits: longLimits)
        let run = startRun(
            &session, document: document(selected: "abcdef", before: nil),
            documentCapabilities: [.insertPreservingSelection])!
        _ = session.complete(["OUT"], token: run.runToken, now: 0)

        guard
            case .requested(let request) = session.replace(
                current: document(selected: "Xbcdef", before: nil), now: 2)
        else { return XCTFail("expected an insertion") }
        XCTAssertEqual(request.target, .insertionPoint, "the prefix changed, so insert instead")
        XCTAssertTrue(session.writeSucceeded(at: 2))
        guard case .wrote(let wrote) = session.phase else { return XCTFail("expected a write") }
        XCTAssertTrue(wrote.sourceChanged)
    }

    /// A truncated selection is never replaced, even when the gateway declares
    /// range replacement: the selection's text could not be kept otherwise.
    func testTruncatedSelectionIsNeverReplacedNotEvenWithTheRangeCapability() {
        let shortLimits = ToolLimits(
            maximumInputUnits: 4, runTimeout: 1, undoWindow: nil, maximumResults: 4)
        let states: [ToolDocumentSnapshot] = [
            document(selected: "abcdef"),  // unchanged
            document(selected: "Xbcdef"),  // changed
            document(selected: nil),  // unreadable
        ]
        for capabilities: ToolDocumentCapabilities in [
            [], [.replacePrecedingTail, .insertPreservingSelection],
        ] {
            for state in states {
                var session = makeSession(limits: shortLimits)
                let run = startRun(
                    &session, document: document(selected: "abcdef"),
                    documentCapabilities: capabilities)!
                _ = session.complete(["OUT"], token: run.runToken, now: 0)
                XCTAssertEqual(
                    session.replace(current: state, now: 2),
                    .blocked(.unsupportedPartialReplacement))
                XCTAssertEqual(session.writeBlock, .unsupportedPartialReplacement)
                guard case .previewing = session.phase else {
                    return XCTFail("the preview is kept")
                }
            }
        }
    }

    /// Such a selection can still be written as an insertion when the gateway can
    /// keep the selected text.
    func testTruncatedSelectionCanStillInsertWithTheRangeCapability() {
        let shortLimits = ToolLimits(
            maximumInputUnits: 4, runTimeout: 1, undoWindow: nil, maximumResults: 4)
        let selected = document(selected: "abcdef")

        var without = makeSession(limits: shortLimits)
        let plainRun = startRun(&without, document: selected)!
        _ = without.complete(["OUT"], token: plainRun.runToken, now: 0)
        XCTAssertEqual(
            without.insert(current: selected, now: 2),
            .blocked(.unsupportedInsertion))

        var with = makeSession(limits: shortLimits)
        let rangeRun = startRun(
            &with, document: selected, documentCapabilities: [.insertPreservingSelection])!
        _ = with.complete(["OUT"], token: rangeRun.runToken, now: 0)
        guard case .requested(let write) = with.insert(current: selected, now: 2) else {
            return XCTFail("the declared gateway can keep the selection")
        }
        XCTAssertEqual(write.target, .insertionPoint)
    }

    /// The caret-preceding tail can be replaced when the gateway can edit a range.
    func testTruncatedBeforeCursorTailIsReplacedWithTheRangeCapability() {
        let shortLimits = ToolLimits(
            maximumInputUnits: 4, runTimeout: 1, undoWindow: nil, maximumResults: 4)
        let source = document(selected: nil, before: "abcdef")
        var session = makeSession(limits: shortLimits)
        let run = startRun(
            &session, document: source, documentCapabilities: [.replacePrecedingTail])!
        _ = session.complete(["OUT"], token: run.runToken, now: 0)
        guard case .requested(let write) = session.replace(current: source, now: 2) else {
            return XCTFail("a declared gateway can replace the validated tail")
        }
        XCTAssertEqual(write.target, .processedRange)
        XCTAssertEqual(write.replacedText, "cdef")
        XCTAssertEqual(write.replacedUnitCount, 4)
        XCTAssertTrue(write.requiresSubrange)
    }

    func testUnreadableSourceInsertsWithoutClaimingItChanged() throws {
        var session = makeSession()
        let run = try XCTUnwrap(
            startRun(&session, document: document(selected: nil, before: "abc")))
        _ = session.complete(["OUT"], token: run.runToken, now: 0)
        let unreadable = ToolDocumentSnapshot(
            documentID: ToolDocumentID(rawValue: "field-1"), privacy: .normal, selectedText: nil,
            textBeforeCaret: nil)
        guard case .requested(let request) = session.replace(current: unreadable, now: 2) else {
            return XCTFail("an unreadable source still allows an insertion")
        }
        XCTAssertEqual(request.target, .insertionPoint)
        XCTAssertTrue(session.writeSucceeded(at: 2))
        guard case .wrote(let wrote) = session.phase else { return XCTFail("expected a write") }
        XCTAssertEqual(wrote.source, .unreadable)
        XCTAssertFalse(wrote.sourceChanged, "a nil read is not proof that the source changed")
    }

    /// A no-text field has its own blocking reason; the UI must not tell the user
    /// the password story for it.
    func testNoTextFieldHasItsOwnBlockReason() {
        var session = startedSession().0
        let noText = document(privacy: .noText)
        XCTAssertEqual(session.replace(current: noText, now: 2), .blocked(.noText))
        XCTAssertEqual(session.writeBlock, .noText)
        XCTAssertEqual(session.insert(current: noText, now: 2), .blocked(.noText))

        var undoSession = startedSession().0
        _ = undoSession.replace(current: document(), now: 2)
        _ = undoSession.writeSucceeded(at: 2)
        XCTAssertEqual(undoSession.undo(current: noText, writtenText: "OUT", now: 2.1), .blocked(.noText))
        XCTAssertEqual(undoSession.writeBlock, .noText)
    }

    func testUndoFailuresKeepTheWriteAndUndoCanExpire() {
        var (session, _) = startedSession()
        _ = session.replace(current: document(), now: 2)
        XCTAssertTrue(session.writeSucceeded(at: 2))
        _ = session.undo(current: document(selected: nil, before: "zzOUT"), writtenText: "OUT", now: 2.1)
        XCTAssertTrue(session.undoFailed())
        guard case .wrote = session.phase else { return XCTFail("undo failure keeps the write") }
        XCTAssertTrue(session.canUndo(at: 2.2))

        var expired = startedSession().0
        _ = expired.replace(current: document(), now: 2)
        _ = expired.writeSucceeded(at: 2)
        XCTAssertEqual(
            expired.undo(current: document(selected: nil, before: "zzOUT"), writtenText: "OUT", now: 3), .expired)
        XCTAssertFalse(expired.canUndo(at: 3))
    }

    /// A truncated tail that is still unchanged replaces part of its range, so it
    /// still needs the gateway range capability.
    func testTruncatedUnchangedReplaceStillNeedsTheRangeCapability() {
        let shortLimits = ToolLimits(
            maximumInputUnits: 4, runTimeout: 1, undoWindow: nil, maximumResults: 4)
        let source = document(selected: nil, before: "abcdef")
        var session = makeSession(limits: shortLimits)
        let run = startRun(&session, document: source)!
        _ = session.complete(["OUT"], token: run.runToken, now: 0)
        XCTAssertEqual(
            session.replace(current: source, now: 2),
            .blocked(.unsupportedPartialReplacement))
        guard case .previewing = session.phase else { return XCTFail("preview is kept") }
    }

    /// A truncated tail whose source changed is written as an insertion, which
    /// keeps the original text: no range capability is needed, only inserting.
    func testTruncatedChangedSourceInsertsWithoutTheRangeCapability() {
        let shortLimits = ToolLimits(
            maximumInputUnits: 4, runTimeout: 1, undoWindow: nil, maximumResults: 4)
        let source = document(selected: nil, before: "abcdef")
        var session = makeSession(limits: shortLimits)
        let run = startRun(
            &session, document: source, documentCapabilities: [])!
        _ = session.complete(["OUT"], token: run.runToken, now: 0)
        let changed = document(selected: nil, before: "XXXXef")
        guard case .requested(let write) = session.replace(current: changed, now: 2) else {
            return XCTFail("an insertion needs no range capability")
        }
        XCTAssertEqual(write.target, .insertionPoint)
        XCTAssertFalse(write.requiresSubrange)
        XCTAssertTrue(session.writeSucceeded(at: 2))
        guard case .wrote(let wrote) = session.phase else { return XCTFail("expected a write") }
        XCTAssertTrue(wrote.sourceChanged)
    }

    /// Inserting a truncated caret-preceding result replaces nothing, so it needs
    /// no gateway capability at all.
    func testInsertOnTruncatedPrecedingTextNeedsNoCapability() {
        let shortLimits = ToolLimits(
            maximumInputUnits: 4, runTimeout: 1, undoWindow: nil, maximumResults: 4)
        let source = document(selected: nil, before: "abcdef")
        var session = makeSession(limits: shortLimits)
        let run = startRun(&session, document: source)!
        _ = session.complete(["OUT"], token: run.runToken, now: 0)
        guard case .requested(let write) = session.insert(current: source, now: 2) else {
            return XCTFail("a caret insertion needs no range capability")
        }
        XCTAssertEqual(write.target, .insertionPoint)
        XCTAssertFalse(write.requiresSubrange)
        XCTAssertTrue(session.writeSucceeded(at: 2))
        guard
            case .requested(let undo) = session.undo(
                current: document(selected: nil, before: "abcdefOUT"), writtenText: "OUT", now: 2.1)
        else { return XCTFail("removing an insertion needs no range capability either") }
        XCTAssertEqual(undo.kind, .removeInserted)
        XCTAssertEqual(undo.unitCount, 3)
    }

    /// Inserting while the run read a selection would replace that selection, so it
    /// needs the gateway's range capability.
    func testInsertWithALiveSelectionNeedsTheRangeCapability() {
        let selected = document(selected: "abc", before: "zzabc")
        var without = makeSession()
        let run = startRun(&without, document: selected)!
        _ = without.complete(["OUT"], token: run.runToken, now: 0)
        XCTAssertEqual(
            without.insert(current: selected, now: 2),
            .blocked(.unsupportedInsertion))
        XCTAssertEqual(without.writeBlock, .unsupportedInsertion)
        guard case .previewing = without.phase else { return XCTFail("preview is kept") }

        var with = makeSession()
        let withRun = startRun(
            &with, document: selected, documentCapabilities: [.insertPreservingSelection])!
        _ = with.complete(["OUT"], token: withRun.runToken, now: 0)
        guard case .requested = with.insert(current: selected, now: 2) else {
            return XCTFail("the declared gateway can keep the selection text")
        }
    }

    /// Results beyond the injected limit are dropped, not shown.
    func testResultCountIsCappedByTheInjectedLimit() {
        let twoResults = ToolLimits(
            maximumInputUnits: 8, runTimeout: 1, undoWindow: nil, maximumResults: 2)
        var session = makeSession(limits: twoResults)
        let run = startRun(&session, document: document())!
        XCTAssertTrue(session.complete(["a", "b", "c"], token: run.runToken, now: 0))
        XCTAssertEqual(session.preview?.results, ["a", "b"])
    }

    /// The whole original text is compared, so the same tail under another prefix
    /// also counts as changed for caret-preceding text.
    func testPrecedingTextWithTheSameTailButAnotherPrefixInserts() {
        let source = document(selected: nil, before: "xxabc")
        var session = makeSession()
        let run = startRun(&session, document: source)!
        _ = session.complete(["OUT"], token: run.runToken, now: 0)
        guard
            case .requested(let write) = session.replace(
                current: document(selected: nil, before: "yyabc"), now: 2)
        else { return XCTFail("expected an insertion") }
        XCTAssertEqual(write.target, .insertionPoint)
        XCTAssertTrue(session.writeSucceeded(at: 2))
        guard case .wrote(let wrote) = session.phase else { return XCTFail("expected a write") }
        XCTAssertTrue(wrote.sourceChanged)
    }

    /// Undo re-reads the written text: if the user typed after the write, undo must
    /// be refused instead of overwriting the new input.
    func testUndoIsRefusedAfterTheUserEditedTheWrittenText() {
        var (session, _) = startedSession()
        _ = session.replace(current: document(), now: 2)
        _ = session.writeSucceeded(at: 2)
        let edited = document(selected: nil, before: "zzOUT and more")
        XCTAssertEqual(
            session.undo(current: edited, writtenText: "OUT and more", now: 2.1), .blocked(.editedAfterWrite))
        XCTAssertEqual(session.writeBlock, .editedAfterWrite)
        guard case .wrote = session.phase else { return XCTFail("the write stays undoable") }
    }

    /// A late result that arrives after the timeout must not reach the preview.
    func testLateResultAfterTheTimeoutIsDropped() throws {
        var session = makeSession()
        let run = try XCTUnwrap(startRun(&session, now: 0))
        XCTAssertEqual(session.tick(now: 2), .cancelRun(run.runToken))
        XCTAssertEqual(session.phase, .failed(.timedOut))
        XCTAssertFalse(session.complete(["late"], token: run.runToken, now: 0))
        XCTAssertNil(session.preview)
    }

    /// A result that arrives after the deadline is rejected even when nobody
    /// called tick: the delivery re-checks the same injected deadline.
    func testResultAfterTheDeadlineIsRejectedWithoutATick() throws {
        var session = makeSession()
        let run = try XCTUnwrap(startRun(&session, now: 10))
        XCTAssertFalse(session.complete(["late"], token: run.runToken, now: 11.5))
        XCTAssertEqual(session.phase, .failed(.timedOut))
        XCTAssertNil(session.preview)
        XCTAssertFalse(session.fail(message: "late", token: run.runToken, now: 12))
    }

    /// replacePrecedingTail and insertPreservingSelection are independent: neither
    /// may stand in for the other.
    func testTheTwoCapabilitiesAreIndependent() {
        let shortLimits = ToolLimits(
            maximumInputUnits: 4, runTimeout: 1, undoWindow: nil, maximumResults: 4)
        let preceding = document(selected: nil, before: "abcdef")
        let selected = document(selected: "abcdef")
        let combos: [(ToolDocumentCapabilities, Bool, Bool)] = [
            ([], false, false),
            ([.replacePrecedingTail], true, false),
            ([.insertPreservingSelection], false, true),
            ([.replacePrecedingTail, .insertPreservingSelection], true, true),
        ]
        for (capabilities, canReplacePreceding, canInsertSelection) in combos {
            var tailReplace = makeSession(limits: shortLimits)
            let tailRun = startRun(
                &tailReplace, document: preceding, documentCapabilities: capabilities)!
            _ = tailReplace.complete(["OUT"], token: tailRun.runToken, now: 0)
            XCTAssertEqual(
                tailReplace.replace(current: preceding, now: 2)
                    == .blocked(.unsupportedPartialReplacement),
                !canReplacePreceding, "replacePrecedingTail only")

            var selectionInsert = makeSession(limits: shortLimits)
            let insertRun = startRun(
                &selectionInsert, document: selected, documentCapabilities: capabilities)!
            _ = selectionInsert.complete(["OUT"], token: insertRun.runToken, now: 0)
            XCTAssertEqual(
                selectionInsert.insert(current: selected, now: 2) == .blocked(.unsupportedInsertion),
                !canInsertSelection, "insertPreservingSelection only")

            var truncatedSelection = makeSession(limits: shortLimits)
            let truncatedRun = startRun(
                &truncatedSelection, document: selected, documentCapabilities: capabilities)!
            _ = truncatedSelection.complete(["OUT"], token: truncatedRun.runToken, now: 0)
            XCTAssertEqual(
                truncatedSelection.replace(current: selected, now: 2),
                .blocked(.unsupportedPartialReplacement),
                "a truncated selection is never replaced, whatever is declared")

            var precedingInsert = makeSession(limits: shortLimits)
            let plainRun = startRun(
                &precedingInsert, document: preceding, documentCapabilities: capabilities)!
            _ = precedingInsert.complete(["OUT"], token: plainRun.runToken, now: 0)
            guard case .requested = precedingInsert.insert(current: preceding, now: 2) else {
                return XCTFail("a caret insertion never needs a capability")
            }
        }
    }

    func testCopyWritesNothingAndHasNoUndo() {
        var (session, _) = startedSession()
        XCTAssertEqual(session.copy(), "OUT")
        XCTAssertEqual(session.phase, .idle)
    }
}

extension ToolEffect {
    fileprivate var request: ToolRunRequest? {
        if case .run(let request) = self { return request }
        return nil
    }
}
