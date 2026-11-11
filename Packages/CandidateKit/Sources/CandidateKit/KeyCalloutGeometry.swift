import CoreGraphics

/// Where a pressed letter key's callout bubble sits.
///
/// A bubble resting right on the key's top edge puts its lower half under the finger that
/// is pressing the key. The bubble is lifted by up to `maximumLift` key heights; the callout
/// shape keeps it joined to the key with a taller neck. When the keyboard's top edge leaves
/// too little room, the lift goes first, then the bubble gets shorter, and only when even a
/// short bubble does not fit does it overlap the key.
public enum KeyCalloutGeometry {
    public static let maximumLift: CGFloat = 0.45
    public static let minimumBubbleHeight: CGFloat = 36

    /// How far a popup of the key's callout family rises above the key: up to `maximumLift` key
    /// heights, never more than the `spare` room the popup leaves above it.
    public static func lift(keyHeight: CGFloat, spare: CGFloat) -> CGFloat {
        max(0, min((keyHeight * maximumLift).rounded(), spare))
    }

    public static func bubbleFrame(key: CGRect, safe: CGRect) -> CGRect {
        let width = min(max(48, key.width * 1.2), safe.width)
        let wanted = min(max(52, key.height * 1.12), safe.height)
        let room = key.minY - safe.minY
        let lift = lift(keyHeight: key.height, spare: room - wanted)
        let available = room - lift
        let height = available >= minimumBubbleHeight ? min(wanted, available) : wanted
        let x = min(max(key.midX - width / 2, safe.minX), safe.maxX - width)
        let y = max(safe.minY, key.minY - lift - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
