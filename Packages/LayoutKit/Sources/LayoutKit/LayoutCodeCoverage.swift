import Foundation

/// Which codes of a scheme a layout can send.
public enum LayoutCodeCoverage {
    /// Every code the layout's keys send: rows, split halves, auxiliary areas and long-press options.
    /// A lowercase letter key covers its uppercase, as the shift state types it.
    public static func declared(_ layout: LayoutDefinition) -> Set<String> {
        let keys =
            layout.rows.flatMap(\.keys) + (layout.split?.halves ?? []).flatMap(\.keys)
            + (layout.auxiliaryAreas ?? []).flatMap(\.keys)
        var result = Set<String>()
        for key in keys {
            let actions = [key.action] + (key.longPress ?? []).map(\.action)
            for action in actions where action.type == .code {
                guard let code = action.value else { continue }
                result.insert(code)
                if code.count == 1, ("a"..."z").contains(code) { result.insert(code.uppercased()) }
            }
        }
        return result
    }

    /// The codes in `needed` that `layout` cannot send, in the given order.
    public static func missing(_ layout: LayoutDefinition, needed: [String]) -> [String] {
        let declared = declared(layout)
        return needed.filter { !declared.contains($0) }
    }

    /// The codes in `needed` that `layout` cannot send and cannot go without: the speller's alphabet and
    /// initials, not the delimiter or the prefix and suffix codes of reverse lookups (`optional`). Empty
    /// when the profile does not tell them apart (`optional` is nil).
    public static func missingRequired(_ layout: LayoutDefinition, needed: [String], optional: [String]?) -> [String] {
        guard let optional else { return [] }
        return missing(layout, needed: needed).filter { !optional.contains($0) }
    }
}
