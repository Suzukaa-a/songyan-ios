import XCTest

@testable import LayoutKit

final class AutomaticFooterWidthTests: XCTestCase {
    private func policy(globe: Bool = true, sideMarks: Bool = false) -> KeyboardControlPolicy {
        KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: globe,
            isPhoneLayout: false, usesASCIIPunctuation: false, showsSpaceSideMarks: sideMarks)
    }

    private var main: [LayoutKey] {
        [
            LayoutKey(label: "符", action: .pageSwitch(.symbols)),
            LayoutKey(label: "地球", action: .init(.globe)),
            LayoutKey(label: "123", action: .pageSwitch(.numeric)),
            LayoutKey(label: "空格", width: 4, action: .init(.space)),
            LayoutKey(label: "中/英", action: .init(.languageSwitch)),
            LayoutKey(label: "搜索", action: .init(.enter)),
        ]
    }

    private var abc: [LayoutKey] {
        var keys = main
        keys[1] = main[2]
        keys[2] = LayoutKey(label: ",", action: .init(.literal, value: ","))
        return keys
    }

    func testMainAndABCKeepEveryKeyBoundaryWhenGlobeIsReplaced() {
        for width in [320.0, 382, 443, 600, 834] {
            let chinese = KeyboardPageFooterGeometry(width: width, keys: main, policy: policy(sideMarks: true))
            let english = KeyboardPageFooterGeometry(width: width, keys: abc, policy: policy())
            XCTAssertTrue(chinese.usesControlRowBudget)
            XCTAssertTrue(english.usesControlRowBudget)
            XCTAssertEqual(chinese.keyWidths, english.keyWidths, "width \(width)")
            XCTAssertEqual(chinese.keyWidths[0], chinese.keyWidths[1])
            XCTAssertEqual(chinese.keyWidths[1], chinese.keyWidths[2])
            XCTAssertEqual(chinese.keyWidths[2], chinese.keyWidths[4])
            XCTAssertGreaterThanOrEqual(chinese.keyWidths[5], 60)
            XCTAssertEqual(chinese.keyWidths.reduce(0, +) + chinese.spacing * 5, width, accuracy: 0.001)
        }
    }

    func testAddingOrRemovingAKeyChangesSpaceBeforeTheOtherKeys() {
        let baseline = KeyboardPageFooterGeometry(width: 443, keys: main, policy: policy())
        var added = main
        added.insert(LayoutKey(label: ".", action: .init(.literal, value: ".")), at: 3)
        let expanded = KeyboardPageFooterGeometry(width: 443, keys: added, policy: policy())
        XCTAssertEqual(Array(expanded.keyWidths.prefix(3)), Array(baseline.keyWidths.prefix(3)))
        XCTAssertEqual(Array(expanded.keyWidths.suffix(2)), Array(baseline.keyWidths.suffix(2)))
        XCTAssertEqual(expanded.keyWidths[4] + expanded.keyWidths[3] + expanded.spacing, baseline.keyWidths[3])

        let removed = KeyboardPageFooterGeometry(width: 443, keys: Array(main.dropFirst()), policy: policy())
        XCTAssertEqual(Array(removed.keyWidths.suffix(2)), Array(baseline.keyWidths.suffix(2)))
        XCTAssertEqual(removed.keyWidths[2], baseline.keyWidths[3] + baseline.keyWidths[0] + baseline.spacing)
    }

    func testAutomaticSpaceAndUnrelatedPresentationFlagsDoNotChangeWidths() {
        let baseline = KeyboardPageFooterGeometry(width: 443, keys: main, policy: policy(sideMarks: true))
        var keys = abc
        keys[3] = keys[3].settingWidth(nil)
        let changed = KeyboardPageFooterGeometry(width: 443, keys: keys, policy: policy(globe: false))
        XCTAssertEqual(changed.keyWidths, baseline.keyWidths)
    }

    func testManualWidthStillUsesTheAuthoredRatio() {
        var keys = abc
        keys[0] = keys[0].settingWidth(2)
        // All keys exceed the touch minimum, so none needs to borrow room from its neighbours.
        let geometry = KeyboardPageFooterGeometry(width: 600, keys: keys, policy: policy())
        XCTAssertFalse(geometry.usesControlRowBudget)
        XCTAssertEqual(geometry.keyWidths[0], geometry.keyWidths[1] * 2, accuracy: 0.001)
        XCTAssertEqual(geometry.keyWidths[3], geometry.keyWidths[1] * 4, accuracy: 0.001)
    }

    func testHiddenGlobeDoesNotTurnAutomaticReturnIntoAManualWidth() {
        let visible = main.forSystemSwitch(shown: false)
        XCTAssertNil(visible.last?.width)
        let geometry = KeyboardPageFooterGeometry(width: 443, keys: visible, policy: policy(globe: false))
        let authored = KeyboardPageFooterGeometry(
            width: 443, keys: main.filter { $0.action.type != .globe }, policy: policy())
        XCTAssertEqual(geometry.keyWidths, authored.keyWidths)
        XCTAssertTrue(geometry.usesControlRowBudget)
    }

    func testCrowdedAutomaticRowsScrollWithoutShrinkingTouchTargets() {
        var keys = abc
        keys.insert(contentsOf: [abc[2], abc[2]], at: 3)
        let geometry = KeyboardPageFooterGeometry(width: 320, keys: keys, policy: policy())
        XCTAssertTrue(geometry.usesControlRowBudget)
        XCTAssertTrue(geometry.keyWidths.allSatisfy { $0 >= 44 })
        XCTAssertGreaterThanOrEqual(geometry.keyWidths.last ?? 0, 60)
        XCTAssertEqual(geometry.scrollWidths(availableWidth: 320), geometry.keyWidths)
        let regular = KeyboardPageFooterGeometry(width: 443, keys: abc, policy: policy())
        XCTAssertNil(regular.scrollWidths(availableWidth: 443))
    }
}
