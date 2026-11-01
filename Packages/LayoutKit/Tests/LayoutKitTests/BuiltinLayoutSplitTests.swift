import XCTest

@testable import LayoutKit

/// Default split of the merged letter pads: wide surfaces only, while saved layouts (including
/// an explicit off and a custom break) stay exactly as the author stored them.
final class BuiltinLayoutSplitTests: XCTestCase {
    func testMergedLayoutsSplitByDefaultOnlyOnWideSurfaces() throws {
        for layout in [BuiltinLayouts.merged14, BuiltinLayouts.merged18] {
            let split = try XCTUnwrap(layout.split, layout.id)
            XCTAssertEqual(split.activation, .automatic)
            XCTAssertNoThrow(try layout.validate())

            for width in [0.0, 320, 466, KeyboardSurfaceWidth.phoneMaximum] {
                XCTAssertFalse(split.isActive(width: width), "\(layout.id) at \(width)")
                XCTAssertNil(split.resolved(forWidth: width))
            }
            for width in [601.0, 834, 1024, 1366] {
                XCTAssertTrue(split.isActive(width: width), "\(layout.id) at \(width)")
                let resolved = try XCTUnwrap(split.resolved(forWidth: width))
                XCTAssertEqual(resolved.breakIndex(row: 0, keyCount: 5), 3)
                XCTAssertGreaterThan(resolved.gap(width: width, keyCount: 5), 0)
            }
        }
    }

    /// The bundled definitions stay as they are (copies and encoded documents must not carry the
    /// hand cuts); the cuts are applied when the page is rendered.
    func testBundledDefinitionsCarryNoHandCuts() {
        XCTAssertNil(BuiltinLayouts.qwerty26.split)
        XCTAssertNil(BuiltinLayouts.phone9.split)
        XCTAssertEqual(BuiltinLayouts.merged18.split, LayoutSplitConfiguration())
        XCTAssertEqual(BuiltinLayouts.merged14.split, LayoutSplitConfiguration())
    }

    func testHandCutsApplyToTheUneditedBundled26And18KeyLayoutsOnly() throws {
        let qwerty = try XCTUnwrap(BuiltinLayouts.handSplit(for: BuiltinLayouts.qwerty26))
        XCTAssertEqual(qwerty.activation, .off, "26 keys stays whole until splitting is turned on")
        XCTAssertEqual(qwerty.rowBreaks, [5, 5, 5])
        XCTAssertNil(qwerty.resolved(forWidth: 1366))
        let merged = try XCTUnwrap(BuiltinLayouts.handSplit(for: BuiltinLayouts.merged18))
        XCTAssertEqual(merged.activation, .automatic)
        XCTAssertEqual(merged.rowBreaks, [3, 3, 4])
        XCTAssertEqual(merged.gapFraction, LayoutSplitConfiguration.defaultGapFraction)
        XCTAssertTrue(merged.automaticGap)
        XCTAssertNil(BuiltinLayouts.handSplit(for: BuiltinLayouts.merged14))
        XCTAssertNil(BuiltinLayouts.handSplit(for: BuiltinLayouts.phone9))
        // An edited key set, or a split with saved cuts, passes through untouched.
        var edited = BuiltinLayouts.qwerty26
        edited.rows.removeLast()
        XCTAssertNil(BuiltinLayouts.handSplit(for: edited))
        let saved = LayoutSplitConfiguration(activation: .always, rowBreaks: [4, 4, 4])
        XCTAssertNil(BuiltinLayouts.handSplit(for: BuiltinLayouts.qwerty26.settingSplit(saved)))
        // A saved split without cuts keeps its own activation and spacing.
        let always = LayoutSplitConfiguration(activation: .always)
        let kept = try XCTUnwrap(BuiltinLayouts.handSplit(for: BuiltinLayouts.qwerty26.settingSplit(always)))
        XCTAssertEqual(kept.activation, .always)
        XCTAssertEqual(kept.rowBreaks, [5, 5, 5])
    }

