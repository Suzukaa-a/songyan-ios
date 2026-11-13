import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

// MARK: - Main key row (letters / numbers / symbols, full width)

private struct KeyboardKeyHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 50 }
private struct KeyboardPopupSurfaceKey: EnvironmentKey { static let defaultValue: UIView? = nil }

/// The live gate is checked at touch-down and takeover so pending input keeps its keys.
struct KeyboardCursorSwipe {
    let isActive: () -> Bool
    let isIdle: () -> Bool
    let move: (Int) -> Void
}

private struct KeyboardCursorSwipeKey: EnvironmentKey { static var defaultValue: KeyboardCursorSwipe? { nil } }
extension EnvironmentValues {
    var keyboardCursorSwipe: KeyboardCursorSwipe? {
        get { self[KeyboardCursorSwipeKey.self] }
        set { self[KeyboardCursorSwipeKey.self] = newValue }
    }
    var keyboardKeyHeight: CGFloat {
        get { self[KeyboardKeyHeightKey.self] }
        set { self[KeyboardKeyHeightKey.self] = newValue }
    }
    var keyboardPopupSurface: UIView? {
        get { self[KeyboardPopupSurfaceKey.self] }
        set { self[KeyboardPopupSurfaceKey.self] = newValue }
    }
}

/// The same clipped, panel-local overlay is used in both the app and the extension.
struct KeyboardPopupSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView {
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Value snapshot of the key-area render inputs (see `KeyboardPanelView.keyAreaRenderToken`).
struct KeyAreaRenderToken: Equatable {
    let phoneMetrics: PhoneKeypadMetrics?
    let controller: ObjectIdentifier
    let hostBindingTick: Int
    let keyAreaGeneration: Int
    let page: KeyboardPage
    let keyHeight: CGFloat
    let appearance: KeyboardAppearance
    let preferredLayoutID: String?
    let definitionInputsRevision: UInt64
    let shuangpinHintEnabled: Bool
    let shuangpinHintPresetID: String?
    let shuangpinHintLabels: [String: String]
    let shuangpinHintRevision: UInt64
    let activeDefinition: LayoutDefinition?
    let pageDefinition: KeyboardPageDefinition?
    let split: ActiveLayoutSplit?
    let layout: KeyboardLayoutKind
    let selectedSchemaID: String
    let inputMode: InputMode
    let isEnglishMode: Bool
    let shiftState: ShiftState
    let isComposing: Bool
    let usesASCIIPunctuation: Bool
    /// Automatic captions follow the scheme's language; a scheme switch must redraw the rows.
    let inputLanguage: InputLanguageProfile
    /// Panel-local symbol language after override/page-default/controller resolution; the language
    /// key, symbol pages and paired literal faces redraw from it.
    let symbolMarks: KeyboardNumericMarks
    let returnKeyTitle: String
    let isReturnKeyEnabled: Bool
    let schemaAlphabet: String
    let publishedKeyboards: [UserKeyboard]
    /// The keyboard menu also lists the other packages' keyboards, which change on their own.
    let otherPackageKeyboards: [OtherPackageKeyboard]
    /// URL and email fields change the marks beside the space bar.
    let hostFieldMarks: KeyboardControlPolicy.FieldMarks
    let quickSymbols: String
    let layoutHintName: String?
    let layoutHintToken: UUID?
    let hasKeyAlternates: Bool
    let hasSystemKeyboardSwitch: Bool
    let allowsCursorMovement: Bool
    /// The letter page's utility key types punctuation or opens symbols depending on the paired
    /// 123 page, which can change without any other token input.
    let numericPageReachesSymbols: Bool
    /// Authored symbol-lock keys redraw their selected state; the token is what lets the gate see it.
    let symbolPageLocked: Bool
    /// The row symbol page's switch turns between its extra everyday-marks page and the usual rows.
    let showsEverydayMarksPage: Bool
    /// The open category of a categorized authored page (its rail and grid render inside the gate).
    let symbolCategoryID: String
    /// An authored page swaps its main area for the expanded candidate list inside the gate.
    let showsExpandedCandidates: Bool
}

/// `.equatable()` gate: while the token is unchanged SwiftUI skips recomputing `content`, and subviews'
/// environment dependencies (appearance, disabled state) still update as usual.
struct KeyAreaRenderGate<Content: View>: View, Equatable {
    let token: KeyAreaRenderToken
    @ViewBuilder let content: () -> Content

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.token == rhs.token }

    var body: some View { content() }
}

/// A native inert control keeps gap routing from turning the split into a key.
struct KeyboardSplitGap: UIViewRepresentable {
    func makeUIView(context: Context) -> UIControl {
        let view = UIControl()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.001)
        view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ uiView: UIControl, context: Context) {}
}

