import XCTest

@testable import KeyboardCore

/// The kana12 surface queues every code key of one gesture through the existing deferred
/// batch, including the first key of a composition, and never decodes on the calling thread.
/// Keys keep their order with any batch already running, and a cancelled or retired session
/// never lets a queued key reach the engine.
@MainActor
final class Kana12CodeKeyQueueTests: XCTestCase {
    /// Records every key it receives and keeps a kana-shaped composition: a text key appends
    /// one character, BackSpace removes the last one, the closing read is counted per batch.
    private final class RecordingEngine: EngineBackend {
        let kind: EngineBackendKind = .demoSimulator("kana12-queue-test")
        private let lock = NSLock()
        private var input = ""
        private var storedProcessed: [String] = []
        private var storedClosingReads = 0

        var processed: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storedProcessed
        }
        var closingReads: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedClosingReads
        }

        func setup(sharedDirectory: URL, userDirectory: URL) throws {}
        func selectSchema(_ schemaID: String) throws {}

        func processKey(_ keyValue: String) throws -> EngineSnapshot {
            lock.lock()
            defer { lock.unlock() }
            storedProcessed.append(keyValue)
            switch keyValue {
            case EngineCodeKeyToken.backspace:
                if !input.isEmpty { input.removeLast() }
            case EngineCodeKeyToken.cursorLeft, " ", "\n", "Esc":
                break
            default:
                input += keyValue
            }
            return state()
        }

        func processKeys(_ keys: [String], gate: any EngineKeyGate) -> EngineKeyBatch {
            var batch = EngineKeyBatch()
            for key in keys {
                do {
                    guard try gate.admit({ _ = try processKey(key) }) else { break }
                    batch.processed += 1
                } catch {
                    batch.error = error
                    break
                }
            }
            guard batch.processed > 0 else { return batch }
            gate.settle {
                lock.lock()
                storedClosingReads += 1
                lock.unlock()
                batch.snapshot = currentSnapshot()
            }
            return batch
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
        var statusSummary: String { "recording" }

        private func state() -> EngineSnapshot {
            EngineSnapshot(preedit: input, rawInput: input, isComposing: !input.isEmpty)
        }
    }

    /// Holds work until the test runs it, like a busy serial engine queue.
    private final class ManualQueue: EngineWorkQueue {
        private(set) var queued: [@Sendable () -> Void] = []
        func async(_ work: @escaping @Sendable () -> Void) { queued.append(work) }
        func runAll() {
            while !queued.isEmpty { queued.removeFirst()() }
        }
    }

    private func makeSession() -> (InputSession, RecordingEngine, ManualQueue) {
        let engine = RecordingEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        let queue = ManualQueue()
        session.codeKeyQueue = queue
        return (session, engine, queue)
    }

    /// The main-queue hop that applies a finished batch.
    private func deliverMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testTheFirstKeyOfACompositionAlsoDecodesOffTheCallingThread() {
        let (session, engine, queue) = makeSession()
        let revision = session.pendingCodesRevision
        session.enqueueCodeKeys(["k", "a"])
        XCTAssertEqual(session.pendingCodes, ["k", "a"])
        XCTAssertNotEqual(session.pendingCodesRevision, revision, "a queued press is an effect")
        XCTAssertEqual(session.snapshot.rawInput, "", "the press never decodes on the main thread")
        XCTAssertTrue(engine.processed.isEmpty)
        XCTAssertEqual(queue.queued.count, 1, "the whole gesture is one batch")

        queue.runAll()
        deliverMainQueue()
        XCTAssertEqual(engine.processed, ["k", "a"])
        XCTAssertEqual(session.snapshot.rawInput, "ka")
        XCTAssertTrue(session.pendingCodes.isEmpty)
    }

    func testReplacementBackspaceAndRomajiStayInOneBatchInOrder() {
        let (session, engine, queue) = makeSession()
        session.enqueueCodeKeys(["k", "a"])
        queue.runAll()
        deliverMainQueue()
        XCTAssertEqual(session.snapshot.rawInput, "ka")

        session.enqueueCodeKeys([EngineCodeKeyToken.backspace, "g", "a"])
        queue.runAll()
        deliverMainQueue()
        XCTAssertEqual(engine.processed, ["k", "a", "\u{08}", "g", "a"])
        XCTAssertEqual(engine.closingReads, 2, "each gesture reads the engine once, at its end")
    }

    func testPressesQueuedWhileABatchIsDecodingStayInOrder() {
        let (session, engine, queue) = makeSession()
        session.enqueueCodeKeys(["k", "a"])
        session.enqueueCodeKeys(["n", "a"])
        XCTAssertEqual(session.pendingCodes, ["k", "a", "n", "a"])
        XCTAssertEqual(queue.queued.count, 1, "a press that arrives mid-decode joins the wait list")

        queue.runAll()
        deliverMainQueue()
        XCTAssertEqual(session.snapshot.rawInput, "ka")
        XCTAssertEqual(session.pendingCodes, ["n", "a"])
        XCTAssertEqual(queue.queued.count, 1, "the second press decodes after the first lands")

        queue.runAll()
        deliverMainQueue()
        XCTAssertEqual(engine.processed, ["k", "a", "n", "a"])
        XCTAssertEqual(session.snapshot.rawInput, "kana")
        XCTAssertTrue(session.pendingCodes.isEmpty)
    }

    func testTheCursorTokenTravelsAsOneEngineKey() {
        let (session, engine, queue) = makeSession()
        session.enqueueCodeKeys([EngineCodeKeyToken.cursorLeft])
        queue.runAll()
        deliverMainQueue()
        XCTAssertEqual(engine.processed, [EngineCodeKeyToken.cursorLeft])
        XCTAssertEqual(session.snapshot.rawInput, "", "a caret move is not composition text")
    }

    func testSynchronousActionsDrainQueuedKeysFirst() {
        let (session, engine, queue) = makeSession()
        session.enqueueCodeKeys(["k", "a"])
        session.tap(.space)
        XCTAssertEqual(
            Array(engine.processed.prefix(3)), ["k", "a", " "],
            "space still sees every key typed before it")
        XCTAssertTrue(session.pendingCodes.isEmpty)
        queue.runAll()
        deliverMainQueue()
        XCTAssertEqual(Array(engine.processed.prefix(3)), ["k", "a", " "], "nothing lands twice")
    }

    func testCancelDropsKeysTheEngineHasNotSeen() {
        let (session, engine, queue) = makeSession()
        session.enqueueCodeKeys(["k", "a"])
        session.cancelPendingCodes()
        XCTAssertTrue(session.pendingCodes.isEmpty)
        queue.runAll()
        deliverMainQueue()
        XCTAssertTrue(engine.processed.isEmpty, "a cancelled press never reaches the engine")
    }

    func testRetireDropsKeysQueuedForTheNextDocument() {
        let (session, engine, queue) = makeSession()
        session.enqueueCodeKeys(["k", "a"])
        session.retire()
        queue.runAll()
        deliverMainQueue()
        XCTAssertTrue(engine.processed.isEmpty, "retiring the session drops its queued keys")
        XCTAssertTrue(session.pendingCodes.isEmpty)
    }

    func testWithoutAnAsynchronousQueueTheGestureStillRunsOnceAndInOrder() {
        let engine = RecordingEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        session.enqueueCodeKeys(["k", "a"])
        XCTAssertEqual(engine.processed, ["k", "a"], "no queue: one synchronous batch")
        XCTAssertEqual(session.snapshot.rawInput, "ka")
        XCTAssertTrue(session.pendingCodes.isEmpty)
    }
}
