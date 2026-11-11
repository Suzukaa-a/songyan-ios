import XCTest

@testable import KeyboardCore

/// A cursor drag while a spelling is composed walks the engine's own caret: it sends the engine's
/// Left / Right keys, commits nothing and leaves the host's caret alone. Idle drags still move the host.
@MainActor
final class CompositionCaretMoveTests: XCTestCase {
    /// Keeps a spelling with a caret: a text key inserts at the caret, Left / Right move it and
    /// stop at either end, and it records every key it was given.
    private final class CaretEngine: EngineBackend {
        let kind: EngineBackendKind = .demoSimulator("caret-test")
        private let lock = NSLock()
        private var input = ""
        private var caret = 0
        private var keys: [String] = []

        var received: [String] {
            lock.lock()
            defer { lock.unlock() }
            return keys
        }
        var spelling: String {
            lock.lock()
            defer { lock.unlock() }
            return input
        }

        func setup(sharedDirectory: URL, userDirectory: URL) throws {}
        func selectSchema(_ schemaID: String) throws {}

        func processKey(_ keyValue: String) throws -> EngineSnapshot {
            lock.lock()
            defer { lock.unlock() }
            keys.append(keyValue)
            switch keyValue {
            case EngineCodeKeyToken.cursorLeft: caret = max(0, caret - 1)
            case EngineCodeKeyToken.cursorRight: caret = min(input.count, caret + 1)
            case " ", "\n", "Esc", "\u{08}": break
            default:
                input.insert(contentsOf: keyValue, at: input.index(input.startIndex, offsetBy: caret))
                caret += keyValue.count
            }
            return state()
        }

        func selectCandidate(_ index: Int) throws -> EngineSnapshot { currentSnapshot() }
        func nextPage() throws -> EngineSnapshot { currentSnapshot() }
        func previousPage() throws -> EngineSnapshot { currentSnapshot() }
        func currentSnapshot() -> EngineSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return state()
        }
        func shutdown() {}
        var statusSummary: String { "caret" }

        private func state() -> EngineSnapshot {
            var snapshot = EngineSnapshot(preedit: input, rawInput: input, isComposing: !input.isEmpty)
            snapshot.preeditCaretByte = caret
            return snapshot
        }
    }

    private final class ManualQueue: EngineWorkQueue {
        private(set) var queued: [@Sendable () -> Void] = []
        func async(_ work: @escaping @Sendable () -> Void) { queued.append(work) }
        func runAll() {
            while !queued.isEmpty { queued.removeFirst()() }
        }
    }

    private func makeSession() -> (InputSession, CaretEngine, Box) {
        let engine = CaretEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        let box = Box()
        session.onCommitted = { box.committed.append($0) }
        session.onMoveCursor = { box.hostMoves.append($0) }
        return (session, engine, box)
    }

    private final class Box {
        var committed: [String] = []
        var hostMoves: [Int] = []
    }

    func testADragWhileComposingMovesTheEngineCaretAndNeverCommits() {
        let (session, engine, box) = makeSession()
        "ludi".forEach { session.tap(.code(String($0))) }
        XCTAssertTrue(session.movesCompositionCaret)
        XCTAssertTrue(session.moveCompositionCaret(by: -2))
        XCTAssertEqual(
            Array(engine.received.suffix(2)), [EngineCodeKeyToken.cursorLeft, EngineCodeKeyToken.cursorLeft])
        XCTAssertTrue(session.snapshot.isComposing, "the spelling is still being composed")
        XCTAssertEqual(session.snapshot.preeditCaretByte, 2)
        XCTAssertTrue(box.committed.isEmpty, "a caret move never confirms the composition")
        XCTAssertTrue(box.hostMoves.isEmpty, "the editor's caret stays where it is")
        // The next letter lands where the caret was taken.
        session.tap(.code("e"))
        XCTAssertEqual(engine.spelling, "luedi")
        XCTAssertEqual(session.snapshot.rawInput, "luedi")
    }

    func testTheCaretStopsAtBothEnds() {
        let (session, engine, box) = makeSession()
        "ludi".forEach { session.tap(.code(String($0))) }
        session.moveCompositionCaret(by: -9)
        XCTAssertEqual(session.snapshot.preeditCaretByte, 0)
        session.moveCompositionCaret(by: 9)
        XCTAssertEqual(session.snapshot.preeditCaretByte, 4)
        XCTAssertEqual(engine.received.filter { $0 == EngineCodeKeyToken.cursorRight }.count, 9)
        XCTAssertTrue(box.committed.isEmpty)
    }

    func testIdleDragsStillMoveTheHostCaret() {
        let (session, engine, box) = makeSession()
        XCTAssertFalse(session.movesCompositionCaret)
        XCTAssertFalse(session.moveCompositionCaret(by: -1))
        session.moveCursor(by: -3)
        XCTAssertEqual(box.hostMoves, [-3])
        XCTAssertTrue(engine.received.isEmpty, "nothing reaches the engine while idle")
    }

    func testZeroOffsetSendsNothing() {
        let (session, engine, _) = makeSession()
        session.tap(.code("l"))
        let before = engine.received
        XCTAssertFalse(session.moveCompositionCaret(by: 0))
        XCTAssertEqual(engine.received, before)
    }

    func testKeysStillDecodingCountAsAComposition() {
        let (session, engine, box) = makeSession()
        let queue = ManualQueue()
        session.codeKeyQueue = queue
        session.enqueueCodeKeys(["l", "u"])
        XCTAssertTrue(session.movesCompositionCaret, "the first keys have not landed yet")
        XCTAssertTrue(session.moveCompositionCaret(by: -1))
        XCTAssertTrue(engine.received.isEmpty, "no engine work on the calling thread")
        queue.runAll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        queue.runAll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.received, ["l", "u", EngineCodeKeyToken.cursorLeft], "the move keeps its place")
        XCTAssertTrue(box.committed.isEmpty)
    }
}
