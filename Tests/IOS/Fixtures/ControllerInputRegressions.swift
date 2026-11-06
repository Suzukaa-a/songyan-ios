import CandidateKit
import Foundation
import KeyboardCore
import LayoutKit
import OSLog

// Compile the unmodified controller body outside UIKit. These enums contain only
// the host traits it reads; neither input state nor controller behavior is stubbed.
public enum UIKeyboardType {
    case `default`, asciiCapable, numbersAndPunctuation, URL, emailAddress, numberPad, decimalPad,
        asciiCapableNumberPad, phonePad, namePhonePad, twitter, webSearch
}
public enum UIReturnKeyType {
    case `default`, go, google, yahoo, search, join, next, route, send, done, emergencyCall, `continue`
}
public enum UIKeyboardAppearance { case `default`, dark, light }
public enum UITextAutocapitalizationType { case none, words, sentences, allCharacters }
enum KeyboardLifecycleDiagnostics { static func emit(_ event: String, _ values: [String: String]) {} }
enum KeyboardStallReport { static func begin(_ kind: String) -> () -> Void { {} } }
extension Logger {
    static let keyboardController = Logger(subsystem: "app.songyan.ime", category: "KeyboardController")
}

// RimeBackend is only a production downcast for diagnostics/persistence. The
// behavioral fixture below uses EngineBackend and real InputSession instead.
class RimeBackend: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("controller-regression")
    var lastErrorText: String?
    var optionPersistenceError: Error?
    var onOptionPersistenceCompleted: (@MainActor (Error?) -> Void)?
    var statusSummary: String { "fixture" }
    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws {}
    func processKey(_ keyValue: String) throws -> EngineSnapshot { EngineSnapshot() }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot { EngineSnapshot() }
    func nextPage() throws -> EngineSnapshot { EngineSnapshot() }
    func previousPage() throws -> EngineSnapshot { EngineSnapshot() }
    func currentSnapshot() -> EngineSnapshot { EngineSnapshot() }
    func shutdown() {}
}

final class ProbeEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("controller-regression")
    var statusSummary: String { "fixture" }
    var state = EngineSnapshot()
    var selectedAbsolute: Int?
    var probeGate: DispatchSemaphore?
    private let lock = NSLock()
    private var didStartProbe = false
    private var queriedPrefixes: [String] = []
    var probeStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStartProbe
    }
    var prefixes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return queriedPrefixes
    }
    var supportsReadOnlyBrowsing: Bool { true }
    /// Puts this code key into a real composing state (default nil = every key commits directly, leaving other cases unaffected).
    var composingCode: String?
    /// When set, a composition started by `composingCode` offers this one candidate.
    var composingCandidate: String?
    /// When set, this code key is committed directly by the schema and never composes.
    var directCommitCode: String?
    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws { state.schemaID = schemaID }
    func processKey(_ keyValue: String) throws -> EngineSnapshot {
        if keyValue == "Esc" {
            state.isPrediction = false
            state.candidates = []
            return state
        }
        // Real engine semantics: confirm (newline) ends the composition and commits its content. Without this,
        // `commitComposition` would correctly refuse later direct input because "the composition is still open" -
        // which is an incomplete fixture, not a production defect.
        if keyValue == "\n", state.isComposing {
            var confirmed = EngineSnapshot(committed: state.preedit)
            confirmed.schemaID = state.schemaID
            var cleared = EngineSnapshot()
            cleared.schemaID = state.schemaID
            state = cleared
            return confirmed
        }
        if let composingCode, keyValue == composingCode {
            var composing = state
            composing.isComposing = true
            composing.preedit = keyValue
            composing.rawInput = keyValue
            composing.committed = ""
            if let composingCandidate {
                composing.candidates = [Candidate(index: 0, text: composingCandidate)]
                composing.highlightedIndex = 0
                composing.pageSize = 1
            }
            state = composing
            return composing
        }
        // A schema may commit an ordinary letter itself instead of starting a composition.
        if let directCommitCode, keyValue == directCommitCode {
            var confirmed = EngineSnapshot(committed: keyValue)
            confirmed.schemaID = state.schemaID
            var cleared = EngineSnapshot()
            cleared.schemaID = state.schemaID
            state = cleared
            return confirmed
        }
        // Engine backspace deletes the composition's last code; it never deletes host text.
        if keyValue == "\u{08}" {
            var result = state
            if result.isComposing {
                result.preedit = String(result.preedit.dropLast())
                result.rawInput = result.preedit
                result.candidates = result.preedit.isEmpty ? [] : [Candidate(index: 0, text: result.preedit)]
                result.highlightedIndex = result.preedit.isEmpty ? -1 : 0
                result.isComposing = !result.preedit.isEmpty
                if !result.isComposing {
                    result.pageSize = 0
                }
            }
            result.committed = ""
            state = result
            return result
        }
        var result = state
        result.committed = keyValue
        return result
    }

    /// A real engine clears the composition unconditionally; the demo default would leave this
    /// fixture's state composing.
    func cancelComposition() throws -> EngineSnapshot {
        let schema = state.schemaID
        state = EngineSnapshot()
        state.schemaID = schema
        return state
    }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot { try selectCandidateAbsolute(index) }
    func selectCandidateAbsolute(_ index: Int) throws -> EngineSnapshot {
        selectedAbsolute = index
        var result = EngineSnapshot(committed: "c\(index)")
        result.schemaID = state.schemaID
        state = EngineSnapshot()
        return result
    }
    func readCandidates(fromIndex: Int, count: Int) throws -> [Candidate] {
        Array(fromIndex..<min(5, fromIndex + count)).enumerated().map {
            Candidate(index: $0.offset, text: "c\($0.element)")
        }
    }
    func wordCompletionSchemas(sourceSchemaID: String) throws -> [String] {
        lock.lock()
        didStartProbe = true
        lock.unlock()
        if let probeGate { precondition(probeGate.wait(timeout: .now() + 5) == .success) }
        return ["english"]
    }
    func wordCompletions(prefix: String, schemaID: String, limit: Int) throws -> [String]? {
        lock.lock()
        queriedPrefixes.append(prefix)
        lock.unlock()
        return prefix == "th" ? ["the", "this"] : [prefix + "word", prefix + "words"]
    }
    func nextPage() throws -> EngineSnapshot { state }
    func previousPage() throws -> EngineSnapshot { state }
    func currentSnapshot() -> EngineSnapshot { state }
    func shutdown() {}
}