    /// The editor writes no cuts when splitting is turned on, so the keyboard keeps drawing the hand
    /// cuts; the cuts it shows are the same ones, and the steppers' saved cuts win.
    func testTurningSplittingOnKeepsTheHandCuts() throws {
        for (layout, cuts, middle) in [
            (BuiltinLayouts.qwerty26, [5, 5, 5], [5, 5, 4]), (BuiltinLayouts.merged18, [3, 3, 4], [4, 3, 3]),
        ] {
            let toggled = layout.settingSplit(LayoutSplitConfiguration(activation: .automatic))
            let split = try XCTUnwrap(BuiltinLayouts.handSplit(for: toggled), layout.id)
            XCTAssertEqual(split.rowBreaks, cuts)
            XCTAssertEqual(split.activation, .automatic)
            let counts = layout.rows.prefix(3).map { $0.keys.count }
            let untouched = try XCTUnwrap(toggled.split)
            XCTAssertEqual(untouched.cutPositions(rowKeyCounts: counts, defaults: cuts), cuts)
            XCTAssertEqual(untouched.cutPositions(rowKeyCounts: counts, defaults: nil), middle)
            var saved = untouched
            saved.rowBreaks = [2, 2, 2]
            XCTAssertEqual(saved.cutPositions(rowKeyCounts: counts, defaults: cuts), [2, 2, 2])
            XCTAssertNil(BuiltinLayouts.handSplit(for: layout.settingSplit(saved)))
        }
    }

    /// A copy that changed anything but its split is the user's own layout.
    func testARenamedOrEditedCopyGetsNoHandCuts() {
        XCTAssertNil(BuiltinLayouts.handSplit(for: BuiltinLayouts.qwerty26.renamed("我的 26 键")))
        XCTAssertNil(BuiltinLayouts.handSplit(for: BuiltinLayouts.merged18.copy()))
    }

    func testTheEnglishPageKeepsInheritedCutsWhenAnAuthoredPageShows() throws {
        let main = try XCTUnwrap(BuiltinLayouts.handSplit(for: BuiltinLayouts.merged18))
        let nonStandard = KeyboardPageDefinition(
            id: "page.test.rows", name: "测试", kind: .english,
            rows: KeyboardPagePresets.englishQwerty.rows.dropLast().map { $0 })
        func drawn(authored: Bool, pageSplit: LayoutSplitConfiguration? = nil) -> ActiveLayoutSplit? {
            ActiveLayoutSplit.drawn(
                main: main, mainWidth: 1024, showsMainLetters: false, showsEnglishLetters: true,
                authoredPage: authored ? nonStandard : nil, pageSplit: pageSplit, contentWidth: 1024)
        }
        XCTAssertEqual(drawn(authored: false)?.rowBreaks, [5, 5, 5])
        XCTAssertEqual(drawn(authored: true)?.rowBreaks, [])
        let own = LayoutSplitConfiguration(activation: .always, rowBreaks: [4, 4, 4])
        XCTAssertEqual(drawn(authored: false, pageSplit: own)?.rowBreaks, [4, 4, 4])
        // The main letters take the main split as it is.
        XCTAssertEqual(
            ActiveLayoutSplit.drawn(
                main: main, mainWidth: 1024, showsMainLetters: true, showsEnglishLetters: false,
                authoredPage: nil, pageSplit: nil, contentWidth: 1024)?.rowBreaks, [3, 3, 4])
    }

    /// The preset English page draws like the built-in letters, so it keeps the hand cuts; a page of
    /// other rows, or one with chrome (Shift and Delete are keys there), keeps the inherited cuts.
    func testThePresetEnglishPageKeepsTheHandCutsButOtherAuthoredPagesDoNot() throws {
        let main = try XCTUnwrap(BuiltinLayouts.handSplit(for: BuiltinLayouts.merged18))
        func drawn(_ page: KeyboardPageDefinition) -> [Int]? {
            ActiveLayoutSplit.drawn(
                main: main, mainWidth: 1024, showsMainLetters: false, showsEnglishLetters: true,
                authoredPage: page, pageSplit: page.split, contentWidth: 1024)?.rowBreaks
        }
        XCTAssertEqual(drawn(KeyboardPagePresets.englishQwerty), [5, 5, 5])
        var shortRows = KeyboardPagePresets.englishQwerty
        shortRows.rows.removeLast()
        XCTAssertEqual(drawn(shortRows), [])
        var withChrome = KeyboardPagePresets.englishQwerty
        withChrome.chrome = KeyboardPageChrome(bottom: [])
        XCTAssertEqual(drawn(withChrome), [])
    }

