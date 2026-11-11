import CoreGraphics

/// Fingers land a little below the point they aim at, and more so on the lower rows, where the
/// thumb reaches down and flattens. A press is read that much higher before the key under it is
/// picked, after AOSP LatinIME's touch position correction (about 0, 0.04 and 0.09 of a key height
/// on its three letter rows): growing from nothing at the top of the key area to `maximum` of the
/// touched row's height at the bottom. The same rule as Songyan for Android.
public enum KeyTouchCorrection {
    public static let maximum: CGFloat = 0.09

    /// How far above `y` the press is read, for a touch on a row `rowHeight` tall inside a key
    /// area spanning `areaTop`...`areaBottom`.
    public static func lift(y: CGFloat, rowHeight: CGFloat, areaTop: CGFloat, areaBottom: CGFloat) -> CGFloat {
        let height = areaBottom - areaTop
        guard height > 0, rowHeight > 0 else { return 0 }
        let reach = min(max((y - areaTop) / height, 0), 1)
        return maximum * rowHeight * reach
    }

    /// Only a press within this distance below a key's top edge can be read as the row above;
    /// lower presses never need the key area measured.
    public static func band(rowHeight: CGFloat) -> CGFloat { maximum * max(rowHeight, 0) }
}
