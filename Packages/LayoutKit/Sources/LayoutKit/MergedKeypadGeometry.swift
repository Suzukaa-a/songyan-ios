import Foundation

/// Key widths of the merged letter pad (14-key, 18-key). One unit is one 26-key letter:
/// a key of weight `w` spans `w` units plus the `w - 1` gaps between them (fractional
/// weights included), so a row's width depends only on its total weight. The upper rows
/// share the widest row's unit and are centred, like the 26-key stagger; the last row sits
/// between the separator and Delete keys and fills that space.
public enum MergedKeypadGeometry {
    public struct Row: Equatable, Sendable {
        /// Space before the first key (centring).
        public let leadingInset: Double
        public let keyWidths: [Double]
    }

    /// The last row of a split pad, laid into the halves of the row above it so the halves' edges
    /// and the gutter line up: the word-split key opens the left half and Delete closes the right
    /// one, each as wide as a letter key (weight 1), and every key of a half shares its width by
    /// weight. `upperWidths` are the row above's key widths, cut at `upperBreak`; `lastWeights` are
    /// the last row's letters, cut at `lastBreak`. Returns the widths of the left half (the
    /// word-split key first) and of the right half (Delete last).
    public static func splitLastRow(
        upperWidths: [Double], upperBreak: Int, lastWeights: [Double], lastBreak: Int, spacing: Double
    ) -> (left: [Double], right: [Double]) {
        func halfWidth(_ widths: ArraySlice<Double>) -> Double {
            widths.reduce(0, +) + Double(max(0, widths.count - 1)) * spacing
        }
        func share(_ width: Double, _ weights: [Double]) -> [Double] {
            let total = weights.reduce(0) { $0 + safe($1) }
            guard total > 0 else { return weights.map { _ in 0 } }
            let unit = max(0, width - Double(weights.count - 1) * spacing) / total
            return weights.map { safe($0) * unit }
        }
        let cut = min(max(0, upperBreak), upperWidths.count)
        let lastCut = min(max(0, lastBreak), lastWeights.count)
        let left = share(halfWidth(upperWidths[..<cut]), [1] + Array(lastWeights[..<lastCut]))
        let right = share(halfWidth(upperWidths[cut...]), Array(lastWeights[lastCut...]) + [1])
        return (left, right)
    }

    /// `width` is the full row width; `sideWidth` is each side key in the last row.
    public static func rows(
        weights: [[Double]], width: Double, spacing: Double,
        sideWidth: Double
    ) -> [Row] {
        guard !weights.isEmpty else { return [] }
        let upper = weights.dropLast()
        let widest = upper.map(units).max() ?? 0
        let unit = widest > 0 ? max(0, (width - (widest - 1) * spacing) / widest) : 0
        var result = upper.map { row in
            let widths = row.map { span(safe($0), unit: unit, spacing: spacing) }
            let used = widths.reduce(0, +) + Double(max(0, row.count - 1)) * spacing
            return Row(leadingInset: max(0, (width - used) / 2), keyWidths: widths)
        }
        let last = weights[weights.count - 1]
        let available = max(0, width - 2 * (sideWidth + spacing))
        let lastUnits = units(last)
        let lastUnit = lastUnits > 0 ? max(0, (available - (lastUnits - 1) * spacing) / lastUnits) : 0
        result.append(
            Row(
                leadingInset: 0,
                keyWidths: last.map { span(safe($0), unit: lastUnit, spacing: spacing) }))
        return result
    }

    /// Total units of a row, gaps of multi-unit keys included.
    static func units(_ row: [Double]) -> Double { row.map(safe).reduce(0, +) }

    private static func span(_ weight: Double, unit: Double, spacing: Double) -> Double {
        weight * unit + max(0, weight - 1) * spacing
    }

    private static func safe(_ weight: Double) -> Double { weight.isFinite && weight > 0 ? weight : 1 }
}