/// Commits exactly the candidate text the front end renders at that index. ProbeEngine answers
/// every selection with a synthetic "c<index>", so it cannot show whether a stale tap commits a
/// word the user never saw.
final class SelectionEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("controller-regression")
    var statusSummary: String { "fixture" }
    private var candidates: [String]
    private let pageSize: Int
    private var pageIndex = 0
    private var state = EngineSnapshot()

    init(candidates: [String], pageSize: Int = 2) {
        self.candidates = candidates
        self.pageSize = pageSize
        publish()
    }

    /// A new engine result for the running composition. The front end has not re-rendered yet.
    func replaceCandidates(_ texts: [String]) {
        candidates = texts
        pageIndex = 0
        publish()
    }

    var visibleTexts: [String] { state.candidates.map(\.text) }

    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws {}
    func processKey(_ keyValue: String) throws -> EngineSnapshot { state }

    func selectCandidate(_ index: Int) throws -> EngineSnapshot {
        try commit(absolute: pageIndex * pageSize + index)
    }

    func selectCandidateAbsolute(_ index: Int) throws -> EngineSnapshot { try commit(absolute: index) }

    func nextPage() throws -> EngineSnapshot {
        let next = pageIndex + 1
        guard next * pageSize < candidates.count else { return state }
        pageIndex = next
        publish()
        return state
    }

    func previousPage() throws -> EngineSnapshot {
        guard pageIndex > 0 else { return state }
        pageIndex -= 1
        publish()
        return state
    }

    func currentSnapshot() -> EngineSnapshot { state }
    var supportsReadOnlyBrowsing: Bool { true }

    /// Read by offset like the real engine: never moves the page or the highlight.
    func readCandidates(fromIndex: Int, count: Int) throws -> [Candidate] {
        guard fromIndex < candidates.count else { return [] }
        return (fromIndex..<min(candidates.count, fromIndex + count)).map {
            Candidate(index: $0 - fromIndex, text: candidates[$0])
        }
    }

    func shutdown() {}

    private func publish() {
        let start = pageIndex * pageSize
        let page = start < candidates.count ? Array(candidates[start..<min(candidates.count, start + pageSize)]) : []
        state = EngineSnapshot(
            candidates: page.enumerated().map { Candidate(index: $0.offset, text: $0.element) },
            preedit: "x", rawInput: "x", isComposing: !page.isEmpty,
            highlightedIndex: page.isEmpty ? -1 : 0,
            pageIndex: pageIndex, pageSize: pageSize,
            isLastPage: start + pageSize >= candidates.count)
    }

    /// Real engine semantics: the chosen candidate commits its own text and the composition ends.
    /// The stored snapshot must not keep that commit, or a later refresh would deliver it again.
    private func commit(absolute index: Int) throws -> EngineSnapshot {
        guard candidates.indices.contains(index) else {
            throw EngineBackendError.operationFailed("no candidate at \(index)")
        }
        let committed = candidates[index]
        candidates = []
        pageIndex = 0
        state = EngineSnapshot()
        return EngineSnapshot(committed: committed)
    }
}

