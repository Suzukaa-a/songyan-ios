import XCTest

@testable import LayoutKit

/// The bundled 9-key identities stay separate:
///  * chrome identity rejects every control-row/rail edit that the chrome would otherwise cover up
///    by drawing its own keys; main keys are drawn from the definition, so their edits keep it.
///  * the live first key also needs the first key's own preset face.
///  * primary-gesture semantics ignores main-row metadata so first-key cycling and digit up-flick
///    survive label/secondary/title edits, but never gates injected chrome. Control-row/rail
///    long-press edits also keep the gestures alive (only their non-LP fields must match).
final class Phone9SemanticsTests: XCTestCase {
    private var preset: LayoutDefinition { BuiltinLayouts.phone9 }

    private func clone(
        rows: [LayoutRow]? = nil, areas: [LayoutAuxiliaryArea]?? = nil,
        input: LayoutInput? = nil, behavior: T9FirstKeyBehavior? = nil
    ) -> LayoutDefinition {
        LayoutDefinition(
            id: "phone9-lp-clone", name: "9 键 LP 副本",
            input: input ?? preset.input, rows: rows ?? preset.rows,
            auxiliaryAreas: areas ?? preset.auxiliaryAreas, t9FirstKeyBehavior: behavior)
    }

    private func replacingKey(
        in rows: [LayoutRow], row: Int, key: Int, with transform: (LayoutKey) -> LayoutKey
    ) -> [LayoutRow] {
        var rows = rows
        let old = rows[row].keys[key]
        rows[row] = LayoutRow(
            keys: rows[row].keys.enumerated().map { index, value in
                index == key ? transform(old) : value
            })
        return rows
    }

    private func replacingAuxKey(
        in areas: [LayoutAuxiliaryArea], area: Int, key: Int, with transform: (LayoutKey) -> LayoutKey
    ) -> [LayoutAuxiliaryArea] {
        var areas = areas
        let old = areas[area].keys[key]
        areas[area] = LayoutAuxiliaryArea(
            position: areas[area].position, role: areas[area].role,
            keys: areas[area].keys.enumerated().map { index, value in
                index == key ? transform(old) : value
            })
        return areas
    }

    private func extraLongPress(_ key: LayoutKey) -> LayoutKey {
        key.settingLongPress(
            (key.longPress ?? []) + [LayoutOption(label: "#+=", action: .pageSwitch(.symbols))])
    }

    private func assertVisualOnlyIsBroken(
        _ definition: LayoutDefinition, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(
            BuiltinLayouts.matchesPhone9LiveFirstKey(definition), "the live first key must fall back",
            file: file, line: line)
    }

    // MARK: Pristine

