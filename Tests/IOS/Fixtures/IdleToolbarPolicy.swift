import CandidateKit
import Foundation
import KeyboardCore
import LayoutKit
import UniformTypeIdentifiers

// The platform/backend seam is reused from the existing complete-controller probe.
enum KeyboardRecipeStore {
    nonisolated(unsafe) static var canWriteSharedContainer = true
    static let groupID = "test.idle-toolbar-policy"
    static func sharedContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
    static func sharedDefaults() -> UserDefaults? { UserDefaults(suiteName: groupID) }
}
enum KeyboardFeedbackPreferences { static var defaults: UserDefaults { .standard } }

private final class IdleEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("idle-toolbar-policy")
    var statusSummary: String { "fixture" }
    var state = EngineSnapshot()
    var unavailable: String?
    var inputUnavailableReason: String? { unavailable }
    var failsKey = false
    var failsCandidateRead = false
    var supportsReadOnlyBrowsing: Bool { true }
    var readingGate: DispatchSemaphore?
    var ambiguityGate: DispatchSemaphore?
    let readingEntered = DispatchSemaphore(value: 0)
    let ambiguityEntered = DispatchSemaphore(value: 0)
    var report: AmbiguitySpellingsReport?

    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws { state.schemaID = schemaID }
    func currentSnapshot() -> EngineSnapshot { state }
    func processKey(_ key: String) throws -> EngineSnapshot {
        if failsKey { throw EngineBackendError.operationFailed("fixture-key-failure") }
        return state
    }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot { state }
    func nextPage() throws -> EngineSnapshot { state }
    func previousPage() throws -> EngineSnapshot { state }
    func shutdown() {}
    func readCandidates(fromIndex: Int, count: Int) throws -> [Candidate] {
        precondition(!Thread.isMainThread)
        if failsCandidateRead { throw EngineBackendError.operationFailed("fixture-page-failure") }
        return []
    }
    func readCandidatesWithReadings(fromIndex: Int, count: Int) throws -> [ReadingCandidate]? {
        precondition(!Thread.isMainThread)
        readingEntered.signal()
        if let readingGate { precondition(readingGate.wait(timeout: .now() + 5) == .success) }
        return fromIndex == 0 ? [ReadingCandidate(index: 0, text: "candidate", syllables: ["ni"])] : []
    }
    func ambiguitySpellings() throws -> AmbiguitySpellingsReport? {
        precondition(!Thread.isMainThread)
        ambiguityEntered.signal()
        if let ambiguityGate { precondition(ambiguityGate.wait(timeout: .now() + 5) == .success) }
        return report
    }
}

/* PRODUCTION_TOOLBAR_PREFERENCES */

/* PRODUCTION_DEFINITION_MEMO */

// Only SwiftUI-owned state is substituted. Layout facts and the getter and
// observation/eligibility statements below are copied verbatim from production.
@MainActor private final class IdlePanelProbe {
    struct HeaderPlan { var headerHeight: Double }
    let controller: KeyboardController
    let quickSymbols: T9QuickSymbolModel
    var statusMessage: String?
    var showsAllCandidates = false
    var showsCoveringPanel: Bool { showsUtilitiesMenu || showsSymbolLibrary }
    var showsUtilitiesMenu = false
    var showsSymbolLibrary = false
    var page: KeyboardControlPolicy.Page = .letters
    var selectedDefinition: LayoutDefinition? = BuiltinLayouts.phone9
    var activeDefinition: LayoutDefinition? { selectedDefinition }
    var pageDefinition: KeyboardPageDefinition?
    var activeSplit: LayoutSplitConfiguration? { selectedDefinition?.split }
    private var definitionFacts: DefinitionResolutionMemo.Facts {
        DefinitionResolutionMemo.Facts(usable: BuiltinLayouts.all, active: selectedDefinition)
    }

    /* PRODUCTION_DEFINITION_CHROME */

    init(
        controller: KeyboardController, quickSymbols: T9QuickSymbolModel
    ) {
        self.controller = controller
        self.quickSymbols = quickSymbols
    }

    /* PRODUCTION_IDLE_GETTER */
    /* PRODUCTION_SYMBOL_ERROR_GETTER */

    var input: IdleToolbarInput { idleToolbarInput }
}

