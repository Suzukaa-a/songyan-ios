import Foundation

/// One policy for the small secondary hint drawn on a keycap.
///
/// A hint is always one line, so every key of a row puts its hint, and the letter above it, on
/// the same baselines. A hint that is too wide for its slot shrinks down to `minimumScaleFactor`
/// and is truncated only beyond that. The policy never moves the key frame or the touch target.
public enum KeyHintLayoutPolicy {

    /// A hint never takes more than one line.
    public static let maximumLines = 1
    /// A hint may shrink this far before it is truncated.
    public static let minimumScaleFactor: Double = 0.6
    /// The height of a one-line hint (points); also the band a key reserves for a hint it lacks.
    public static let singleLineHeight: Double = 12

    /// The font scale a hint needs to fit `availableWidth`, clamped to `minimumScaleFactor`.
    /// Returns 1 when it already fits or the input is degenerate.
    public static func fitScale(measuredWidth: Double, availableWidth: Double) -> Double {
        guard measuredWidth.isFinite, availableWidth.isFinite, availableWidth > 0, measuredWidth > availableWidth
        else { return 1 }
        return max(minimumScaleFactor, availableWidth / measuredWidth)
    }

    /// Whether the hint is still wider than its slot at the smallest allowed scale.
    public static func truncates(measuredWidth: Double, availableWidth: Double) -> Bool {
        guard measuredWidth.isFinite, availableWidth.isFinite, availableWidth > 0 else { return false }
        return measuredWidth * minimumScaleFactor > availableWidth
    }

    /// The hint label's height: never smaller than the one-line band, so a key with a tall font
    /// metric and a key with a short one reserve the same room.
    public static func height(lineHeight: Double, minimumHeight: Double = singleLineHeight) -> Double {
        guard lineHeight.isFinite, lineHeight > 0 else { return minimumHeight }
        return max(minimumHeight, lineHeight)
    }

    /// The vertical middle of a letter's line in a key's content area, from the top of the area.
    ///
    /// Every key of a row passes the same inputs, whether it shows a hint or only reserves the band
    /// (`hintHeight` > 0), so the letters share one baseline. The letter rises half of `lift`
    /// when a band is present, and stays clear of the hint on a short key, giving way into the
    /// area's top margin (`topOvershoot`) before anything shrinks.
    public static func titleMidY(
        contentHeight: Double, lineHeight: Double, hintHeight: Double, lift: Double = 4,
        gap: Double = 1, topOvershoot: Double = 2
    ) -> Double {
        guard hintHeight > 0 else { return contentHeight / 2 }
        let preferred = contentHeight / 2 - lift
        let limit = contentHeight - hintHeight - gap
        guard preferred + lineHeight / 2 > limit else { return preferred }
        return max(-topOvershoot, limit - lineHeight) + lineHeight / 2
    }
}

public extension KeyHintLayoutPolicy {
    /// Gap between the per-letter hint columns of a merged key (points).
    static let columnGap: Double = 2

    /// Width of one per-letter hint column when `total` is split into `columns`.
    static func columnWidth(total: Double, columns: Int, gap: Double = columnGap) -> Double {
        guard columns > 0, total.isFinite, total > 0 else { return 0 }
        return max(0, (total - gap * Double(columns - 1)) / Double(columns))
    }
}
