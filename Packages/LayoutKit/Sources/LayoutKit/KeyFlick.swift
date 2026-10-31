import Foundation

/// The vertical flick of a character key: up types its first long-press option, down its second.
///
/// The nine-key digit flick (up only) uses the same distance and give-back rule, so every flick
/// on the keyboard feels alike. Pure so the rules are testable without a view.
public enum KeyFlick {
    public enum Direction: Equatable, Sendable {
        case up, down

        /// Index into the key's long-press options.
        public var optionIndex: Int { self == .up ? 0 : 1 }
    }

    /// A flick shorter than this (or than 40% of the key) is finger drift in a normal tap.
    public static let distance: Double = 24
    public static let keyShare: Double = 0.4
    /// Coming back this close to the touch-down point undoes the flick.
    public static let returnDistance: Double = 10

    public static func threshold(keyHeight: Double) -> Double {
        max(distance, keyHeight * keyShare)
    }

    /// `rise` is how far the finger is above the touch-down point (negative below it); `dx` the
    /// sideways offset. The flick must be mostly vertical.
    public static func direction(rise: Double, dx: Double, threshold: Double) -> Direction? {
        guard rise.isFinite, dx.isFinite, abs(rise) >= threshold, abs(dx) < abs(rise) else { return nil }
        return rise > 0 ? .up : .down
    }

    /// Whether a released flick still counts, or the finger came back and the press is a tap.
    public static func isGivenBack(rise: Double, direction: Direction) -> Bool {
        (direction == .up ? rise : -rise) < returnDistance
    }

    public enum Release: Equatable, Sendable {
        /// The finger came back: the press is the key's own tap.
        case tap
        /// The flick's option types.
        case option
        /// Past the threshold with nothing to type that way: nothing types, not even the key the
        /// finger ended on.
        case nothing
    }

    /// What lifting the finger does after a flick armed in `direction`.
    public static func release(rise: Double, direction: Direction, hasOption: Bool) -> Release {
        if isGivenBack(rise: rise, direction: direction) { return .tap }
        return hasOption ? .option : .nothing
    }

    /// The option a flick types, nil when the key has no option for that direction.
    public static func option<T>(in options: [T], direction: Direction) -> T? {
        options.indices.contains(direction.optionIndex) ? options[direction.optionIndex] : nil
    }

    /// Whether a key takes part: plain character keys only. Merged keys keep their sideways
    /// swipe, and nine-key digit keys keep their own upward flick.
    public static func isEligible(
        actionType: LayoutAction.Kind, enabled: Bool, merged: Bool, ownsUpwardFlick: Bool
    ) -> Bool {
        enabled && !merged && !ownsUpwardFlick && (actionType == .code || actionType == .literal)
    }
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
