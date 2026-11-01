import XCTest

@testable import LayoutKit

final class SplitArrangementTests: XCTestCase {
    private func letter(_ c: Character) -> LayoutKey {
        LayoutKey(label: String(c), action: LayoutAction(.code, value: String(c)))
    }

    private func text(_ keys: [LayoutKey]) -> String { keys.map(\.label).joined() }

    /// The acceptance layout: qwerty26 whose split arrangement repeats y, g and v on both halves.
    private func duplicated() -> LayoutDefinition {
        let base = BuiltinLayouts.qwerty26
        let split = LayoutSplitConfiguration(activation: .always)
        var derived = split.derivedArrangement(of: base.rows)
        derived[0].left.append(letter("y"))
        derived[1].right.insert(letter("g"), at: 0)
        derived[2].right.insert(letter("v"), at: 0)
        var arranged = split
        arranged.halves = derived
        return base.settingSplit(arranged)
    }

    func testTheWholeRowsStayAndTheHalvesCarryTheDuplicates() throws {
        let layout = duplicated()
        XCTAssertEqual(layout.rows, BuiltinLayouts.qwerty26.rows)
        let halves = try XCTUnwrap(layout.split?.halves)
        XCTAssertEqual([text(halves[0].left), text(halves[0].right)], ["qwerty", "yuiop"])
        XCTAssertEqual([text(halves[1].left), text(halves[1].right)], ["asdfg", "ghjkl"])
        XCTAssertEqual([text(halves[2].left), text(halves[2].right)], ["zxcv", "vbnm"])
        for c in ["y", "g", "v"] {
            let sent = halves.flatMap(\.keys).filter { $0.label == c }
            XCTAssertEqual(sent.count, 2)
            XCTAssertTrue(sent.allSatisfy { $0.action == LayoutAction(.code, value: c) })
        }
    }

    func testTheHalvesRoundTripThroughJsonAndAreWrittenOnlyWhenSet() throws {
        let layout = duplicated()
        let data = try layout.encoded()
        XCTAssertTrue(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("\"halves\""))
        XCTAssertEqual(try LayoutDefinition.decode(data), layout)
        let plain = try BuiltinLayouts.qwerty26.settingSplit(LayoutSplitConfiguration()).encoded()
        XCTAssertFalse(try XCTUnwrap(String(data: plain, encoding: .utf8)).contains("halves"))
    }

    func testWithoutHalvesTheArrangementIsTheRowsCutAtTheirBreaks() {
        let split = LayoutSplitConfiguration(activation: .always, rowBreaks: [4, 5, 3, 1])
        let arranged = split.arrangement(of: BuiltinLayouts.qwerty26.rows)
        XCTAssertEqual([text(arranged[0].left), text(arranged[0].right)], ["qwer", "tyuiop"])
        // The control row's space bar becomes one half under each thumb.
        XCTAssertEqual(arranged.last?.left.last?.action.type, .space)
        XCTAssertEqual(arranged.last?.right.first?.action.type, .space)
        XCTAssertEqual(
            (arranged.last?.left.last?.widthWeight ?? 0) * 2,
            BuiltinLayouts.qwerty26.rows.last?.keys.first { $0.action.type == .space }?.widthWeight ?? -1)
    }

