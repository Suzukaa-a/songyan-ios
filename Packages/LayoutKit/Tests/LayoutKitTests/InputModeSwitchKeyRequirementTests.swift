import XCTest

@testable import LayoutKit

/// Entry-context rule for the system input-mode switch key. The rule is opt-in data validation: a
/// host that needs the switch key must save/import main layouts that offer one. Auxiliary pages
/// are valid with or without it, and an old catalog stays readable everywhere else.
final class InputModeSwitchKeyRequirementTests: XCTestCase {
    private let globe = LayoutKey(label: "🌐", action: .init(.globe))
    private let letter = LayoutKey(label: "q", action: .init(.literal, value: "q"))

    private func layout(
        rows: [LayoutRow], auxiliaryAreas: [LayoutAuxiliaryArea]? = nil
    ) -> LayoutDefinition {
        LayoutDefinition(
            id: "test.layout", name: "测试布局", input: .init(builtinLayout: .qwerty26),
            rows: rows, auxiliaryAreas: auxiliaryAreas)
    }

    private var letterRows: [LayoutRow] {
        [LayoutRow(keys: (0..<10).map { _ in letter })]
    }

    // MARK: - Main layouts

    func testMainLayoutWithoutAGlobeFailsOnlyWhenRequired() throws {
        let definition = layout(rows: letterRows)
        XCTAssertFalse(definition.hasInputModeSwitchKey)
        XCTAssertThrowsError(try definition.validateRequiredInputModeSwitchKey(true))
        XCTAssertNoThrow(try definition.validateRequiredInputModeSwitchKey(false))
    }

    func testMainLayoutChecksPrimaryGlobeActionsOnly() throws {
        let withGlobe = layout(rows: letterRows + [LayoutRow(keys: [globe])])
        XCTAssertTrue(withGlobe.hasInputModeSwitchKey)
        XCTAssertNoThrow(try withGlobe.validateRequiredInputModeSwitchKey(true))

        let fakeGlyph = layout(
            rows: [LayoutRow(keys: [LayoutKey(label: "🌐", action: .init(.space))])])
        XCTAssertFalse(fakeGlyph.hasInputModeSwitchKey, "a label that looks like the globe is not an entry")

        let longPressOnly = layout(
            rows: [
                LayoutRow(keys: [
                    LayoutKey(
                        label: "空格", action: .init(.space),
                        longPress: [LayoutOption(label: "🌐", action: .init(.globe))])
                ])
            ])
        XCTAssertFalse(longPressOnly.hasInputModeSwitchKey, "a long-press alternate is not the switch key")
    }

    func testHiddenDisambiguationAreaIsNotAnEntryButVisibleAuxiliaryIs() throws {
        let hidden = layout(
            rows: letterRows,
            auxiliaryAreas: [.init(position: .leading, role: .disambiguation, keys: [globe])])
        XCTAssertFalse(hidden.hasInputModeSwitchKey)
        XCTAssertThrowsError(try hidden.validateRequiredInputModeSwitchKey(true))

        let visible = layout(
            rows: letterRows,
            auxiliaryAreas: [.init(position: .trailing, role: .editing, keys: [globe])])
        XCTAssertTrue(visible.hasInputModeSwitchKey)
    }

    // MARK: - Pages

    func testNativeControlsAndOptionalAuthoredGlobeDetection() throws {
        XCTAssertTrue(KeyboardPagePresets.englishQwerty.hasInputModeSwitchKey)
        XCTAssertTrue(KeyboardPagePresets.numericAutomatic.hasInputModeSwitchKey)

        var materialized = KeyboardPagePresets.englishQwerty.materialized()
        XCTAssertTrue(materialized.hasInputModeSwitchKey)
        XCTAssertNoThrow(try materialized.validate())

        var materializedBottom = materialized.chrome?.bottom ?? []
        materializedBottom.removeAll { $0.action.type == .globe }
        materialized.chrome?.bottom = materializedBottom
        XCTAssertFalse(materialized.hasInputModeSwitchKey)
        XCTAssertNoThrow(try materialized.validate())

        // A real globe anywhere renderable counts again.
        materialized.rows[0] = LayoutRow(keys: materialized.rows[0].keys + [globe])
        XCTAssertTrue(materialized.hasInputModeSwitchKey)
    }

