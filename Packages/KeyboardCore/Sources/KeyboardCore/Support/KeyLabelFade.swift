import Foundation

extension Notification.Name {
    /// Posted when the key labels start fading out or back in; read `KeyLabelFade.shared`.
    public static let keyLabelFadeDidChange = Notification.Name("KeyLabelFadeDidChange")
}

/// Whether every key's labels and corner hints are faded out because the space bar is dragging the
/// caret. One shared value: each key view reads `opacity` and `animationDuration` on the change
/// notification and runs a single opacity animation; the keycaps stay drawn.
@MainActor
public final class KeyLabelFade {
    public static let shared = KeyLabelFade()

    public static let duration: TimeInterval = 0.15

    public private(set) var isFaded = false

    /// The label opacity every key heads for.
    public var opacity: CGFloat { isFaded ? 0 : 1 }

    /// How long the change animates; Reduce Motion jumps.
    public private(set) var animationDuration: TimeInterval = KeyLabelFade.duration

    public init() {}

    /// Enters or leaves the drag state. True only when the state really changed, so the caller's
    /// entry feedback (the haptic tick) fires once per drag, not once per touch event.
    @discardableResult
    public func setDragging(_ dragging: Bool, reduceMotion: Bool, notify: Bool = true) -> Bool {
        guard dragging != isFaded else { return false }
        isFaded = dragging
        animationDuration = reduceMotion ? 0 : Self.duration
        if notify { NotificationCenter.default.post(name: .keyLabelFadeDidChange, object: self) }
        return true
    }
}
