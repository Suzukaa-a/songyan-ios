import CoreGraphics
import SwiftUI

private struct CandidateExpandedGridKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Expanded candidates in a grid of equal columns divided by hairlines. The grid is drawn even
    /// with nothing to show, so an area that stays on screen beside the keys never reads as empty.
    public var candidateExpandedGrid: Bool {
        get { self[CandidateExpandedGridKey.self] }
        set { self[CandidateExpandedGridKey.self] = newValue }
    }
}

/// Grid layout of expanded candidates: equal columns, a candidate spanning as many as its text
/// needs, rows filled in order and padded with empty cells so every row divides the same way.
public enum CandidateExpandedGrid {
    public struct Cell: Equatable, Sendable {
        /// nil is an empty cell.
        public let entry: BrowserCandidate?
        public let span: Int
    }

    /// Columns about two and a half characters wide, never fewer than two.
    public static func columns(availableWidth: CGFloat, fontSize: Double) -> Int {
        guard availableWidth.isFinite, availableWidth > 0 else { return 2 }
        let target = max(52, CGFloat(fontSize.isFinite ? fontSize : 0) * 2.6)
        return max(2, Int(availableWidth / target))
    }

    public static func rows(
        entries: [BrowserCandidate], columns: Int, columnWidth: CGFloat,
        typography: CandidateTypography, cellPaddingX: Double
    ) -> [[Cell]] {
        let columns = max(1, columns)
        var rows: [[Cell]] = []
        var current: [Cell] = []
        var used = 0
        func flush() {
            guard !current.isEmpty else { return }
            current += Array(repeating: Cell(entry: nil, span: 1), count: columns - used)
            rows.append(current)
            current = []
            used = 0
        }
        for entry in entries {
            let width = CandidateExpandedFlow.cellWidth(
                for: entry, typography: typography, cellPaddingX: cellPaddingX)
            let span =
                columnWidth > 0 ? min(columns, max(1, Int((width / columnWidth).rounded(.up)))) : 1
            if used + span > columns { flush() }
            current.append(Cell(entry: entry, span: span))
            used += span
        }
        flush()
        return rows
    }
}
