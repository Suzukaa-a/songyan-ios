import Foundation

/// The twelve-key kana board as a layout describes it: a 4x3 grid of kana keys between a leading
/// and a trailing side area. The grid keys keep their authored labels, so a board the user edited
/// still reads as authored, while the kana model owns what each row types (its flicks). A layout
/// that is not a twelve-key board (another row count, a grid key that types no kana, a missing
/// side area) has none, and the ordinary row rendering keeps it usable. The Android keyboard reads
/// the board by the same rule.
public struct Kana12Board: Equatable, Sendable {
    public static let rowCount = 4
    public static let columnCount = 3

    public let grid: [[LayoutKey]]
    public let leading: [LayoutKey]
    public let trailing: [LayoutKey]
    /// Where the side keys are stored in the layout, for an editor that selects them; nil when they
    /// came from the main layout because the page carries none.
    public let leadingArea: Int?
    public let trailingArea: Int?

    /// The board `definition` describes, or nil when it is not a twelve-key kana board. A page
    /// keeps a layout's rows but not its side areas, so `mainLayout` supplies them when the
    /// definition has none.
    public static func of(_ definition: LayoutDefinition?, mainLayout: LayoutDefinition? = nil) -> Kana12Board? {
        guard let definition, definition.rows.count == rowCount else { return nil }
        let grid = definition.rows.map(\.keys)
        guard grid.allSatisfy({ $0.count == columnCount && $0.allSatisfy(\.isKana12GridKey) }),
            grid.joined().contains(where: { $0.action.type == .kana })
        else { return nil }
        let own = definition.auxiliaryAreas ?? []
        let areas = own.isEmpty ? (mainLayout?.auxiliaryAreas ?? []) : own
        guard let leading = areas.firstIndex(where: { $0.position == .leading }),
            let trailing = areas.firstIndex(where: { $0.position == .trailing }),
            !areas[leading].keys.isEmpty, !areas[trailing].keys.isEmpty
        else { return nil }
        return Kana12Board(
            grid: grid, leading: areas[leading].keys, trailing: areas[trailing].keys,
            leadingArea: own.isEmpty ? nil : leading, trailingArea: own.isEmpty ? nil : trailing)
    }

    /// How many of the four rows each side key spans: one each, and the last key takes the rows
    /// that are left (the return key under delete and space). More than four keys share the height.
    public static func railSpans(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard count < rowCount else { return Array(repeating: Double(rowCount) / Double(count), count: count) }
        return Array(repeating: 1, count: count - 1) + [Double(rowCount - count + 1)]
    }
}

extension LayoutKey {
    /// A grid key of the twelve-key board: a kana row, the modifier, or a literal (the punctuation
    /// key types its mark as text; the kana model still owns that row's flicks).
    public var isKana12GridKey: Bool {
        action.type == .kana || action.type == .kanaModifier || action.type == .literal
    }
}
