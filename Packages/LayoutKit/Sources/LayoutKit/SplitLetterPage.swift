import Foundation

/// The explicit split arrangement of a layout, dressed as the letters page draws it: the same
/// native controls the whole rows get, one half at a time. Resolved when the layout is built, never
/// per key press.
public enum SplitLetterPage {
    /// Which keys the key area adds around the author's letters.
    public enum Shell: Sendable {
        /// The bundled 26-key shell: Shift opens and Delete closes the last letter row.
        case qwerty
        /// The bundled merged pad: the word-split key takes Shift's place, Delete closes the row.
        case merged
        /// The author's rows as declared; nothing is added.
        case declared
    }

    public struct Arrangement: Equatable, Sendable {
        /// The letter rows, one entry per main row.
        public let rows: [LayoutSplitRow]
        /// The control row's halves, when the layout has a control row.
        public let footer: LayoutSplitRow?
    }

    public static let shiftKey = LayoutKey(label: "⇧", width: 1.5, action: LayoutAction(.shift))
    public static let mergedShiftKey = LayoutKey(label: "分词", width: 1.8, action: LayoutAction(.shift))
    public static let deleteKey = LayoutKey(label: "⌫", width: 1.5, action: LayoutAction(.backspace))
    public static let mergedDeleteKey = LayoutKey(label: "⌫", width: 1.8, action: LayoutAction(.backspace))

    /// Nil when `halves` do not match the layout's rows (the caller then draws the whole rows).
    /// `mainRowCount` excludes the control row, which is the last entry when `hasControlRow`.
    public static func arrangement(
        halves: [LayoutSplitRow], mainRowCount: Int, hasControlRow: Bool, shell: Shell
    ) -> Arrangement? {
        guard mainRowCount > 0, halves.count == mainRowCount + (hasControlRow ? 1 : 0) else { return nil }
        var rows = Array(halves.prefix(mainRowCount))
        if shell != .declared, let last = rows.last {
            let hasShift = last.keys.contains { $0.action.type == .shift }
            let hasDelete = last.keys.contains { $0.action.type == .backspace }
            let shift = shell == .merged ? mergedShiftKey : Self.shiftKey
            let delete = shell == .merged ? mergedDeleteKey : Self.deleteKey
            rows[rows.count - 1] = LayoutSplitRow(
                left: (hasShift ? [] : [shift]) + last.left, right: last.right + (hasDelete ? [] : [delete]))
        }
        return Arrangement(rows: rows, footer: hasControlRow ? halves[mainRowCount] : nil)
    }
}

public extension LayoutSplitRow {
    /// The row as one piece again: the space bar's two halves become one key at their combined width.
    var wholeKeys: [LayoutKey] {
        guard let leftSpace = left.last, leftSpace.action.type == .space,
            let rightSpace = right.first, rightSpace.action.type == .space
        else { return left + right }
        let space = leftSpace.settingWidth(leftSpace.widthWeight + rightSpace.widthWeight)
        return Array(left.dropLast()) + [space] + Array(right.dropFirst())
    }
}