    /// The page preview resolves the English page through the same rule with the layout's hand
    /// cuts as the inherited split, so it shows what the keyboard draws.
    func testThePreviewOfThePresetEnglishPageShowsTheHandCutsOnBothBundledLayouts() throws {
        let on = LayoutSplitConfiguration(activation: .always)
        for layout in [BuiltinLayouts.qwerty26.settingSplit(on), BuiltinLayouts.merged18.settingSplit(on)] {
            let inherited = try XCTUnwrap(BuiltinLayouts.handSplit(for: layout), layout.id)
            let drawn = ActiveLayoutSplit.drawn(
                main: inherited, mainWidth: 1024, showsMainLetters: false, showsEnglishLetters: true,
                authoredPage: KeyboardPagePresets.englishQwerty, pageSplit: nil, contentWidth: 1024)
            XCTAssertEqual(drawn?.rowBreaks, [5, 5, 5], layout.id)
        }
    }

    /// A saved copy keeps the cuts the editor showed; a changed note on the bundled layout would
    /// not drop them.
    func testACopyKeepsTheShownHandCuts() throws {
        for (layout, cuts) in [(BuiltinLayouts.qwerty26, [5, 5, 5]), (BuiltinLayouts.merged18, [3, 3, 4])] {
            let draft = layout.settingSplit(LayoutSplitConfiguration(activation: .automatic))
            let copy = BuiltinLayouts.persistingHandCuts(in: draft).copy()
            XCTAssertEqual(copy.split?.rowBreaks, cuts, layout.id)
            XCTAssertEqual(copy.split?.activation, .automatic)
            XCTAssertNil(BuiltinLayouts.handSplit(for: copy), "the copy now has saved cuts")
            XCTAssertNoThrow(try copy.validate())
        }
        let plain = BuiltinLayouts.phone9
        XCTAssertEqual(BuiltinLayouts.persistingHandCuts(in: plain), plain)
        let renamedNote = LayoutDefinition(
            id: "qwerty26", name: "26 键", input: BuiltinLayouts.qwerty26.input,
            rows: BuiltinLayouts.qwerty26.rows, note: "另一句说明")
        XCTAssertEqual(BuiltinLayouts.handSplit(for: renamedNote)?.rowBreaks, [5, 5, 5])
    }

    /// The letters left of the cut in each letter row, for a split active at a wide width.
    private func leftLetters(_ rows: [[String]], _ split: ActiveLayoutSplit) -> [String] {
        rows.enumerated().map { index, row in
            row.prefix(split.breakIndex(row: index, keyCount: row.count)).joined().lowercased()
        }
    }

    func testTwentySixKeysPutFiveLettersOfEveryRowOnTheLeft() throws {
        var split = try XCTUnwrap(BuiltinLayouts.handSplit(for: BuiltinLayouts.qwerty26))
        split.activation = .always
        let rows = BuiltinLayouts.qwerty26.rows.prefix(3).map { $0.keys.map(\.label) }
        XCTAssertEqual(leftLetters(rows, try XCTUnwrap(split.resolved(forWidth: 1024))), ["qwert", "asdfg", "zxcvb"])
        // The English page is the same rows whatever the main layout's own cuts.
        let merged = try XCTUnwrap(BuiltinLayouts.handSplit(for: BuiltinLayouts.merged18)?.resolved(forWidth: 1024))
        XCTAssertEqual(leftLetters(rows, merged.forStandardLetterRows), ["qwert", "asdfg", "zxcvb"])
        XCTAssertEqual(merged.forStandardLetterRows.gapFraction, merged.gapFraction)
    }

    func testEighteenKeysPutThreeThreeAndFourKeysOnTheLeft() throws {
        let split = try XCTUnwrap(BuiltinLayouts.handSplit(for: BuiltinLayouts.merged18)?.resolved(forWidth: 1024))
        let rows = BuiltinLayouts.merged18.rows.prefix(3).map { $0.keys.map(\.label) }
        XCTAssertEqual(leftLetters(rows, split), ["qwert", "asdfg", "zxcvbn"])
    }

