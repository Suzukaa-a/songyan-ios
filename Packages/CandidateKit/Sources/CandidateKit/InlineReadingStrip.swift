import Foundation

/// Where the readings and spelling choices of a compact (14-key / 18-key) layout show while composing.
/// The nine-key layout keeps its leading rail and ignores this.
public enum ReadingPlacement: String, CaseIterable, Sendable {
    /// A row of its own above the candidate bar, reserved for as long as the layout is active.
    case row
    /// The leading edge of the candidate bar; the keyboard gets no taller.
    case candidateBar

    /// Unknown or missing stored values resolve to the row.
    public static func resolve(_ storedValue: String?) -> Self {
        storedValue.flatMap(Self.init(rawValue:)) ?? .row
    }
}

/// The stored form of `ReadingPlacement`, shared by the host app and the keyboard extension.
public enum ReadingPlacementStorage {
    public static let key = "keyboard.readingPlacement.v1"

    public static func read(from defaults: UserDefaults) -> ReadingPlacement {
        ReadingPlacement.resolve(defaults.string(forKey: key))
    }

    public static func write(_ placement: ReadingPlacement, to defaults: UserDefaults) {
        defaults.set(placement.rawValue, forKey: key)
    }
}

/// What tapping an inline reading does: the same calls the reading row makes.
public enum InlineReadingAction: Hashable, Sendable {
    case lockSpelling(String)
    case selectReading(String)
}

/// One cell of the inline readings section.
public struct InlineReadingItem: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Tappable.
        case choice
        /// An applied choice: drawn selected, not tappable (Backspace undoes it).
        case selected
    }

    public var label: String
    public var kind: Kind
    public var action: InlineReadingAction?
    public var accessibilityLabel: String
    public var accessibilityHint: String?
    public var inputLabels: [String]
}

extension CandidateReadingRowContent {
    /// The cells the inline section shows for this content, with the labels the reading row uses.
    public var inlineItems: [InlineReadingItem] {
        switch self {
        case .empty:
            return []
        case .options(let options):
            return options.map { option in
                InlineReadingItem(
                    label: option, kind: .choice, action: .lockSpelling(option),
                    accessibilityLabel: "锁定组合 \(option)", accessibilityHint: nil,
                    inputLabels: [option, "锁定组合 \(option)"])
            }
        case .locked(let chosen):
            return [
                InlineReadingItem(
                    label: chosen, kind: .selected, action: nil,
                    accessibilityLabel: "已锁定组合 \(chosen)", accessibilityHint: "按删除键撤销组合",
                    inputLabels: [])
            ]
        case .readings(let selected, let options):
            var items: [InlineReadingItem] = []
            if !selected.isEmpty {
                let joined = selected.joined(separator: " ")
                items.append(
                    InlineReadingItem(
                        label: joined, kind: .selected, action: nil,
                        accessibilityLabel: "已选读音 \(joined)", accessibilityHint: "按删除键取消上一音节",
                        inputLabels: []))
            }
            items += options.map { reading in
                InlineReadingItem(
                    label: reading, kind: .choice, action: .selectReading(reading),
                    accessibilityLabel: "选择读音 \(reading)", accessibilityHint: nil,
                    inputLabels: [reading, "选择读音 \(reading)"])
            }
            return items
        }
    }
}

/// Pure geometry of the inline readings section at the leading edge of the candidate bar, in points.
///
/// The section scrolls on its own, ends in a fixed divider, and the candidates start after it, so
/// however many readings there are the first candidates stay in view. It is as wide as its cells
/// when they fit; otherwise it takes a third of the row, or two cells when those need more, but
/// never more than half, so the candidates always keep at least half of the row.
public enum InlineReadingStrip {
    /// Smallest cell width: a full-height touch target.
    public static let minimumCellWidth: Double = 48
    /// Horizontal padding around a cell's text.
    public static let cellPaddingX: Double = 12
    /// Space before the first cell.
    public static let startInset: Double = 4
    /// Share of the row the section takes before it scrolls.
    public static let rowShare: Double = 1.0 / 3.0
    /// The section never takes more of the row than this, whatever two cells need.
    public static let maximumRowShare: Double = 0.5
    /// Width of the fade at the section's trailing end while more cells lie beyond it.
    public static let fadeWidth: Double = 16

    public static func cellWidth(textWidth: Double) -> Double {
        max(minimumCellWidth, textWidth + cellPaddingX * 2)
    }

    public struct Sections: Equatable, Sendable {
        /// The section occupies `0..<width` of the row; the divider sits at its end.
        public let width: Double
        /// Right edge of the last cell at no scroll.
        public let contentWidth: Double
        public var maxScroll: Double { max(0, contentWidth - width) }
        public var scrolls: Bool { maxScroll > 0.5 }
    }

    /// The section for cells of `cellWidths` in a row `available` wide. No cells, no width.
    public static func sections(cellWidths: [Double], available: Double) -> Sections {
        guard !cellWidths.isEmpty, available > 0 else { return Sections(width: 0, contentWidth: 0) }
        let content = startInset + cellWidths.reduce(0, +)
        let two = startInset + cellWidths.prefix(2).reduce(0, +)
        let cap = min(max(available * rowShare, two), available * maximumRowShare)
        return Sections(width: min(content, cap), contentWidth: content)
    }

    public struct Layout: Equatable, Sendable {
        public let cellWidths: [Double]
        public let sections: Sections
    }

    /// Cell widths from measured text widths, and the section they make in a row `available` wide.
    public static func layout(textWidths: [Double], available: Double) -> Layout {
        let widths = textWidths.map(cellWidth(textWidth:))
        return Layout(cellWidths: widths, sections: sections(cellWidths: widths, available: available))
    }
}
