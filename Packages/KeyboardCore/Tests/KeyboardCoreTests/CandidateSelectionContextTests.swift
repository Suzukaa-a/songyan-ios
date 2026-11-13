import XCTest

@testable import KeyboardCore

@MainActor
final class CandidateSelectionContextTests: XCTestCase {
    private final class MenuEngine: EngineBackend {
        let kind: EngineBackendKind = .demoSimulator("candidate-selection")
        var statusSummary: String { "test" }
        var words = ["你好", "拟好", "你号", "拟号"]
        var nextWords: [String]?
        var input = "niha"
        var pageSize = 2
        var keepsComposition = false
        var advancesSegment = false
        var selectionFails = false
        var selected: [String] = []
        var reads: [Range<Int>] = []
        var supportsReadOnlyBrowsing: Bool { true }

        func setup(sharedDirectory: URL, userDirectory: URL) throws {}
        func selectSchema(_ schemaID: String) throws {}
        func shutdown() {}
        func nextPage() throws -> EngineSnapshot { currentSnapshot() }
        func previousPage() throws -> EngineSnapshot { currentSnapshot() }
        func processKey(_ keyValue: String) throws -> EngineSnapshot {
            if keyValue == "\u{08}" { input.removeLast() } else { input += keyValue }
            if let nextWords { words = nextWords }
            return currentSnapshot()
        }
        func currentSnapshot() -> EngineSnapshot {
            let visible = pageSize > 0 ? Array(words.prefix(pageSize)) : words
            return EngineSnapshot(
                candidates: visible.enumerated().map { Candidate(index: $0.offset, text: $0.element) },
                preedit: input, rawInput: input, isComposing: !input.isEmpty,
                pageSize: pageSize, isLastPage: visible.count == words.count)
        }
        func selectCandidate(_ index: Int) throws -> EngineSnapshot {
            if selectionFails { throw NSError(domain: "selection-test", code: 1) }
            let text = words[index]
            selected.append(text)
            if advancesSegment {
                input.removeFirst()
                return currentSnapshot()
            }
            if keepsComposition { return currentSnapshot() }
            input = ""
            words = []
            var result = currentSnapshot()
            result.committed = text
            return result
        }
        func selectCandidateAbsolute(_ index: Int) throws -> EngineSnapshot { try selectCandidate(index) }
        func cancelComposition() throws -> EngineSnapshot {
            input = ""
            words = []
            return currentSnapshot()
        }
        func readCandidates(fromIndex: Int, count: Int) throws -> [Candidate] {
            reads.append(fromIndex..<(fromIndex + count))
            return words.dropFirst(fromIndex).prefix(count).enumerated().map {
                Candidate(index: $0.offset, text: $0.element)
            }
        }
    }

    private final class ManualQueue: EngineWorkQueue {
        var work: [@Sendable () -> Void] = []
        func async(_ work: @escaping @Sendable () -> Void) { self.work.append(work) }
        func runAll() {
            while !work.isEmpty { work.removeFirst()() }
        }
    }

    private func makeSession() -> (InputSession, MenuEngine, () -> [String]) {
        let engine = MenuEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        session.refresh()
        return (session, engine, { committed })
    }

    func testRefreshBetweenPressAndReleaseCommitsExactlyOnce() {
        let (session, _, commits) = makeSession()
        let context = session.candidateSelectionContext
        session.refresh()
        XCTAssertTrue(session.selectCandidate(0, seenText: "你好", from: context))
        XCTAssertFalse(session.selectCandidate(0, seenText: "你好", from: context))
        XCTAssertEqual(commits(), ["你好"])
    }

    func testPreparedSelectionDoesNotReportAnUnchangedEngineAsSuccess() throws {
        let (session, engine, commits) = makeSession()
        engine.keepsComposition = true
        let press = try XCTUnwrap(session.prepareCandidateSelection(0))
        let before = session.snapshot
        XCTAssertFalse(session.selectCandidate(press))
        XCTAssertEqual(session.snapshot, before)
        XCTAssertTrue(commits().isEmpty)
    }

