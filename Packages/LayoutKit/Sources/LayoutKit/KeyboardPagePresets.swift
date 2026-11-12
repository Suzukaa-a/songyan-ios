import Foundation

public enum KeyboardPagePresets {
    /// English QWERTY letters: each key carries one fixed letter, independent of the symbol branch.
    private static func letterRows(_ values: [[String]]) -> [LayoutRow] {
        values.map { row in
            LayoutRow(
                keys: row.map { value in
                    let options = AlternateKeyPolicy.options(
                        for: .init(
                            keyLabel: value, secondaryLiterals: AlternateKeyPolicy.defaultLetterLiterals(for: value),
                            page: .letters, language: .english, usesASCIIPunctuation: true, visibleKeys: [])
                    )
                    .map { option -> LayoutOption in
                        let text: String
                        switch option.payload {
                        case .code(let value), .literal(let value): text = value
                        }
                        return LayoutOption(label: option.label, action: .init(.literal, value: text))
                    }
                    return LayoutKey(
                        label: value, secondaryLabel: options.first?.label,
                        action: .init(.literal, value: value), longPress: options.isEmpty ? nil : options)
                })
        }
    }

    /// 123 / row-shaped symbol marks pair the two existing key tables by slot. The stored action
    /// keeps the Chinese branch in `value` and the ASCII branch in `asciiValue`; the label and the
    /// long-press list follow the branch the page opens in, so a copy shows a real symbol switch
    /// without translating anything for an ordinary author literal.
    private static func markRows(
        _ marks: [[BuiltinLayouts.BilingualPageMark]], kind: KeyboardPageKind, ascii: Bool
    ) -> [LayoutRow] {
        let policyPage: AlternateKeyPolicy.Page = kind == .numeric ? .numeric : .symbols
        let visible = Set(marks.flatMap { $0.map { ascii ? $0.ascii : $0.chinese } })
        return marks.map { row in
            LayoutRow(
                keys: row.map { mark in
                    let initial = ascii ? mark.ascii : mark.chinese
                    let options = AlternateKeyPolicy.options(
                        for: .init(
                            keyLabel: initial, secondaryLiterals: [], page: policyPage,
                            language: ascii ? .english : .chinese, usesASCIIPunctuation: ascii,
                            visibleKeys: visible)
                    )
                    .map { option -> LayoutOption in
                        let text: String
                        switch option.payload {
                        case .code(let value), .literal(let value): text = value
                        }
                        return LayoutOption(label: option.label, action: .init(.literal, value: text))
                    }
                    return LayoutKey(
                        label: initial, secondaryLabel: options.first?.label,
                        action: .init(
                            .literal, value: mark.chinese,
                            asciiValue: mark.ascii == mark.chinese ? nil : mark.ascii),
                        longPress: options.isEmpty ? nil : options,
                        titleMode: .automatic)
                })
        }
    }

    /// The default 123 page: its marks follow the running language and its shape follows the
    /// running main layout, so pairing a keyboard never freezes the other punctuation width and
    /// never turns a phone keypad's digit pad into a ten-column page.
    public static let numericAutomatic = KeyboardPageDefinition(
        id: "page.numeric.automatic", name: "自动 123", kind: .numeric, rows: [],
        numericPresentation: .automatic)
    /// An authored digit pad: the nine-key letter shell's grid with 1–9 in it and Delete, 0 and the
    /// comma down the right (see `KeyboardPageDefinition.keypadChrome`) as editable data, usable
    /// with any main layout. Copying the automatic phone digit pad lands here.
    public static let numericKeypad: KeyboardPageDefinition = {
        var page = numericAutomatic.materialized(numericForm: .phoneDigitPad)
        page.id = "page.numeric.keypad"
        page.name = "数字九宫格"
        return page
    }()
    /// The ten-column 123 rows of one symbol branch. Every key carries both branches in its action;
    /// the label and the long-press list are the `ascii` branch's, because alternates are plain data.
    /// The running keyboard draws these for the automatic page, and a copy starts from them.
    public static func numericRowsPage(ascii: Bool) -> KeyboardPageDefinition {
        ascii ? numericAsciiRows : numericChineseRows
    }

    /// The row-shaped symbol page of one symbol branch; see `numericRowsPage(ascii:)`.
    public static func symbolRowsPage(ascii: Bool) -> KeyboardPageDefinition {
        ascii ? symbolsAsciiRows : symbolsChineseRows
    }

    private static let numericChineseRows = rowsPage(.numeric, ascii: false)
    private static let numericAsciiRows = rowsPage(.numeric, ascii: true)
    private static let symbolsChineseRows = rowsPage(.symbols, ascii: false)
    private static let symbolsAsciiRows = rowsPage(.symbols, ascii: true)

    private static func rowsPage(_ kind: KeyboardPageKind, ascii: Bool) -> KeyboardPageDefinition {
        let numeric = kind == .numeric
        let marks = numeric ? BuiltinLayouts.numericPageBilingualRows() : BuiltinLayouts.symbolPageBilingualRows()
        return KeyboardPageDefinition(
            id: numeric ? "page.numeric.rows" : "page.symbols.rows", name: numeric ? "123" : "符号", kind: kind,
            rows: markRows(marks, kind: kind, ascii: ascii))
    }

