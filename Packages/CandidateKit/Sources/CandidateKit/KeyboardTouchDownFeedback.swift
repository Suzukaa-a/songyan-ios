import SwiftUI

// MARK: - Touch-down feedback for SwiftUI controls
//
// Keys give sound and haptics on touch-down, not on release. SwiftUI controls (candidates, the
// candidate bar's controls, readings, tools buttons) draw their pressed state from
// `ButtonStyleConfiguration.isPressed`, so the same rising edge is the touch-down moment. The panel
// injects the app's feedback action through the environment; a package view without one (previews,
// tests) stays silent.

/// What the panel runs at the moment a SwiftUI control is pressed.
public typealias KeyboardTouchDownAction = @MainActor () -> Void

private struct KeyboardTouchDownFeedbackKey: EnvironmentKey {
    static var defaultValue: KeyboardTouchDownAction? { nil }
}

public extension EnvironmentValues {
    /// Key feedback to run when a SwiftUI control is pressed; nil outside the live keyboard panel.
    var keyboardTouchDownFeedback: KeyboardTouchDownAction? {
        get { self[KeyboardTouchDownFeedbackKey.self] }
        set { self[KeyboardTouchDownFeedbackKey.self] = newValue }
    }
}

public enum KeyboardTouchDownFeedback {
    /// Only the press beginning counts: release and cancel never give feedback of their own.
    public static func shouldFire(wasPressed: Bool, isPressed: Bool) -> Bool {
        isPressed && !wasPressed
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct KeyboardTouchDownFeedbackModifier: ViewModifier {
    @Environment(\.keyboardTouchDownFeedback) private var feedback
    let pressed: Bool

    func body(content: Content) -> some View {
        content.onChange(of: pressed) { wasPressed, isPressed in
            if KeyboardTouchDownFeedback.shouldFire(wasPressed: wasPressed, isPressed: isPressed) {
                feedback?()
            }
        }
    }
}

public extension View {
    /// Runs the panel's key feedback when `isPressed` turns true.
    @ViewBuilder
    func keyboardTouchDownFeedback(isPressed: Bool) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            modifier(KeyboardTouchDownFeedbackModifier(pressed: isPressed))
        } else {
            self
        }
    }
}