    func testPreparedSelectionDoesNotReportARefusedHostCommitAsSuccess() throws {
        let (session, _, commits) = makeSession()
        session.onDispatchCommit = { _ in false }
        let press = try XCTUnwrap(session.prepareCandidateSelection(0))
        XCTAssertFalse(session.selectCandidate(press))
        XCTAssertTrue(commits().isEmpty)
    }

    func testPreparedSelectionAcceptsRealPartialProgressWithoutACommit() throws {
        let (session, engine, commits) = makeSession()
        engine.advancesSegment = true
        let press = try XCTUnwrap(session.prepareCandidateSelection(0))
        XCTAssertTrue(session.selectCandidate(press))
        XCTAssertEqual(session.snapshot.rawInput, "iha")
        XCTAssertTrue(commits().isEmpty)
    }

    func testPreparedSelectionReportsEngineErrorsWithoutACommit() throws {
        let (session, engine, commits) = makeSession()
        engine.selectionFails = true
        let press = try XCTUnwrap(session.prepareCandidateSelection(0))
        XCTAssertFalse(session.selectCandidate(press))
        XCTAssertTrue(commits().isEmpty)
    }

    func testReorderedWordIsFoundAcrossPagesInsteadOfSelectingItsReplacement() {
        let (session, engine, commits) = makeSession()
        let context = session.candidateSelectionContext
        engine.words = ["新词", "另一词", "第三词", "你好"]
        session.refresh()
        XCTAssertTrue(session.selectCandidate(0, seenText: "你好", from: context))
        XCTAssertEqual(commits(), ["你好"])
    }

    func testDisappearedWordNeverCommitsTheNewOccupantOfItsSlot() {
        let (session, engine, commits) = makeSession()
        let context = session.candidateSelectionContext
        engine.words = ["新词", "另一词"]
        session.refresh()
        XCTAssertFalse(session.selectCandidate(0, seenText: "你好", from: context))
        XCTAssertTrue(commits().isEmpty)
        XCTAssertTrue(engine.selected.isEmpty)
    }

    func testQueuedFinalCodeKeySettlesBeforeSelectingTheTouchedWord() {
        let (session, engine, commits) = makeSession()
        let queue = ManualQueue()
        session.codeKeyQueue = queue
        let context = session.candidateSelectionContext
        engine.nextWords = ["拟号", "你好", "新词"]
        session.tap(.code("o"))
        XCTAssertEqual(session.pendingCodes, ["o"])
        XCTAssertTrue(session.selectCandidate(0, seenText: "你好", from: context))
        XCTAssertEqual(commits(), ["你好"])
        XCTAssertTrue(session.pendingCodes.isEmpty)
        queue.runAll()
        XCTAssertEqual(commits(), ["你好"])
    }

    func testBackgroundDecodeCanLandBetweenPressAndRelease() async {
        let (session, engine, commits) = makeSession()
        let queue = ManualQueue()
        session.codeKeyQueue = queue
        let context = session.candidateSelectionContext
        engine.nextWords = ["拟号", "你好"]
        session.tap(.code("o"))
        queue.runAll()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(session.snapshot.rawInput, "nihao")
        XCTAssertTrue(session.pendingCodes.isEmpty)
        XCTAssertTrue(session.selectCandidate(0, seenText: "你好", from: context))
        XCTAssertEqual(commits(), ["你好"])
    }