/// Holds code-key work until the test runs it: a deterministic stand-in for the production
/// engine queue, so a first key is provably still decoding while the next action is handled.
final class ManualQueue: EngineWorkQueue {
    private(set) var queued: [@Sendable () -> Void] = []
    func async(_ work: @escaping @Sendable () -> Void) { queued.append(work) }
    func runAll() {
        while !queued.isEmpty { queued.removeFirst()() }
    }
}

@main struct ControllerInputChecks {
    @MainActor static func eventually(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        preconditionFailure(message)
    }

    /// The first ordinary letter of a plain composition decodes on the engine queue: the tap
    /// returns before the backend runs, the field echoes the letter, and every non-code action
    /// settles the key first so it acts on the real state. A schema may also commit the letter
    /// directly (no composition at all), which the same actions must handle.
    @MainActor static func firstKeyDeferred() async {
        // 1. The schema starts a composition with one candidate: space confirms it, no literal space.
        do {
            let engine = ProbeEngine()
            engine.composingCode = "n"
            engine.composingCandidate = "你"
            let controller = KeyboardController(engine: engine)
            let queue = ManualQueue()
            controller.session.codeKeyQueue = queue
            var commits: [String] = []
            controller.onDispatchCommit = {
                commits.append($0)
                return true
            }
            var marks: [MarkedComposition?] = []
            controller.onMarkedComposition = { marks.append($0) }

            controller.handle(.code("n"))
            precondition(controller.session.pendingCodes == ["n"], "the first key must still be decoding")
            precondition(!controller.snapshot.isComposing, "no engine result is applied before the queue runs")
            await eventually("the pending first key was never echoed") { marks.last??.text == "n" }

            controller.handle(.space)
            precondition(commits == ["c0"], "space must confirm the candidate, not type a space: \(commits)")
            queue.runAll()
            await eventually("the stopped batch must not apply twice") { commits == ["c0"] }
            controller.retire()
        }

        // 2. Return on a plain composition commits the raw composition, never a newline.
        do {
            let engine = ProbeEngine()
            engine.composingCode = "n"
            engine.composingCandidate = "你"
            let controller = KeyboardController(engine: engine)
            let queue = ManualQueue()
            controller.session.codeKeyQueue = queue
            var commits: [String] = []
            controller.onDispatchCommit = {
                commits.append($0)
                return true
            }
            controller.handle(.code("n"))
            controller.handle(.enter)
            precondition(commits == ["n"], "return commits the raw composition, never a newline: \(commits)")
            queue.runAll()
            await eventually("the stopped batch must not apply twice") { commits == ["n"] }
            controller.retire()
        }

        // 3. Backspace on a decoding first letter deletes the composition in the engine, never host text.
        do {
            let engine = ProbeEngine()
            engine.composingCode = "n"
            let controller = KeyboardController(engine: engine)
            let queue = ManualQueue()
            controller.session.codeKeyQueue = queue
            var hostDeletes = 0
            controller.onRequestDeleteBackward = { hostDeletes += 1 }
            var commits: [String] = []
            controller.onDispatchCommit = {
                commits.append($0)
                return true
            }
            controller.handle(.code("n"))
            controller.handle(.backspace)
            precondition(hostDeletes == 0, "a decoding first letter must not delete host text")
            precondition(commits.isEmpty)
            precondition(!controller.snapshot.isComposing)
            queue.runAll()
            await eventually("the stopped batch must not apply") { !controller.snapshot.isComposing }
            controller.retire()
        }

        // 4. A schema that commits the letter directly: space appends a real space, backspace
        //    deletes the committed character from the host, Return types a newline, toggle commits
        //    nothing extra.
        do {
            let engine = ProbeEngine()
            engine.directCommitCode = "n"
            let controller = KeyboardController(engine: engine)
            let queue = ManualQueue()
            controller.session.codeKeyQueue = queue
            var commits: [String] = []
            controller.onDispatchCommit = {
                commits.append($0)
                return true
            }
            controller.handle(.code("n"))
            precondition(controller.session.pendingCodes == ["n"], "the first key must still be decoding")
            controller.handle(.space)
            precondition(commits == ["n", " "], "a directly committed first letter still gets a space: \(commits)")
            queue.runAll()
            controller.retire()
        }
        do {
            let engine = ProbeEngine()
            engine.directCommitCode = "n"
            let controller = KeyboardController(engine: engine)
            let queue = ManualQueue()
            controller.session.codeKeyQueue = queue
            var hostDeletes = 0
            controller.onRequestDeleteBackward = { hostDeletes += 1 }
            controller.handle(.code("n"))
            controller.handle(.backspace)
            precondition(hostDeletes == 1, "the directly committed letter must be deleted from the host")
            precondition(!controller.snapshot.isComposing, "an idle engine must not be asked to compose")
            queue.runAll()
            controller.retire()
        }
        do {
            let engine = ProbeEngine()
            engine.directCommitCode = "n"
            let controller = KeyboardController(engine: engine)
            let queue = ManualQueue()
            controller.session.codeKeyQueue = queue
            var commits: [String] = []
            controller.onDispatchCommit = {
                commits.append($0)
                return true
            }
            controller.handle(.code("n"))
            controller.handle(.enter)
            precondition(
                commits == ["n", "\n"], "return types a newline after a directly committed letter: \(commits)")
            queue.runAll()
            controller.retire()
        }
        do {
            let engine = ProbeEngine()
            engine.directCommitCode = "n"
            let controller = KeyboardController(engine: engine)
            let queue = ManualQueue()
            controller.session.codeKeyQueue = queue
            var commits: [String] = []
            controller.onDispatchCommit = {
                commits.append($0)
                return true
            }
            controller.handle(.code("n"))
            controller.toggleInputMode()
            precondition(
                commits == ["n"], "toggle must not confirm or re-commit a directly committed letter: \(commits)")
            precondition(controller.inputMode == .english)
            queue.runAll()
            controller.retire()
        }

        // 5. Cancelling pending keys clears their echo; a real composition echo survives it.
        do {
            let engine = ProbeEngine()
            engine.composingCode = "n"
            let controller = KeyboardController(engine: engine)
            let queue = ManualQueue()
            controller.session.codeKeyQueue = queue
            var marks: [MarkedComposition?] = []
            controller.onMarkedComposition = { marks.append($0) }
            var commits: [String] = []
            controller.onDispatchCommit = {
                commits.append($0)
                return true
            }
            controller.handle(.code("n"))
            await eventually("the pending first key was never echoed") { marks.last??.text == "n" }
            controller.session.cancelPendingCodes()
            await eventually("cancelling must clear the pending-only echo") { marks.last! == nil }
            queue.runAll()
            precondition(commits.isEmpty, "a cancelled first key never commits")
            precondition(controller.snapshot.rawInput.isEmpty && !controller.snapshot.isComposing)
            controller.retire()
        }
        do {
            let engine = ProbeEngine()
            engine.composingCode = "n"
            let controller = KeyboardController(engine: engine)
            let queue = ManualQueue()
            controller.session.codeKeyQueue = queue
            var marks: [MarkedComposition?] = []
            controller.onMarkedComposition = { marks.append($0) }
            controller.handle(.code("n"))
            queue.runAll()
            await eventually("the first key did not land as a composition") { controller.snapshot.isComposing }
            controller.handle(.code("i"))
            precondition(controller.session.pendingCodes == ["i"])
            controller.session.cancelPendingCodes()
            await eventually("the composition echo must survive the cancel") {
                marks.last??.text == "n" && controller.snapshot.isComposing
            }
            controller.retire()
        }
    }

