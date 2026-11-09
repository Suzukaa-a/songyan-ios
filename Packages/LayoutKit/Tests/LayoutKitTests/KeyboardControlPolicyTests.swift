import XCTest

@testable import LayoutKit

final class KeyboardControlPolicyTests: XCTestCase {
    func testT9LeadingShortcutsAreComplementaryLiteralsAndASCIIAdapts() {
        let chinese = BuiltinLayouts.t9LeadingShortcuts(ascii: false)
        XCTAssertEqual(chinese.map(\.action.value), ["@", "/", "-", "(", ")", "…"])
        XCTAssertTrue(Set(chinese.map(\.label)).isDisjoint(with: ["，", "。", "？"]))
        for ascii in [false, true] {
            let keys = BuiltinLayouts.t9LeadingShortcuts(ascii: ascii)
            XCTAssertEqual(keys.count, 6)
            let actions = keys.map(\.action) + keys.flatMap { ($0.longPress ?? []).map(\.action) }
            XCTAssertTrue(actions.allSatisfy { $0.type == .literal })
            if ascii {
                XCTAssertTrue(actions.allSatisfy { ($0.value ?? "").utf8.allSatisfy { $0 < 128 } })
            }
        }
        // Presentation shortcuts do not mutate the persisted builtin.
        XCTAssertFalse((BuiltinLayouts.phone9.auxiliaryAreas ?? []).contains { $0.role == .punctuation })
    }
    /// I-D4: the native footer's punctuation follows the input script, not the engine mode.
    func testFooterPunctuationFollowsTheInputScript() {
        func text(_ script: KeyLabelScript, ascii: Bool = false) -> (String, [String]) {
            let policy = KeyboardControlPolicy(
                page: .letters, isEnglishMode: false, hasGlobe: true, isPhoneLayout: false,
                usesASCIIPunctuation: ascii, script: script)
            return (policy.utilityText, policy.utilityAlternates)
        }
        XCTAssertEqual(text(.simplifiedChinese).0, "，")
        XCTAssertEqual(text(.traditionalChinese).0, "，")
        XCTAssertEqual(text(.japanese).0, "、")
        XCTAssertEqual(text(.simplifiedChinese, ascii: true).0, ",")
        XCTAssertEqual(text(.simplifiedChinese).1, ["。", "？", "！", "、", "…"])
        XCTAssertEqual(text(.traditionalChinese).1, ["。", "？", "！", "、", "…"])
        XCTAssertEqual(text(.japanese).1, ["。", "？", "！", "・", "…"])
        XCTAssertEqual(text(.simplifiedChinese, ascii: true).1, [".", "?", "!", "'", "\""])
        XCTAssertEqual(text(.japanese, ascii: true).1, [".", "?", "!", "'", "\""])
    }

    /// The split footer gives the full stop its own key: the comma holds the pauses, the full stop
    /// holds the sentence-ending marks.
    func testSplitFooterLongPressListsAreSplitBetweenCommaAndFullStop() {
        func policy(_ script: KeyLabelScript, ascii: Bool = false) -> KeyboardControlPolicy {
            KeyboardControlPolicy(
                page: .letters, isEnglishMode: false, hasGlobe: true, isPhoneLayout: false,
                usesASCIIPunctuation: ascii, script: script, showsSpaceSideMarks: true)
        }
        XCTAssertEqual(policy(.simplifiedChinese).utilityAlternates, ["、", "：", "；"])
        XCTAssertEqual(policy(.traditionalChinese).utilityAlternates, ["、", "：", "；"])
        XCTAssertEqual(policy(.japanese).utilityAlternates, ["・", "：", "；"])
        XCTAssertEqual(policy(.japanese).fullStopAlternates, ["？", "！", "…"])
        XCTAssertEqual(policy(.simplifiedChinese).fullStopAlternates, ["？", "！", "…"])
        XCTAssertEqual(policy(.simplifiedChinese, ascii: true).utilityAlternates, ["'", ";", ":"])
        XCTAssertEqual(policy(.simplifiedChinese, ascii: true).fullStopAlternates, ["?", "!", "…"])
    }

    /// 中/英 changes the marks beside the space bar, never the footer's keys or their widths.
    func testEnglishKeepsTheSplitFooterWithASCIIMarks() {
        func policy(english: Bool) -> KeyboardControlPolicy {
            KeyboardControlPolicy(
                page: .letters, isEnglishMode: english, hasGlobe: true, isPhoneLayout: false,
                usesASCIIPunctuation: english, script: .simplifiedChinese, showsSpaceSideMarks: true)
        }
        let chinese = policy(english: false)
        let english = policy(english: true)
        XCTAssertEqual(chinese.slots, english.slots)
        XCTAssertEqual(chinese.metrics(width: 382), english.metrics(width: 382))
        XCTAssertEqual(english.utilityText, ",")
        XCTAssertEqual(english.utility, .punctuation("."))
        XCTAssertEqual(chinese.utility, .punctuation("。"))
    }

    /// A URL field puts `:` and `/` beside the space bar and an email field `@` and `.`; the keys
    /// and their widths stay the text field's on every page.
    func testAddressFieldsChangeTheMarksNotTheKeys() {
        for page in KeyboardControlPolicy.Page.allCases {
            let text = KeyboardControlPolicy(
                page: page, isEnglishMode: true, hasGlobe: true, isPhoneLayout: false,
                usesASCIIPunctuation: true, usesCategorySymbolPage: false, showsSpaceSideMarks: true)
            let url = text.withFieldMarks(.url)
            let email = text.withFieldMarks(.email)
            for field in [url, email] {
                XCTAssertEqual(field.slots, text.slots, "\(page)")
                XCTAssertEqual(field.metrics(width: 382), text.metrics(width: 382), "\(page)")
            }
            XCTAssertEqual([url.markLeftText, url.fullStopText], [":", "/"])
            XCTAssertEqual([email.markLeftText, email.fullStopText], ["@", "."])
        }
        XCTAssertEqual(
            KeyboardControlPolicy(
                page: .letters, isEnglishMode: false, hasGlobe: true, isPhoneLayout: false,
                usesASCIIPunctuation: false, showsSpaceSideMarks: true
            ).markLeftText, "，")
    }

