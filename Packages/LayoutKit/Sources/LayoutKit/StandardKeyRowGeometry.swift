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
    /// 44 pt. A wider column (landscape, an unfolded or tablet screen) widens the gaps, so a wide
    /// board does not read as one slab of keys; every phone keeps the skin's gaps exactly.
    public static let skinReferencePitch = 44.0

    /// How much wider this board's columns are than a phone's; never below 1.
    public func keyGapScale(spacing: Double = 4) -> Double {
        max(1, (keyWidth + spacing) / Self.skinReferencePitch)
    }

    /// The factor on the horizontal gap for a board whose columns are `columnScale` times a
    /// phone's: the gap grows a little faster than the keys, so wide keys stay visibly apart.
    public static func horizontalGapScale(_ columnScale: Double) -> Double {
        1 + 1.5 * max(0, columnScale - 1)
    }

    /// The factor on the gap between rows: rows keep their height on a wide board, so this gap
    /// grows at half the rate the columns do.
    public static func verticalGapScale(_ columnScale: Double) -> Double {
        1 + 0.5 * max(0, columnScale - 1)
    }

    /// The factor on corner radii: rows keep their height, so corners grow at half the rate the
    /// columns do and a wide key does not read as a box.
    public static func cornerScale(_ columnScale: Double) -> Double {
        1 + 0.5 * max(0, columnScale - 1)
    }

    /// The factor on key labels and icons: a quarter of the columns' growth, enough that a wide
    /// key is not an empty slab, while a label still fits its unchanged row height.
    public static func labelScale(_ columnScale: Double) -> Double {
        1 + 0.25 * max(0, columnScale - 1)
    }

    /// The cap inset that draws a skin's visible gap (`spacing + 2 × inset`) at `scale`.
    public static func capInset(_ inset: Double, scale: Double, spacing: Double = 4) -> Double {
        max(inset, ((spacing + 2 * inset) * scale - spacing) / 2)
    }
}