    @MainActor static func pendingFirstKeyFallback() async {
        let engine = ProbeEngine()
        engine.composingCode = "n"
        let controller = KeyboardController(engine: engine)
        let queue = ManualQueue()
        controller.session.codeKeyQueue = queue
        controller.updateHostTraits(
            keyboardType: .default, returnKeyType: .search, keyboardAppearance: .default,
            enablesReturnKeyAutomatically: true, documentIsEmpty: true)
        precondition(!controller.isReturnKeyEnabled)
        controller.handle(.code("n"))
        precondition(controller.isReturnKeyEnabled, "a pending first letter enables confirmation")
        await eventually("the keyboard must show a pending first letter without a host outlet") {
            controller.keyboardCompositionFallback?.text == "n"
        }
        controller.session.cancelPendingCodes()
        precondition(!controller.isReturnKeyEnabled, "cancelling the pending letter disables empty-field Search")
        precondition(controller.keyboardCompositionFallback == nil, "cancel must remove the fallback echo")
        queue.runAll()
        controller.retire()
    }

    @MainActor static func letters(ascii: Bool) {
        let engine = ProbeEngine()
        engine.state.isAsciiMode = ascii
        let controller = KeyboardController(engine: engine)
        if !ascii { controller.setInputMode(.english) }
        var commits: [String] = []
        var accepts = true
        controller.onDispatchCommit = { text in
            if accepts { commits.append(text) }
            return accepts
        }
        controller.handleShiftTap()
        controller.handle(.letterVariant("á"))
        precondition(commits == ["Á"] && controller.shiftState == .off, "variant must consume once")
        controller.handle(.code("b"))
        precondition(commits.last == "b")
        controller.handleShiftDoubleTap()
        controller.handle(.letterVariant("é"))
        precondition(commits.last == "É" && controller.shiftState == .locked)
        controller.handleShiftTap()
        controller.handleShiftTap()
        accepts = false
        controller.handle(.letterVariant("á"))
        precondition(controller.shiftState == .once, "refused variant must keep shift")
        controller.handle(.code("a"))
        precondition(controller.shiftState == .once, "refused ordinary letter must keep shift")
        accepts = true
        controller.handle(.literal("á"))
        precondition(commits.last == "á" && controller.shiftState == .once, "DIY literal stays verbatim")
        controller.handle(.letterVariant("1"))
        precondition(controller.shiftState == .once)
        controller.handle(.letterVariant("á"))
        precondition(commits.last == "Á" && controller.shiftState == .off)
        controller.updateHostTraits(
            keyboardType: .default, returnKeyType: .default,
            keyboardAppearance: .default, autocapitalizationType: .allCharacters, beforeCursor: "word")
        controller.handle(.letterVariant("é"))
        controller.handle(.code("b"))
        precondition(
            commits.suffix(2) == ["É", "B"] && controller.shiftState == .once,
            "allCharacters re-arms after both input routes")
        controller.retire()
    }

