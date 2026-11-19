import Foundation

/// Layouts made for one scheme from its key profile: the 26-key board with the codes it lacks
/// added, and the stroke pad. Pure builders; the app layer passes the saved name from its strings.
public enum GeneratedLayouts {
    /// Id prefix every generated layout carries, so the app can tell it needs installing.
    public static let idPrefix = "auto."

    public static let keys26Suffix = ".keys26"
    public static func keys26ID(schemaID: String) -> String { "\(idPrefix)\(schemaID)\(keys26Suffix)" }
    public static func strokesID(schemaID: String) -> String { "\(idPrefix)\(schemaID).strokes" }
    public static func isGeneratedID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// The codes a generated 26-key layout sends beyond the standard 26-key board, in key order; nil
    /// for any other layout.
    public static func addedCodes(_ layout: LayoutDefinition) -> [String]? {
        guard isGeneratedID(layout.id), layout.id.hasSuffix(keys26Suffix) else { return nil }
        let standard = LayoutCodeCoverage.declared(BuiltinLayouts.qwerty26)
        var seen = Set<String>()
        let added = layout.rows.flatMap(\.keys).compactMap { key -> String? in
            guard key.action.type == .code, let code = key.action.value, !standard.contains(code) else { return nil }
            return seen.insert(code).inserted ? code : nil
        }
        return added.isEmpty ? nil : added
    }

    private static let rowTwoExtras = 2
    private static let digits = "1234567890".map(String.init)

    /// The built-in 26-key board plus the codes it cannot send: needed digits become a new top row
    /// in keyboard order, the first two other symbols end row two, and any more join the top row.
    /// Every added key is a code key captioned with its character. `codes` are the profile's codes.
    public static func keys26(schemaID: String, name: String, codes: [String]) -> LayoutDefinition {
        let base = BuiltinLayouts.qwerty26
        let missing = LayoutCodeCoverage.missing(base, needed: codes)
        let neededDigits = digits.filter { missing.contains($0) }
        let symbols = missing.filter { !neededDigits.contains($0) }
        var rows = base.rows
        rows[1] = LayoutRow(keys: rows[1].keys + symbols.prefix(rowTwoExtras).map(codeKey))
        let rest = symbols.dropFirst(rowTwoExtras).map(codeKey)
        if !neededDigits.isEmpty {
            rows.insert(LayoutRow(keys: neededDigits.map(codeKey) + rest), at: 0)
        } else if !rest.isEmpty {
            rows[0] = LayoutRow(keys: rows[0].keys + rest)
        }
        return LayoutDefinition(
            id: keys26ID(schemaID: schemaID), name: name,
            input: LayoutInput(schemaID: schemaID, builtinLayout: .qwerty26), rows: rows)
    }

    /// The stroke pad: the first three strokes on row one, the rest and backspace on row two, then
    /// the standard bottom row. Keys carry the scheme's captions.
    public static func strokes(
        schemaID: String, name: String, strokes: [(code: String, label: String)]
    ) -> LayoutDefinition {
        let keys = strokes.map { LayoutKey(label: $0.label, action: LayoutAction(.code, value: $0.code)) }
        let backspace = LayoutKey(label: "⌫", action: LayoutAction(.backspace))
        return LayoutDefinition(
            id: strokesID(schemaID: schemaID), name: name,
            input: LayoutInput(schemaID: schemaID, builtinLayout: .qwerty26),
            rows: [
                LayoutRow(keys: Array(keys.prefix(3))),
                LayoutRow(keys: Array(keys.dropFirst(3)) + [backspace]),
                BuiltinLayouts.qwerty26.rows[BuiltinLayouts.qwerty26.rows.count - 1],
            ])
    }

    private static func codeKey(_ code: String) -> LayoutKey {
        LayoutKey(label: code, action: LayoutAction(.code, value: code))
    }
}
