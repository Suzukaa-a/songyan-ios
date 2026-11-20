import Foundation

/// Which codes of a scheme a layout can send.
public enum LayoutCodeCoverage {
    /// Every code the layout's keys send: rows, split halves, auxiliary areas and long-press options.
    /// A merged key also covers the codes grouped on it (`LayoutFold.groups`). A lowercase letter
    /// covers its uppercase, as the shift state types it.
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
        if let kind = LayoutFold.kind(of: layout) {
            for code in LayoutFold.groups(layout, kind: kind).flatMap(\.codes) {
                result.insert(String(code))
                if ("a"..."z").contains(code) { result.insert(String(code).uppercased()) }
            }
        }
        return result
    }

    /// The missing codes worth telling the user about for a keyboard of `kind` drawing `layout`. A
    /// 26-key layout reports `missingToReport`; a merged one (14, 18 or 9 keys) only what it covers
    /// less than the bundled layout of its kind, since folding schemes are typed on those as they are.
    public static func missingToReport(
        _ layout: LayoutDefinition, kind: LayoutInput.Builtin, needed: [String], optional: [String]?
    ) -> [String] {
        let report = missingToReport(layout, needed: needed, optional: optional)
        guard kind != .qwerty26 else { return report }
        let already = Set(
            missingToReport(BuiltinLayouts.preset(for: kind), needed: needed, optional: optional))
        return report.filter { !already.contains($0) }
    }

    /// The codes in `needed` that `layout` cannot send, in the given order.
    public static func missing(_ layout: LayoutDefinition, needed: [String]) -> [String] {
        let declared = declared(layout)
        return needed.filter { !declared.contains($0) }
    }

    /// The missing codes worth telling the user about: the required ones, or every missing code when the
    /// profile does not tell required from optional (`optional` is nil, an older profile), so nothing is hidden.
    public static func missingToReport(_ layout: LayoutDefinition, needed: [String], optional: [String]?) -> [String] {
        guard optional != nil else { return missing(layout, needed: needed) }
        return missingRequired(layout, needed: needed, optional: optional)
    }

    /// The codes in `needed` that `layout` cannot send and cannot go without: the speller's alphabet and
    /// initials, not the delimiter or the prefix and suffix codes of reverse lookups (`optional`). Empty
    /// when the profile does not tell them apart (`optional` is nil).
    public static func missingRequired(_ layout: LayoutDefinition, needed: [String], optional: [String]?) -> [String] {
        guard let optional else { return [] }
        return missing(layout, needed: needed).filter { !optional.contains($0) }
    }
}