    /// Repeated taps of the idle first key rotate through symbols (nine-key, "item 4 onward").
    ///
    /// Real contract (everything goes through production `cycleT9Punctuation(symbols:)`; its logic is not copied):
    /// 1. On an empty field the first tap inserts item 1;
    /// 2. A second tap within 0.8 s with the document context unchanged -> **replaces** the previous item with the next, cycling back to item 1;
    /// 3. While composing, the call returns false (the first key is still a segment delimiter, not taken over by rotation);
    /// 4. After retirement it returns false (no more document writes).
    @MainActor static func punctuationCycle() {
        let engine = ProbeEngine()
        let controller = KeyboardController(engine: engine)
        var document = ""
        var commits: [String] = []
        // Host semantics: an accepted commit really enters the document, so the context read-back sees it.
        controller.onDispatchCommit = { text in
            commits.append(text)
            document += text
            return true
        }
        controller.onReadDocumentContext = { document }
        controller.onReplaceLiteralSuffix = { expected, old, new in
            // Production semantics: replacement is allowed only while the document suffix still equals expected.
            guard document.hasSuffix(expected), document.hasSuffix(old) else { return false }
            document.removeLast(old.count)
            document += new
            return true
        }
        let symbols = ["！", "、", "…"]

        precondition(controller.cycleT9Punctuation(symbols: symbols), "empty field must insert the first symbol")
        precondition(document == "！" && commits == ["！"], "first tap inserts symbols[0]")

        precondition(controller.cycleT9Punctuation(symbols: symbols), "second tap must advance")
        precondition(document == "、", "second tap must replace, not append: \(document)")
        precondition(controller.cycleT9Punctuation(symbols: symbols), "third tap must advance")
        precondition(document == "…", "third tap: \(document)")
        precondition(controller.cycleT9Punctuation(symbols: symbols), "fourth tap must wrap")
        precondition(document == "！", "cycle must wrap to the first symbol: \(document)")

        // Empty order: nothing may be inserted, and it must not crash.
        precondition(!controller.cycleT9Punctuation(symbols: []), "empty order must be refused")
        precondition(document == "！")

        // While composing: the first key is still a delimiter and rotation must not take over (enter composing via the real engine, without changing controller visibility).
        engine.composingCode = "n"
        controller.handle(.code("n"))
        precondition(controller.snapshot.isComposing, "fixture must be composing")
        precondition(!controller.cycleT9Punctuation(symbols: symbols), "composing must refuse the cycle")
        precondition(document == "！", "composing must not write the document")
        engine.composingCode = nil

        controller.retire()
        precondition(!controller.cycleT9Punctuation(symbols: symbols), "retired controller must refuse")
    }

