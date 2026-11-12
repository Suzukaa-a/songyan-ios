import Foundation

/// The bottom row of a letter layout, the same rule as on Android.
///
/// A layout's last row is its bottom row when it holds the space bar or types no engine input, so
/// it stays the bottom row even after its space key is removed. The bundled layouts carry a
/// stand-in there that asks for the keyboard's own bottom row; any other row is the author's and is
/// drawn as stored.
public enum LayoutBottomRow {
    public static func index(_ layout: LayoutDefinition) -> Int? {
        guard let last = layout.rows.indices.last else { return nil }
        let keys = layout.rows[last].keys
        let isBottom =
            keys.contains { $0.action.type == .space }
            || !keys.contains { $0.action.type == .code || $0.action.type == .kana }
        return isBottom ? last : nil
    }

    /// The author's bottom row, or nil when the layout keeps the bundled stand-in.
    public static func authored(_ layout: LayoutDefinition) -> [LayoutKey]? {
        guard let index = index(layout) else { return nil }
        let keys = layout.rows[index].keys
        return keys == standIn(for: layout) ? nil : keys
    }

    /// What the bottom row holds when the author has not changed it: the keyboard's own row.
    public static var defaultKeys: [LayoutKey] {
        KeyboardPagePresets.englishQwerty.materialized().chrome?.bottom ?? []
    }

    /// The bottom row to edit: the author's row, or the keyboard's own row as editable keys.
    public static func editable(_ layout: LayoutDefinition) -> LayoutDefinition {
        guard !PhoneKeypadStructure.matches(layout), index(layout) != nil, authored(layout) == nil
        else { return layout }
        return replacing(defaultKeys, in: layout)
    }

    /// The layout to store: an unchanged default bottom row goes back to the bundled stand-in, so
    /// the layout keeps following the keyboard's own row.
    public static func storable(_ layout: LayoutDefinition) -> LayoutDefinition {
        guard let index = index(layout), layout.rows[index].keys == defaultKeys,
            let standIn = standIn(for: layout)
        else { return layout }
        return replacing(standIn, in: layout)
    }

    public static func replacing(_ keys: [LayoutKey], in layout: LayoutDefinition) -> LayoutDefinition {
        var rows = layout.rows
        if let index = index(layout) {
            rows[index] = LayoutRow(keys: keys)
        } else {
            rows.append(LayoutRow(keys: keys))
        }
        return layout.replacingRowsFollowingSplit(rows)
    }

    private static func standIn(for layout: LayoutDefinition) -> [LayoutKey]? {
        guard let builtin = layout.input.builtinLayout else { return nil }
        // Every bundled row-shaped board ends with the same stand-in as its shape's preset.
        return BuiltinLayouts.preset(for: builtin).rows.last?.keys
    }
}