    func testPressBindsReplacementAfterEveryFinalCodeCompletionTiming() async throws {
        // 0: queued; 1: decoded but not delivered to main; 2: delivered before
        // the old rendered button receives its down event. A is absent from B.
        for phase in 0...2 {
            let (session, engine, commits) = makeSession()
            let queue = ManualQueue()
            session.codeKeyQueue = queue
            engine.nextWords = ["目标B", "其他B"]
            session.tap(.code("o"))
            if phase >= 1 { queue.runAll() }
            if phase == 2 {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
            let press = try XCTUnwrap(session.prepareCandidateSelection(0))
            XCTAssertEqual(session.snapshot.rawInput, "nihao")
            XCTAssertEqual(press.text, "目标B")
            XCTAssertTrue(commits().isEmpty, "touch-down must not commit; the gesture may become a scroll")
            XCTAssertTrue(engine.selected.isEmpty)
            XCTAssertTrue(session.selectCandidate(press))
            XCTAssertFalse(session.selectCandidate(press), "release may commit only once")
            queue.runAll()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            XCTAssertEqual(commits(), ["目标B"], "an obsolete decode completion must not replay after selection")
        }
    }

    func testPreparedPressKeepsItsWordThroughLaterReranking() throws {
        let (session, engine, commits) = makeSession()
        let press = try XCTUnwrap(session.prepareCandidateSelection(0))
        engine.words = ["新词", "另一词", "第三词", "你好"]
        session.refresh()
        XCTAssertTrue(session.selectCandidate(press))
        XCTAssertEqual(commits(), ["你好"])
    }

    func testPreparedPressCannotSelectAReplacementOrANewComposition() throws {
        let (session, engine, commits) = makeSession()
        let press = try XCTUnwrap(session.prepareCandidateSelection(0))
        engine.words = ["新词", "另一词"]
        session.refresh()
        XCTAssertFalse(session.selectCandidate(press))
        XCTAssertTrue(session.discardComposition())
        engine.words = ["你好"]
        session.tap(.code("nihao"))
        XCTAssertFalse(session.selectCandidate(press))
        XCTAssertTrue(commits().isEmpty)
    }

    func testCrossPagePressReadsOnlyTheTouchedSlotWithoutSelecting() throws {
        let (session, engine, commits) = makeSession()
        let press = try XCTUnwrap(session.prepareCandidateSelection(1, onPage: 1))
        XCTAssertEqual(engine.reads, [3..<4])
        XCTAssertTrue(engine.selected.isEmpty)
        XCTAssertTrue(commits().isEmpty)
        XCTAssertTrue(session.selectCandidate(press))
        XCTAssertEqual(commits(), ["拟号"])
    }

    func testPreparingMissingSlotDoesNotSelectAnotherCandidate() {
        let (session, engine, commits) = makeSession()
        XCTAssertNil(session.prepareCandidateSelection(2))
        XCTAssertNil(session.prepareCandidateSelection(0, onPage: 20))
        XCTAssertTrue(commits().isEmpty)
        XCTAssertTrue(engine.selected.isEmpty)
    }

    func testOldTouchCannotCrossClearAndRetypeEvenWithTheSameWord() {
        let (session, engine, commits) = makeSession()
        let context = session.candidateSelectionContext
        XCTAssertTrue(session.discardComposition())
        engine.words = ["你好"]
        session.tap(.code("niha"))
        XCTAssertFalse(session.selectCandidate(0, seenText: "你好", from: context))
        XCTAssertTrue(commits().isEmpty)
    }

    func testPartialSelectionInvalidatesOtherHeldTouches() {
        let (session, engine, _) = makeSession()
        let context = session.candidateSelectionContext
        engine.keepsComposition = true
        session.selectCandidate(1)
        XCTAssertFalse(session.selectCandidate(0, seenText: "你好", from: context))
        XCTAssertEqual(engine.selected, ["拟好"])
    }

    func testBackspaceInvalidatesTheOldCandidateContext() {
        let (session, _, commits) = makeSession()
        let context = session.candidateSelectionContext
        session.tap(.backspace)
        XCTAssertFalse(session.selectCandidate(0, seenText: "你好", from: context))
        XCTAssertTrue(commits().isEmpty)
    }

    func testPreviouslyBrowsedDistantWordSurvivesAnUnchangedRefresh() {
        let (session, engine, commits) = makeSession()
        engine.words = (0..<500).map { "word\($0)" }
        session.refresh()
        let context = session.candidateSelectionContext
        session.refresh()
        XCTAssertTrue(session.selectCandidate(1, onPage: 200, seenText: "word401", from: context))
        XCTAssertEqual(commits(), ["word401"])
        XCTAssertEqual(engine.reads, [401..<402], "do not read hundreds of unrelated candidates")
    }
}
