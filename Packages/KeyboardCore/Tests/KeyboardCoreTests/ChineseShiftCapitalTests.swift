import XCTest

@testable import KeyboardCore

/// Shift in Chinese mode hands the capital to the engine, which decides what it means. A schema
/// that reads capitals (rime_ice's `V` symbol input) composes it; one that does not hands the
/// letter back and it is typed as itself.
@MainActor
final class ChineseShiftCapitalTests: XCTestCase {
    private final class CapitalEngine: EngineBackend {
        var readsCapitals: Bool
        private(set) var keys: [String] = []
        private var input = ""
        var kind: EngineBackendKind { .demoSimulator("capital") }
        var statusSummary: String { "capital" }
        init(readsCapitals: Bool) { self.readsCapitals = readsCapitals }
        func setup(sharedDirectory: URL, userDirectory: URL) throws {}
        func validateSchema(_ schemaID: String) throws {}
        func selectSchema(_ schemaID: String) throws {}
        func spellerAlphabet(schemaID: String) -> String? { nil }
        func processKey(_ keyValue: String) throws -> EngineSnapshot {
            keys.append(keyValue)
            let isCapital = keyValue.count == 1 && keyValue.first?.isUppercase == true
            if isCapital && !readsCapitals {
                // Not read by the speller: the engine hands the letter back, typed as itself.
                return EngineSnapshot(committed: keyValue)
            }
            input += keyValue
            return currentSnapshot()
        }
        func selectCandidate(_ index: Int) throws -> EngineSnapshot { currentSnapshot() }
        func nextPage() throws -> EngineSnapshot { currentSnapshot() }
        func previousPage() throws -> EngineSnapshot { currentSnapshot() }
        func currentSnapshot() -> EngineSnapshot {
            EngineSnapshot(preedit: input, rawInput: input, isComposing: !input.isEmpty)
        }
        func shutdown() {}
    }

    private func make(readsCapitals: Bool) -> (InputSession, CapitalEngine, () -> [String]) {
        let engine = CapitalEngine(readsCapitals: readsCapitals)
        let session = InputSession(engine: engine, layout: .qwerty26)
        var commits: [String] = []
        session.onCommitted = { commits.append($0) }
        return (session, engine, { commits })
    }

    func testACapitalTheEngineAcceptsComposes() {
        let (session, engine, commits) = make(readsCapitals: true)
        session.tapShift()
        XCTAssertEqual(session.shiftState, .once, "Chinese mode arms Shift")
        session.tap(.code("v"))
        XCTAssertEqual(engine.keys, ["V"])
        XCTAssertEqual(session.shiftState, .off, "once is consumed by the letter")
        for key in "help" { session.tap(.code(String(key))) }
        XCTAssertEqual(session.snapshot.rawInput, "Vhelp")
        XCTAssertTrue(session.snapshot.isComposing)
        XCTAssertEqual(commits(), [])
    }

    func testACapitalTheEngineRejectsIsTyped() {
        let (session, engine, commits) = make(readsCapitals: false)
        session.tapShift()
        session.tap(.code("v"))
        XCTAssertEqual(engine.keys, ["V"])
        XCTAssertEqual(commits(), ["V"])
        XCTAssertFalse(session.snapshot.isComposing)
        XCTAssertEqual(session.shiftState, .off, "Shift releases after one capital")
        session.tap(.code("v"))
        XCTAssertEqual(engine.keys, ["V", "v"], "the next letter is lowercase again")
    }

    func testCapsLockSendsEveryLetterAsACapital() {
        let (session, engine, _) = make(readsCapitals: true)
        session.doubleTapShift()
        XCTAssertEqual(session.shiftState, .locked)
        session.tap(.code("a"))
        session.tap(.code("b"))
        XCTAssertEqual(engine.keys, ["A", "B"])
        XCTAssertEqual(session.shiftState, .locked)
    }

    func testAnUnarmedLetterIsStillLowercase() {
        let (session, engine, _) = make(readsCapitals: true)
        session.tap(.code("v"))
        XCTAssertEqual(engine.keys, ["v"])
    }

    func testLeavingChineseModeReleasesShift() {
        let (session, _, _) = make(readsCapitals: true)
        session.tapShift()
        session.setMode(.english)
        XCTAssertEqual(session.shiftState, .off)
    }
}
