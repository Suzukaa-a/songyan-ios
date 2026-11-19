import Foundation

/// Swipe left on Delete to mark the text before the caret, then lift to delete it. The finger's travel
/// decides how many user-perceived characters are marked; everything here is pure arithmetic so the
/// feel is unit-tested. The host selection is never moved: UITextDocumentProxy cannot set one.
public enum KeyboardDeleteSwipePolicy {
    /// The most text before the caret one swipe can reach; the context is read once, when it begins.
    public static let reachLimit = 256

    /// The setting is on, nothing is being typed and VoiceOver is off.
    public static func isAvailable(
        settingOn: Bool, isComposing: Bool, hasPendingCodes: Bool, voiceOverRunning: Bool
    ) -> Bool {
        settingOn && !isComposing && !hasPendingCodes && !voiceOverRunning
    }

    /// Whether a move of (`dx`, `dy`) from the touch-down point turns the held Delete into a swipe.
    public static func canBegin(dx: Double, dy: Double) -> Bool {
        dx <= -KeyboardCursorDragPolicy.startDistance && abs(dx) > abs(dy)
    }

    /// `count` characters are marked; `anchorX` is where the next step is measured from. It follows the
    /// finger even when the text cannot reach further, so turning back reacts on the next step.
    public struct State: Equatable, Sendable {
        public var count: Int
        public var anchorX: Double

        public init(count: Int, anchorX: Double) {
            self.count = count
            self.anchorX = anchorX
        }
    }

    public static func begin(startX: Double) -> State { State(count: 0, anchorX: startX) }

    /// The state after the finger moved to `x`; `reach` is how many characters the text allows.
    public static func move(
        _ state: State, x: Double, startX: Double, stepWidth: Double = KeyboardCursorDragPolicy.stepWidth,
        reach: Int
    ) -> State {
        // Back within the dead zone, or right of the touch-down point, marks nothing and restarts the count.
        if x >= startX - KeyboardCursorDragPolicy.startDistance { return begin(startX: startX) }
        let steps = Int(((state.anchorX - x) / stepWidth).rounded(.towardZero))
        return State(
            count: min(max(state.count + steps, 0), max(reach, 0)),
            anchorX: state.anchorX - Double(steps) * stepWidth)
    }

    /// The text a read of the document before the caret allows the swipe to reach.
    public static func reachable(_ contextBeforeCaret: String) -> String {
        String(contextBeforeCaret.suffix(reachLimit))
    }

    /// The last `count` characters of `context`: exactly what that many Delete presses remove, because a
    /// `Character` is one extended grapheme cluster (an emoji sequence is never split).
    public static func marked(in context: String, count: Int) -> String {
        String(context.suffix(max(count, 0)))
    }
}
