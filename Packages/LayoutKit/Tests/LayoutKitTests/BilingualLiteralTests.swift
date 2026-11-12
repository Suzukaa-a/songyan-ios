import XCTest

@testable import LayoutKit

/// Explicit Chinese/ASCII literal pairs, page-following language behavior, and the frozen default
/// footers: the tests pin the author-visible contract so copying, saving and reuse keep resolving
/// the same visible text.
final class BilingualLiteralTests: XCTestCase {
    // MARK: - Explicit behavior payload

    func testLanguageBehaviorPayloadRoundTripsAndRejectsUnknownValues() throws {
        XCTAssertEqual(LayoutAction.LanguageSwitchBehavior.symbols.rawValue, "symbols")
        XCTAssertEqual(LayoutAction.LanguageSwitchBehavior.letters.rawValue, "letters")
        let followPage = LayoutAction.languageSwitch()
        XCTAssertNil(followPage.value)
        XCTAssertNil(followPage.languageSwitchBehavior)
        XCTAssertNoThrow(try followPage.validate())
        for behavior in LayoutAction.LanguageSwitchBehavior.allCases {
            let action = LayoutAction.languageSwitch(behavior)
            XCTAssertEqual(action.value, behavior.rawValue)
            XCTAssertEqual(action.languageSwitchBehavior, behavior)
            XCTAssertNoThrow(try action.validate())
            XCTAssertEqual(
                try JSONDecoder().decode(LayoutAction.self, from: JSONEncoder().encode(action)), action)
        }
        let unknown = LayoutAction(.languageSwitch, value: "toggleEverything")
        XCTAssertNil(unknown.languageSwitchBehavior)
        XCTAssertThrowsError(try unknown.validate())
        let invalidJSON = Data(
            "{\"id\":\"bad\",\"name\":\"坏\",\"input\":{\"builtinLayout\":\"qwerty26\"},\"rows\":[{\"keys\":[{\"label\":\"中英\",\"action\":{\"type\":\"languageSwitch\",\"value\":\"toggleEverything\"}}]}]}"
                .utf8)
        XCTAssertThrowsError(try LayoutDefinition.decode(invalidJSON))
    }

    func testPolicyPageFollowingMatrixAndExplicitOverrides() {
        func policy(_ page: KeyboardControlPolicy.Page, ascii: Bool = false, category: Bool = true)
            -> KeyboardControlPolicy
        {
            KeyboardControlPolicy(
                page: page, isEnglishMode: false, hasGlobe: true, isPhoneLayout: false,
                usesASCIIPunctuation: ascii, usesCategorySymbolPage: category)
        }
        XCTAssertEqual(policy(.letters).languageAction, .toggleLanguage)
        XCTAssertEqual(policy(.numeric).languageAction, .toggleSymbols)
        XCTAssertEqual(policy(.symbols, category: false).languageAction, .toggleSymbols)
        XCTAssertEqual(policy(.symbols, category: true).languageAction, .returnToLetters)
        for page in KeyboardControlPolicy.Page.allCases {
            XCTAssertEqual(policy(page).languageAction(for: .symbols), .toggleSymbols, "\(page)")
            XCTAssertEqual(policy(page).languageAction(for: .letters), .returnToLetters, "\(page)")
        }
        // One face; the emphasised side follows the page's own state.
        XCTAssertEqual(policy(.letters).languageTitle, "中/英")
        XCTAssertEqual(policy(.letters, ascii: true).languageTitle, "中/英")
        XCTAssertEqual(policy(.numeric).languageTitle, "中/英")
        XCTAssertEqual(policy(.numeric, ascii: true).languageTitle, "中/英")
        XCTAssertEqual(policy(.letters, ascii: true).languageCurrentSideIsFirst(for: nil), true)
        XCTAssertEqual(policy(.numeric).languageCurrentSideIsFirst(for: nil), true)
        XCTAssertEqual(policy(.numeric, ascii: true).languageCurrentSideIsFirst(for: nil), false)
        XCTAssertNil(policy(.symbols, category: true).languageCurrentSideIsFirst(for: nil))
        XCTAssertEqual(policy(.symbols, category: true).languageTitle, "返回")
        XCTAssertEqual(policy(.numeric).languageTitle(for: .letters), "返回")
        XCTAssertEqual(policy(.symbols, category: true).languageAction(for: .symbols), .toggleSymbols)
        XCTAssertEqual(policy(.letters).languageAccessibilityLabel, "切换到英文")
        XCTAssertEqual(policy(.numeric, ascii: true).languageAccessibilityLabel, "切换到中文符号")
        XCTAssertEqual(policy(.symbols, category: true).languageAccessibilityLabel, "返回主键盘")
    }

