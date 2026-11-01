import Foundation

/// Widths of the split letter rows drawn from an explicit arrangement. One key unit and one gutter
/// are solved for the whole page, on the widest cut row, so every row keeps the same key size and
/// the outer edges line up; shorter rows leave their extra room in the gutter.
public struct SplitHalvesGeometry: Equatable, Sendable {
    /// The gutter between the halves; zero when the surface is too narrow to open one.
    public let gap: Double
    /// The width of a key of weight 1.
    public let unit: Double
    public let spacing: Double

    public init(width: Double, rows: [LayoutSplitRow], split: ActiveLayoutSplit, spacing: Double = 4) {
        let width = max(0, width)
        self.spacing = spacing
        let widest = rows.map { $0.left.count + $0.right.count }.max() ?? 1
        let gap = split.gap(width: width, keyCount: widest, spacing: spacing)
        self.gap = gap
        var unit = Double.infinity
        for row in rows {
            let count = row.left.count + row.right.count
            let weight = row.keys.reduce(0) { $0 + $1.widthWeight }
            guard count > 0, weight > 0 else { continue }
            let cut = gap > 0 && !row.left.isEmpty && !row.right.isEmpty
            // A cut row spends its gutter in place of one key spacing.
            let fixed = cut ? gap + spacing * Double(count - 2) : spacing * Double(count - 1)
            unit = min(unit, max(0, width - fixed) / weight)
        }
        self.unit = unit.isFinite ? unit : 0
    }

    public func width(of key: LayoutKey) -> Double { unit * key.widthWeight }
}