    public static let englishQwerty = KeyboardPageDefinition(
        id: "page.english.qwerty", name: "英文 QWERTY", kind: .english,
        rows: letterRows([
            Array("qwertyuiop").map(String.init), Array("asdfghjkl").map(String.init),
            Array("zxcvbnm").map(String.init),
        ]))
    public static let symbolsSystem = KeyboardPageDefinition(
        id: "page.symbols.system", name: "默认符号页", kind: .symbols,
        rows: symbolRowsPage(ascii: false).rows, symbolPresentation: .automatic)
    public static let symbolsCategorized = KeyboardPageDefinition(
        id: "page.symbols.categorized", name: "分类符号", kind: .symbols,
        rows: [], symbolPresentation: .categorized)

    public static let all = [
        symbolsSystem, symbolsCategorized, numericAutomatic, numericKeypad, englishQwerty,
    ]

    public static func preset(id: String) -> KeyboardPageDefinition? {
        all.first { $0.id == id }
    }

    /// The Chinese and the English copy of the 123 page and of the symbol rows were separate library
    /// pages although every key carries both branches. They are one page now, the automatic page of
    /// each kind, which opens in the branch of the input language.
    private static let retiredBranchPageIDs: Set<String> = [
        "page.numeric.chinese", "page.numeric.english", "page.symbols.chinese", "page.symbols.english",
    ]

    /// The retired presets exactly as they shipped, to tell an untouched stored copy from an edited one.
    /// A branch page here is also the merged rows pinned to that branch, so it stands in for a page
    /// a pairing still names.
    private static let retiredPresets: [KeyboardPageDefinition] = {
        func old(_ id: String, _ name: String, _ kind: KeyboardPageKind, ascii: Bool) -> KeyboardPageDefinition {
            var page = rowsPage(kind, ascii: ascii)
            page.id = id
            page.name = name
            page.defaultSymbolMarks = ascii ? .ascii : .chinese
            return page
        }
        var previousKeypad = numericKeypad
        previousKeypad.chrome = KeyboardPageDefinition.previousKeypadChrome(marks: .chinese)
        let pages = [
            // The keypad keeps its id; dropping a stored copy of its earlier arrangement lets the
            // current preset merge back in under the same id.
            previousKeypad,
            old("page.numeric.chinese", "中文 123", .numeric, ascii: false),
            old("page.numeric.english", "英文 123", .numeric, ascii: true),
            old("page.symbols.chinese", "中文符号", .symbols, ascii: false),
            old("page.symbols.english", "英文符号", .symbols, ascii: true),
        ]
        // Every preset also shipped with the globe first in its footer.
        let globeFirst = (pages + [numericKeypad]).compactMap(withGlobeFirst)
        return pages + globeFirst
    }()

    /// The page as it shipped while the footer's globe came first; nil when that was no different.
    private static func withGlobeFirst(_ page: KeyboardPageDefinition) -> KeyboardPageDefinition? {
        guard let bottom = page.chrome?.bottom, let index = bottom.firstIndex(where: { $0.action.type == .globe }),
            index > 0
        else { return nil }
        var moved = bottom
        moved.insert(moved.remove(at: index), at: 0)
        var copy = page
        copy.chrome?.bottom = moved
        return copy
    }

    /// A loaded catalog with the retired presets resolved: a stored copy the user never edited goes
    /// (the automatic page replaces it in the library), an edited one stays as an ordinary user page
    /// under its own ID. A pairing that names a retired branch page chose that branch on purpose, as
    /// no default pairing ever named one, so the merged rows pinned to it come back under that ID.
    public static func resolvingRetired(
        pages: [KeyboardPageDefinition], compositions: [String: KeyboardComposition]
    ) -> (pages: [KeyboardPageDefinition], compositions: [String: KeyboardComposition]) {
        let kept = pages.filter { page in !retiredPresets.contains(page) }
        let keptIDs = Set(kept.map(\.id))
        let named = Set(compositions.values.flatMap { [$0.symbolPageID, $0.numericPageID, $0.englishPageID] })
        let pinned = retiredPresets.filter {
            retiredBranchPageIDs.contains($0.id) && named.contains($0.id) && !keptIDs.contains($0.id)
        }
        return (kept + pinned, compositions)
    }

    /// A stored page with a preset ID may be a user-modified preset; only an unchanged one is left
    /// out of the saved catalog and of the catalog totals, because loading restores it from code.
    public static func isUnmodifiedPreset(_ page: KeyboardPageDefinition) -> Bool {
        preset(id: page.id) == page
    }

    /// Adds the built-in pages a stored catalog does not carry: saves leave unchanged ones out, and
    /// a release may add one. A stored page with the same ID stays untouched (it may be the user's
    /// edited preset); missing ones append in `all` order.
    public static func mergingInto(_ pages: [KeyboardPageDefinition]) -> [KeyboardPageDefinition] {
        var merged = pages
        var known = Set(pages.map(\.id))
        for preset in all where known.insert(preset.id).inserted { merged.append(preset) }
        return merged
    }
}
