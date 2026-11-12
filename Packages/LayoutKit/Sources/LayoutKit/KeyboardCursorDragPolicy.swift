import Foundation

public enum KeyboardCursorDragPolicy {
    public enum Ownership: Sendable, CaseIterable {
        case keyboard, sidewaysKey, space, delete, candidateBand, scrollView
    }

    // Letter swipes lock at 18 pt, and kana flicks select at a similarly short distance.
    // Ownership preserves those gestures before dwell or velocity can distinguish intent.
    // Holds and menus must finish their own interaction; a later sideways move cannot reclaim it.
    public struct Attempt {
        private var hasYielded = false

        public init() {}

        public mutating func observe(isIdle: Bool) -> Bool {
            hasYielded = hasYielded || !isIdle
            return !hasYielded
        }
    }
    public static func canBegin(
        settingOn: Bool, isComposing: Bool, hasPendingCodes: Bool, isIdle: Bool,
        ownership: Ownership, dx: Double, dy: Double
    ) -> Bool {
        settingOn && !isComposing && !hasPendingCodes && isIdle && ownership == .keyboard
            && abs(dx) >= 14 && abs(dx) > abs(dy)
    }
}