    /// The "1" selected by long-pressing the first key goes through a **plain literal action** and does not take part in rotation.
    ///
    /// The panel branches on the selected cap (rotation only when `selected == cap`), so what actually runs when the finger lifts after a long-press on 1
    /// is `handleDefinitionAction(.literal("1"))` -> `handleKey` -> one ordinary commit.
    /// This pins that semantics with a real controller:
    /// 1. Idle long-press 1 = insert `1`, and does **not** replace/advance any rotation item;
    /// 2. The rotation pointer is unaffected by the long-press: a short tap right after still starts from item 1;
    /// 3. Long-press 1 while composing = commit the composition first, then insert `1` (existing commit semantics; not a delimiter, not rotation).
    @MainActor static func firstKeyLongPressInsertsOne() {
        let engine = ProbeEngine()
        let controller = KeyboardController(engine: engine)
        var document = ""
        var commits: [String] = []
        controller.onDispatchCommit = { text in
            commits.append(text)
            document += text
            return true
        }
        controller.onReadDocumentContext = { document }
        controller.onReplaceLiteralSuffix = { expected, old, new in
            guard document.hasSuffix(expected), document.hasSuffix(old) else { return false }
            document.removeLast(old.count)
            document += new
            return true
        }
        let symbols = ["！", "、", "…"]

        // Long-press 1: plain literal commit.
        controller.handle(.literal("1"))
        precondition(document == "1", "long press 1 must insert the digit: \(document)")
        precondition(commits == ["1"], "exactly one commit: \(commits)")

        // The rotation pointer is unaffected by the long-press: a short tap right after is still item 1 (replace, not advance).
        precondition(controller.cycleT9Punctuation(symbols: symbols), "cycle after long press")
        precondition(
            document == "1！", "a short tap inserts from item 1 and does not continue the long-press: \(document)")
        precondition(controller.cycleT9Punctuation(symbols: symbols), "second short tap advances")
        precondition(document == "1、", "second short tap replaces: \(document)")

        // Long-press 1 while composing: commit the composition first (existing semantics), then insert 1; no delimiter, no rotation.
        let engine2 = ProbeEngine()
        engine2.composingCode = "n"
        let composing = KeyboardController(engine: engine2)
        var composingDocument = ""
        composing.onDispatchCommit = { text in
            composingDocument += text
            return true
        }
        composing.onReadDocumentContext = { composingDocument }
        composing.onReplaceLiteralSuffix = { expected, old, new in
            guard composingDocument.hasSuffix(expected), composingDocument.hasSuffix(old) else { return false }
            composingDocument.removeLast(old.count)
            composingDocument += new
            return true
        }
        composing.handle(.code("n"))
        precondition(composing.snapshot.isComposing, "fixture must be composing")
        let beforeDigits = composingDocument
        precondition(
            !composing.cycleT9Punctuation(symbols: symbols),
            "a short tap while composing is still a delimiter: rotation must refuse")
        precondition(composingDocument == beforeDigits, "rotation while composing must not write the document")
        composing.handle(.literal("1"))
        precondition(
            composingDocument.hasSuffix("1"),
            "long-press 1 while composing must still insert the digit: \(composingDocument)")
        precondition(
            !composingDocument.hasSuffix("'"),
            "long-press 1 must never be treated as a delimiter: \(composingDocument)")
        composing.retire()
        controller.retire()
    }

    @MainActor static func probeWhileTyping() async {
        let engine = ProbeEngine()
        engine.state.schemaID = "source"
        let gate = DispatchSemaphore(value: 0)
        engine.probeGate = gate
        let controller = KeyboardController(engine: engine)
        controller.onDispatchCommit = { _ in true }
        controller.setInputMode(.english)
        await eventually("probe never started") { engine.probeStarted }
        controller.handle(.code("h"))
        controller.handle(.code("e"))
        precondition(controller.englishSuggestions.isEmpty)
        gate.signal()
        await eventually("probe completion did not query the current word") {
            controller.englishSuggestions == ["heword", "hewords"]
        }
        precondition(engine.prefixes == ["th", "he"], "query the current word once")
        controller.retire()
    }

