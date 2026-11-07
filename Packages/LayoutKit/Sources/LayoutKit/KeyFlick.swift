import Foundation

/// The vertical flick of a character key: one configured direction types the long-press option
/// whose label is the key's drawn corner hint, so a key only ever types what it shows.
///
/// The nine-key digit flick follows the same direction setting, distance and give-back rule, so
/// every flick on the keyboard feels alike. Pure so the rules are testable without a view.
public enum KeyFlick {
    public enum Direction: Equatable, Sendable {
        case up, down
    }

    /// The user's choice: no flick, or the one direction that types the corner hint.
    public enum Setting: String, CaseIterable, Sendable {
        case off, up, down

        public static let storageKey = "keyboard.keyFlickDirection.v1"
        /// The earlier on/off switch; only a stored `false` still means something.
        public static let legacyEnabledKey = "keyboard.keyFlickEnabled.v1"

        public var direction: Direction? {
            switch self {
            case .off: nil
            case .up: .up
            case .down: .down
            }
        }

        /// Unknown strings mean up. Without a stored value, a user who had switched the old
        /// toggle off stays off.
        public static func resolve(stored: Any?, legacyEnabled: Any?) -> Setting {
            guard let stored else {
                return (legacyEnabled as? Bool) == false ? .off : .up
            }
            return (stored as? String).flatMap(Setting.init(rawValue:)) ?? .up
        }
    }

    /// A flick shorter than this (or than 40% of the key) is finger drift in a normal tap.
    public static let distance: Double = 24
    public static let keyShare: Double = 0.4
    /// Coming back this close to the touch-down point undoes the flick.
    public static let returnDistance: Double = 10
    /// Finger travel that is still a tap's roll; progress starts after it.
    public static let touchSlop: Double = 8

    public static func threshold(keyHeight: Double) -> Double {
        max(distance, keyHeight * keyShare)
    }

    /// `rise` is how far the finger is above the touch-down point (negative below it); `dx` the
    /// sideways offset. The flick must be mostly vertical.
    public static func direction(rise: Double, dx: Double, threshold: Double) -> Direction? {
        guard rise.isFinite, dx.isFinite, abs(rise) >= threshold, abs(dx) < abs(rise) else { return nil }
        return rise > 0 ? .up : .down
    }

    /// Travel along `direction`, positive when the finger went that way.
    public static func travel(rise: Double, direction: Direction) -> Double {
        direction == .up ? rise : -rise
    }

    /// Whether a released flick still counts, or the finger came back and the press is a tap.
    public static func isGivenBack(rise: Double, direction: Direction) -> Bool {
        travel(rise: rise, direction: direction) < returnDistance
    }

    public enum Release: Equatable, Sendable {
        /// The finger came back: the press is the key's own tap.
        case tap
        /// The flick's target types.
        case option
        /// Nothing types, not even the key the finger ended on.
        case nothing
    }

    /// What lifting the finger does after a vertical drag past the threshold in `direction`.
    /// Coming back near the key makes it a tap; otherwise only the configured direction types,
    /// wherever the finger lifts, and the other one voids the press.
    public static func release(
        rise: Double, direction: Direction, configured: Direction, hasTarget: Bool
    ) -> Release {
        if isGivenBack(rise: rise, direction: direction) { return .tap }
        guard direction == configured else { return .nothing }
        return hasTarget ? .option : .nothing
    }

    /// The index of the long-press option a flick types: the one labelled like the key's drawn
    /// corner hint. Nil when there is no hint or no option shows it.
    public static func targetIndex(optionLabels: [String], hint: String?) -> Int? {
        guard let hint, !hint.isEmpty else { return nil }
        return optionLabels.firstIndex(of: hint)
    }

    /// What a flick types: a nine-key digit key's own digit, otherwise the option showing the hint.
    public static func target<T>(options: [T], label: (T) -> String, hint: String?, digit: T?) -> T? {
        if let digit { return digit }
        return targetIndex(optionLabels: options.map(label), hint: hint).map { options[$0] }
    }

    /// Whether a key takes part: plain character keys only, and only when a direction is set.
    /// Merged keys flick as well as swiping sideways; the nine-key digits flick their digit.
    public static func isEligible(actionType: LayoutAction.Kind, setting: Setting) -> Bool {
        setting != .off && (actionType == .code || actionType == .literal)
    }

    /// How far a flick has progressed, 0...1, along the configured direction; 1 while armed.
    public static func progress(travel: Double, threshold: Double, armed: Bool) -> Double {
        if armed { return 1 }
        return fraction(travel - touchSlop, over: threshold - touchSlop)
    }

    /// Progress of a sideways swipe on a merged key: before the swipe locks and while the move is
    /// mostly sideways it follows `|dx|`; 1 once a letter is picked; 0 for a vertical drag.
    public static func sidewaysProgress(dx: Double, dy: Double, lockDistance: Double, picked: Bool) -> Double {
        if picked { return 1 }
        guard dx.isFinite, dy.isFinite, abs(dx) > abs(dy) else { return 0 }
        return fraction(abs(dx) - touchSlop, over: lockDistance - touchSlop)
    }

    private static func fraction(_ value: Double, over span: Double) -> Double {
        guard value.isFinite, span > 0 else { return value > 0 ? 1 : 0 }
        return min(1, max(0, value / span))
    }
}

/// The drawn progress of a flick transition: eases toward the target over 90 ms (ease-out
/// quadratic), restarting from what is drawn whenever the target changes. Time is passed in so
/// the rule is testable without a display link.
public struct EasedProgress: Equatable, Sendable {
    public static let duration: Double = 0.09

    private var from = 0.0
    private var target = 0.0
    private var startedAt = 0.0
    private var reduceMotion = false

    public init() {}

    public var targetValue: Double { target }

    public func value(at time: Double) -> Double {
        if isSettled(at: time) { return target }
        let t = max(0, (time - startedAt) / Self.duration)
        let eased = 1 - (1 - t) * (1 - t)
        return from + (target - from) * eased
    }

    public func isSettled(at time: Double) -> Bool {
        reduceMotion || time >= startedAt + Self.duration
    }

    /// Returns whether the target changed.
    @discardableResult
    public mutating func setTarget(_ next: Double, at time: Double, reduceMotion: Bool) -> Bool {
        guard next != target else { return false }
        from = value(at: time)
        target = next
        startedAt = time
        self.reduceMotion = reduceMotion
        return true
    }

    public mutating func reset() { self = EasedProgress() }
}

/// The global long-press delay: nil follows each layout's own value, otherwise a fixed one.
public enum LongPressDelaySetting {
    public static let minimumMilliseconds = 150
    public static let maximumMilliseconds = 1000
    /// Choices offered in settings, in milliseconds.
    public static let choices = [150, 200, 250, 300, 350, 400, 500, 600, 800, 1000]

    /// A stored value out of range (or not a number) means "follow the layout".
    public static func resolve(_ stored: Any?) -> Int? {
        guard let value = (stored as? NSNumber)?.intValue,
            (minimumMilliseconds...maximumMilliseconds).contains(value)
        else { return nil }
        return value
    }

    public static func effectiveDelay(layout: Double?, override: Int?) -> TimeInterval {
        if let override { return TimeInterval(override) / 1000 }
        return layout ?? 0.35
    }
}
