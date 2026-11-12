import Foundation

public enum KeyboardCursorDragPolicy {
    public enum Ownership: Sendable, CaseIterable {
        case keyboard, sidewaysKey, space, delete, candidateBand, scrollView
    }

    // Letter swipes lock at 18 pt, and kana flicks select at a similarly short distance.
    // Ownership preserves those gestures before dwell or velocity can distinguish intent.
    public static func canBegin(
        settingOn: Bool, isComposing: Bool, hasPendingCodes: Bool,
        ownership: Ownership, dx: Double, dy: Double
    ) -> Bool {
        settingOn && !isComposing && !hasPendingCodes && ownership == .keyboard
            && abs(dx) >= 14 && abs(dx) > abs(dy)
    }
}
