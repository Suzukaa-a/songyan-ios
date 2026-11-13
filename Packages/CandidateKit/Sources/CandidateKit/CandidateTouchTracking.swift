import Foundation

/// A tap may drift slightly, including across a cell edge, but never selects after a drag or cancellation.
/// There is no minimum press duration: a down/up pair in the same frame is still a tap.
struct CandidateTouchTracking {
    static let movementTolerance: CGFloat = 10
    private var origin: CGPoint?
    var isPressed: Bool { origin != nil }

    mutating func begin(at point: CGPoint) {
        origin = point
    }

    mutating func move(to point: CGPoint) {
        guard let origin else { return }
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        // Hit testing already chose the cell at touch-down. Measuring against its
        // edges gives an edge tap virtually no tolerance (even 1pt could cancel it).
        // Every tap gets the same travel allowance, independent of where it lands.
        if dx * dx + dy * dy >= Self.movementTolerance * Self.movementTolerance {
            cancel()
        }
    }

    mutating func end(at point: CGPoint) -> Bool {
        move(to: point)
        let selects = isPressed
        cancel()
        return selects
    }

    mutating func cancel() {
        origin = nil
    }
}

#if canImport(UIKit)
    import SwiftUI
    import UIKit

    struct CandidateTouchSurface: UIViewRepresentable {
        let isEnabled: Bool
        let onPressChanged: (Bool) -> Void
        let prepareTap: @MainActor () -> CandidateAreaActionSink.PreparedAction?

        func makeUIView(context: Context) -> CandidateTouchView { CandidateTouchView() }

        func updateUIView(_ view: CandidateTouchView, context: Context) {
            view.onPressChanged = onPressChanged
            view.prepareTap = prepareTap
            view.isUserInteractionEnabled = isEnabled
            if !isEnabled { view.tapRecognizer?.cancelPress(from: view) }
            view.configureRecognizer()
        }

        static func dismantleUIView(_ view: CandidateTouchView, coordinator: ()) {
            // A re-rank can remove this cell while its word remains elsewhere in
            // the menu. The scroll container owns that in-flight press, not the
            // disposable cell. Non-scrolling controls still cancel on removal.
            if view.tapRecognizer?.view === view { view.tapRecognizer?.cancelPress(from: view) }
            view.onPressChanged = nil
            view.prepareTap = nil
        }
    }

    final class CandidateTouchView: UIView {
        var onPressChanged: ((Bool) -> Void)?
        var prepareTap: (@MainActor () -> CandidateAreaActionSink.PreparedAction?)?
        fileprivate weak var tapRecognizer: CandidateTapRecognizer?

        init() {
            super.init(frame: .zero)
            isOpaque = false
            isAccessibilityElement = false
            isMultipleTouchEnabled = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            configureRecognizer()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            configureRecognizer()
        }

        func configureRecognizer() {
            guard window != nil else { return }
            var ancestor = superview
            var container: UIView = self
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    scroll.delaysContentTouches = false
                    scroll.canCancelContentTouches = true
                    container = scroll
                    break
                }
                ancestor = view.superview
            }
            if tapRecognizer?.view === container { return }
            if let previous = tapRecognizer, previous.view === self {
                previous.cancelPress(from: self)
                removeGestureRecognizer(previous)
            }
            if let existing = container.gestureRecognizers?.compactMap({ $0 as? CandidateTapRecognizer }).first {
                tapRecognizer = existing
            } else {
                let recognizer = CandidateTapRecognizer()
                container.addGestureRecognizer(recognizer)
                tapRecognizer = recognizer
            }
        }
    }

    /// One recognizer per candidate scroll container. UIKit keeps delivering the
    /// physical touch to this ancestor even when SwiftUI recycles its original
    /// cell. The prepared command keeps the word/context, never a mutable index.
    private final class CandidateTapRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private var tracking = CandidateTouchTracking()
        private var trackedTouch: UITouch?
        private weak var pressedCell: CandidateTouchView?
        private weak var touchWindow: UIWindow?
        private var pendingTap: CandidateAreaActionSink.PreparedAction?
        private var scrollView: UIScrollView? { view as? UIScrollView }

        init() {
            super.init(target: nil, action: nil)
            delegate = self
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        private func source(for touch: UITouch) -> CandidateTouchView? {
            var ancestor = touch.view
            while let view = ancestor {
                if let cell = view as? CandidateTouchView, cell.tapRecognizer === self { return cell }
                if view === self.view { break }
                ancestor = view.superview
            }
            return nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            source(for: touch)?.isUserInteractionEnabled == true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Native scrolling remains independent. Real finger travel cancels
            // the tap below; a layout/scroll reset is not finger movement.
            otherGestureRecognizer === scrollView?.panGestureRecognizer
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        // Observation must be non-exclusive in BOTH directions. Returning false
        // only from canPrevent lets an ancestor's non-cancelling tap observer
        // recognize first and fail this recognizer on every ordinary release.
        // We decide cancellation from real travel/scrolling, disabled controls,
        // detachment and UIKit's system touch-cancellation events below.
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard trackedTouch == nil, touches.count == 1, let touch = touches.first,
                let cell = source(for: touch), let window = view?.window,
                scrollView?.isDragging != true, scrollView?.isDecelerating != true
            else {
                fail()
                return
            }
            trackedTouch = touch
            pressedCell = cell
            touchWindow = window
            tracking.begin(at: touch.location(in: window))
            // This may synchronously land the final code key and replace cells.
            // Check for re-entrant cancellation before arming/highlighting again.
            guard let action = cell.prepareTap?(), state == .possible,
                trackedTouch === touch, view?.window === window
            else {
                fail()
                return
            }
            pendingTap = action
            cell.onPressChanged?(true)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch = trackedTouch, touches.contains(touch), let window = touchWindow else {
                return
            }
            for sample in event.coalescedTouches(for: touch) ?? [touch] {
                tracking.move(to: sample.location(in: window))
            }
            if !tracking.isPressed || scrollView?.isDragging == true {
                fail()
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch = trackedTouch, touches.contains(touch), let window = touchWindow else {
                return
            }
            let selects =
                tracking.end(at: touch.location(in: window))
                && view?.window === window && scrollView?.isDragging != true
            let action = pendingTap
            clearPress()
            state = selects ? .recognized : .failed
            guard selects else { return }
            // .recognized schedules target delivery; it does not guarantee it.
            // UIKit can reset us without sending that action, even after a valid
            // stationary release. Deliver here after all physical-touch checks.
            // clearPress consumed the command before any re-entrant callbacks;
            // local captures survive a reset caused by the state transition.
            _ = action?()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            fail()
        }

        override func reset() {
            clearPress()
            super.reset()
        }

        func cancelPress(from cell: CandidateTouchView) {
            if pressedCell === cell { fail() }
        }

        private func fail() {
            clearPress()
            if state == .possible { state = .failed }
        }

        private func clearPress() {
            tracking.cancel()
            trackedTouch = nil
            pendingTap = nil
            touchWindow = nil
            let cell = pressedCell
            pressedCell = nil
            cell?.onPressChanged?(false)
        }

    }
#endif