    func testBundledPhone9MatchesBoth() {
        XCTAssertTrue(BuiltinLayouts.matchesPhone9LiveFirstKey(preset))
        XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(preset))
    }

    func testRenamedCloneMatchesBoth() {
        XCTAssertTrue(BuiltinLayouts.matchesPhone9LiveFirstKey(clone()))
        XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(clone()))
    }

    func testLegacyFirstKeyBehaviorUsesPrimarySemantics() throws {
        let changed = preset.replacingKey(
            at: .row(0, key: 0),
            with: preset.rows[0].keys[0].settingAction(.init(.literal, value: "!")))
        let bound = clone(input: .init(schemaID: "unknown_t9", builtinLayout: .phone9))
        for definition in [preset, clone(), changed, bound] {
            let decoded = try LayoutDefinition.decode(definition.encoded())
            XCTAssertNil(decoded.t9FirstKeyBehavior)
            XCTAssertEqual(
                BuiltinLayouts.usesPhone9QuickSymbols(decoded),
                BuiltinLayouts.matchesPhone9PrimarySemantics(definition))
        }
    }

    func testExplicitCustomCommaKeepsOrdinaryAction() {
        let custom = clone(behavior: .custom)
        XCTAssertEqual(custom.rows[0].keys[0].action, .init(.literal, value: "，"))
        XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(custom))
        XCTAssertFalse(BuiltinLayouts.usesPhone9QuickSymbols(custom))
        XCTAssertFalse(BuiltinLayouts.matchesPhone9LiveFirstKey(custom))
        XCTAssertTrue(BuiltinLayouts.matchesPhone9Chrome(custom))
    }

    func testExplicitQuickSymbolsOverridesLegacyInferenceOnlyForPhone9() {
        let changed = preset.replacingKey(
            at: .row(0, key: 0),
            with: preset.rows[0].keys[0].settingAction(.init(.literal, value: "!")))
        XCTAssertFalse(BuiltinLayouts.matchesPhone9PrimarySemantics(changed))
        XCTAssertTrue(BuiltinLayouts.usesPhone9QuickSymbols(changed.settingT9FirstKeyBehavior(.quickSymbols)))
        XCTAssertTrue(
            BuiltinLayouts.usesPhone9QuickSymbols(
                clone(input: .init(schemaID: "unknown_t9", builtinLayout: .phone9), behavior: .quickSymbols)))
        XCTAssertTrue(
            BuiltinLayouts.usesPhone9QuickSymbols(clone(input: .init(schemaID: "custom_t9"), behavior: .quickSymbols)))
        for definition in [BuiltinLayouts.qwerty26, BuiltinLayouts.merged14, BuiltinLayouts.merged18] {
            XCTAssertFalse(BuiltinLayouts.usesPhone9QuickSymbols(definition.settingT9FirstKeyBehavior(.quickSymbols)))
        }
    }

    func testFirstKeyBehaviorWireRoundTrip() throws {
        for (behavior, wire) in [(T9FirstKeyBehavior.quickSymbols, "quickSymbols"), (.custom, "custom")] {
            let definition = clone(behavior: behavior)
            let encoded = try definition.encoded()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(json["t9FirstKeyBehavior"] as? String, wire)
            XCTAssertEqual(try LayoutDefinition.decode(encoded), definition)
        }
    }

    func testFirstKeyBehaviorSurvivesValueEdits() {
        for behavior in [T9FirstKeyBehavior.quickSymbols, .custom] {
            let definition = clone(behavior: behavior)
            let key = definition.rows[0].keys[0].title("首键")
            let edited = [
                definition.copy(), definition.renamed("新名称"),
                definition.replacingKey(at: .row(0, key: 0), with: key),
                definition.replacingKey(at: .auxiliary(0, key: 0), with: key),
                definition.replacingRowsFollowingSplit(definition.rows),
                definition.settingSplit(.init(activation: .off)),
                definition.settingCandidateArea(.init(candidates: true, reading: false)),
            ]
            for result in edited {
                XCTAssertEqual(result.t9FirstKeyBehavior, behavior)
            }
            XCTAssertNil(definition.settingT9FirstKeyBehavior(nil).t9FirstKeyBehavior)
        }
    }

    func testQuickSymbolsWireRoundTrip() throws {
        for symbols: String? in [nil, "；：！", ""] {
            let definition = clone().settingT9QuickSymbols(symbols)
            let encoded = try definition.encoded()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(json["t9QuickSymbols"] as? String, symbols)
            let decoded = try LayoutDefinition.decode(encoded)
            XCTAssertEqual(decoded.t9QuickSymbols, symbols)
            XCTAssertEqual(decoded, definition)
        }
    }

    func testQuickSymbolsSurviveValueEdits() {
        for symbols in ["；：！", ""] {
            let definition = clone(behavior: .custom).settingT9QuickSymbols(symbols)
            let key = definition.rows[0].keys[0].title("首键")
            let edited = [
                definition.copy(), definition.renamed("新名称"),
                definition.replacingKey(at: .row(0, key: 0), with: key),
                definition.replacingKey(at: .auxiliary(0, key: 0), with: key),
                definition.replacingRowsFollowingSplit(definition.rows),
                definition.settingSplit(.init(activation: .off)),
                definition.settingCandidateArea(.init(candidates: true, reading: false)),
                definition.settingT9FirstKeyBehavior(.quickSymbols),
            ]
            for result in edited {
                XCTAssertEqual(result.t9QuickSymbols, symbols)
            }
            XCTAssertEqual(definition.t9FirstKeyBehavior, .custom)
            XCTAssertNil(definition.settingT9QuickSymbols(nil).t9QuickSymbols)
        }
    }

    func testEffectiveQuickSymbolsResolveInheritanceAndASCII() {
        XCTAssertEqual(
            Array(
                BuiltinLayouts.t9QuickSymbolValues(
                    for: clone(input: .init(schemaID: "custom_t9")).settingT9QuickSymbols("；：！"), inherited: "【】？",
                    ascii: true
                ).prefix(3)),
            [";", ":", "!"])
        for ascii in [false, true] {
            for symbols: String? in [nil, "；：！", ""] {
                let definition = clone().settingT9QuickSymbols(symbols)
                XCTAssertEqual(
                    BuiltinLayouts.t9QuickSymbolValues(for: definition, inherited: "【】？", ascii: ascii),
                    BuiltinLayouts.t9QuickSymbolValues(saved: symbols ?? "【】？", ascii: ascii))
            }
        }
        XCTAssertEqual(
            Array(
                BuiltinLayouts.t9QuickSymbolValues(
                    for: clone().settingT9QuickSymbols("；：！"), inherited: "【】？", ascii: true
                ).prefix(3)),
            [";", ":", "!"])
        for definition in [
            BuiltinLayouts.qwerty26, BuiltinLayouts.merged14, BuiltinLayouts.merged18,
        ] {
            XCTAssertEqual(
                BuiltinLayouts.t9QuickSymbolValues(
                    for: definition.settingT9QuickSymbols("；：！"), inherited: "【】？", ascii: false), [])
        }
    }

    func testQuickSymbolValidationRejectsInvalidAndDuplicateValues() throws {
        for layout in [BuiltinLayouts.qwerty26, BuiltinLayouts.merged14, BuiltinLayouts.merged18] {
            XCTAssertNoThrow(try layout.validate())
            for symbols in ["", "；：！"] {
                let invalid = layout.settingT9QuickSymbols(symbols)
                XCTAssertThrowsError(try invalid.validate())
                XCTAssertThrowsError(try LayoutDefinition.decode(JSONEncoder().encode(invalid)))
            }
            for behavior in [T9FirstKeyBehavior.quickSymbols, .custom] {
                let invalid = layout.settingT9FirstKeyBehavior(behavior)
                XCTAssertThrowsError(try invalid.validate())
                XCTAssertThrowsError(try LayoutDefinition.decode(JSONEncoder().encode(invalid)))
            }
        }
        let oversizedGrapheme = "a" + String(repeating: "\u{0301}", count: T9QuickSymbolStore.maximumFileBytes)
        for symbols in ["！！", "a b", "a\n", "a\u{0000}", "abcdefghijklm", oversizedGrapheme] {
            let definition = clone().settingT9QuickSymbols(symbols)
            XCTAssertThrowsError(try definition.validate())
            XCTAssertThrowsError(try definition.encoded())
            let encoded = try JSONEncoder().encode(definition)
            XCTAssertThrowsError(try LayoutDefinition.decode(encoded))
        }
        for symbols: String? in [nil, "", "；：！", "abcdefghijkl"] {
            XCTAssertNoThrow(try clone().settingT9QuickSymbols(symbols).validate())
        }
    }

    // MARK: Long-press edits on the rendered main rows

    func testFirstKeyAndDigitLongPressEditsKeepBoth() {
        var rows = replacingKey(in: preset.rows, row: 0, key: 0, with: extraLongPress)
        let digitRow = 1
        rows = replacingKey(in: rows, row: digitRow, key: 0) { key in
            key.settingLongPress([])
        }
        let edited = clone(rows: rows)
        XCTAssertTrue(BuiltinLayouts.matchesPhone9LiveFirstKey(edited))
        XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(edited))
    }

    // MARK: Main-row metadata

    func testFirstKeyLabelSecondaryTitleEditsKeepPrimaryOnly() {
        let label = clone(rows: replacingKey(in: preset.rows, row: 0, key: 0) { $0.title("RET") })
        let secondary = clone(
            rows: replacingKey(in: preset.rows, row: 0, key: 0) { $0.settingSecondaryLabel("x") })
        let title = clone(
            rows: replacingKey(in: preset.rows, row: 0, key: 0) { $0.settingTitleMode(.automatic) })
        for definition in [label, secondary, title] {
            assertVisualOnlyIsBroken(definition)
            XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(definition))
            XCTAssertTrue(BuiltinLayouts.matchesPhone9Chrome(definition))
        }
    }

    func testOtherKeyFaceEditsKeepTheLiveFirstKey() {
        let label = clone(rows: replacingKey(in: preset.rows, row: 1, key: 0) { $0.title("RET") })
        let secondary = clone(
            rows: replacingKey(in: preset.rows, row: 1, key: 1) { $0.settingSecondaryLabel("x") })
        for definition in [label, secondary] {
            XCTAssertTrue(BuiltinLayouts.matchesPhone9LiveFirstKey(definition))
        }
    }

    // MARK: Main-row geometry / primary action

    func testMainGeometryOrActionEditsBreakBoth() {
        let width = clone(rows: replacingKey(in: preset.rows, row: 1, key: 0) { $0.settingWidth(2) })
        let action = clone(
            rows: replacingKey(in: preset.rows, row: 1, key: 0) { $0.settingAction(.init(.code, value: "0")) })
        var swapped = preset.rows
        swapped[1] = LayoutRow(keys: Array(swapped[1].keys.reversed()))
        let order = clone(rows: swapped)
        let fewerRows = clone(rows: Array(preset.rows.prefix(3)), areas: [])
        for definition in [width, action, order] {
            assertVisualOnlyIsBroken(definition)
            XCTAssertFalse(BuiltinLayouts.matchesPhone9PrimarySemantics(definition))
        }
        // The three-row phone shape keeps the canonical main rows. Its shell identity is false, but
        // primary gestures are main-row only, so they survive the author's structure edit.
        XCTAssertFalse(BuiltinLayouts.matchesPhone9LiveFirstKey(fewerRows))
        XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(fewerRows))
    }

    func testMainKeyCountChangeBreaksBoth() {
        var rows = preset.rows
        rows[0] = LayoutRow(keys: Array(rows[0].keys.prefix(2)) + Array(preset.rows[0].keys.prefix(1)))
        let edited = clone(rows: rows)
        XCTAssertFalse(BuiltinLayouts.matchesPhone9PrimarySemantics(edited))
        assertVisualOnlyIsBroken(edited)
    }

    // MARK: Injected control row / rails

    func testControlRowLongPressEditKeepsPrimaryGestures() {
        var parts = preset.rows
        let last = parts.count - 1
        parts[last] = LayoutRow(
            keys: parts[last].keys.enumerated().map { index, key in
                index == 0 ? extraLongPress(key) : key
            })
        let edited = clone(rows: parts)
        assertVisualOnlyIsBroken(edited)
        XCTAssertTrue(
            BuiltinLayouts.matchesPhone9PrimarySemantics(edited),
            "a footer long-press edit must not re-degrade digit flick / first-key cycling")
    }

    func testControlRowNonLongPressEditsKeepPrimaryGestures() {
        var parts = preset.rows
        let last = parts.count - 1
        let label = clone(
            rows: {
                parts[last] = LayoutRow(
                    keys: parts[last].keys.enumerated().map { index, key in
                        index == 0 ? key.title("布局!") : key
                    })
                return parts
            }())
        let width = clone(
            rows: {
                parts[last] = LayoutRow(
                    keys: parts[last].keys.enumerated().map { index, key in
                        index == 1 ? key.settingWidth(8) : key
                    })
                return parts
            }())
        for definition in [label, width] {
            assertVisualOnlyIsBroken(definition)
            // The shell falls back to the author renderer (its fixed row would otherwise hide these
            // edits), but the main-row gestures stay native.
            XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(definition))
        }
    }

    func testRailLongPressEditKeepsPrimaryGestures() {
        guard let areas = preset.auxiliaryAreas else { return XCTFail("preset has rails") }
        let edited = clone(areas: replacingAuxKey(in: areas, area: 0, key: 0, with: extraLongPress))
        assertVisualOnlyIsBroken(edited)
        XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(edited))
    }

    func testRailNonLongPressOrShapeEditsKeepPrimaryGestures() {
        guard let areas = preset.auxiliaryAreas else { return XCTFail("preset has rails") }
        let label = clone(areas: replacingAuxKey(in: areas, area: 0, key: 0) { $0.title("Del") })
        let action = clone(areas: replacingAuxKey(in: areas, area: 0, key: 1) { $0.settingAction(.init(.enter)) })
        let removed = clone(
            areas: areas.enumerated().map { index, area in
                index == 0
                    ? LayoutAuxiliaryArea(
                        position: area.position, role: area.role, keys: Array(area.keys.dropFirst()))
                    : area
            })
        for definition in [label, action, removed] {
            assertVisualOnlyIsBroken(definition)
            // Rails are not part of the main-row gesture predicate; the author renderer shows them.
            XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(definition))
        }
    }

    // MARK: Chrome

    /// An edited 9-key key keeps the keyboard's rails and bottom row: the chrome replaces only the
    /// stand-in rails and control row, never the main keys the author changed.
    func testMainKeyEditsKeepTheChrome() {
        let label = clone(rows: replacingKey(in: preset.rows, row: 0, key: 1) { $0.title("AB") })
        let secondary = clone(
            rows: replacingKey(in: preset.rows, row: 1, key: 1) { $0.settingSecondaryLabel("x") })
        let firstKey = clone(
            rows: replacingKey(in: preset.rows, row: 0, key: 0) { $0.settingAction(.init(.literal, value: "。")) })
        let width = clone(rows: replacingKey(in: preset.rows, row: 1, key: 0) { $0.settingWidth(2) })
        for definition in [label, secondary, firstKey, width] {
            XCTAssertTrue(BuiltinLayouts.matchesPhone9Chrome(definition))
            XCTAssertTrue(PhoneKeypadStructure.matches(definition))
        }
        XCTAssertTrue(BuiltinLayouts.matchesPhone9Chrome(preset))
        XCTAssertTrue(BuiltinLayouts.matchesPhone9Chrome(clone()))
    }

    func testChromeEditsAndOtherShapesLeaveTheChrome() {
        guard let areas = preset.auxiliaryAreas else { return XCTFail("preset has rails") }
        var footer = preset.rows
        footer[3] = LayoutRow(keys: footer[3].keys.enumerated().map { $0 == 0 ? $1.title("布局!") : $1 })
        let rail = clone(areas: replacingAuxKey(in: areas, area: 0, key: 0) { $0.title("Del") })
        let digit = clone(
            rows: replacingKey(in: preset.rows, row: 1, key: 0) { $0.settingAction(.init(.code, value: "0")) })
        let threeRows = clone(rows: Array(preset.rows.prefix(3)))
        let bound = clone(input: .init(schemaID: "unknown_t9", builtinLayout: .phone9))
        for definition in [clone(rows: footer), rail, digit, threeRows, bound] {
            XCTAssertFalse(BuiltinLayouts.matchesPhone9Chrome(definition))
        }
    }

    // MARK: Unknown / other builtin layouts

    func testUnknownSchemaNeverMatches() {
        let bound = clone(input: .init(schemaID: "unknown_t9", builtinLayout: .phone9))
        for definition in [bound] {
            XCTAssertFalse(BuiltinLayouts.matchesPhone9LiveFirstKey(definition))
            XCTAssertFalse(BuiltinLayouts.matchesPhone9PrimarySemantics(definition))
        }
    }

    func testOtherBuiltinLayoutsNeverMatch() {
        for definition in [BuiltinLayouts.qwerty26, BuiltinLayouts.merged14, BuiltinLayouts.merged18] {
            XCTAssertFalse(BuiltinLayouts.matchesPhone9LiveFirstKey(definition))
            XCTAssertFalse(BuiltinLayouts.matchesPhone9PrimarySemantics(definition))
        }
    }

    func testImportedPhoneShapeWithoutBuiltinMetadataNeverMatches() {
        let imported = LayoutDefinition(
            id: "imported-t9", name: "导入九键", input: .init(),
            rows: preset.rows, auxiliaryAreas: preset.auxiliaryAreas)
        XCTAssertFalse(BuiltinLayouts.matchesPhone9LiveFirstKey(imported))
        XCTAssertFalse(BuiltinLayouts.matchesPhone9PrimarySemantics(imported))
    }
}
