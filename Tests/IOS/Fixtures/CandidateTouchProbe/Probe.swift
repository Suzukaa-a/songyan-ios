import CandidateKit
import Combine
import KeyboardCore
import SwiftUI
import UIKit

final class ProbeFlashSurface: UIView {
    var addedFlash: (() -> Void)?
    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        addedFlash?()
    }
}

struct ProbeFlashOverlay: UIViewRepresentable {
    let view: ProbeFlashSurface
    func makeUIView(context: Context) -> ProbeFlashSurface { view }
    func updateUIView(_ view: ProbeFlashSurface, context: Context) {}
}

@main
struct CandidateProbe: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--keyboard-host") {
                KeyboardHostedProbe()
            } else {
                ProbeView()
            }
        }
    }
}

/// Exercise a real UIKit keyboard container, including a non-cancelling ancestor
/// recognizer. Such a recognizer observes housekeeping taps without owning input.
struct KeyboardHostedProbe: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> KeyboardProbeController { KeyboardProbeController() }
    func updateUIViewController(_ view: KeyboardProbeController, context: Context) {}
}

/// Reproduce a release whose target delivery is suppressed by UIKit arbitration.
/// The candidate receives its complete touch sequence, but must wait for this
/// non-cancelling ancestor, which recognizes on the next main-queue turn.
final class DeferredAncestorRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private var origin: CGPoint?
    private(set) var hasCandidateFailureRequirement = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delegate = self
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let blocks = String(describing: type(of: otherGestureRecognizer)) == "CandidateTapRecognizer"
        if blocks {
            hasCandidateFailureRequirement = true
        }
        return blocks
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        origin = touches.first?.location(in: view?.window)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let origin, let point = touches.first?.location(in: view?.window) else { return }
        if hypot(point.x - origin.x, point.y - origin.y) >= 10 { state = .failed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self, state == .possible else { return }
            state = .recognized
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }

    override func reset() {
        origin = nil
        super.reset()
    }
}

