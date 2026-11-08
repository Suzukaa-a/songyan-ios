import Foundation

/// Projects relative row weights into finite fractions without overflowing their
/// sum. Scaling by the largest weight preserves authored ratios, including rows
/// whose equally weighted keys are all near Double's largest or smallest value.
public struct LayoutRowWidthProjection: Equatable, Sendable {
    public let keyFractions: [Double]
    /// Fraction of the available row width reserved on each horizontal edge.
    public let insetFraction: Double

    public init(weights: [Double], inset: Double = 0) {
        // Imported definitions validate positive finite weights. Keep raw,
        // unvalidated preview values from producing NaN or infinite geometry.
        let safeWeights = weights.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let safeInset = inset.isFinite && inset > 0 ? inset : 0
        let scale = max(safeWeights.max() ?? 0, safeInset)
        guard scale > 0 else {
            keyFractions = Array(repeating: 0, count: weights.count)
            insetFraction = 0
            return
        }
        let scaledWeights = safeWeights.map { $0 / scale }
        let scaledInset = safeInset / scale
        let total = scaledWeights.reduce(0, +) + scaledInset + scaledInset
        keyFractions = scaledWeights.map { $0 / total }
        insetFraction = scaledInset / total
    }
}

extension Array where Element == LayoutKey {
    /// A key row as it draws when the system keyboard switch is not shown. The globe's width goes
    /// to the row's Return key, so the space bar keeps its width and Return does not stay narrow.
    /// A row without a space key just loses the globe.
    public func withoutGlobe() -> [LayoutKey] {
        let freed = filter { $0.action.type == .globe }.reduce(0) { $0 + $1.widthWeight }
        guard freed > 0 else { return self }
        let rest = filter { $0.action.type != .globe }
        guard rest.contains(where: { $0.action.type == .space }) else { return rest }
        return rest.map { $0.action.type == .enter ? $0.settingWidth($0.widthWeight + freed) : $0 }
    }
}