struct WeightedKeyRow: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let caps: [KeyCap]
    var edgeUnits: CGFloat = 0
    var alternates: (KeyCap) -> [KeyCap] = { _ in [] }
    var isEnabled: (KeyCap) -> Bool = { _ in true }
    var showsKeyPreview = false
    var visualRole: String? = nil
    var split: ActiveLayoutSplit? = nil
    var rowIndex = 0
    var fixedKeyWidth: CGFloat? = nil
    var splitGap: CGFloat? = nil
    let onTap: (KeyCap) -> Void

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 4
            let gap = splitGap ?? CGFloat(split?.gap(width: Double(geometry.size.width), keyCount: caps.count) ?? 0)
            let boundary = split?.breakIndex(row: rowIndex, keyCount: caps.count)
            let available = max(geometry.size.width - spacing * CGFloat(max(caps.count - 1, 0)) - gap, 0)
            let total = max(caps.reduce(CGFloat.zero) { $0 + CGFloat($1.width) } + edgeUnits * 2, 1)
            HStack(spacing: spacing) {
                ForEach(Array(caps.enumerated()), id: \.element.id) { index, cap in
                    if index == boundary, gap > 0 {
                        KeyboardSplitGap().frame(width: gap - spacing, height: keyHeight)
                    }
                    AlternateCharacterKey(
                        cap: cap, alternates: alternates(cap),
                        showsKeyPreview: showsKeyPreview,
                        visualRole: visualRole, onSelect: onTap
                    )
                    .disabled(!isEnabled(cap))
                    .opacity(isEnabled(cap) ? 1 : 0.45)
                    .keyboardRowKeyFrame(
                        width: fixedKeyWidth ?? (available * CGFloat(cap.width) / total), height: keyHeight,
                        standard: fixedKeyWidth != nil)
                }
            }
            .padding(
                .horizontal,
                fixedKeyWidth.map { max(0, (available - $0 * CGFloat(caps.count)) / 2) }
                    ?? (available * edgeUnits / total))
        }
        .frame(height: keyHeight)
    }
}

/// A background anchor keeps the candidate band outside the recognizer's input region.
struct KeyboardCursorDragSurface: UIViewRepresentable {
    @Environment(\.keyboardCursorSwipe) private var cursorSwipe
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> KeyboardCursorDragAnchor { KeyboardCursorDragAnchor() }
    func updateUIView(_ view: KeyboardCursorDragAnchor, context: Context) {
        view.cursorSwipe = isEnabled ? cursorSwipe : nil
    }
    static func dismantleUIView(_ view: KeyboardCursorDragAnchor, coordinator: ()) { view.detach() }
}

/// SwiftUI flick keys have no UIControl ancestor, so their backgrounds declare ownership.
struct KeyboardSidewaysGestureOwner: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardSidewaysOwnerView { KeyboardSidewaysOwnerView() }
    func updateUIView(_ view: KeyboardSidewaysOwnerView, context: Context) {}
}

final class KeyboardSidewaysOwnerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension Notification.Name {
    static let keyboardKeyInteractionDidEngage = Notification.Name("keyboardKeyInteractionDidEngage")
}

final class KeyboardCursorDragAnchor: UIView, UIGestureRecognizerDelegate {
    var cursorSwipe: KeyboardCursorSwipe? {
        didSet { if !isIdle { drag.yieldToInteraction() } }
    }
    private var steppedX: CGFloat = 0
    private var dragging = false
    private lazy var drag = KeyboardCursorDragRecognizer(target: self, action: #selector(trackDrag))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        drag.delegate = self
        drag.cancelsTouchesInView = true
        drag.delaysTouchesBegan = false
        drag.delaysTouchesEnded = false
        drag.isIdle = { [weak self] in self?.isIdle == true }
        drag.canStart = { [weak self] delta in
            KeyboardCursorDragPolicy.canBegin(
                settingOn: self?.cursorSwipe?.isActive() == true,
                isComposing: false, hasPendingCodes: false, isIdle: self?.isIdle == true,
                ownership: .keyboard, dx: Double(delta.x), dy: Double(delta.y))
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyInteractionDidEngage), name: .keyboardKeyInteractionDidEngage, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        guard window != nil else { return }
        // The recognizer must be an ancestor of represented keys to receive their touches.
        // The extension has a routing input view; embedded keyboards use their hosting root.
        var root: UIView = self
        while let parent = root.superview, !(parent is UIWindow), !(root is FeedbackInputView) { root = parent }
        root.addGestureRecognizer(drag)
    }