    // MARK: - asciiValue legality, resolution and budget

    func testAsciiValueIsLiteralOnlyNonEmptyAndResolvesWithoutTouchingMetadata() throws {
        let fixed = LayoutAction(.literal, value: "。")
        XCTAssertNil(fixed.asciiValue)
        XCTAssertEqual(fixed.literalValue(usesASCIIPunctuation: false), "。")
        XCTAssertEqual(fixed.literalValue(usesASCIIPunctuation: true), "。")

        let pair = LayoutAction(.literal, value: "。", asciiValue: ".")
        XCTAssertEqual(pair.literalValue(usesASCIIPunctuation: false), "。")
        XCTAssertEqual(pair.literalValue(usesASCIIPunctuation: true), ".")
        XCTAssertEqual(pair.settingAsciiValue(nil).literalValue(usesASCIIPunctuation: true), "。")
        XCTAssertThrowsError(try LayoutAction(.literal, value: "x", asciiValue: "").validate())
        XCTAssertThrowsError(try LayoutAction(.space, asciiValue: "x").validate())
        XCTAssertNil(LayoutAction(.space).literalValue(usesASCIIPunctuation: true))

        // Editing only the value/face keeps pair data untouched through every setter.
        let key = LayoutKey(label: "。", action: pair, titleMode: .automatic)
        XCTAssertEqual(key.title("新").action.asciiValue, ".")
        XCTAssertEqual(key.settingWidth(2).action.asciiValue, ".")
        XCTAssertEqual(key.settingSecondaryLabel("提示").action.asciiValue, ".")
        XCTAssertEqual(key.settingLongPress([]).action.asciiValue, ".")
        XCTAssertEqual(key.settingAction(key.action.settingAsciiValue(".")).action.asciiValue, ".")
    }

    func testAsciiValueCountsInTheExistingTextBudget() throws {
        let definition = LayoutDefinition(
            id: "pair.budget", name: "双语预算", input: .init(builtinLayout: .qwerty26),
            rows: [
                LayoutRow(keys: [
                    LayoutKey(
                        label: "q",
                        action: .init(.literal, value: "q", asciiValue: String(repeating: "x", count: 4097)))
                ])
            ])
        XCTAssertThrowsError(try definition.validate())
    }

    // MARK: - Presets carry the two explicit branches

    private func resolve(_ key: LayoutKey, ascii: Bool) -> String? {
        key.action.literalValue(usesASCIIPunctuation: ascii)
    }

