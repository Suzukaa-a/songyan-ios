import Foundation

/// Character rows share ten columns; controls absorb the remaining third-row width.
public struct StandardKeyRowGeometry: Equatable, Sendable {
    public let gap: Double
    public let keyWidth: Double
    public let thirdRowSideWidth: Double

    public init(width: Double, split: ActiveLayoutSplit? = nil, spacing: Double = 4) {
        let width = max(0, width)
        gap = split?.gap(width: width, keyCount: 10, spacing: spacing) ?? 0
        keyWidth = max(0, (width - gap - spacing * 9) / 10)
        thirdRowSideWidth = max(0, (width - gap - keyWidth * 7 - spacing * 8) / 2)
    }

    /// Skins set their key gaps for a phone's keys; the widest phone column, gap included, is about
    /// 44 pt. A wider column (landscape, an unfolded or tablet screen) grows the visible gap in the
    /// same proportion, so a skin keeps the look its author drew; every phone keeps it exactly.
    public static let skinReferencePitch = 44.0

    /// How much wider this board's columns are than a phone's; never below 1.
    public func keyGapScale(spacing: Double = 4) -> Double {
        max(1, (keyWidth + spacing) / Self.skinReferencePitch)
    }

    /// The cap inset that draws a skin's visible gap (`spacing + 2 × inset`) at `scale`.
    public static func capInset(_ inset: Double, scale: Double, spacing: Double = 4) -> Double {
        max(inset, ((spacing + 2 * inset) * scale - spacing) / 2)
    }
}