private struct NativeHeightProbe {
    let presentedHeight: CGFloat?
    let candidateHeight: Double = 56
    let candidateSize: Double = 30
    let readingRowGranted = true
    let candidateAreaGranted = true
    let compactReadingRow = true
    let heightPreset = KeyboardHeightPreset.standard
    let keyHeight: CGFloat = 38
    let drawnMainRows = KeyboardPanelGeometry.standardMainRowCount
    var fixedShellHeight: CGFloat {
        CGFloat(
            KeyboardPanelPresentationBudget(
                candidateHeight: candidateHeight, candidateSize: candidateSize,
                readingRow: true, candidateArea: true, compact: true
            ).shellHeight)
    }
    /* PRODUCTION_NATIVE_SHELL_HEIGHT */
    var resolved: CGFloat { layoutShellHeight }
    var fittedKeyHeight: Double { panelFit(shellHeight: presentedHeight!).keyHeight }
}

@main struct IdleToolbarChecks {
    static let atoms: [(String, WritableKeyPath<IdleToolbarInput, Bool>)] = [
        ("composition", \.isComposing), ("prediction", \.hasPrediction),
        ("candidates", \.hasCandidates), ("English suggestions", \.hasEnglishSuggestions),
        ("unfinished English word", \.hasActiveEnglishInput), ("status", \.hasStatus),
        ("composition fallback", \.hasCompositionFallback), ("readings", \.hasReadingContent),
        ("pending queries", \.hasPendingQueries), ("expanded", \.isExpanded), ("covered", \.isCovered),
    ]

    static func wait(_ semaphore: DispatchSemaphore) async {
        let signaled = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
        precondition(signaled, "fixture operation did not start")
    }
    @MainActor static func eventually(_ reason: String, _ predicate: () -> Bool) async {
        for _ in 0..<3000 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure(reason)
    }
    @MainActor static func symbols(_ root: URL, name: String) async -> T9QuickSymbolModel {
        let model = T9QuickSymbolModel(
            sharedContainer: { root.appendingPathComponent(name) },
            observesNotifications: false, postChange: {})
        await model.reload().value
        precondition(model.error == nil)
        return model
    }
    @MainActor static func atomicPolicies() {
        precondition(atoms.count == 11)
        for mask in 0..<(1 << atoms.count) {
            var input = IdleToolbarInput()
            for (index, atom) in atoms.enumerated() { input[keyPath: atom.1] = mask & (1 << index) != 0 }
            precondition(input.allowsToolbar == (mask == 0), "unexpected idle eligibility for mask \(mask)")
        }
        print(
            "PASS I1: all 2048 combinations of 11 independent blockers permit the toolbar only for the all-idle state")
    }

