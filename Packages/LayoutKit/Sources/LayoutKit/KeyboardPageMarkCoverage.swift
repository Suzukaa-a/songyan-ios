import Foundation

/// The built-in row 123 page carries the everyday marks, and the built-in symbol pages leave them
/// out on purpose. When a pairing draws another 123 page (a digit pad, a custom page), some of
/// those marks are on no page the pairing opens; this finds them so the symbol page can take them
/// over.
///
/// Only a key's tap counts as reaching a mark. Long-press menus show at most their first entry on
/// the key face and the rest only after a press, so a mark that lives only there is effectively
/// hidden; repeating it on the symbol page costs a key, while missing it costs the mark.
public enum KeyboardPageMarkCoverage {
    /// How the pairing's symbol page takes over the missing marks.
    public enum SymbolPageForm: Equatable, Sendable {
        /// The built-in row page: it opens on an extra first page holding them.
        case builtInRows
        /// The built-in category tabs: 常用 lists them first.
        case builtInCategories
        /// A page the user made: never changed; the pairing screen names what is missing instead.
        case custom
    }

    /// `page` is the pairing's symbol page, nil when it has none (the built-in page draws it).
    public static func symbolPageForm(
        _ page: KeyboardPageDefinition?, mainLayoutIsPhoneKeypad: Bool
    ) -> SymbolPageForm {
        guard let page, page.kind == .symbols, page.symbolPresentation != .automatic else {
            // The automatic page is the category browser on a phone keypad, rows elsewhere.
            return mainLayoutIsPhoneKeypad ? .builtInCategories : .builtInRows
        }
        // A categorized page without its own categories draws the built-in tabs.
        if page.symbolPresentation == .categorized, page.categories == nil { return .builtInCategories }
        return .custom
    }

    /// The everyday marks in the 123 page's mark rows (the digit row left out).
    public static func everydayMarkRows(ascii: Bool) -> [[String]] {
        Array(BuiltinLayouts.numericPageRows(ascii: ascii).dropFirst())
    }

    /// The everyday marks of the `ascii` branch that no page of the pairing types with a tap, in
    /// the 123 page's order. `numeric` and `symbols` are the pages the pairing draws, nil for the
    /// built-in ones; `letters` is the main layout.
    ///
    /// The built-in category tabs are left out of the count: every mark is somewhere in them, and
    /// the point is to bring the missing ones to the front of 常用.
    public static func missingMarks(
        letters: LayoutDefinition?, numeric: KeyboardPageDefinition?, symbols: KeyboardPageDefinition?,
        mainLayoutIsPhoneKeypad: Bool, ascii: Bool
    ) -> [String] {
        // The built-in 123 page types every everyday mark in both shapes: the row page holds them
        // and the phone digit pad's rail lists them all.
        guard let numeric, numeric.kind == .numeric, numeric.numericPresentation != .automatic else { return [] }
        var reached = Set<String>()
        func reach(_ keys: [LayoutKey]) {
            for key in keys {
                if let value = key.action.literalValue(usesASCIIPunctuation: ascii) { reached.insert(value) }
            }
        }
        if let letters {
            reach(letters.rows.flatMap(\.keys) + (letters.auxiliaryAreas ?? []).flatMap(\.keys))
        }
        reach(numeric.rows.flatMap(\.keys) + numeric.chromeKeys)
        switch symbolPageForm(symbols, mainLayoutIsPhoneKeypad: mainLayoutIsPhoneKeypad) {
        case .builtInRows:
            reached.formUnion(BuiltinLayouts.symbolPageRows(ascii: ascii).joined())
        case .builtInCategories:
            break
        case .custom:
            if let symbols {
                // A recent tab's keys are a backup of fixed content; what it shows changes.
                let categories = (symbols.categories ?? []).filter { $0.source != .recent }
                reach(symbols.rows.flatMap(\.keys) + categories.flatMap(\.keys) + symbols.chromeKeys)
            }
        }
        return everydayMarkRows(ascii: ascii).joined().filter { !reached.contains($0) }
    }

    /// The row symbol page's extra first page, in the symbol page's own rows (ten, ten and the seven
    /// between the page switch and Delete), so it has that page's key widths and no row stands
    /// empty. The missing marks come first in the 123 page's order; the slots they leave take the
    /// symbol page's own marks from its start, which are the ones the next page opens with, so a mark
    /// appears at most once here and never a digit. Empty when nothing is missing: the symbol page
    /// then has no extra page.
    public static func extraSymbolPageRows(missing: [String], ascii: Bool) -> [[String]] {
        guard !missing.isEmpty else { return [] }
        let shape = BuiltinLayouts.symbolPageRows(ascii: ascii)
        var seen = Set<String>()
        let marks = (missing + shape.flatMap { $0 }).filter { seen.insert($0).inserted }
            .prefix(shape.reduce(0) { $0 + $1.count })
        var next = marks.startIndex
        return shape.map { row in
            defer { next = marks.index(next, offsetBy: row.count) }
            return Array(marks[next..<marks.index(next, offsetBy: row.count)])
        }
    }

    /// 常用 with the missing marks first; a mark already in it moves to the front instead of
    /// appearing twice.
    public static func commonSymbols(_ common: [String], leading missing: [String]) -> [String] {
        var seen = Set<String>()
        return (missing + common).filter { seen.insert($0).inserted }
    }

    /// The pairing screen's note for a user's own symbol page, or nil when nothing is missing or
    /// the symbol page is a built-in one (which takes the marks over itself). Lists both branches.
    public static func pairingNote(
        letters: LayoutDefinition?, numeric: KeyboardPageDefinition?, symbols: KeyboardPageDefinition?,
        mainLayoutIsPhoneKeypad: Bool
    ) -> String? {
        guard symbolPageForm(symbols, mainLayoutIsPhoneKeypad: mainLayoutIsPhoneKeypad) == .custom else { return nil }
        let marks = [false, true].flatMap { ascii in
            missingMarks(
                letters: letters, numeric: numeric, symbols: symbols,
                mainLayoutIsPhoneKeypad: mainLayoutIsPhoneKeypad, ascii: ascii)
        }
        var seen = Set<String>()
        let unique = marks.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return nil }
        return String(
            format: String(localized: "page.pairingNote", bundle: .module),
            unique.joined(separator: " "))
    }
}