    func testPresetsStoreChineseValueAsciiCounterpartAndInitialBranch() throws {
        let chinese = KeyboardPagePresets.numericRowsPage(ascii: false)
        XCTAssertNil(chinese.defaultSymbolMarks, "the rows follow the input language until a copy chooses")
        let chinesePaired = chinese.rows[1].keys[2]
        XCTAssertEqual(chinesePaired.action.value, "：")
        XCTAssertEqual(chinesePaired.action.asciiValue, ":")
        XCTAssertEqual(chinesePaired.label, "：")
        XCTAssertEqual(chinesePaired.titleMode, .automatic)
        XCTAssertEqual(resolve(chinesePaired, ascii: false), "：")
        XCTAssertEqual(resolve(chinesePaired, ascii: true), ":")

        let english = KeyboardPagePresets.numericRowsPage(ascii: true)
        XCTAssertNil(english.defaultSymbolMarks)
        let englishPaired = english.rows[1].keys[2]
        XCTAssertEqual(englishPaired.action.value, "：")
        XCTAssertEqual(englishPaired.action.asciiValue, ":")
        XCTAssertEqual(englishPaired.label, ":")
        XCTAssertEqual(resolve(englishPaired, ascii: false), "：")
        XCTAssertEqual(resolve(englishPaired, ascii: true), ":")

        XCTAssertNil(KeyboardPagePresets.symbolRowsPage(ascii: false).defaultSymbolMarks)
        XCTAssertNil(KeyboardPagePresets.symbolRowsPage(ascii: true).defaultSymbolMarks)
        XCTAssertNil(KeyboardPagePresets.numericAutomatic.defaultSymbolMarks)
        XCTAssertNil(KeyboardPagePresets.symbolsSystem.defaultSymbolMarks)
        XCTAssertEqual(KeyboardPagePresets.numericKeypad.defaultSymbolMarks, .chinese)

        // Every paired literal resolves to its own branch; identical slots stay fixed.
        for preset in [
            KeyboardPagePresets.numericRowsPage(ascii: false), KeyboardPagePresets.symbolRowsPage(ascii: false),
        ] {
            try preset.validate()
            for key in preset.rows.flatMap(\.keys) {
                XCTAssertNotNil(resolve(key, ascii: false))
                if let ascii = key.action.asciiValue {
                    XCTAssertEqual(resolve(key, ascii: true), ascii)
                } else {
                    XCTAssertEqual(resolve(key, ascii: true), key.action.value)
                }
            }
        }
        // The presets round-trip through the wire form unchanged (pageOrder omission relies on it).
        for preset in KeyboardPagePresets.all {
            XCTAssertEqual(
                try JSONDecoder().decode(
                    KeyboardPageDefinition.self, from: JSONEncoder().encode(preset)), preset)
        }
    }

    func testCopiedPresetsKeepOrChooseTheirInitialSymbolBranch() throws {
        // A copy of the rows keeps the labels of the branch they were drawn in and still follows the input.
        let englishRowsCopy = KeyboardPagePresets.numericRowsPage(ascii: true).copy()
        XCTAssertNil(englishRowsCopy.defaultSymbolMarks)
        XCTAssertEqual(englishRowsCopy.rows[1].keys[2].label, ":")

        let followingCopy = KeyboardPagePresets.numericAutomatic.copy()
        XCTAssertNil(followingCopy.defaultSymbolMarks, "a copy never pins the Chinese marks by accident")
        XCTAssertEqual(followingCopy.rows[1].keys[2].titleMode, .automatic)

        let automaticASCIICopy = KeyboardPagePresets.numericAutomatic.copy(numericMarks: .ascii)
        XCTAssertEqual(automaticASCIICopy.defaultSymbolMarks, .ascii)
        XCTAssertEqual(automaticASCIICopy.rows[1].keys[2].label, ":")

        let automaticChineseCopy = KeyboardPagePresets.numericAutomatic.copy(numericMarks: .chinese)
        XCTAssertEqual(automaticChineseCopy.defaultSymbolMarks, .chinese)
        XCTAssertEqual(automaticChineseCopy.rows[1].keys[2].label, "：")

        // An authored page without an initial branch is never guessed one.
        let unmarked = KeyboardPageDefinition(
            id: "unmarked.rows", name: "旧行页", kind: .numeric,
            rows: [LayoutRow(keys: [LayoutKey(label: "1", action: .init(.literal, value: "1"))])])
        XCTAssertNil(unmarked.defaultSymbolMarks)
        XCTAssertNil(unmarked.materialized().defaultSymbolMarks)
        XCTAssertNil(unmarked.copy().defaultSymbolMarks)
    }