    /// Without the globe the keys left of the space bar and the keys right of it take the same
    /// width, so the space bar sits on the keyboard's centre line on every page. With the globe the
    /// space bar keeps the wider budget: 44pt switches, a 44pt comma and a 60pt-based Return.
    func testSpaceBarIsCentredOnlyWithoutTheGlobe() {
        for width in [312.0, 320, 382, 390, 422, 430, 768, 1024] {
            for page in KeyboardControlPolicy.Page.allCases {
                for globe in [false, true] {
                    let policy = KeyboardControlPolicy(
                        page: page, isEnglishMode: false, hasGlobe: globe,
                        isPhoneLayout: false, usesASCIIPunctuation: false)
                    let m = policy.metrics(width: width)
                    let slots = policy.slots
                    let space = slots.firstIndex(of: .space)!
                    let left = slots[..<space].reduce(0) { $0 + m[$1] } + Double(space) * m.spacing
                    let after = slots[(space + 1)...]
                    let right = after.reduce(0) { $0 + m[$1] } + Double(after.count) * m.spacing
                    let label = "globe \(globe) width \(width) \(page)"
                    XCTAssertGreaterThanOrEqual(m.enter, 60, label)
                    XCTAssertGreaterThanOrEqual(m.space, 44, label)
                    if globe {
                        XCTAssertEqual(m.page, 44, label)
                        XCTAssertEqual(m.utility, 44, label)
                        XCTAssertGreaterThan(left, right, label)
                        XCTAssertLessThan(m.enter, 92, label)
                    } else {
                        XCTAssertEqual(left, right, accuracy: 0.0001, label)
                    }
                }
            }
        }
        // Too narrow for the centred budget: the old budget applies, so the sides differ.
        let narrow = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: false,
            isPhoneLayout: false, usesASCIIPunctuation: false
        ).metrics(width: 260)
        XCTAssertNotEqual(narrow.page + narrow.language, narrow.utility + narrow.enter, accuracy: 0.01)
        let withGlobe = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: true,
            isPhoneLayout: false, usesASCIIPunctuation: false
        ).metrics(width: 382)
        XCTAssertEqual(withGlobe.space, 114.8, accuracy: 0.5)
        XCTAssertEqual(withGlobe.enter, 71.2, accuracy: 0.5)
    }

    /// The comma key carries the full stop first, so it is the corner hint, and the other sentence
    /// marks after it.
    func testCommaKeyLongPressStartsWithTheFullStop() {
        let chinese = KeyboardControlPolicy(
            page: .numeric, isEnglishMode: false, hasGlobe: true, isPhoneLayout: false, usesASCIIPunctuation: false)
        XCTAssertEqual(chinese.utility, .punctuation("，"))
        XCTAssertEqual(chinese.utilityAlternates.first, "。")
        let english = KeyboardControlPolicy(
            page: .letters, isEnglishMode: true, hasGlobe: true, isPhoneLayout: false, usesASCIIPunctuation: true)
        XCTAssertEqual(english.utilityAlternates.first, ".")
    }

    func testPageLanguageMatrixKeepsAllSlotWidthsAndReturnLanguage() {
        for globe in [false, true] {
            for width in [312.0, 367, 382, 422, 804] {
                let reference = KeyboardControlPolicy(
                    page: .letters, isEnglishMode: false,
                    hasGlobe: globe, isPhoneLayout: true, usesASCIIPunctuation: false)
                for phone in [false, true] {
                    for english in [false, true] {
                        for page in KeyboardControlPolicy.Page.allCases {
                            let policy = KeyboardControlPolicy(
                                page: page, isEnglishMode: english,
                                hasGlobe: globe, isPhoneLayout: phone, usesASCIIPunctuation: false)
                            // Every page keeps the same slots and widths; the symbol page here is the
                            // categorized grid (the default).
                            XCTAssertEqual(policy.isRowPage, page == .numeric && !phone)
                            XCTAssertEqual(policy.slots, reference.slots)
                            let metrics = policy.metrics(width: width)
                            XCTAssertEqual(metrics, reference.metrics(width: width))
                            XCTAssertEqual(
                                policy.slots.reduce(0) { $0 + metrics[$1] }
                                    + Double(policy.slots.count - 1) * metrics.spacing, width, accuracy: 0.0001)
                            XCTAssertGreaterThanOrEqual(metrics.page, globe ? 44 : 50)
                            XCTAssertGreaterThanOrEqual(metrics.language, globe ? 44 : 50)
                            XCTAssertGreaterThanOrEqual(metrics.space, 44)
                            XCTAssertGreaterThanOrEqual(metrics.enter, 60)
                            switch page {
                            case .letters:
                                XCTAssertEqual(policy.languageAction, .toggleLanguage)
                                XCTAssertEqual(policy.languageTitle, "中/英")
                                XCTAssertEqual(policy.languageCurrentSideIsFirst(for: nil), !english)
                            case .numeric:
                                XCTAssertEqual(policy.languageAction, .toggleSymbols)
                                XCTAssertEqual(policy.languageTitle, "中/英")
                                XCTAssertEqual(policy.pageTarget, .symbols)
                            case .symbols:
                                XCTAssertEqual(policy.languageAction, .returnToLetters)
                                XCTAssertEqual(policy.languageTitle, "返回")
                                XCTAssertEqual(policy.pageTarget, .numeric)
                            }
                            if page == .letters {
                                // Punctuation on a native letter page, the direct symbol key on a phone pad.
                                XCTAssertEqual(policy.key(at: .utility), phone ? .symbolPage : .utility)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Every page puts the globe first. The left switch after it is 123 on letters and a literal
    /// return on the row pages, which keep the comma in the utility position (their third row holds
    /// the page switch).
    /// Slot widths stay position-based.
    func testNonLetterPagesLeadWithTheirSwitchKey() {
        let expectations: [KeyboardControlPolicy.Page: [KeyboardControlPolicy.Slot]] = [
            .letters: [.globe, .page, .language, .space, .utility, .enter],
            .numeric: [.globe, .returnToLetters, .language, .space, .utility, .enter],
            .symbols: [.globe, .returnToLetters, .language, .space, .utility, .enter],
        ]
        for (page, expected) in expectations {
            let policy = KeyboardControlPolicy(
                page: page, isEnglishMode: false,
                hasGlobe: true, isPhoneLayout: false, usesASCIIPunctuation: false,
                usesCategorySymbolPage: false)
            XCTAssertEqual(policy.slots.map(policy.key(at:)), expected, "\(page)")
        }
    }

    /// The utility position types a comma on native letter and row pages. The mark follows only the effective symbol state, never the input language.
    func testGenericControlRowTypesPunctuationFromLetters() {
        for phone in [false, true] {
            for english in [false, true] {
                for page in KeyboardControlPolicy.Page.allCases {
                    let policy = KeyboardControlPolicy(
                        page: page, isEnglishMode: english,
                        hasGlobe: true, isPhoneLayout: phone, usesASCIIPunctuation: false)
                    XCTAssertEqual(policy.utility, .punctuation("，"))
                    let keys = policy.slots.map(policy.key(at:))
                    XCTAssertEqual(
                        keys.contains(.utility), !phone && (page != .symbols || !policy.usesCategorySymbolPage))
                    XCTAssertEqual(keys.contains(.symbolPage), page == .letters && phone)
                }
            }
        }
        // English input with an explicit Chinese symbol state keeps Chinese punctuation.
        let englishChineseSymbols = KeyboardControlPolicy(
            page: .numeric, isEnglishMode: true, hasGlobe: true,
            isPhoneLayout: false, usesASCIIPunctuation: false)
        XCTAssertEqual(englishChineseSymbols.utility, .punctuation("，"))
        let chineseASCIISymbols = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: true,
            isPhoneLayout: false, usesASCIIPunctuation: true)
        XCTAssertEqual(chineseASCIISymbols.utility, .punctuation(","))
    }

    /// A 123 page without its own symbol switch (phone keypad, authored keypad) sends the letter
    /// page's utility position to the symbol page so symbols stay reachable.
    func testLetterUtilityOpensSymbolsWhenNumericPageCannotReachThem() {
        let policy = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: true,
            isPhoneLayout: false, usesASCIIPunctuation: false, numericPageReachesSymbols: false)
        XCTAssertEqual(policy.key(at: .utility), .symbolPage)
        XCTAssertEqual(policy.slots.map(policy.key(at:)), [.globe, .page, .language, .space, .symbolPage, .enter])
    }

    /// Bundled 9-key: 123 | 中/英 | 空格 | 符 on letters, so 123 and the language key stay where every layout
    /// has them and the symbol page is one tap away on the right; on 123 and 符号 the left corner returns to letters.
    func testBundledT9BottomRowEndsWithSymbolKey() {
        func keys(_ page: KeyboardControlPolicy.Page, globe: Bool = false) -> [KeyboardControlPolicy.Slot] {
            let policy = KeyboardControlPolicy(
                page: page, isEnglishMode: false, hasGlobe: globe, isPhoneLayout: true,
                usesASCIIPunctuation: false, includesBottomEnter: false)
            return policy.slots.map(policy.key(at:))
        }
        XCTAssertEqual(keys(.letters), [.page, .language, .space, .symbolPage])
        XCTAssertEqual(keys(.numeric), [.returnToLetters, .language, .space, .utility])
        XCTAssertEqual(keys(.symbols), [.language, .page, .space, .symbolLock])
        XCTAssertEqual(keys(.letters, globe: true), [.globe, .page, .language, .space, .symbolPage])
        let letters = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: false, isPhoneLayout: true,
            usesASCIIPunctuation: false, includesBottomEnter: false)
        XCTAssertEqual(letters.pageTitle, "123")
        XCTAssertEqual(letters.languageTitle, "中/英")
        let numeric = KeyboardControlPolicy(
            page: .numeric, isEnglishMode: false, hasGlobe: false, isPhoneLayout: true,
            usesASCIIPunctuation: false, includesBottomEnter: false)
        XCTAssertEqual(numeric.pageTitle, "符")
        XCTAssertEqual(numeric.pageTarget, .symbols)
        XCTAssertEqual(numeric.languageTitle, "中/英")
        XCTAssertEqual(numeric.languageAction, .toggleSymbols)
        // Generic surfaces use the same page-following matrix.
        let qwertyNumeric = KeyboardControlPolicy(
            page: .numeric, isEnglishMode: false, hasGlobe: false, isPhoneLayout: false,
            usesASCIIPunctuation: false)
        XCTAssertEqual(qwertyNumeric.pageTitle, "符")
        XCTAssertEqual(qwertyNumeric.languageTitle, "中/英")
        XCTAssertEqual(qwertyNumeric.languageAction, .toggleSymbols)
    }

    /// 9-key trailing column (system/mainstream 9-key): delete (row 0) + re-input (row 1) + return/confirm
    /// (row 2 through the bottom row, in the bottom-right corner). The bottom row stops one spacing left of the column and fills exactly.
    func testBundledT9ReturnFillsBottomRightCornerBesideControlRow() {
        for width in [312.0, 367, 382, 430] {
            let m = PhoneKeypadMetrics.resolve(width: width, rowHeight: 54)
            let slots = m.railSlots(.trailing, spans: PhoneKeypadRailPolicy.bundledTrailingSpans)
            XCTAssertEqual(slots.count, 3)
            XCTAssertEqual(slots[0].height, m.rowHeight, accuracy: 0.0001)
            XCTAssertEqual(slots[1].height, m.rowHeight, accuracy: 0.0001)
            let control = m.controlRowRectBesideTrailingRail()
            XCTAssertEqual(slots[2].minY, m.rowY(2), accuracy: 0.0001)
            XCTAssertEqual(
                slots[2].maxY, control.maxY, accuracy: 0.0001,
                "\(width): return must align with the bottom edge of the bottom row (bottom-right corner)")
            XCTAssertEqual(control.maxX + m.spacing, slots[2].minX, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(
                slots[2].width * slots[2].height, 60 * m.rowHeight,
                "\(width): return must not be smaller than the historical bottom-row return budget")
            for page in [KeyboardControlPolicy.Page.letters, .numeric, .symbols] {
                let policy = KeyboardControlPolicy(
                    page: page, isEnglishMode: false,
                    hasGlobe: true, isPhoneLayout: true, usesASCIIPunctuation: false,
                    includesBottomEnter: false)
                XCTAssertFalse(
                    policy.slots.contains(.enter), "\(width): the 9-key bottom row must not repeat the confirm key")
                XCTAssertTrue(
                    policy.slots.contains(.utility),
                    "\(width): letters hold 中/英, 123 holds 0 and the symbol page holds 锁定 there")
                let metrics = policy.metrics(width: control.width)
                let total =
                    policy.slots.reduce(0.0) { $0 + metrics[$1] }
                    + metrics.spacing * Double(max(0, policy.slots.count - 1))
                XCTAssertEqual(total, control.width, accuracy: 0.0001)
            }
        }
    }

    /// 9-key bottom row: the first key sits under the rail; under the grid the space bar is about 2.4× each side
    /// key (123 and 中/英, 0 or 锁定), wider than a digit column, and both side keys stay at least 44pt.
    func testBundledT9ControlRowGivesSpaceMostOfTheGrid() {
        for width in [367.0, 382, 412, 430] {
            let m = PhoneKeypadMetrics.resolve(width: width, rowHeight: 54)
            let columns = KeyboardControlPolicy.PhoneColumns(rail: m.railWidth, digit: m.digitWidth)
            let control = m.controlRowRectBesideTrailingRail().width
            for page in [KeyboardControlPolicy.Page.letters, .numeric, .symbols] {
                let policy = KeyboardControlPolicy(
                    page: page, isEnglishMode: false, hasGlobe: false,
                    isPhoneLayout: true, usesASCIIPunctuation: false,
                    includesBottomEnter: false
                ).aligned(to: columns)
                let metrics = policy.metrics(width: control)
                XCTAssertEqual(metrics.page, m.railWidth, accuracy: 0.0001)
                XCTAssertEqual(metrics.language, metrics.utility, accuracy: 0.0001)
                XCTAssertEqual(metrics.space / metrics.language, 2.4, accuracy: 0.0001, "\(width) \(page)")
                XCTAssertGreaterThan(metrics.space, m.digitWidth * 1.4, "\(width) \(page)")
                XCTAssertGreaterThanOrEqual(metrics.language, 44, "\(width) \(page)")
                let total =
                    policy.slots.reduce(0.0) { $0 + metrics[$1] }
                    + metrics.spacing * Double(max(0, policy.slots.count - 1))
                XCTAssertEqual(total, control, accuracy: 0.0001)
            }
        }
    }

    /// Other layouts (including imported keyboards) keep Return in the bottom row; only the builtin 9-key moves confirm into the trailing column.
    func testOnlyBundledT9OmitsBottomEnter() {
        let withEnter = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false,
            hasGlobe: false, isPhoneLayout: false, usesASCIIPunctuation: false)
        XCTAssertTrue(withEnter.slots.contains(.enter))
        XCTAssertGreaterThanOrEqual(withEnter.metrics(width: 382).enter, 60)
        let t9 = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false,
            hasGlobe: false, isPhoneLayout: true, usesASCIIPunctuation: false,
            includesBottomEnter: false)
        XCTAssertEqual(t9.slots, [.page, .language, .space, .utility])
    }

    func testTinyOrInvalidPreviewWidthNeverOverflowsOrProducesNaN() {
        for globe in [false, true] {
            let policy = KeyboardControlPolicy(
                page: .numeric, isEnglishMode: false,
                hasGlobe: globe, isPhoneLayout: false, usesASCIIPunctuation: false)
            for width in [0.0, 44, 180, 250, -1, .nan, .infinity] {
                let metrics = policy.metrics(width: width)
                for slot in policy.slots {
                    XCTAssertTrue(metrics[slot].isFinite)
                    XCTAssertGreaterThanOrEqual(metrics[slot], 0)
                }
                let total =
                    policy.slots.reduce(0) { $0 + metrics[$1] }
                    + Double(policy.slots.count - 1) * metrics.spacing
                XCTAssertEqual(total, width.isFinite ? max(0, width) : 0, accuracy: 0.0001)
            }
        }
    }

    func testT9SeparatorKeyAndAddressFallback() {
        for ascii in [false, true] {
            // The first key while composing still separates syllables; long-press is digit 1 like 2-9 (not cycling, not punctuation).
            let separator = BuiltinLayouts.t9SeparatorKey()
            XCTAssertEqual(separator.action, .init(.code, value: "'"))
            XCTAssertEqual(separator.secondaryLabel, "1")
            XCTAssertEqual(separator.longPress?.compactMap(\.action.value), ["1"])
            XCTAssertEqual(separator.longPress?.first?.action.type, .literal)
            let fallback = BuiltinLayouts.t9PunctuationSymbols()
            XCTAssertFalse(fallback.contains("1"))
            if ascii { XCTAssertTrue(fallback.allSatisfy { $0.utf8.allSatisfy { $0 < 128 } }) }
        }
    }

    /// The first key's long-press must match 2-9: badge 1 + long-press types literal 1.
    /// The persisted declaration must carry it too: the layout manager/resource inspector show the declared key,
    /// and adding it only in a UI callback would make declaration and runtime disagree.
    func testFirstKeyLongPressMatchesDigitKeys() throws {
        let cycle = try XCTUnwrap(BuiltinLayouts.t9CycleKey(["！", "、", "…"]))
        for key in [cycle, BuiltinLayouts.t9SeparatorKey()] {
            XCTAssertEqual(key.secondaryLabel, "1", "badge must match 2-9")
            XCTAssertEqual(key.longPress?.count, 1)
            XCTAssertEqual(key.longPress?.first?.label, "1")
            XCTAssertEqual(key.longPress?.first?.action, .init(.literal, value: "1"))
        }
        // Style baseline of 2-9: the same secondaryLabel + a single literal longPress.
        // Real declared shape of 2-9: letter label + digit badge + code action + a single literal long-press.
        let digits = BuiltinLayouts.phone9.rows.flatMap(\.keys).filter {
            $0.action.type == .code && $0.longPress?.count == 1
        }
        XCTAssertEqual(digits.count, 8, "expected 8 digit keys (2-9)")
        for key in digits {
            let digit = try XCTUnwrap(key.action.value)
            XCTAssertEqual(key.secondaryLabel, digit, "badge = the key's digit")
            XCTAssertEqual(
                key.longPress?.compactMap(\.action.value), [digit],
                "long-press types the same digit directly")
            XCTAssertEqual(key.longPress?.first?.action.type, .literal)
        }
        let digitTwo = try XCTUnwrap(digits.first { $0.action.value == "2" })
        XCTAssertEqual(cycle.longPress?.count, digitTwo.longPress?.count)
        XCTAssertEqual(digitTwo.secondaryLabel, "2")

        // Persisted declaration consistency: the builtin phone9's stored first key also carries 1.
        let stored = BuiltinLayouts.phone9.rows[0].keys[0]
        XCTAssertEqual(stored.secondaryLabel, "1", "the declaration must carry 1 too, not only a runtime substitution")
        XCTAssertEqual(stored.longPress?.compactMap(\.action.value), ["1"])
        XCTAssertEqual(stored.action, .init(.literal, value: "，"))
    }

    /// Rail first three + first-key cycle must exactly partition the saved order: no duplicates, no gaps, same order.
    func testQuickSymbolPartitionCoversSavedOrderExactlyOnce() {
        for ascii in [false, true] {
            for saved in ["，。？！、…：；（）【】", "@/-()…", "@（，,、。.?？!！）…@", "。"] {
                let ordered = BuiltinLayouts.t9QuickSymbolValues(saved: saved, ascii: ascii)
                let rail = BuiltinLayouts.t9QuickRailValues(saved: saved, ascii: ascii)
                let cycle = BuiltinLayouts.t9QuickCycleValues(saved: saved, ascii: ascii)
                XCTAssertEqual(rail + cycle, ordered, "saved=\(saved) ascii=\(ascii)")
                XCTAssertLessThanOrEqual(rail.count, 3)
                XCTAssertEqual(Set(rail).count, rail.count, "the rail must not repeat")
                XCTAssertEqual(Set(cycle).count, cycle.count, "the cycle must not repeat")
                XCTAssertTrue(Set(rail).isDisjoint(with: Set(cycle)), "the two reachability sets must not overlap")
                XCTAssertEqual(cycle, Array(ordered.dropFirst(3)))
                XCTAssertFalse(
                    cycle.isEmpty,
                    "the original first-key marks keep the tail non-empty, so the first key never becomes dead")
            }
        }
    }

    /// Default sequence: the rail is exactly the top three frequent symbols, and the cycle starts at the 4th item and keeps the original first-key marks.
    func testDefaultOrderGivesRailThreeAndCycleFromFourth() {
        let saved = T9QuickSymbolStore.defaultSymbols
        XCTAssertEqual(
            BuiltinLayouts.t9QuickRailValues(saved: saved, ascii: false),
            ["，", "。", "？"])
        XCTAssertEqual(
            BuiltinLayouts.t9QuickCycleValues(saved: saved, ascii: false),
            ["！", "、", "…", "@", "/", ".", ":", "_", "-"])
        // ASCII: map full-width first, then de-duplicate (`、`->`,` and `，`->`,` collide, keeping only the first occurrence's position).
        XCTAssertEqual(BuiltinLayouts.t9QuickRailValues(saved: saved, ascii: true), [",", ".", "?"])
        XCTAssertEqual(
            BuiltinLayouts.t9QuickCycleValues(saved: saved, ascii: true),
            ["!", "...", "@", "/", ":", "_", "-"])
        for ascii in [false, true] {
            let cycle = BuiltinLayouts.t9QuickCycleValues(saved: saved, ascii: ascii)
            let rail = BuiltinLayouts.t9QuickRailValues(saved: saved, ascii: ascii)
            XCTAssertTrue(Set(rail).isDisjoint(with: Set(cycle)), "the first three must not reappear in the cycle")
        }
    }

    /// ASCII mapping must cover all full-width punctuation in the manager's default sequence, or ASCII fields get full-width characters.
    func testASCIIMappingCoversManagedDefaultPunctuation() {
        let managed = "，。？！、…：；（）【】"
        let mapped = BuiltinLayouts.t9QuickSymbolValues(saved: managed, ascii: true)
        XCTAssertEqual(
            Array(mapped.prefix(12)),
            [",", ".", "?", "!", "...", ":", ";", "(", ")", "[", "]", "@"])
        XCTAssertTrue(
            mapped.allSatisfy { $0.utf8.allSatisfy { $0 < 128 } },
            "the ASCII sequence must keep no full-width punctuation: \(mapped)")
        // Chinese mode keeps the user's characters verbatim, with no mapping.
        let chinese = BuiltinLayouts.t9QuickSymbolValues(saved: managed, ascii: false)
        XCTAssertEqual(
            Array(chinese.prefix(12)),
            ["，", "。", "？", "！", "、", "…", "：", "；", "（", "）", "【", "】"])
    }

    /// The address/URL marks are not in the quick bar default set; the cycle tail keeps them reachable.
    func testAddressMarksStayReachableFromTheCycle() {
        let saved = T9QuickSymbolStore.defaultSymbols
        for ascii in [false, true] {
            let cycle = BuiltinLayouts.t9QuickCycleValues(saved: saved, ascii: ascii)
            let rail = BuiltinLayouts.t9QuickRailValues(saved: saved, ascii: ascii)
            let ordered = BuiltinLayouts.t9QuickSymbolValues(saved: saved, ascii: ascii)
            for mark in BuiltinLayouts.t9PunctuationSymbols() {
                XCTAssertTrue(ordered.contains(mark), "\(mark) must still be reachable")
            }
            // `@` and `/` are not in the default quick set, so they land in the cycle (not the first three).
            XCTAssertTrue(cycle.contains("@"), "ascii=\(ascii)")
            XCTAssertTrue(cycle.contains("/"), "ascii=\(ascii)")
            XCTAssertFalse(rail.contains("@"), "ascii=\(ascii)")
            XCTAssertFalse(rail.contains("/"), "ascii=\(ascii)")
            // A mark duplicating an earlier item keeps only its first position.
            XCTAssertEqual(Set(cycle).count, cycle.count)
        }
    }

    /// Cap and first-insert action both derive from the cycle order: the label is the first three items, tap inserts the first.
    func testCycleKeyDerivesLabelAndInsertionFromRealOrder() throws {
        let key = try XCTUnwrap(BuiltinLayouts.t9CycleKey(["！", "、", "…"]))
        XCTAssertEqual(key.label, "！、…")
        XCTAssertEqual(key.action, .init(.literal, value: "！"))
        XCTAssertEqual(
            key.longPress?.compactMap(\.action.value), ["1"],
            "the cycle key has a single long-press alternate, digit 1 (like 2-9), and no symbol menu")
        XCTAssertNil(
            BuiltinLayouts.t9CycleKey([]), "an empty order must not fabricate a key that looks usable but is not")
        // With a single item, label and action are both that item.
        let single = try XCTUnwrap(BuiltinLayouts.t9CycleKey(["！"]))
        XCTAssertEqual(single.label, "！")
        XCTAssertEqual(single.action, .init(.literal, value: "！"))
        // Tied to the real default cycle order: the label must equal the first three items of that order.
        let cycle = BuiltinLayouts.t9QuickCycleValues(
            saved: T9QuickSymbolStore.defaultSymbols,
            ascii: false)
        XCTAssertEqual(
            try XCTUnwrap(BuiltinLayouts.t9CycleKey(cycle)).label,
            cycle.prefix(3).joined())
    }

    private func digitPad(globe: Bool, ascii: Bool = false) -> KeyboardControlPolicy {
        KeyboardControlPolicy(
            page: .numeric, isEnglishMode: false, hasGlobe: globe,
            isPhoneLayout: true, usesASCIIPunctuation: ascii, includesBottomEnter: false,
            usesDigitPadRow: true)
    }

    /// The 9-key digit page's bottom row is a grid row: 返回, 中/英, space, 符号 and Return, the
    /// globe first when shown. The 0 and the comma live in the right column, so there is no
    /// utility slot; any other phone page keeps its slots.
    func testDigitPadRowIsAGridRowWithSymbolsAndReturn() {
        XCTAssertEqual(
            digitPad(globe: false).slots.map(digitPad(globe: false).key(at:)),
            [.returnToLetters, .language, .space, .symbolPage, .enter])
        XCTAssertEqual(
            digitPad(globe: true).slots.map(digitPad(globe: true).key(at:)),
            [.globe, .returnToLetters, .language, .space, .symbolPage, .enter])
        let imported = KeyboardControlPolicy(
            page: .numeric, isEnglishMode: false, hasGlobe: true,
            isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false)
        XCTAssertFalse(imported.isDigitPad)
        XCTAssertTrue(imported.slots.contains(.utility))
        let letters = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: true,
            isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false,
            usesDigitPadRow: true)
        XCTAssertFalse(letters.isDigitPad)
    }

    /// One cell under the rail, three digit cells and one under the right column, with the right
    /// cell as wide as the rail; the globe takes the rail's cell and 返回 and 中/英 split the next.
    func testDigitPadMetricsFollowTheShellColumns() {
        let rail = 54.0
        for width in [320.0, 382.0, 432.0] {
            for globe in [false, true] {
                let policy = digitPad(globe: globe).aligned(to: .init(rail: rail, digit: 80))
                let m = policy.metrics(width: width)
                let cell = (width - 2 * rail - 16) / 3
                XCTAssertEqual(m[.space], cell, accuracy: 0.001)
                XCTAssertEqual(m[.symbolPage], cell, accuracy: 0.001)
                XCTAssertEqual(m[.enter], rail, accuracy: 0.001)
                let widths = policy.slots.map { m[$0] }
                XCTAssertEqual(widths.reduce(0, +) + 4 * Double(widths.count - 1), width, accuracy: 0.001)
                if globe {
                    XCTAssertEqual(m[.globe], rail, accuracy: 0.001)
                    XCTAssertEqual(m[.returnToLetters] + 4 + m[.language], cell, accuracy: 0.001)
                } else {
                    XCTAssertEqual(m[.returnToLetters], rail, accuracy: 0.001)
                    XCTAssertEqual(m[.language], cell, accuracy: 0.001)
                }
            }
        }
        // Without the shell's columns the row falls back to a fifth for the side keys.
        let bare = digitPad(globe: false).metrics(width: 400)
        XCTAssertEqual(bare[.enter], (400 - 16) / 5, accuracy: 0.001)
        // A letter page's symbol key is as wide as the page switch, as before.
        let letters = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: true,
            isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false)
        XCTAssertEqual(letters.metrics(width: 390)[.symbolPage], letters.metrics(width: 390)[.page])
    }

    /// An imported keypad keeps its declared trailing rail on 123, which has no 0, so its utility
    /// slot types 0; the bundled digit pad carries 0 in its own right column instead.
    func testImportedKeypadTypesZeroInTheUtilitySlot() {
        for digitPadRow in [false, true] {
            let policy = KeyboardControlPolicy(
                page: .numeric, isEnglishMode: false, hasGlobe: true,
                isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false,
                usesDigitPadRow: digitPadRow)
            XCTAssertEqual(policy.utility, digitPadRow ? .punctuation("，") : .digit("0"))
        }
    }

    /// I-D4: the native footer puts the comma left of the space bar and the full stop right of
    /// it, keeping the existing control keys; a narrow row falls back to the single comma key.
    func testNativeFooterPutsScriptPunctuationOnBothSidesOfTheSpaceBar() {
        for page in KeyboardControlPolicy.Page.allCases {
            for globe in [false, true] {
                let policy = KeyboardControlPolicy(
                    page: page, isEnglishMode: false, hasGlobe: globe,
                    isPhoneLayout: false, usesASCIIPunctuation: false,
                    usesCategorySymbolPage: false, script: .japanese, showsSpaceSideMarks: true)
                let slots = policy.slots
                guard let space = slots.firstIndex(of: .space) else {
                    XCTFail("no space bar on (page)")
                    continue
                }
                XCTAssertEqual(slots[space - 1], .markLeft, "comma left of space on (page)")
                XCTAssertEqual(slots[space + 1], .utility, "full stop right of space on (page)")
                XCTAssertEqual(policy.key(at: .markLeft), .markLeft)
                XCTAssertEqual(policy.key(at: .markRight), .markRight)
                XCTAssertEqual(policy.utility, .punctuation("。"))
                XCTAssertEqual(policy.utilityText, "、")
                XCTAssertEqual(policy.utilityAlternates.first, "・")
                XCTAssertEqual(policy.fullStopAlternates, ["？", "！", "…"])
            }
        }
    }

    /// The two marks take a constant share and the row still fills the width; below the fit
    /// threshold the space bar would drop under 44pt and the caller falls back.
    func testSpaceSideMarksKeepTheRowWidthAndFallBackWhenTooNarrow() {
        let policy = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: true, isPhoneLayout: false,
            usesASCIIPunctuation: false, script: .japanese, showsSpaceSideMarks: true)
        for width in [382.0, 390, 430, 768] {
            let metrics = policy.metrics(width: width)
            let used =
                policy.slots.reduce(0) { $0 + metrics[$1] }
                + Double(policy.slots.count - 1) * metrics.spacing
            XCTAssertEqual(used, width, accuracy: 0.5, "row fills (width)")
            XCTAssertGreaterThanOrEqual(metrics.space, 44, "space stays usable at (width)")
            XCTAssertGreaterThan(metrics.markLeft, 0)
            XCTAssertGreaterThan(metrics.markRight, 0)
            // The full stop was wider than Return; the marks now match and Return takes the rest.
            XCTAssertEqual(metrics.markRight, metrics.markLeft, accuracy: 0.001)
            XCTAssertGreaterThan(metrics.enter, metrics.markRight)
        }
        XCTAssertLessThan(policy.metrics(width: 320).space, 44)
        XCTAssertEqual(policy.withSpaceSideMarks(false).slots.contains(.markLeft), false)
    }

    /// The letter and row pages share one comma key in the utility position, with the other
    /// sentence marks on long press, so it stays put when the page flips.
    func testRowPagesAndLettersShareTheCommaKey() {
        for ascii in [false, true] {
            for page in KeyboardControlPolicy.Page.allCases {
                let policy = KeyboardControlPolicy(
                    page: page, isEnglishMode: ascii, hasGlobe: true,
                    isPhoneLayout: false, usesASCIIPunctuation: ascii, usesCategorySymbolPage: false)
                XCTAssertEqual(policy.key(at: .utility), .utility)
                XCTAssertEqual(policy.utility, .punctuation(ascii ? "," : "，"))
                XCTAssertEqual(
                    policy.utilityAlternates, ascii ? [".", "?", "!", "'", "\""] : ["。", "？", "！", "、", "…"])
            }
        }
    }

    /// The row-shaped #+= page (the default) has no 锁定 (its utility slot is the comma and its
    /// third row opens with the 123 switch): its language key switches symbols in place and its
    /// left switch returns to letters.
    func testRowShapedSymbolPageTypesCommaAndLanguageSwitchesSymbols() {
        for english in [false, true] {
            let policy = KeyboardControlPolicy(
                page: .symbols, isEnglishMode: english, hasGlobe: true,
                isPhoneLayout: false, usesASCIIPunctuation: english, usesCategorySymbolPage: false)
            XCTAssertEqual(policy.key(at: .utility), .utility)
            XCTAssertEqual(policy.pageTarget, .numeric)
            XCTAssertEqual(policy.pageTitle, "123")
            XCTAssertEqual(policy.key(at: .page), .returnToLetters)
            XCTAssertEqual(policy.languageAction, .toggleSymbols)
            XCTAssertEqual(policy.languageTitle, "中/英")
            XCTAssertEqual(policy.languageCurrentSideIsFirst(for: nil), !english)
            XCTAssertEqual(Array(policy.slots.map(policy.key(at:)).prefix(3)), [.globe, .returnToLetters, .language])
        }
        let grid = KeyboardControlPolicy(
            page: .symbols, isEnglishMode: false, hasGlobe: true,
            isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false)
        XCTAssertEqual(grid.key(at: .utility), .symbolLock)
    }

    /// Builtin 9-key 2-9 long-press must work and use the layout's declared digit.
    ///
    /// Uses the real API (not just static LayoutKey assertions): first proves the generic policy returns empty for a
    /// digit-code key with an ABC cap (which is why it cannot go through that path), then that the production
    /// predicate hands them to the declared path and the declared alternate is exactly that digit's literal.
    func testT9DigitKeysTakeDeclaredAlternatesBecausePolicyDropsThem() throws {
        let digits = BuiltinLayouts.phone9.rows.flatMap(\.keys).filter {
            $0.action.type == .code && ("2"..."9").contains($0.action.value ?? "")
        }
        XCTAssertEqual(digits.count, 8, "the builtin 9-key should have 8 digit keys (2-9)")

        for key in digits {
            let digit = try XCTUnwrap(key.action.value)

            // The generic policy returns empty for these keys (reproduces the request the panel really builds).
            let policyOptions = AlternateKeyPolicy.options(
                for: .init(
                    keyLabel: digit,
                    mergedGroup: key.label.lowercased(),
                    secondaryLiterals: (key.longPress ?? []).compactMap {
                        $0.action.type == .literal ? $0.action.value : nil
                    },
                    page: .letters,
                    language: .chinese,
                    schemaAlphabet: "abcdefghijklmnopqrstuvwxyz"))
            XCTAssertTrue(
                policyOptions.isEmpty,
                "\(digit) generic policy must return empty, otherwise this regression is moot (root cause changed; revisit)"
            )

            // The production predicate must route these keys to the declared path.
            XCTAssertTrue(
                BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(key),
                "\(digit) must take the declared path, otherwise the long-press digit is lost")

            // The declared alternate is exactly that digit's literal (long-press types it directly, not a code).
            let declared = try XCTUnwrap(key.longPress)
            XCTAssertEqual(declared.count, 1, "\(digit) should have exactly one declared long-press alternate")
            XCTAssertEqual(declared.first?.action, .init(.literal, value: digit))
            XCTAssertEqual(declared.first?.label, digit)
        }
    }

    /// The predicate must not hit control keys, auxiliary keys, letter keys or DIY definitions (that would open the
    /// fixed letter menu or rewrite other layouts' alternate policy).
    func testDeclaredAlternatesPredicateOnlyCoversBundledT9Digits() {
        for key in BuiltinLayouts.phone9.rows.flatMap(\.keys) {
            let value = key.action.value ?? ""
            let isDigit = key.action.type == .code && ("2"..."9").contains(value) && value.count == 1
            XCTAssertEqual(
                BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(key), isDigit,
                "\(key.label) predicate disagrees with \"is a digit-code key\"")
        }
        // Control row (layout/space/globe) and auxiliary area (delete/separator/return) are all excluded.
        for area in BuiltinLayouts.phone9.auxiliaryAreas ?? [] {
            for key in area.keys {
                XCTAssertFalse(
                    BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(key),
                    "auxiliary key \(key.label)  must not take the declared path")
            }
        }
        // 26-key letter keys are unaffected (their generic policy path is valid and must stay).
        let letter = BuiltinLayouts.qwerty26.rows.flatMap(\.keys)
            .first { $0.action.type == .code && $0.label == "a" }
        if let letter {
            XCTAssertFalse(
                BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(letter),
                "letter keys must keep going through AlternateKeyPolicy")
            let options = AlternateKeyPolicy.options(
                for: .init(
                    keyLabel: "a", secondaryLiterals: ["，", ","], page: .letters, language: .chinese))
            XCTAssertEqual(options.map(\.label), ["，", ","], "the 26-key letter key alternate policy must not change")
        }
        // Digit-code keys without declared long-press alternates fall back to the generic policy (no new behavior).
        let bare = LayoutKey(label: "ABC", secondaryLabel: "2", action: .init(.code, value: "2"))
        XCTAssertFalse(BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(bare))
    }

    /// The row-shaped symbol page keeps the letters footer's shape, and 更多 takes the full stop's
    /// place right of the space bar at the comma's width; Return stays wider. The 123 page keeps 。.
    func testSymbolPageFooterEndsWithSymbolLibraryKeyAtMarkWidth() {
        for globe in [false, true] {
            for marks in [false, true] {
                let symbols = KeyboardControlPolicy(
                    page: .symbols, isEnglishMode: false, hasGlobe: globe, isPhoneLayout: false,
                    usesASCIIPunctuation: false, usesCategorySymbolPage: false,
                    showsSpaceSideMarks: marks, offersSymbolLibrary: true)
                let footer = symbols.slots.map { symbols.key(at: $0) }
                var expected: [KeyboardControlPolicy.Slot] =
                    globe ? [.globe] : []
                expected += [.returnToLetters, .language]
                expected += marks ? [.markLeft] : []
                expected += [.space, .symbolLibrary, .enter]
                XCTAssertEqual(footer, expected, "globe \(globe) marks \(marks)")
                let metrics = symbols.metrics(width: 390)
                XCTAssertEqual(metrics[.symbolLibrary], metrics[.utility])
                if marks {
                    XCTAssertEqual(metrics[.symbolLibrary], metrics[.markLeft], accuracy: 0.001)
                    XCTAssertGreaterThan(metrics[.enter], metrics[.symbolLibrary])
                }
                // 123 keeps its full stop.
                let numeric = KeyboardControlPolicy(
                    page: .numeric, isEnglishMode: false, hasGlobe: globe, isPhoneLayout: false,
                    usesASCIIPunctuation: false, usesCategorySymbolPage: false,
                    showsSpaceSideMarks: marks, offersSymbolLibrary: true)
                XCTAssertEqual(numeric.key(at: .utility), .utility)
                // Not asked for (authored, preview), categorized and phone pages are untouched.
                let plain = KeyboardControlPolicy(
                    page: .symbols, isEnglishMode: false, hasGlobe: globe, isPhoneLayout: false,
                    usesASCIIPunctuation: false, usesCategorySymbolPage: false,
                    showsSpaceSideMarks: marks)
                XCTAssertEqual(plain.key(at: .utility), .utility)
                let category = KeyboardControlPolicy(
                    page: .symbols, isEnglishMode: false, hasGlobe: globe, isPhoneLayout: false,
                    usesASCIIPunctuation: false, usesCategorySymbolPage: true, offersSymbolLibrary: true)
                XCTAssertEqual(category.key(at: .utility), .symbolLock)
            }
        }
    }

    func testSymbolLibraryKeyFollowsInputLanguage() {
        XCTAssertEqual(KeyLabelPolicy.symbolLibraryTitle(script: .simplifiedChinese), "更多")
        XCTAssertEqual(KeyLabelPolicy.symbolLibraryTitle(script: .traditionalChinese), "更多")
        XCTAssertEqual(KeyLabelPolicy.symbolLibraryTitle(script: .japanese), "その他")
        XCTAssertFalse(KeyLabelPolicy.symbolLibraryAccessibilityLabel().isEmpty)
        XCTAssertNotEqual(KeyLabelPolicy.symbolLibraryAccessibilityLabel(), "key.page.symbolLibrary")
    }
}