    @MainActor static func probeAfterLeavingABC() async {
        let engine = ProbeEngine()
        engine.state.schemaID = "source"
        let gate = DispatchSemaphore(value: 0)
        engine.probeGate = gate
        let controller = KeyboardController(engine: engine)
        controller.onDispatchCommit = { _ in true }
        controller.setInputMode(.english)
        await eventually("probe never started") { engine.probeStarted }
        controller.handle(.code("h"))
        controller.setInputMode(.chinese)
        gate.signal()
        await eventually("probe did not finish") { controller.englishSuggestionsSupported == true }
        precondition(
            controller.englishSuggestions.isEmpty && engine.prefixes == ["th"],
            "late probe must not query the abandoned word")
        controller.retire()
    }

    @MainActor static func predictionPaging() async {
        let engine = ProbeEngine()
        engine.state = EngineSnapshot(
            candidates: [Candidate(index: 0, text: "c0"), Candidate(index: 1, text: "c1")],
            pageSize: 2, isLastPage: false)
        engine.state.isPrediction = true
        let controller = KeyboardController(engine: engine)
        var commits: [String] = []
        var nonnilMarks = 0
        controller.onDispatchCommit = {
            commits.append($0)
            return true
        }
        controller.onMarkedComposition = { if $0 != nil { nonnilMarks += 1 } }
        precondition(!controller.snapshot.isComposing && controller.candidateBrowser.hasMore)
        controller.loadMoreCandidates()
        await eventually("prediction next pages were not loaded") { controller.candidateBrowser.count == 5 }
        precondition(!controller.candidateBrowser.hasMore && nonnilMarks == 0 && commits.isEmpty)
        controller.selectCandidate(pageIndex: 2, pageLocalIndex: 0)
        precondition(engine.selectedAbsolute == 4 && commits == ["c4"])
        precondition(controller.candidateBrowser.isEmpty && nonnilMarks == 0)
        controller.retire()
    }

    /// A renderer action captured by one render can arrive after the engine published a new
    /// result but before SwiftUI rebuilds the view: the retained sink still carries the old
    /// render's indices. Those two selection cases must then be rejected, while everything that
    /// re-reads the engine's current state (paging, read-only loading) stays allowed.
    @MainActor static func staleCandidateSink() async {
        let engine = SelectionEngine(candidates: ["alpha", "beta", "gamma", "delta"])
        let controller = KeyboardController(engine: engine)
        var document = ""
        controller.onDispatchCommit = { text in
            document += text
            return true
        }
        precondition(
            controller.snapshot.candidates.map(\.text) == ["alpha", "beta"],
            "fixture must show the first page")
        let staleSink = CandidateAreaActionSink.live(controller: controller, onExpand: {}, onCollapse: {})

        // The engine result is published through the real session; the view has not rebuilt, so the
        // sink above is still what a tap under the user's finger would call.
        engine.replaceCandidates(["gamma", "delta", "epsilon", "zeta"])
        controller.session.refresh()
        precondition(
            controller.snapshot.candidates.map(\.text) == ["gamma", "delta"],
            "fixture must publish the changed list: \(controller.snapshot.candidates.map(\.text))")

        staleSink.perform(.select(0))
        precondition(
            document.isEmpty,
            "a tap from the previous render must not commit the newly published candidate: \(document)")
        staleSink.perform(.selectOnPage(page: 0, index: 1))
        precondition(
            document.isEmpty,
            "a cross-page tap from the previous render must not commit: \(document)")

        // Paging reads the engine's current state instead of an index from the old render, so it
        // must keep working from a sink created before the result was published.
        staleSink.perform(.pageForward)
        precondition(
            controller.snapshot.pageIndex == 1
                && controller.snapshot.candidates.map(\.text) == ["epsilon", "zeta"],
            "paging from an older render must not be swallowed: \(controller.snapshot.candidates.map(\.text))")
        controller.retire()

        // A sink created for the render that shows the current list selects the word the user sees.
        let current = KeyboardController(engine: SelectionEngine(candidates: ["gamma", "delta"]))
        var currentDocument = ""
        current.onDispatchCommit = { text in
            currentDocument += text
            return true
        }
        let currentSink = CandidateAreaActionSink.live(controller: current, onExpand: {}, onCollapse: {})
        currentSink.perform(.select(1))
        precondition(
            currentDocument == "delta",
            "a current sink must commit the tapped candidate: \(currentDocument)")
        current.retire()

        // The same for a candidate from a browsed page: read-only loading does not change the
        // composition revision, so a sink created before it must still select.
        let browsed = KeyboardController(engine: SelectionEngine(candidates: ["one", "two", "three", "four"]))
        var browsedDocument = ""
        browsed.onDispatchCommit = { text in
            browsedDocument += text
            return true
        }
        let browsedSink = CandidateAreaActionSink.live(controller: browsed, onExpand: {}, onCollapse: {})
        browsed.loadMoreCandidates()
        await eventually("the read-only second page did not land") { browsed.candidateBrowser.count == 4 }
        browsedSink.perform(.selectOnPage(page: 1, index: 0))
        precondition(
            browsedDocument == "three",
            "a read-only append keeps the same revision, so the older sink must still select: \(browsedDocument)")
        browsed.retire()
    }