final class KeyboardProbeController: UIViewController {
    let model = ProbeModel()
    let field = UITextField()
    var hosted: UIHostingController<KeyboardProbeContent>?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        field.accessibilityIdentifier = "hostDocument"
        field.borderStyle = .roundedRect
        field.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            field.heightAnchor.constraint(equalToConstant: 44),
        ])
        let input = UIInputView(frame: CGRect(x: 0, y: 0, width: 400, height: 240), inputViewStyle: .keyboard)
        let host = UIHostingController(rootView: KeyboardProbeContent(model: model))
        hosted = host
        addChild(host)
        input.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: input.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: input.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: input.bottomAnchor),
        ])
        host.didMove(toParent: self)
        if ProcessInfo.processInfo.arguments.contains("--passive-ancestor") {
            let observer: UIGestureRecognizer =
                ProcessInfo.processInfo.arguments.contains("--deferred-ancestor")
                ? DeferredAncestorRecognizer(target: self, action: #selector(observedTap))
                : UITapGestureRecognizer(target: self, action: #selector(observedTap))
            observer.cancelsTouchesInView = false
            observer.delaysTouchesBegan = false
            observer.delaysTouchesEnded = false
            input.addGestureRecognizer(observer)
        }
        field.inputView = input
        model.session.onDispatchCommit = { [weak self] text in
            guard let self else { return false }
            field.insertText(text)
            model.commits.append(text)
            return true
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    @objc private func observedTap(_ recognizer: UIGestureRecognizer) {
        model.observerTaps += 1
        model.observerHasFailureRequirement =
            (recognizer as? DeferredAncestorRecognizer)?.hasCandidateFailureRequirement == true
    }
}

struct KeyboardProbeContent: View {
    @ObservedObject var model: ProbeModel
    var body: some View {
        VStack(spacing: 8) {
            Text("commits:\(model.commits.count)").accessibilityIdentifier("commitCount")
            Text("observed:\(model.observerTaps)\(model.observerHasFailureRequirement ? " required" : "")")
                .accessibilityIdentifier("observerCount")
            DefaultCandidateAreaRenderer().collapsedView(context: model.context).frame(height: 48)
            Button("Last code") { model.session.tap(.code("o")) }.accessibilityIdentifier("lastCode")
            Spacer()
        }
    }
}

final class ProbeEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("touch-regression")
    var statusSummary: String { "probe" }
    var count = 50
    var input = "n"
    var swapped = false
    var generation = 0
    var replaceOnCode = false
    var onlyWord: String?
    var refusesSelection = false
    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws {}
    func processKey(_ keyValue: String) throws -> EngineSnapshot {
        input += keyValue
        if replaceOnCode { generation += 1 }
        return currentSnapshot()
    }
    func nextPage() throws -> EngineSnapshot { currentSnapshot() }
    func previousPage() throws -> EngineSnapshot { currentSnapshot() }
    func shutdown() {}
    func currentSnapshot() -> EngineSnapshot {
        EngineSnapshot(
            candidates: (0..<count).map {
                Candidate(
                    index: $0,
                    text: onlyWord
                        ?? "\(generation == 0 ? "word" : "new\(generation)-")\(swapped && $0 < 2 ? 1 - $0 : $0)")
            }, preedit: input, rawInput: input, isComposing: true, pageSize: count, isLastPage: true)
    }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot {
        var result = currentSnapshot()
        if refusesSelection { return result }
        result.committed = result.candidates[index].text
        return result
    }
}

final class ProbeQueue: EngineWorkQueue {
    var work: [@Sendable () -> Void] = []
    func async(_ work: @escaping @Sendable () -> Void) { self.work.append(work) }
    func runAll() { while !work.isEmpty { work.removeFirst()() } }
}

@MainActor
final class ProbeModel: ObservableObject {
    let engine = ProbeEngine()
    let session: InputSession
    let queue = ProbeQueue()
    let flashSurface = ProbeFlashSurface()
    @Published var commits: [String] = []
    @Published var revision = 0
    @Published var expanded = false
    @Published var liveRefresh = false
    @Published var reorderOnPress = false
    @Published var growOnPress = false
    @Published var decodeOnPress = false
    @Published var shrinkOnPress = false
    @Published var flashCount = 0
    @Published var removeOnPress = false
    @Published var disableOnPress = false
    @Published var showCandidates = true
    @Published var disabled = false
    @Published var observerTaps = 0
    @Published var observerHasFailureRequirement = false

    init() {
        session = InputSession(engine: engine, layout: .qwerty26)
        session.onCommitted = { [weak self] in self?.commits.append($0) }
        session.onUpdate = { [weak self] in self?.revision += 1 }
        session.refresh()
        session.codeKeyQueue = queue
        flashSurface.addedFlash = { [weak self] in self?.flashCount += 1 }
    }

    func touched() {
        if removeOnPress {
            removeOnPress = false
            DispatchQueue.main.async { [self] in showCandidates = false }
        }
        if disableOnPress {
            disableOnPress = false
            DispatchQueue.main.async { [self] in disabled = true }
        }
        if shrinkOnPress {
            shrinkOnPress = false
            DispatchQueue.main.async { [self] in
                engine.count = 1
                engine.onlyWord = "word2"
                session.refresh()
            }
        }
        if decodeOnPress {
            decodeOnPress = false
            queue.runAll()
        }
        if reorderOnPress {
            reorderOnPress = false
            DispatchQueue.main.async { [self] in
                engine.swapped.toggle()
                session.refresh()
            }
        }
        if growOnPress {
            growOnPress = false
            DispatchQueue.main.async { [self] in
                engine.count = 50
                session.refresh()
            }
        }
    }

    var context: CandidateAreaContext {
        let snapshot = session.snapshot
        let revision = session.compositionRevision
        let state = CandidatePresentationState(snapshot: snapshot, isEnglishMode: false, revision: revision)
        var browser = CandidateBrowser()
        browser.reset(state)
        var bar = CandidateBarDefinition.systemDefault
        bar.collapsed.fillsAvailableWidth = true
        return CandidateAreaContext(
            state: state, bar: bar,
            actions: CandidateAreaActionSink(prepare: { [self] action in
                MainActor.assumeIsolated {
                    switch action {
                    case .select(let index), .selectOnPage(_, let index):
                        guard let prepared = session.prepareCandidateSelection(index) else { return nil }
                        return { MainActor.assumeIsolated { self.session.selectCandidate(prepared) } }
                    default:
                        return nil
                    }
                }
            }) { [self] action in
                switch action {
                case .select(let index), .selectOnPage(_, let index):
                    MainActor.assumeIsolated {
                        guard session.compositionRevision == revision else { return }
                        session.selectCandidate(index)
                    }
                case .expand: expanded = true
                case .collapse: expanded = false
                default: break
                }
            }, typography: .init(candidateSize: 20, secondarySize: 11), browser: browser, isExpanded: expanded)
    }
}

struct ProbeView: View {
    @StateObject private var model = ProbeModel()
    private let pulse = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 8) {
            Text("commits:\(model.commits.count)").accessibilityIdentifier("commitCount")
            Text("pending:\(model.session.pendingCodes.count)").accessibilityIdentifier("pendingCount")
            Text("last:\(model.commits.last ?? "")").accessibilityIdentifier("lastCommit")
            Text("flashes:\(model.flashCount)").accessibilityIdentifier("flashCount")
            HStack {
                Button("Reject engine") { model.engine.refusesSelection = true }.accessibilityIdentifier("rejectEngine")
                Button("Reject host") {
                    model.engine.refusesSelection = false
                    model.session.onDispatchCommit = { _ in false }
                }.accessibilityIdentifier("rejectHost")
                Button("Accept") { model.session.onDispatchCommit = nil }.accessibilityIdentifier("accept")
            }
            Button("Replace before touch") {
                model.engine.replaceOnCode = true
                model.session.tap(.code("o"))
                model.queue.runAll()
            }.accessibilityIdentifier("replaceBeforeTouch")
            Button("Replace during touch") {
                model.engine.replaceOnCode = true
                model.decodeOnPress = true
                model.session.tap(.code("o"))
            }.accessibilityIdentifier("replaceDuringTouch")
            Button("Refresh") {
                model.engine.input += "n"
                model.session.refresh()
            }.accessibilityIdentifier("refresh")
            Button("Fit") {
                model.engine.count = model.engine.count == 50 ? 3 : 50
                model.session.refresh()
            }.accessibilityIdentifier("fit")
            Button("Live refresh") { model.liveRefresh.toggle() }.accessibilityIdentifier("liveRefresh")
            Button("Reorder on press") { model.reorderOnPress = true }.accessibilityIdentifier("reorderOnPress")
            Button("Decode on press") {
                model.decodeOnPress = true
                model.session.tap(.code("i"))
            }.accessibilityIdentifier("decodeOnPress")
            Button("Pending decode") { model.session.tap(.code("i")) }.accessibilityIdentifier("pendingDecode")
            Button("Grow on press") { model.growOnPress = true }.accessibilityIdentifier("growOnPress")
            Button("Shrink on press") { model.shrinkOnPress = true }.accessibilityIdentifier("shrinkOnPress")
            HStack {
                Button("Remove on press") { model.removeOnPress = true }.accessibilityIdentifier("removeOnPress")
                Button("Disable on press") { model.disableOnPress = true }.accessibilityIdentifier("disableOnPress")
                Button("Expand") { model.expanded.toggle() }.accessibilityIdentifier("expand")
            }
            if model.showCandidates {
                DefaultCandidateAreaRenderer().collapsedView(context: model.context).frame(height: 48)
                    .disabled(model.disabled)
                    .environment(\.keyboardTouchDownFeedback, { model.touched() })
            }
            if model.expanded {
                DefaultCandidateAreaRenderer().expandedView(context: model.context).frame(height: 220)
                    .environment(\.keyboardTouchDownFeedback, { model.touched() })
            }
            Spacer()
        }
        .padding(.top, 30)
        .overlay(ProbeFlashOverlay(view: model.flashSurface).allowsHitTesting(false))
        .environment(\.keyboardFlashSurface, model.flashSurface)
        .onReceive(pulse) { _ in if model.liveRefresh { model.session.refresh() } }
    }
}