    @MainActor static func controllerGetter(_ root: URL) async {
        let qs = await symbols(root, name: "getter-symbols")
        let engine = IdleEngine()
        let controller = KeyboardController(engine: engine)
        let panel = IdlePanelProbe(controller: controller, quickSymbols: qs)
        precondition(panel.input == IdleToolbarInput())
        for key in [\IdlePanelProbe.showsAllCandidates, \.showsUtilitiesMenu, \.showsSymbolLibrary] {
            panel[keyPath: key] = true
            precondition(!panel.input.allowsToolbar)
            panel[keyPath: key] = false
            precondition(panel.input.allowsToolbar)
        }
        panel.statusMessage = "real host status"
        precondition(panel.input.hasStatus && !panel.input.allowsToolbar)
        panel.statusMessage = nil
        engine.state.isPrediction = true
        controller.session.refresh()
        precondition(panel.input.hasPrediction && !panel.input.isComposing && !panel.input.allowsToolbar)
        engine.state.isPrediction = false
        engine.state.isComposing = true
        engine.state.rawInput = "ni"
        engine.state.preedit = "ni"
        controller.session.refresh()
        precondition(panel.input.isComposing && panel.input.hasCompositionFallback && !panel.input.allowsToolbar)
        controller.reportCompositionPresentation(.awaitingHost)
        precondition(!panel.input.hasCompositionFallback && !panel.input.allowsToolbar)
        engine.state = EngineSnapshot()
        controller.session.refresh()
        engine.failsKey = true
        controller.handle(.code("x"))
        precondition(controller.inputError != nil && panel.input.hasStatus && !panel.input.allowsToolbar)
        engine.failsKey = false
        engine.state.preedit = "refresh clears a previous error"
        controller.session.refresh()
        precondition(controller.inputError == nil)
        engine.state.preedit = ""
        controller.session.refresh()
        engine.unavailable = "fixture-unavailable"
        controller.session.refresh()
        precondition(controller.inputUnavailableReason != nil && panel.input.hasStatus && !panel.input.allowsToolbar)
        engine.unavailable = nil
        controller.session.refresh()
        precondition(panel.input.allowsToolbar)
        let failedSave = await qs.replaceSymbols("")
        precondition(!failedSave && qs.error != nil && panel.input.hasStatus && !panel.input.allowsToolbar)
        _ = await qs.replaceSymbols("[]")
        precondition(qs.error == nil && panel.input.allowsToolbar)
        controller.retire()
        let suggestedController = KeyboardController(engine: ProbeEngine())
        suggestedController.onDispatchCommit = { _ in true }
        suggestedController.setInputMode(.english)
        await eventually("English completion capability did not settle") {
            suggestedController.englishSuggestionsSupported == true
        }
        let suggestedPanel = IdlePanelProbe(controller: suggestedController, quickSymbols: qs)
        suggestedController.handle(.code("h"))
        suggestedController.handle(.code("e"))
        await eventually("real English suggestions did not arrive") { !suggestedController.englishSuggestions.isEmpty }
        precondition(suggestedPanel.input.hasEnglishSuggestions && !suggestedPanel.input.allowsToolbar)
        suggestedController.retire()
        print(
            "PASS I4: production root getter maps real snapshot, English suggestions, status, failure, fallback and quick-symbol errors; covers and expansion gate the idle toolbar"
        )
    }

    @MainActor static func browsingAndReadings(_ root: URL) async {
        let qs = await symbols(root, name: "reading-symbols")
        let engine = IdleEngine()
        engine.state = EngineSnapshot(
            candidates: [Candidate(index: 0, text: "page-2")],
            pageSize: 2, isLastPage: false)
        engine.state.isPrediction = true
        engine.state.pageIndex = 2
        engine.failsCandidateRead = true
        let controller = KeyboardController(engine: engine)
        let panel = IdlePanelProbe(controller: controller, quickSymbols: qs)
        precondition(
            controller.candidateBrowser.needsEarlier && panel.input.hasCandidates && !panel.input.allowsToolbar)
        controller.loadMoreCandidates()
        await eventually("candidate retry was not published") { controller.candidateBrowser.hasIncompletePage }
        precondition(
            controller.candidateBrowser.needsEarlier && panel.input.hasCandidates && !panel.input.allowsToolbar)
        controller.retire()

        let readingEngine = IdleEngine()
        let readingController = KeyboardController(engine: readingEngine)
        let readingPanel = IdlePanelProbe(controller: readingController, quickSymbols: qs)
        readingController.updateCompactSpellingLayout(true)
        let readingGate = DispatchSemaphore(value: 0)
        readingEngine.readingGate = readingGate
        readingEngine.state = EngineSnapshot(candidates: [Candidate(index: 0, text: "candidate")], pageSize: 2)
        readingEngine.state.isComposing = true
        readingEngine.state.rawInput = "ni"
        readingEngine.state.preedit = "ni"
        readingController.session.refresh()
        precondition(
            readingController.readingQueryPending && readingPanel.input.hasPendingQueries
                && !readingPanel.input.allowsToolbar)
        await wait(readingEngine.readingEntered)
        precondition(readingController.readingQueryPending && readingPanel.input.hasPendingQueries)
        readingGate.signal()
        await eventually("reading page did not settle") {
            !readingController.readingQueryPending && !readingController.ambiguityQueryPending
        }
        precondition(!readingController.readingFilter.entries.isEmpty)
        readingController.selectReading("ni")
        precondition(
            readingController.readingFilter.isFiltering && readingPanel.input.hasReadingContent
                && !readingPanel.input.allowsToolbar)
        readingController.retire()

        let ambiguityEngine = IdleEngine()
        let ambiguityController = KeyboardController(engine: ambiguityEngine)
        let ambiguityPanel = IdlePanelProbe(controller: ambiguityController, quickSymbols: qs)
        ambiguityController.updateCompactSpellingLayout(true)
        let ambiguityGate = DispatchSemaphore(value: 0)
        ambiguityEngine.ambiguityGate = ambiguityGate
        ambiguityEngine.report = AmbiguitySpellingsReport(
            revisionInput: "z", segment: 0..<1,
            options: ["na", "ni"], allSpellings: ["na", "ni"], lockMode: .tokenAlias, isComplete: true)
        ambiguityEngine.state.isComposing = true
        ambiguityEngine.state.rawInput = "z"
        ambiguityEngine.state.preedit = "z"
        ambiguityController.session.refresh()
        precondition(ambiguityController.ambiguityQueryPending && ambiguityPanel.input.hasPendingQueries)
        await wait(ambiguityEngine.ambiguityEntered)
        precondition(ambiguityController.ambiguityQueryPending && !ambiguityPanel.input.allowsToolbar)
        ambiguityGate.signal()
        await eventually("ambiguity picker did not settle") { !ambiguityController.ambiguityQueryPending }
        precondition(
            ambiguityController.ambiguityPicker.showsPicker && ambiguityPanel.input.hasReadingContent
                && !ambiguityPanel.input.allowsToolbar)
        ambiguityController.retire()
        print(
            "PASS I5: actual controller candidate needs-earlier/retry, blocked reading and ambiguity queries, reading filter and spelling picker all block the idle toolbar"
        )
    }