    func testAutomaticSymbolCopySnapshotsTheChosenInitialLanguage() throws {
        let ascii = KeyboardPagePresets.symbolsSystem.copy(numericMarks: .ascii)
        XCTAssertEqual(ascii.symbolPresentation, .rows)
        XCTAssertEqual(ascii.defaultSymbolMarks, .ascii)
        XCTAssertEqual(ascii.rows[0], KeyboardPagePresets.symbolRowsPage(ascii: true).rows[0])
        XCTAssertEqual(ascii.rows[1], KeyboardPagePresets.symbolRowsPage(ascii: true).rows[1])
        // Materializing wraps the marks in the 123 switch and Delete.
        XCTAssertEqual(
            Array(ascii.rows[2].keys.dropFirst().dropLast()),
            KeyboardPagePresets.symbolRowsPage(ascii: true).rows[2].keys)
        XCTAssertEqual(
            ascii.rows[0].keys[0].label, KeyboardPagePresets.symbolRowsPage(ascii: true).rows[0].keys[0].label)
        XCTAssertEqual(
            ascii.rows[0].keys[0].longPress, KeyboardPagePresets.symbolRowsPage(ascii: true).rows[0].keys[0].longPress,
            "the long-press menu is the chosen initial language's fixed snapshot")
        try ascii.validate()

        let chinese = KeyboardPagePresets.symbolsSystem.copy(numericMarks: .chinese)
        XCTAssertEqual(chinese.rows[0], KeyboardPagePresets.symbolRowsPage(ascii: false).rows[0])
        XCTAssertEqual(
            chinese.rows[0].keys[0].label, KeyboardPagePresets.symbolRowsPage(ascii: false).rows[0].keys[0].label)
        XCTAssertEqual(chinese.defaultSymbolMarks, .chinese)
        try chinese.validate()

        // Author-modified automatic rows are never swapped for a whole preset.
        var modified = KeyboardPagePresets.symbolsSystem
        var firstRow = modified.rows[0].keys
        firstRow[0] = LayoutKey(label: "自定", action: .init(.literal, value: "自定"))
        modified.rows[0] = LayoutRow(keys: firstRow)
        let modifiedCopy = modified.materialized(numericMarks: .ascii)
        XCTAssertEqual(modifiedCopy.rows[0].keys[0].label, "自定")
        XCTAssertEqual(modifiedCopy.rows[0].keys[0].action.value, "自定")
        XCTAssertNil(modifiedCopy.rows[0].keys[0].action.asciiValue)
        XCTAssertEqual(modifiedCopy.defaultSymbolMarks, .ascii)
    }

    // MARK: - Fixed author literals

    func testFixedAuthorLiteralNeverGainsAPairOrChangesOnCopy() throws {
        let fixed = LayoutKey(label: "自定", action: .init(.literal, value: "固定"), titleMode: .custom)
        let page = KeyboardPageDefinition(
            id: "author.fixed", name: "作者固定", kind: .numeric,
            rows: [LayoutRow(keys: [fixed])],
            chrome: KeyboardPageChrome(bottom: [fixed]))
        XCTAssertEqual(page.materialized(), page)
        try page.validate()
        let copy = page.copy()
        XCTAssertEqual(copy.rows[0].keys[0], fixed)
        XCTAssertEqual(copy.chrome?.bottom[0], fixed)
        XCTAssertNil(copy.rows[0].keys[0].action.asciiValue)
        XCTAssertEqual(copy.rows[0].keys[0].action.literalValue(usesASCIIPunctuation: true), "固定")

        // Materializing a row page on native controls only adds the switch and Delete the renderer
        // draws; it never rewrites an author literal.
        let native = KeyboardPageDefinition(
            id: "author.native", name: "作者旧页", kind: .numeric,
            rows: [LayoutRow(keys: [fixed, LayoutKey(label: "2", action: .init(.literal, value: "2"))])])
        let materialized = native.materialized()
        XCTAssertEqual(Array(materialized.rows[0].keys.dropFirst().prefix(2)), native.rows[0].keys)
        XCTAssertEqual(materialized.rows[0].keys.count, 4)  // page switch prepended, Delete appended
        XCTAssertEqual(materialized.rows[0].keys[0].action.pageSwitchTarget, .symbols)
        XCTAssertNil(materialized.rows[0].keys[1].action.asciiValue)
        try materialized.validate()
    }