    func detach() {
        drag.view?.removeGestureRecognizer(drag)
        finishDragging()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard isIdle, bounds.contains(touch.location(in: self)) else { return false }
        // FeedbackInputView routes gaps to nearby keys. Delete already acts on touch-down,
        // before a 14 pt drag can begin, so a touch that deletes must never also move the caret.
        // Gaps routed to dual-letter, kana, Space or Delete owners keep their gesture; gaps
        // routed to ordinary keys can drag the caret. Ownership follows the routed hit.
        var ancestor = touch.view
        while let view = ancestor {
            if view is UIScrollView { return false }
            if view is CursorSpaceKey.SpaceButton || view is RepeatingDeleteKey.DeleteButton { return false }
            if let key = view as? AlternateCharacterKey.CharacterButton {
                guard !key.ownsSidewaysGesture else { return false }
            }
            if view === drag.view { break }
            ancestor = view.superview
        }
        return !ownsSidewaysGesture(in: drag.view, touch: touch)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // The first touch may be a tap preview, but an engaged hold or menu owns every later move.
    // Live checks and hold notifications prevent a caret drag from reclaiming that interaction.
    private var isIdle: Bool {
        guard cursorSwipe?.isActive() == true, cursorSwipe?.isIdle() == true,
            interactionsAreIdle(in: drag.view)
        else { return false }
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController, controller.presentedViewController != nil { return false }
            responder = current.next
        }
        return true
    }

    private func interactionsAreIdle(in view: UIView?) -> Bool {
        guard let view, !view.isHidden, view.alpha > 0 else { return true }
        if let key = view as? AlternateCharacterKey.CharacterButton, key.didHold || key.popup != nil { return false }
        if let key = view as? CursorSpaceKey.SpaceButton, key.isTracking { return false }
        if let key = view as? RepeatingDeleteKey.DeleteButton, key.isTracking { return false }
        if view.gestureRecognizers?.contains(where: {
            $0 !== drag && ($0.state == .began || $0.state == .changed)
        }) == true {
            return false
        }
        return view.subviews.allSatisfy { interactionsAreIdle(in: $0) }
    }

    @objc private func keyInteractionDidEngage(_ notification: Notification) {
        guard let key = notification.object as? UIView, let root = drag.view, key.isDescendant(of: root) else { return }
        drag.yieldToInteraction()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { isIdle }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Caret dragging is the last taker; a competing recognizer must get its decision first.
        true
    }

    private func ownsSidewaysGesture(in view: UIView?, touch: UITouch) -> Bool {
        guard let view, !view.isHidden, view.alpha > 0 else { return false }
        if view is KeyboardSidewaysOwnerView, view.bounds.contains(touch.location(in: view)) { return true }
        return view.subviews.contains { ownsSidewaysGesture(in: $0, touch: touch) }
    }

    @objc private func trackDrag() {
        switch drag.state {
        case .began:
            steppedX = 0
            dragging = true
            if KeyLabelFade.shared.setDragging(true, reduceMotion: UIAccessibility.isReduceMotionEnabled) {
                KeyboardFeedbackService.shared.caretModeEntered()
            }
            step()
        case .changed:
            step()
        case .ended, .cancelled, .failed:
            finishDragging()
        default: break
        }
    }

    private func step() {
        let offset = Int((drag.translation.x - steppedX) / 12)
        guard offset != 0 else { return }
        steppedX += CGFloat(offset) * 12
        cursorSwipe?.move(offset)
    }

    private func finishDragging() {
        guard dragging else { return }
        dragging = false
        KeyLabelFade.shared.setDragging(false, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }
}

final class KeyboardCursorDragRecognizer: UIGestureRecognizer {
    var canStart: ((CGPoint) -> Bool)?
    var isIdle: (() -> Bool)?
    private var attempt = KeyboardCursorDragPolicy.Attempt()
    private var trackingTouch = false

    func yieldToInteraction() {
        guard trackingTouch, state == .possible else { return }
        _ = attempt.observe(isIdle: false)
        state = .failed
    }
    private var origin: CGPoint = .zero
    private(set) var translation: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, numberOfTouches == 1, let touch = touches.first else {
            state = state == .possible ? .failed : .cancelled
            return
        }
        trackingTouch = true
        origin = touch.location(in: view)
        if !attempt.observe(isIdle: isIdle?() == true) { state = .failed }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: view)
        translation = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if state == .possible {
            guard attempt.observe(isIdle: isIdle?() == true) else {
                state = .failed
                return
            }
            if canStart?(translation) == true { state = .began }
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() {
        super.reset()
        attempt = KeyboardCursorDragPolicy.Attempt()
        trackingTouch = false
        translation = .zero
    }
}