    /// For the built-in nine-key digits 2-9, long-press and tap must be two distinct semantic paths:
    /// - tap = `.code(digit)`: handed to the engine (composition/candidates);
    /// - long-press = `.literal(digit)`: types the digit directly, bypassing engine composition.
    /// If both behave the same, the declared long-press secondary key was lost (the generic letter policy returns empty for digit-code keys).
    @MainActor static func t9DigitLongPressIsLiteralNotCode() {
        let engine = ProbeEngine()
        let controller = KeyboardController(engine: engine)
        var document = ""
        controller.onDispatchCommit = { text in
            document += text
            return true
        }
        controller.onReadDocumentContext = { document }
        controller.onReplaceLiteralSuffix = { expected, old, new in
            guard document.hasSuffix(expected), document.hasSuffix(old) else { return false }
            document.removeLast(old.count)
            document += new
            return true
        }
        let alphabet = "abcdefghijklmnopqrstuvwxyz"

        // The declaration must really provide a "long-press types the digit" secondary key, otherwise the semantic assertions below are meaningless.
        for digit in ["2", "3", "4", "5", "6", "7", "8", "9"] {
            let key = BuiltinLayouts.phone9.rows.flatMap(\.keys)
                .first { $0.action.type == .code && $0.action.value == digit }
            precondition(key != nil, "the built-in nine-key must declare digit key \(digit)")
            precondition(
                BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(key!),
                "\(digit) must take the declared path (otherwise the long-press secondary key is empty)")
            let declared = key!.longPress ?? []
            precondition(
                declared.count == 1 && declared[0].action == .init(.literal, value: digit),
                "the declared long-press of \(digit) must be literal \(digit), got \(declared.map(\.action))")
            // The generic policy returns empty for this key - it cannot go through that path.
            let policy = AlternateKeyPolicy.options(
                for: .init(
                    keyLabel: digit, mergedGroup: key!.label.lowercased(),
                    secondaryLiterals: declared.compactMap { $0.action.value },
                    page: .letters, language: .chinese, schemaAlphabet: alphabet))
            precondition(policy.isEmpty, "\(digit) generic policy is expected to return empty")
        }

        // Long-press path: literal types directly, the digit appears in the document at once (no composition).
        controller.handle(.literal("6"))
        precondition(document == "6", "long-press 6 must type the digit directly: \(document)")
        precondition(!controller.snapshot.isComposing, "typing a digit directly must not leave a composition")
        controller.handle(.literal("2"))
        precondition(document == "62", "long-press 2 must type the digit directly: \(document)")

        // Tap path: the code goes to the engine (ProbeEngine returns commit/composition with real-engine semantics).
        controller.handle(.code("6"))
        precondition(document.hasSuffix("6"), "a digit-code tap must still go through the engine: \(document)")
        controller.retire()
    }

    @MainActor static func main() async {
        letters(ascii: false)
        letters(ascii: true)
        punctuationCycle()
        firstKeyLongPressInsertsOne()
        t9DigitLongPressIsLiteralNotCode()
        await probeWhileTyping()
        await probeAfterLeavingABC()
        await predictionPaging()
        await staleCandidateSink()
        await firstKeyDeferred()
        await pendingFirstKeyFallback()
        print("controller input regression checks passed")
    }
}