    // MARK: - Frozen default footers and policy mapping

    private func footer(_ page: KeyboardPageDefinition) -> [LayoutKey] {
        page.materialized().chrome?.bottom ?? []
    }

    func testDefaultFootersMatchTheFrozenOrderAndActions() throws {
        let abc = footer(KeyboardPagePresets.englishQwerty)
        XCTAssertEqual(abc[0].action.pageSwitchTarget, .numeric)
        XCTAssertEqual(abc.map(\.action.type), [.pageSwitch, .globe, .languageSwitch, .space, .literal, .enter])
        XCTAssertEqual(abc[4].label, ",")
        XCTAssertEqual(abc[4].action.value, "，")
        XCTAssertEqual(abc[4].action.asciiValue, ",")
        XCTAssertEqual(abc[4].longPress?.compactMap(\.action.value), ["。", "？", "！", "、", "…"])
        XCTAssertEqual(abc[4].longPress?.compactMap(\.action.asciiValue), [".", "?", "!", "'", "\""])

        let numeric = footer(KeyboardPagePresets.numericRowsPage(ascii: false))
        XCTAssertEqual(numeric.map(\.action.type), [.pageSwitch, .globe, .languageSwitch, .space, .literal, .enter])
        XCTAssertEqual(numeric[4], abc[4], "every row page shares the ABC page's comma key")
        XCTAssertEqual(numeric[0].label, "返回")
        XCTAssertEqual(numeric[0].action.pageSwitchTarget, .letters)

        let symbols = footer(KeyboardPagePresets.symbolRowsPage(ascii: false))
        XCTAssertEqual(symbols.map(\.action.type), [.pageSwitch, .globe, .languageSwitch, .space, .literal, .enter])
        XCTAssertEqual(symbols[0].action.pageSwitchTarget, .letters)

        let categorized = try XCTUnwrap(KeyboardPagePresets.symbolsCategorized.materialized().chrome?.bottom)
        XCTAssertEqual(categorized.map(\.action.type), [.languageSwitch, .globe, .pageSwitch, .space, .symbolLock])
        XCTAssertEqual(categorized[0].label, "返回")
        XCTAssertEqual(categorized[0].action.languageSwitchBehavior, .letters)
        XCTAssertEqual(categorized[2].action.pageSwitchTarget, .numeric)

        let keypad = try XCTUnwrap(KeyboardPagePresets.numericKeypad.chrome)
        XCTAssertEqual(
            keypad.bottom.map(\.action.type), [.pageSwitch, .globe, .languageSwitch, .space, .pageSwitch, .enter])
        XCTAssertEqual(keypad.bottom[0].action.pageSwitchTarget, .letters)
        XCTAssertEqual(keypad.bottom[4].action.pageSwitchTarget, .symbols)
        XCTAssertEqual(keypad.trailing.map(\.action.type), [.backspace, .literal, .literal])
        XCTAssertEqual(keypad.trailing[1].action.value, "0")
        XCTAssertFalse(keypad.trailingSpansBottom)

        // Space is the only relative width in a default footer (one digit column on the keypad);
        // function keys draw automatic faces.
        for keys in [abc, numeric, symbols, categorized] {
            for key in keys {
                XCTAssertEqual(key.width, key.action.type == .space ? 4 : nil)
                XCTAssertEqual(key.titleMode, .automatic)
            }
        }
        XCTAssertTrue(keypad.bottom.allSatisfy { $0.width == nil && $0.titleMode == .automatic })
    }