    func testSavedExplicitOffOverridesTheBuiltinDefault() throws {
        let off = LayoutSplitConfiguration(activation: .off)
        let saved = BuiltinLayouts.merged14.settingSplit(off)
        let storedSplit = try XCTUnwrap(saved.split)
        XCTAssertFalse(storedSplit.isActive(width: 1366))
        XCTAssertNil(storedSplit.resolved(forWidth: 1366))

        // A stored catalog keeps the saved definition as-is; loading it must not turn the
        // builtin default back on.
        let registry = try LayoutRegistry(layouts: [
            saved, BuiltinLayouts.merged18, BuiltinLayouts.qwerty26, BuiltinLayouts.phone9,
        ])
        let decoded = try JSONDecoder().decode(LayoutRegistry.self, from: JSONEncoder().encode(registry))
        let restored = try XCTUnwrap(decoded.layout(id: "merged14"))
        XCTAssertEqual(restored.split, off)
    }

    func testSavedCustomSplitConfigurationRoundtripsUnchanged() throws {
        let custom = LayoutSplitConfiguration(rowBreaks: [2, 2, 1], gapFraction: 0.2)
        let saved = BuiltinLayouts.merged14.settingSplit(custom)
        let decoded = try LayoutDefinition.decode(try saved.encoded())
        XCTAssertEqual(decoded.split, custom)
        XCTAssertEqual(decoded.split?.rowBreaks, [2, 2, 1])
        XCTAssertEqual(decoded.split?.gapFraction, 0.2)
    }

    /// The letters each hand types on the three letter rows of a bundled layout, as the keyboard
    /// draws them with no saved cuts (the hand cuts of `BuiltinLayouts.handSplit`, else the
    /// middle). The Android app pins the same strings in `KeyboardSplitTest`, so both keyboards
    /// split every bundled layout alike.
    private func leftAndRightLetters(_ layout: LayoutDefinition) -> (left: [String], right: [String]) {
        let split = BuiltinLayouts.handSplit(for: layout) ?? layout.split ?? LayoutSplitConfiguration()
        let letterRows = layout.rows.filter { row in row.keys.allSatisfy { $0.action.type == .code } }
        let cuts = split.cutPositions(
            rowKeyCounts: letterRows.map(\.keys.count), defaults: BuiltinLayouts.handSplit(for: layout)?.rowBreaks)
        let rows = zip(letterRows, cuts).map { row, cut in
            (
                row.keys.prefix(cut).map(\.label).joined().lowercased(),
                row.keys.dropFirst(cut).map(\.label).joined().lowercased()
            )
        }
        return (rows.map(\.0), rows.map(\.1))
    }

    func testEveryBundledLetterLayoutSplitsWhereAndroidDoes() {
        let qwerty = leftAndRightLetters(BuiltinLayouts.qwerty26)
        XCTAssertEqual(qwerty.left, ["qwert", "asdfg", "zxcvb"])
        XCTAssertEqual(qwerty.right, ["yuiop", "hjkl", "nm"])
        let fourteen = leftAndRightLetters(BuiltinLayouts.merged14)
        XCTAssertEqual(fourteen.left, ["qwerty", "asdfgh", "zxcv"])
        XCTAssertEqual(fourteen.right, ["uiop", "jkl", "bnm"])
        let eighteen = leftAndRightLetters(BuiltinLayouts.merged18)
        XCTAssertEqual(eighteen.left, ["qwert", "asdfg", "zxcvbn"])
        XCTAssertEqual(eighteen.right, ["yuiop", "hjkl", "m"])
        // The phone pad has no letter rows and never splits.
        XCTAssertNil(BuiltinLayouts.phone9.split)
        XCTAssertNil(BuiltinLayouts.handSplit(for: BuiltinLayouts.phone9))
    }

    /// The footer's space bar is the same in both halves: one key per hand, cut where the bar is.
    func testTheControlRowCutsAtItsSpaceBar() {
        for layout in [BuiltinLayouts.qwerty26, BuiltinLayouts.merged14, BuiltinLayouts.merged18] {
            let controls = layout.rows.last!
            let cut = LayoutSplitConfiguration(activation: .always).cut(row: layout.rows.count - 1, keys: controls.keys)
            let space = cut.left.last
            XCTAssertEqual(space?.action.type, .space, layout.id)
            XCTAssertEqual(cut.right.first?.action.type, .space, layout.id)
            XCTAssertEqual(space?.widthWeight, cut.right.first?.widthWeight, layout.id)
        }
    }
}
