import XCTest

@testable import LayoutKit

final class SystemSwitchKeyTests: XCTestCase {
    private func key(_ type: LayoutAction.Kind, width: Double? = nil) -> LayoutKey {
        LayoutKey(label: type.rawValue, width: width, action: LayoutAction(type))
    }

    func testGlobeWidthGoesToReturnWhenRowHasSpace() {
        let row = [key(.globe), key(.pageSwitch), key(.space, width: 4), key(.enter, width: 1.5)]
        let shown = row.forSystemSwitch(shown: false)
        XCTAssertEqual(shown.map(\.action.type), [.pageSwitch, .space, .enter])
        XCTAssertEqual(shown.map(\.widthWeight), [1, 4, 2.5])
    }

    func testRowWithoutGlobeIsUnchanged() {
        let row = [key(.pageSwitch), key(.space, width: 4), key(.enter, width: 1.5)]
        XCTAssertEqual(row.forSystemSwitch(shown: false), row)
    }

    func testRowWithoutSpaceOnlyLosesGlobe() {
        let row = [key(.globe, width: 2), key(.pageSwitch), key(.enter, width: 1.5)]
        let shown = row.forSystemSwitch(shown: false)
        XCTAssertEqual(shown.map(\.action.type), [.pageSwitch, .enter])
        XCTAssertEqual(shown.map(\.widthWeight), [1, 1.5])
    }

    /// Every default footer reads `123 中/英 🌐 空格 ， 换行` with the system's globe and
    /// `123 中/英 ， 空格 。 换行` without it; no other key moves.
    func testDefaultFootersTradeTheGlobeForTheCommaAndTheCommaForTheFullStop() throws {
        for page in [
            KeyboardPagePresets.englishQwerty, KeyboardPagePresets.numericRowsPage(ascii: false),
            KeyboardPagePresets.symbolRowsPage(ascii: false),
        ] {
            let row = try XCTUnwrap(page.materialized().chrome?.bottom)
            XCTAssertEqual(row.forSystemSwitch(shown: true), row)
            XCTAssertEqual(row.map(\.action.type), [.pageSwitch, .languageSwitch, .globe, .space, .literal, .enter])
            XCTAssertEqual(row[4].action.value, "，")

            let shown = row.forSystemSwitch(shown: false)
            XCTAssertEqual(
                shown.map(\.action.type), [.pageSwitch, .languageSwitch, .literal, .space, .literal, .enter])
            XCTAssertEqual(shown[2].action.value, "，")
            XCTAssertEqual(shown[2].action.asciiValue, ",")
            XCTAssertEqual(shown[4].action.value, "。")
            XCTAssertEqual(shown[4].action.asciiValue, ".")
            XCTAssertEqual(shown.map(\.width), row.map(\.width), "no key changes width")
            XCTAssertEqual(row.systemSwitchSources(shown: false), [0, 1, 2, 3, 4, 5])
        }
        // An automatic symbol page keeps 更多 right of the space bar.
        let symbols = try XCTUnwrap(KeyboardPagePresets.symbolsSystem.materialized().chrome?.bottom)
        let shown = symbols.forSystemSwitch(shown: false)
        XCTAssertEqual(shown[2].action.value, "，")
        XCTAssertEqual(shown[4].action.type, .symbolLibrary)
    }

    /// A globe away from the space bar has no comma to stand for: it is just left out.
    func testAGlobeAwayFromTheSpaceBarIsLeftOut() {
        let row = [key(.pageSwitch), key(.globe), key(.languageSwitch), key(.space, width: 4), key(.enter)]
        XCTAssertEqual(
            row.forSystemSwitch(shown: false).map(\.action.type), [.pageSwitch, .languageSwitch, .space, .enter])
        XCTAssertEqual(row.systemSwitchSources(shown: false), [0, 2, 3, 4])
    }

    private func comma() -> LayoutKey { LayoutKey(label: "，", action: LayoutAction(.literal, value: "，")) }

    func testOnlyTheLastGlobeKeyIsKept() {
        XCTAssertTrue([comma(), key(.globe), key(.space)].isLastGlobe(key(.globe)))
        XCTAssertFalse([key(.globe), comma(), key(.globe)].isLastGlobe(key(.globe)))
        XCTAssertFalse([comma(), key(.globe)].isLastGlobe(comma()))
    }

    /// Where the system draws its own switch key, the editor opens the default row with no globe:
    /// the comma and full stop are ordinary keys, and saving it unchanged still follows the keyboard.
    func testADeviceWithoutAGlobeEditsTheRowItShows() throws {
        let base = LayoutBottomRow.editable(BuiltinLayouts.qwerty26.copy())
        let layout = base.forSystemSwitch(shown: false)
        let row = try XCTUnwrap(layout.rows.last?.keys)
        XCTAssertFalse(row.contains { $0.action.type == .globe })
        XCTAssertEqual(row.map(\.action.type), [.pageSwitch, .languageSwitch, .literal, .space, .literal, .enter])
        XCTAssertEqual([row[2].action.value, row[4].action.value], ["，", "。"])
        XCTAssertEqual(LayoutBottomRow.storable(layout), LayoutBottomRow.storable(base))

        // The split view's own copy of the keys opens in the same shape.
        var cutting = base.split ?? LayoutSplitConfiguration(activation: .off)
        cutting.halves = base.splitArrangement()
        let split = base.settingSplit(cutting).forSystemSwitch(shown: false)
        let footer = try XCTUnwrap(split.split?.halves?.last)
        XCTAssertFalse((footer.left + footer.right).contains { $0.action.type == .globe })
        XCTAssertEqual(
            (footer.left + footer.right).compactMap(\.action.value).filter { $0 == "，" || $0 == "。" }, ["，", "。"])

        let page = KeyboardPagePresets.symbolRowsPage(ascii: false).materialized().forSystemSwitch(shown: false)
        XCTAssertFalse(page.hasInputModeSwitchKey)
        XCTAssertEqual(page.chrome?.bottom[2].action.value, "，")
        XCTAssertEqual(page.chrome?.bottom[4].action.value, "。")
    }
}
