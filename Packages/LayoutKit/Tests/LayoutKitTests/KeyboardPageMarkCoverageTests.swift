import XCTest

@testable import LayoutKit

/// The everyday marks of the row 123 page that a pairing reaches nowhere, and how the symbol page
/// takes them over.
final class KeyboardPageMarkCoverageTests: XCTestCase {
    private let chineseKeypadMissing = ["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”", "。", "、", "…", "%"]
    private let asciiKeypadMissing = ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\"", "'", "%", "#", "+"]

    private func missing(
        letters: LayoutDefinition = BuiltinLayouts.qwerty26, numeric: KeyboardPageDefinition?,
        symbols: KeyboardPageDefinition? = KeyboardPagePresets.symbolsSystem, phone: Bool = false, ascii: Bool
    ) -> [String] {
        KeyboardPageMarkCoverage.missingMarks(
            letters: letters, numeric: numeric, symbols: symbols, mainLayoutIsPhoneKeypad: phone, ascii: ascii)
    }

    private func literal(_ value: String, ascii: String? = nil) -> LayoutKey {
        LayoutKey(label: value, action: .init(.literal, value: value, asciiValue: ascii))
    }

    func testTheFullKeyboard123PairingMissesNothing() {
        for ascii in [false, true] {
            XCTAssertEqual(missing(numeric: KeyboardPagePresets.numericAutomatic, ascii: ascii), [])
            XCTAssertEqual(missing(numeric: nil, ascii: ascii), [])
            XCTAssertEqual(missing(numeric: KeyboardPagePresets.numericRowsPage(ascii: false), ascii: ascii), [])
            // A phone keypad's own digit pad lists every mark in its rail.
            XCTAssertEqual(
                missing(
                    letters: BuiltinLayouts.phone9, numeric: KeyboardPagePresets.numericAutomatic, phone: true,
                    ascii: ascii), [])
        }
    }

    func testTheKeypadPairingMissesTheRowMarksInBothBranches() {
        XCTAssertEqual(missing(numeric: KeyboardPagePresets.numericKeypad, ascii: false), chineseKeypadMissing)
        XCTAssertEqual(missing(numeric: KeyboardPagePresets.numericKeypad, ascii: true), asciiKeypadMissing)
    }

    func testACustom123PageWithSomeMarksMissesOnlyTheRest() {
        var page = KeyboardPagePresets.numericKeypad
        page.id = "mine"
        page.rows.append(LayoutRow(keys: [literal("¥", ascii: "$"), literal("@"), literal("、", ascii: "'")]))
        XCTAssertEqual(
            missing(numeric: page, ascii: false), chineseKeypadMissing.filter { !["¥", "@", "、"].contains($0) })
        XCTAssertEqual(
            missing(numeric: page, ascii: true), asciiKeypadMissing.filter { !["$", "@", "'"].contains($0) })
    }

    func testOnlyATapReachesAMark() {
        var page = KeyboardPagePresets.numericKeypad
        page.id = "mine"
        page.rows.append(
            LayoutRow(keys: [
                LayoutKey(
                    label: "#", action: .init(.literal, value: "#"),
                    longPress: [LayoutOption(label: "¥", action: .init(.literal, value: "¥"))])
            ]))
        XCTAssertTrue(missing(numeric: page, ascii: false).contains("¥"))
    }

    func testEveryKindOfSymbolPageIsTold() {
        let form = KeyboardPageMarkCoverage.symbolPageForm
        XCTAssertEqual(form(nil, false), .builtInRows)
        XCTAssertEqual(form(KeyboardPagePresets.symbolsSystem, false), .builtInRows)
        XCTAssertEqual(form(KeyboardPagePresets.symbolsSystem, true), .builtInCategories)
        XCTAssertEqual(form(KeyboardPagePresets.symbolsCategorized, false), .builtInCategories)
        XCTAssertEqual(form(KeyboardPagePresets.symbolsSystem.copy(), false), .custom)
        var edited = KeyboardPagePresets.symbolRowsPage(ascii: false)
        edited.id = "mine"
        XCTAssertEqual(form(edited, false), .custom)
    }

    func testTheRowSymbolPageGrowsAFirstPageOnlyWhenMarksAreMissing() {
        XCTAssertEqual(KeyboardPageMarkCoverage.extraSymbolPageRows(missing: [], ascii: false), [])
        for (ascii, missing) in [(false, chineseKeypadMissing), (true, asciiKeypadMissing), (true, ["'", "#"])] {
            let rows = KeyboardPageMarkCoverage.extraSymbolPageRows(missing: missing, ascii: ascii)
            let shape = BuiltinLayouts.symbolPageRows(ascii: ascii)
            XCTAssertEqual(rows.map(\.count), shape.map(\.count))
            let marks = rows.flatMap { $0 }
            XCTAssertEqual(marks.count, Set(marks).count)
            XCTAssertTrue(marks.allSatisfy { mark in !mark.contains(where: \.isNumber) })
            XCTAssertEqual(Array(marks.prefix(missing.count)), missing)
            XCTAssertEqual(
                Array(marks.dropFirst(missing.count)),
                Array(shape.flatMap { $0 }.filter { !missing.contains($0) }.prefix(marks.count - missing.count)))
        }
        XCTAssertEqual(
            KeyboardPageMarkCoverage.extraSymbolPageRows(missing: chineseKeypadMissing, ascii: false).first,
            ["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”"])
    }

    /// The keyboard draws these rows in the symbol page's own grid, so equal row counts mean equal
    /// key widths, and the third-row switch and Delete are the symbol page's.
    func testTheKeypadPairingGivesTheExtraPageTheSymbolPagesGrid() {
        for ascii in [false, true] {
            let missing = missing(numeric: KeyboardPagePresets.numericKeypad, ascii: ascii)
            let rows = KeyboardPageMarkCoverage.extraSymbolPageRows(missing: missing, ascii: ascii)
            XCTAssertEqual(rows.map(\.count), BuiltinLayouts.symbolPageRows(ascii: ascii).map(\.count))
            XCTAssertTrue(rows.allSatisfy { !$0.isEmpty })
            XCTAssertEqual(Array(rows.flatMap { $0 }.prefix(missing.count)), missing)
            let full = self.missing(numeric: KeyboardPagePresets.numericAutomatic, ascii: ascii)
            XCTAssertEqual(KeyboardPageMarkCoverage.extraSymbolPageRows(missing: full, ascii: ascii), [])
        }
    }

    func testCommonPutsTheMissingMarksFirstWithoutRepeatingThem() {
        XCTAssertEqual(
            KeyboardPageMarkCoverage.commonSymbols(["，", "。", "@", "#"], leading: ["¥", "@", "。"]),
            ["¥", "@", "。", "，", "#"])
        XCTAssertEqual(KeyboardPageMarkCoverage.commonSymbols(["，", "。"], leading: []), ["，", "。"])
    }

    func testThePairingNamesWhatAUsersSymbolPageLacks() {
        let everyday = Set(
            [false, true].flatMap { KeyboardPageMarkCoverage.everydayMarkRows(ascii: $0).joined() })
        var mine = KeyboardPagePresets.symbolRowsPage(ascii: false)
        mine.id = "mine"
        mine.rows = [LayoutRow(keys: everyday.subtracting(["¥", "&"]).sorted().map { literal($0) })]
        XCTAssertEqual(
            KeyboardPageMarkCoverage.pairingNote(
                letters: BuiltinLayouts.qwerty26, numeric: KeyboardPagePresets.numericKeypad, symbols: mine,
                mainLayoutIsPhoneKeypad: false),
            "这个搭配打不出：¥ &，可以在符号页加上这些键。")
        // The full 123 page reaches everything; a built-in symbol page takes the marks over itself.
        XCTAssertNil(
            KeyboardPageMarkCoverage.pairingNote(
                letters: BuiltinLayouts.qwerty26, numeric: KeyboardPagePresets.numericAutomatic, symbols: mine,
                mainLayoutIsPhoneKeypad: false))
        XCTAssertNil(
            KeyboardPageMarkCoverage.pairingNote(
                letters: BuiltinLayouts.qwerty26, numeric: KeyboardPagePresets.numericKeypad,
                symbols: KeyboardPagePresets.symbolsSystem, mainLayoutIsPhoneKeypad: false))
    }
}
