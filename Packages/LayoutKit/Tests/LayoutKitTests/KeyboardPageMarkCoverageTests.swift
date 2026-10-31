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
        XCTAssertEqual(
            KeyboardPageMarkCoverage.extraSymbolPageRows(missing: chineseKeypadMissing, ascii: false),
            [[], ["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”"], ["。", "、", "…", "%"]])
        XCTAssertEqual(
            KeyboardPageMarkCoverage.extraSymbolPageRows(missing: ["'", "#"], ascii: true), [[], [], ["'", "#"]])
        // The third row never holds only the page switch and Delete.
        XCTAssertEqual(
            KeyboardPageMarkCoverage.extraSymbolPageRows(
                missing: ["-", "/", ":", ";", "(", ")", "$", "&"], ascii: true),
            [[], ["-"], ["/", ":", ";", "(", ")", "$", "&"]])
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
