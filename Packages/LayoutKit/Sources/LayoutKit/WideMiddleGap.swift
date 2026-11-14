import Foundation

/// The gap between the two parts of a wide keyboard: the halves of an automatically split
/// keyboard, or the 9-key keyboard and its candidates. Its share of the width grows with the width
/// (`percent` at `referenceWidth`, half that at half the width), so a narrow tablet in portrait
/// keeps more of its width for keys than a wide one in landscape, and a forced split on a small
/// screen still has a gutter.
public enum WideMiddleGap {
    /// The user's choice: the gap in percent of a 1000 pt wide keyboard.
    public static let percentRange = 0...20
    public static let percentStep = 1
    public static let defaultPercent = 10
    /// The keyboard width the percentage is quoted at.
    public static let referenceWidth = 1000.0

    public static func clampedPercent(_ value: Int) -> Int {
        min(max(value, percentRange.lowerBound), percentRange.upperBound)
    }

    /// The gap on a `width` wide keyboard: `percent` of the width, scaled by the width over
    /// `referenceWidth`.
    public static func width(for width: Double, percent: Int) -> Double {
        guard width.isFinite, width > 0 else { return 0 }
        return width * Double(clampedPercent(percent)) / 100 * (width / referenceWidth)
    }

    private static let stored = Locked(defaultPercent)

    /// The choice in effect, set by the keyboard each time it reads the user's width settings.
    /// A device setting rather than layout content, so it is not threaded through every split.
    public static var percent: Int {
        get { stored.value }
        set { stored.value = clampedPercent(newValue) }
    }

    private final class Locked: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Int
        init(_ value: Int) { current = value }
        var value: Int {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
    }
}