    func testKeypadRailUsesTheRealNumericRailFirstThreeWithPairs() throws {
        let railChinese = BuiltinLayouts.phoneNumericRailValues(ascii: false)
        let railASCII = BuiltinLayouts.phoneNumericRailValues(ascii: true)
        XCTAssertEqual(Array(railChinese.prefix(3)), [".", "？", "！"])
        XCTAssertEqual(Array(railASCII.prefix(3)), [".", "?", "!"])
        XCTAssertEqual(Set(railChinese).count, railChinese.count, "the rail de-duplicates by string")
        XCTAssertEqual(Set(railASCII).count, railASCII.count)
        XCTAssertTrue(railChinese.contains("。"))
        XCTAssertTrue(railASCII.contains("-"))

        let chineseKeypad = try XCTUnwrap(KeyboardPagePresets.numericKeypad.chrome)
        XCTAssertEqual(chineseKeypad.leading.map(\.label), [".", "？", "！"])
        XCTAssertEqual(chineseKeypad.leading[1].action.value, "？")
        XCTAssertEqual(chineseKeypad.leading[1].action.asciiValue, "?")
        XCTAssertEqual(chineseKeypad.leading[0].action.asciiValue, nil)

        let asciiCopy = KeyboardPagePresets.numericAutomatic.copy(
            numericMarks: .ascii, numericForm: .phoneDigitPad)
        let asciiLeading = try XCTUnwrap(asciiCopy.chrome?.leading)
        XCTAssertEqual(asciiLeading.map(\.label), [".", "?", "!"])
        XCTAssertEqual(asciiLeading[2].action.value, "！")
        XCTAssertEqual(asciiLeading[2].action.asciiValue, "!")
        XCTAssertEqual(
            Array(BuiltinLayouts.phoneNumericRailValues(ascii: true).prefix(3)),
            asciiLeading.prefix(3).map { $0.action.asciiValue ?? $0.action.value ?? "" })
        try asciiCopy.validate()
    }

    func testDefaultFooterGeometryStillRecognisesEveryNewDefault() {
        let variants: [(KeyboardPageDefinition, KeyboardControlPolicy)] = [
            (
                KeyboardPagePresets.englishQwerty,
                KeyboardControlPolicy(
                    page: .letters, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: false, usesASCIIPunctuation: false)
            ),
            (
                KeyboardPagePresets.numericRowsPage(ascii: false),
                KeyboardControlPolicy(
                    page: .numeric, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: false, usesASCIIPunctuation: false)
            ),
            (
                KeyboardPagePresets.symbolRowsPage(ascii: false),
                KeyboardControlPolicy(
                    page: .symbols, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: false, usesASCIIPunctuation: false, usesCategorySymbolPage: false)
            ),
            (
                KeyboardPagePresets.symbolsCategorized,
                KeyboardControlPolicy(
                    page: .symbols, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false)
            ),
            (
                KeyboardPagePresets.numericKeypad,
                KeyboardControlPolicy(
                    page: .numeric, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false,
                    usesDigitPadRow: true)
            ),
        ]
        for (page, policy) in variants {
            let geometry = KeyboardPageFooterGeometry(width: 402, keys: footer(page), policy: policy)
            XCTAssertTrue(geometry.usesControlRowBudget, page.name)
        }
    }

    // MARK: - Pages saved without the newer fields

    func testLiteralWithoutASCIICounterpartKeepsFixedText() throws {
        let json = Data(
            """
            {"id":"fixed.pair","name":"固定标点","kind":"numeric","rows":[{"keys":[{"label":"。","action":{"type":"literal","value":"。"}}]}]}
            """.utf8)
        let page = try JSONDecoder().decode(KeyboardPageDefinition.self, from: json)
        XCTAssertNil(page.defaultSymbolMarks)
        XCTAssertNil(page.rows[0].keys[0].action.asciiValue)
        XCTAssertEqual(page.rows[0].keys[0].action.literalValue(usesASCIIPunctuation: true), "。")
        try page.validate()
        XCTAssertEqual(page.materialized().rows[0].keys[1], page.rows[0].keys[0])
    }
}
