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

    /// Keep the established column centres while leaving one sixth of each pitch between caps.
    /// Narrow/split keyboards never grow a cap beyond its column or shrink it just to add a gap.
    public static func keyCapWidth(columnWidth: Double, spacing: Double = 4) -> Double {
        let width = columnWidth.isFinite ? max(0, columnWidth) : 0
        return min(width, (width + max(0, spacing)) * 5 / 6)
    }

    /// Leave breathing room above and below portrait keys without changing the keyboard's height.
    /// Compact keys at 40pt or below retain all their height for the letter and its hint.
    public static func keyCapHeight(rowHeight: Double) -> Double {
        let height = rowHeight.isFinite ? max(0, rowHeight) : 0
        return height - min(6, max(0, height - 40))
    }
}