    func testASplitWithoutAGapSettingDecodesWithTheAutomaticGap() throws {
        let whole = try BuiltinLayouts.qwerty26.encoded()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: whole) as? [String: Any])
        object["split"] = ["activation": "always"]
        let data = try JSONSerialization.data(withJSONObject: object)
        let split = try XCTUnwrap(try LayoutDefinition.decode(data).split)
        XCTAssertTrue(split.automaticGap)
        XCTAssertEqual(split.gapFraction, LayoutSplitConfiguration.defaultGapFraction)
        XCTAssertEqual(split.rowBreaks, [])
        let drawn = try XCTUnwrap(split.resolved(forWidth: 1000))
        XCTAssertGreaterThan(drawn.gap(width: 1000, keyCount: 10), 0)
        // Every field is still written, for readers that require them.
        let written = try JSONEncoder().encode(split)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["activation", "rowBreaks", "gapFraction", "automaticGap"])
    }

    private func assertInvalid(_ layout: LayoutDefinition, _ message: String, line: UInt = #line) {
        XCTAssertThrowsError(try layout.validate(), line: line) {
            XCTAssertEqual($0 as? LayoutError, .invalid(message), line: line)
        }
    }

    func testTheHalvesMustMatchTheRowsAndKeepAKeyInEachHalf() throws {
        let layout = duplicated()
        var split = try XCTUnwrap(layout.split)
        let full = try XCTUnwrap(split.halves)
        split.halves = Array(full.dropLast())
        XCTAssertEqual(split.halvesProblem(rowCount: full.count), .rowCountMismatch)
        assertInvalid(layout.settingSplit(split), LayoutSplitMessage.halvesShape)
        var emptied = full
        emptied[0].right = []
        split.halves = emptied
        XCTAssertEqual(split.halvesProblem(rowCount: full.count), .halfEmpty)
        assertInvalid(layout.settingSplit(split), LayoutSplitMessage.halvesShape)
        // A row of one key cannot be cut: one empty half is fine there.
        var single = full
        single[0] = LayoutSplitRow(left: [letter("q")], right: [])
        split.halves = single
        XCTAssertNil(split.halvesProblem(rowCount: full.count))
        // A key inside a half is validated like any other key.
        var broken = full
        broken[0].left[0] = letter("q").settingLabel("")
        split.halves = broken
        assertInvalid(layout.settingSplit(split), "请填写按键标题，并把宽度设为大于 0 的数字。")
        var badAction = full
        badAction[0].left[0] = letter("q").settingAction(LayoutAction(.code, value: "ab"))
        split.halves = badAction
        XCTAssertThrowsError(try layout.settingSplit(split).validate())
    }

    func testStaleBreaksAreIgnoredWhileHalvesExist() throws {
        var split = try XCTUnwrap(duplicated().split)
        split.rowBreaks = [99, 99, 99, 99, 99, 99]
        XCTAssertNoThrow(try duplicated().settingSplit(split).validate())
        XCTAssertEqual(split.rowBreaks, [99, 99, 99, 99, 99, 99])
        XCTAssertEqual(split.resolved(forWidth: 1000)?.rowBreaks, [])
    }

    func testAPageDoesNotCarryItsOwnHalvesAndInheritingDropsThem() throws {
        var page = KeyboardPagePresets.englishQwerty
        page.split = try XCTUnwrap(duplicated().split)
        XCTAssertThrowsError(try page.validate()) {
            XCTAssertEqual($0 as? LayoutError, .invalid(LayoutSplitMessage.halvesOnlyOnLayout))
        }
        let inherited = try XCTUnwrap(LayoutSplitConfiguration.resolving(page: nil, main: duplicated().split))
        XCTAssertNil(inherited.halves)
        XCTAssertEqual(inherited.rowBreaks, [])
        // Pages drawn under the main split never see the halves.
        let active = try XCTUnwrap(duplicated().split?.resolved(forWidth: 1000))
        XCTAssertNotNil(active.halves)
        XCTAssertNil(active.withoutRowBreaks.halves)
        XCTAssertNil(active.forStandardLetterRows.halves)
    }

    func testKeysOnlyTheHalvesSendStillCountAsSendingCodes() {
        let literal = LayoutKey(label: "，", action: LayoutAction(.literal, value: "，"))
        let layout = LayoutDefinition(
            id: "x", name: "x", input: .init(builtinLayout: .qwerty26),
            rows: [LayoutRow(keys: [literal, literal])],
            split: LayoutSplitConfiguration(
                activation: .always,
                halves: [LayoutSplitRow(left: [letter("a")], right: [letter("b")])]))
        XCTAssertTrue(layout.sendsEngineCode)
        XCTAssertTrue(layout.effectiveCandidateArea.candidates)
        let without = LayoutDefinition(
            id: "x", name: "x", input: .init(builtinLayout: .qwerty26), rows: [LayoutRow(keys: [literal, literal])])
        XCTAssertFalse(without.sendsEngineCode)
    }

    func testTheHalvesSpendTheKeyBudgetLikeRows() {
        let many = (0..<(LayoutResourceBudget.keysPerRegion + 1)).map { _ in letter("a") }
        let layout = BuiltinLayouts.qwerty26.settingSplit(
            LayoutSplitConfiguration(
                activation: .always,
                halves: BuiltinLayouts.qwerty26.rows.map { _ in LayoutSplitRow(left: many, right: [letter("a")]) }))
        XCTAssertThrowsError(try layout.validate())
    }

    // MARK: The letters page

    func testTheLettersPageCarriesShiftDeleteAndTheFooterPerHalf() throws {
        let layout = duplicated()
        let halves = try XCTUnwrap(layout.split?.halves)
        let arrangement = try XCTUnwrap(
            SplitLetterPage.arrangement(halves: halves, mainRowCount: 3, hasControlRow: true, shell: .qwerty))
        XCTAssertEqual(arrangement.rows.count, 3)
        let last = arrangement.rows[2]
        XCTAssertEqual(last.left.first?.action.type, .shift)
        XCTAssertEqual(last.right.last?.action.type, .backspace)
        XCTAssertEqual(text(Array(last.left.dropFirst())), "zxcv")
        XCTAssertEqual(text(Array(last.right.dropLast())), "vbnm")
        // The first rows are the author's halves, untouched.
        XCTAssertEqual(Array(arrangement.rows.prefix(2)), Array(halves.prefix(2)))
        let footer = try XCTUnwrap(arrangement.footer)
        XCTAssertEqual(footer.left.last?.action.type, .space)
        XCTAssertEqual(footer.right.first?.action.type, .space)
        XCTAssertEqual(footer, halves[3])
        // Drawn columns equal the arrangement: each row's keys are left + right.
        XCTAssertEqual(arrangement.rows.map { $0.left.count + $0.right.count }, [11, 10, 10])
    }

    func testShiftAndDeleteAreNotAddedWhereTheRowAlreadyHasThem() throws {
        var halves = try XCTUnwrap(duplicated().split?.halves)
        halves[2].left.insert(SplitLetterPage.shiftKey, at: 0)
        halves[2].right.append(SplitLetterPage.deleteKey)
        let arrangement = try XCTUnwrap(
            SplitLetterPage.arrangement(halves: halves, mainRowCount: 3, hasControlRow: true, shell: .qwerty))
        XCTAssertEqual(arrangement.rows[2], halves[2])
        let declared = try XCTUnwrap(
            SplitLetterPage.arrangement(
                halves: try XCTUnwrap(duplicated().split?.halves), mainRowCount: 3, hasControlRow: true,
                shell: .declared))
        XCTAssertEqual(declared.rows[2].left.first?.label, "z")
        XCTAssertNil(
            SplitLetterPage.arrangement(halves: halves, mainRowCount: 2, hasControlRow: true, shell: .qwerty))
    }

    func testTheFooterHalvesJoinBackIntoOneSpaceBar() throws {
        let halves = try XCTUnwrap(duplicated().split?.halves)
        let whole = BuiltinLayouts.qwerty26.rows.last
        XCTAssertEqual(halves[3].wholeKeys, whole?.keys)
    }
}