    @MainActor static func englishBoundaries(_ root: URL) async {
        let qs = await symbols(root, name: "english-symbols")
        let controller = KeyboardController(engine: IdleEngine())
        controller.onDispatchCommit = { _ in true }
        controller.onRequestDeleteBackward = {}
        controller.setInputMode(.english)
        await eventually("unsupported English suggestions did not settle") {
            controller.englishSuggestionsSupported == false
        }
        let panel = IdlePanelProbe(controller: controller, quickSymbols: qs)
        precondition(panel.input.allowsToolbar)
        var published: [Bool] = []
        let subscription = controller.$hasActiveEnglishInput.sink { published.append($0) }
        controller.handle(.code("q"))
        precondition(controller.hasActiveEnglishInput && controller.englishSuggestions.isEmpty)
        precondition(panel.input.hasActiveEnglishInput && !panel.input.allowsToolbar)
        controller.handle(.code("x"))
        controller.handle(.code("z"))
        precondition(published == [false, true])
        controller.handle(.backspace)
        controller.handle(.backspace)
        precondition(published == [false, true] && controller.hasActiveEnglishInput)
        controller.handle(.backspace)
        precondition(published == [false, true, false] && !controller.hasActiveEnglishInput)
        controller.resetEnglishWord()
        precondition(published == [false, true, false] && panel.input.allowsToolbar)
        _ = subscription
        controller.retire()
        print("PASS unfinished English input hides idle tools and publishes only word boundaries")
    }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let suite = "IdleToolbarProbe-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        precondition(KeyboardIdleToolbarPreferences.read(from: preferences))
        preferences.set(false, forKey: KeyboardIdleToolbarPreferences.key)
        precondition(!KeyboardIdleToolbarPreferences.read(from: UserDefaults(suiteName: suite)!))
        preferences.set(true, forKey: KeyboardIdleToolbarPreferences.key)
        precondition(KeyboardIdleToolbarPreferences.read(from: UserDefaults(suiteName: suite)!))
        print("PASS toolbar defaults on and persists explicit disable/enable")
        for height: CGFloat in [160, 201] {
            let panel = NativeHeightProbe(presentedHeight: height)
            precondition(panel.fittedKeyHeight > 0 && panel.fittedKeyHeight < 30)
            precondition(panel.resolved == height, "a real short viewport must not use the taller nominal shell")
        }
        let initial = NativeHeightProbe(presentedHeight: nil)
        precondition(initial.resolved == initial.fixedShellHeight)
        print("PASS native short viewport fits the actual height with tall candidates and readings")
        atomicPolicies()
        await controllerGetter(root)
        await browsingAndReadings(root)
        await englishBoundaries(root)
    }
}