    func testPageFakeGlyphOrLongPressGlobeDoesNotCount() throws {
        var page = KeyboardPagePresets.numericRowsPage(ascii: false).materialized()
        var bottom = page.chrome?.bottom ?? []
        bottom[1] = LayoutKey(label: "🌐", action: .init(.space))
        bottom[0] = bottom[0].settingLongPress([LayoutOption(label: "🌐", action: .init(.globe))])
        page.chrome?.bottom = bottom
        XCTAssertFalse(page.hasInputModeSwitchKey)
        XCTAssertNoThrow(try page.validate())
    }

    func testCategorizedPageOnlyCountsThePermanentFunctionArea() throws {
        XCTAssertTrue(
            KeyboardPagePresets.symbolsCategorized.hasInputModeSwitchKey,
            "a categorized page on native controls draws the built-in globe")

        var page = KeyboardPagePresets.symbolsCategorized
        page.categories = [
            KeyboardPageCategory(id: "c", name: "常用", keys: [globe])
        ]
        page.rows = [LayoutRow(keys: [globe])]
        let materialized = page.materialized()
        XCTAssertTrue(materialized.hasInputModeSwitchKey, "the authored default footer carries the globe")

        var withoutFixedGlobe = materialized
        var fixedBottom = withoutFixedGlobe.chrome?.bottom ?? []
        fixedBottom.removeAll { $0.action.type == .globe }
        withoutFixedGlobe.chrome?.bottom = fixedBottom
        XCTAssertFalse(
            withoutFixedGlobe.hasInputModeSwitchKey,
            "a category's own globe is not permanent: switching categories would drop it")

        withoutFixedGlobe.categories = [KeyboardPageCategory(id: "c", name: "常用", keys: [globe])]
        withoutFixedGlobe.rows = [LayoutRow(keys: [globe])]
        XCTAssertFalse(
            withoutFixedGlobe.hasInputModeSwitchKey,
            "hidden rows and category content never substitute for the permanent area")
        XCTAssertNoThrow(try withoutFixedGlobe.validate())

        withoutFixedGlobe.categories?.append(
            KeyboardPageCategory(id: "recent", name: "最近", keys: [globe], source: .recent))
        XCTAssertFalse(withoutFixedGlobe.hasInputModeSwitchKey)
    }

    func testAllAuxiliaryPagesCanRoundTripWithoutAGlobeAndRemainAuthored() throws {
        for page in KeyboardPagePresets.all {
            var authored = page.materialized()
            authored.chrome?.bottom.removeAll { $0.action.type == .globe }
            XCTAssertFalse(authored.hasInputModeSwitchKey, page.id)
            XCTAssertNoThrow(try authored.validate(), page.id)
            let decoded = try JSONDecoder().decode(KeyboardPageDefinition.self, from: JSONEncoder().encode(authored))
            XCTAssertEqual(decoded, authored)
            let resolution = KeyboardPageResolver.resolve(
                page: decoded, kind: decoded.kind,
                input: .init(usesASCIIPunctuation: false, mainLayoutIsPhoneKeypad: false))
            XCTAssertEqual(resolution.page, decoded, page.id)
        }
    }

    func testRequiredFalseNeverThrowsForMainLayouts() {
        for definition in BuiltinLayouts.all {
            XCTAssertNoThrow(try definition.validateRequiredInputModeSwitchKey(false))
        }
        let bare = layout(rows: letterRows)
        XCTAssertNoThrow(try bare.validateRequiredInputModeSwitchKey(false))
    }
}
