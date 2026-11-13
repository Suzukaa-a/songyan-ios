import XCTest

@testable import LayoutKit

final class KeyboardPageFooterGeometryTests: XCTestCase {
    func testCopiedSymbolFooterKeepsNativeKeysAndGeometry() throws {
        for automatic in [false, true] {
            let source =
                automatic ? KeyboardPagePresets.symbolsSystem : KeyboardPagePresets.symbolRowsPage(ascii: false)
            for globe in [false, true] {
                let keys = try XCTUnwrap(source.materialized().chrome?.bottom).forSystemSwitch(shown: globe)
                for ascii in [false, true] {
                    let policy = KeyboardControlPolicy(
                        page: .symbols, isEnglishMode: false, hasGlobe: globe, isPhoneLayout: false,
                        usesASCIIPunctuation: ascii, usesCategorySymbolPage: false,
                        showsSpaceSideMarks: true, offersSymbolLibrary: automatic)
                    for width in [375.0, 402, 600, 834] {
                        let geometry = KeyboardPageFooterGeometry(width: width, keys: keys, policy: policy)
                        let native = policy.metrics(width: width)
                        XCTAssertEqual(geometry.keyWidths, policy.slots.map { native[$0] })
                        XCTAssertEqual(geometry.spacing, native.spacing)
                        XCTAssertTrue(geometry.usesControlRowBudget)
                    }
                }
            }
        }
    }

    private func lettersPolicy(globe: Bool = true) -> KeyboardControlPolicy {
        KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: globe,
            isPhoneLayout: false, usesASCIIPunctuation: false)
    }

    private func footer(_ page: KeyboardPageDefinition) -> [LayoutKey] {
        page.materialized().chrome?.bottom ?? []
    }

    private func assertFillsWidth(
        _ geometry: KeyboardPageFooterGeometry, width: Double, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            geometry.keyWidths.reduce(0, +) + geometry.spacing * Double(max(0, geometry.keyWidths.count - 1)),
            width, accuracy: 0.001, file: file, line: line)
        XCTAssertTrue(geometry.keyWidths.allSatisfy { $0.isFinite && $0 >= 0 }, file: file, line: line)
    }

    func testDefaultABCFooterKeepsTheControlRowBudget() {
        let keys = footer(KeyboardPagePresets.englishQwerty)
        for width in [320.0, 382, 466, 834] {
            let policy = lettersPolicy()
            let geometry = KeyboardPageFooterGeometry(width: width, keys: keys, policy: policy)
            XCTAssertTrue(geometry.usesControlRowBudget)
            let metrics = policy.metrics(width: width)
            for (width, expected) in zip(geometry.keyWidths, policy.slots.map({ metrics[$0] })) {
                XCTAssertEqual(width, expected, accuracy: 1e-9)
            }
            // The tuned default bottom row is not squeezed by a fresh copy.
            XCTAssertEqual(geometry.keyWidths[3], metrics[.space], accuracy: 0.001)
            assertFillsWidth(geometry, width: width)
        }
    }

    func testHiddenGlobeUsesTheSameBudgetWithoutItsWidth() {
        let metricsKeys = footer(KeyboardPagePresets.englishQwerty).filter { $0.action.type != .globe }
        let policy = lettersPolicy(globe: false)
        let geometry = KeyboardPageFooterGeometry(width: 382, keys: metricsKeys, policy: policy)
        XCTAssertTrue(geometry.usesControlRowBudget)
        XCTAssertEqual(geometry.keyWidths.count, metricsKeys.count)
        assertFillsWidth(geometry, width: 382)
        XCTAssertGreaterThan(geometry.keyWidths[2], 100, "space takes the width the hidden globe gave up")
    }

    func testEveryDefaultFooterVariantMatchesItsOwnControlRowPolicy() {
        let variants: [(KeyboardPageDefinition, KeyboardControlPolicy)] = [
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
            assertFillsWidth(geometry, width: 402)
        }
    }

    private func digitPadPolicy(globe: Bool) -> KeyboardControlPolicy {
        KeyboardControlPolicy(
            page: .numeric, isEnglishMode: false, hasGlobe: globe,
            isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false,
            usesDigitPadRow: true)
    }

    /// The keypad footer is the digit pad's grid row: 返回 under the rail, 中英, space and 符号
    /// one digit column each, Return as wide as the rail; the globe takes the rail's cell.
    func testKeypadFooterOnThePhoneShellKeepsTheRailColumns() {
        let rail = 88.0
        let policy = digitPadPolicy(globe: false)
        let keys = footer(KeyboardPagePresets.numericKeypad).filter { $0.action.type != .globe }
        let geometry = KeyboardPageFooterGeometry(
            width: 402, keys: keys, policy: policy, rails: .init(leading: rail, trailing: rail))
        XCTAssertTrue(geometry.usesControlRowBudget)
        let cell = (402 - 2 * rail - 16) / 3
        XCTAssertEqual(geometry.keyWidths[0], rail, accuracy: 0.001, "返回 sits under the rail")
        for width in geometry.keyWidths[1...3] { XCTAssertEqual(width, cell, accuracy: 0.001) }
        XCTAssertEqual(geometry.keyWidths[4], rail, accuracy: 0.001, "Return sits under the right column")
        assertFillsWidth(geometry, width: 402)

        let withGlobe = KeyboardPageFooterGeometry(
            width: 402, keys: footer(KeyboardPagePresets.numericKeypad), policy: digitPadPolicy(globe: true),
            rails: .init(leading: rail, trailing: rail))
        XCTAssertTrue(withGlobe.usesControlRowBudget)
        XCTAssertEqual(withGlobe.keyWidths[0], rail, accuracy: 0.001, "the globe leads under the rail")
        XCTAssertEqual(withGlobe.keyWidths[1] + 4 + withGlobe.keyWidths[2], cell, accuracy: 0.001)
        assertFillsWidth(withGlobe, width: 402)
    }

    /// A copied or edited pad's footer keeps the columns of the rows above: first key under the
    /// leading rail, last under the trailing rail, the rest by their own weights in between.
    func testAFooterUnderRailsStartsUnderTheLeadingRailAndEndsUnderTheTrailingOne() {
        var keys = footer(KeyboardPagePresets.numericKeypad).filter { $0.action.type != .globe }
        keys[1] = keys[1].settingWidth(2)
        let geometry = KeyboardPageFooterGeometry(
            width: 400, keys: keys, policy: digitPadPolicy(globe: false), rails: .init(leading: 60, trailing: 50))
        XCTAssertFalse(geometry.usesControlRowBudget)
        XCTAssertEqual(geometry.keyWidths.first ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(geometry.keyWidths.last ?? 0, 50, accuracy: 0.001)
        let rest = Array(geometry.keyWidths.dropFirst().dropLast())
        XCTAssertEqual(rest[0], rest[1] * 2, accuracy: 0.001)
        assertFillsWidth(geometry, width: 400)

        // Without a leading rail only the last key is pinned; without any rails weights decide.
        let trailingOnly = KeyboardPageFooterGeometry(
            width: 400, keys: keys, policy: digitPadPolicy(globe: false), rails: .init(leading: 0, trailing: 50))
        XCTAssertEqual(trailingOnly.keyWidths.last ?? 0, 50, accuracy: 0.001)
        assertFillsWidth(trailingOnly, width: 400)
        let plain = KeyboardPageFooterGeometry(width: 400, keys: keys, policy: digitPadPolicy(globe: false))
        XCTAssertNotEqual(plain.keyWidths.first, 60)
        // Rails that leave no room for the middle keys fall back to the authored weights.
        let tooWide = KeyboardPageFooterGeometry(
            width: 100, keys: keys, policy: digitPadPolicy(globe: false), rails: .init(leading: 90, trailing: 90))
        assertFillsWidth(tooWide, width: 100)
    }

    /// A stored copy of the retired keypad is an untouched old preset and gives way; an edited one stays.
    func testRetiredKeypadChromeIsReplacedOnlyWhenUntouched() {
        var old = KeyboardPagePresets.numericKeypad
        old.chrome = KeyboardPageDefinition.previousKeypadChrome(marks: .chinese)
        let resolved = KeyboardPagePresets.resolvingRetired(pages: [old], compositions: [:])
        XCTAssertTrue(resolved.pages.isEmpty)
        var edited = old
        edited.chrome?.bottom.removeLast()
        XCTAssertEqual(KeyboardPagePresets.resolvingRetired(pages: [edited], compositions: [:]).pages, [edited])
        XCTAssertEqual(
            KeyboardPagePresets.resolvingRetired(pages: [KeyboardPagePresets.numericKeypad], compositions: [:]).pages,
            [KeyboardPagePresets.numericKeypad])
        XCTAssertNotEqual(old.chrome, KeyboardPagePresets.numericKeypad.chrome)
    }

    /// Pages saved while the globe came first, or right after the page key, keep the native widths,
    /// each key its own slot's, and an untouched stored copy of a preset in that order still counts
    /// as the preset.
    func testFootersSavedWithAnEarlierGlobePlaceKeepTheirWidths() throws {
        let policy = lettersPolicy()
        let keys = footer(KeyboardPagePresets.englishQwerty)
        let current = KeyboardPageFooterGeometry(width: 382, keys: keys, policy: policy)
        XCTAssertTrue(current.usesControlRowBudget)
        let globe = try XCTUnwrap(keys.firstIndex { $0.action.type == .globe })
        for place in [0, 1] {
            var saved = keys
            saved.insert(saved.remove(at: globe), at: place)
            let geometry = KeyboardPageFooterGeometry(width: 382, keys: saved, policy: policy)
            XCTAssertTrue(geometry.usesControlRowBudget, "globe at \(place)")
            let widths = keys.map { key in geometry.keyWidths[saved.firstIndex(of: key)!] }
            for (width, expected) in zip(widths, current.keyWidths) {
                XCTAssertEqual(width, expected, accuracy: 0.001, "globe at \(place)")
            }
        }

        var keypad = KeyboardPagePresets.numericKeypad
        var bottom = keypad.chrome?.bottom ?? []
        bottom.insert(bottom.remove(at: 1), at: 0)
        keypad.chrome?.bottom = bottom
        XCTAssertTrue(KeyboardPagePresets.resolvingRetired(pages: [keypad], compositions: [:]).pages.isEmpty)
    }

    func testCustomLabelsAndLongPressDoNotChangeTheGeometry() {
        let policy = lettersPolicy()
        let baseline = KeyboardPageFooterGeometry(
            width: 382, keys: footer(KeyboardPagePresets.englishQwerty), policy: policy)
        let decorated = footer(KeyboardPagePresets.englishQwerty).map { key in
            key.title("我的\(key.label)").settingSecondaryLabel("提示").settingLongPress([
                LayoutOption(label: "选项", action: .pageSwitch(.letters))
            ])
        }
        let geometry = KeyboardPageFooterGeometry(width: 382, keys: decorated, policy: policy)
        XCTAssertTrue(geometry.usesControlRowBudget)
        XCTAssertEqual(geometry.keyWidths, baseline.keyWidths)
    }

    func testExplicitWidthsUseWeightsWhileAutomaticKeyChangesKeepTheControlBudget() {
        let policy = lettersPolicy()
        let defaults = footer(KeyboardPagePresets.englishQwerty)
        var spaceWider = defaults
        spaceWider[3] = spaceWider[3].settingWidth(3)
        XCTAssertFalse(
            KeyboardPageFooterGeometry(width: 382, keys: spaceWider, policy: policy).usesControlRowBudget)

        var globeExplicit = defaults
        globeExplicit[0] = globeExplicit[0].settingWidth(1)
        XCTAssertFalse(
            KeyboardPageFooterGeometry(width: 382, keys: globeExplicit, policy: policy).usesControlRowBudget)

        var letterExplicit = defaults
        letterExplicit[1] = letterExplicit[1].settingWidth(1)
        XCTAssertFalse(
            KeyboardPageFooterGeometry(width: 382, keys: letterExplicit, policy: policy).usesControlRowBudget)

        let reordered = [defaults[0], defaults[2], defaults[1], defaults[3], defaults[4], defaults[5]]
        XCTAssertTrue(
            KeyboardPageFooterGeometry(width: 382, keys: reordered, policy: policy).usesControlRowBudget)

        let fewer = Array(defaults.dropLast())
        XCTAssertTrue(
            KeyboardPageFooterGeometry(width: 382, keys: fewer, policy: policy).usesControlRowBudget)
        let more = defaults + [LayoutKey(label: "×", action: .init(.clearInput))]
        XCTAssertTrue(
            KeyboardPageFooterGeometry(width: 382, keys: more, policy: policy).usesControlRowBudget)

        // An omitted key is never added back; the remaining keys keep automatic sizing.
        let globeDeleted = Array(defaults.dropFirst())
        XCTAssertTrue(
            KeyboardPageFooterGeometry(width: 382, keys: globeDeleted, policy: policy).usesControlRowBudget)
    }

    func testAuthoredRelativeWidthsShareTheAvailableWidth() {
        let keys = [
            LayoutKey(label: "a", width: 1, action: .pageSwitch(.numeric)),
            LayoutKey(label: "b", width: 3, action: .init(.literal, value: "b")),
        ]
        let policy = lettersPolicy()
        let geometry = KeyboardPageFooterGeometry(width: 402, keys: keys, policy: policy)
        XCTAssertFalse(geometry.usesControlRowBudget)
        let available = 402 - geometry.spacing
        XCTAssertEqual(geometry.keyWidths, [available / 4, available * 3 / 4])
        assertFillsWidth(geometry, width: 402)
    }

    func testHugeFiniteWeightsStayFinite() {
        let keys = [
            LayoutKey(label: "a", width: Double.greatestFiniteMagnitude, action: .pageSwitch(.letters)),
            LayoutKey(label: "b", width: 1, action: .init(.literal, value: "b")),
            LayoutKey(label: "c", width: Double.greatestFiniteMagnitude, action: .init(.literal, value: "c")),
        ]
        let geometry = KeyboardPageFooterGeometry(width: 402, keys: keys, policy: lettersPolicy())
        XCTAssertFalse(geometry.usesControlRowBudget)
        XCTAssertTrue(geometry.keyWidths.allSatisfy { $0.isFinite && $0 >= 0 })
        XCTAssertEqual(geometry.keyWidths[0], geometry.keyWidths[2], accuracy: 0.001)
        XCTAssertLessThan(geometry.keyWidths[1], geometry.keyWidths[0])
        assertFillsWidth(geometry, width: 402)
    }

    func testWeightedSixKeyFooterFitsWithoutClippingTheReturnKey() {
        let weights = [1.0, 1, 1, 3, 1, 2]
        let keys = zip(footer(KeyboardPagePresets.englishQwerty), weights).map { $0.settingWidth($1) }
        for width in [320.0, 374, 394, 592] {
            let geometry = KeyboardPageFooterGeometry(width: width, keys: keys, policy: lettersPolicy())
            XCTAssertFalse(geometry.usesControlRowBudget)
            XCTAssertNil(geometry.scrollWidths(availableWidth: width))
            XCTAssertTrue(geometry.keyWidths.allSatisfy { $0 >= 44 })
            assertFillsWidth(geometry, width: width)
            XCTAssertEqual(geometry.keyWidths[3] / geometry.keyWidths[5], 1.5, accuracy: 0.001)
        }
        let wide = KeyboardPageFooterGeometry(width: 592, keys: keys, policy: lettersPolicy())
        XCTAssertEqual(wide.keyWidths[3] / wide.keyWidths[0], 3, accuracy: 0.001)
        XCTAssertEqual(wide.keyWidths[5] / wide.keyWidths[0], 2, accuracy: 0.001)
        let narrow = KeyboardPageFooterGeometry(width: 240, keys: keys, policy: lettersPolicy())
        XCTAssertTrue(narrow.scrollWidths(availableWidth: 240)?.allSatisfy { $0 >= 44 } == true)
    }

    func testEmptyAndInvalidFootersStayFinite() {
        let policy = lettersPolicy()
        let empty = KeyboardPageFooterGeometry(width: 382, keys: [], policy: policy)
        XCTAssertTrue(empty.keyWidths.isEmpty)
        XCTAssertFalse(empty.usesControlRowBudget)
        for width in [-1.0, .nan, .infinity] {
            let geometry = KeyboardPageFooterGeometry(
                width: width, keys: footer(KeyboardPagePresets.englishQwerty), policy: policy)
            XCTAssertTrue(geometry.keyWidths.allSatisfy(\.isFinite))
            XCTAssertTrue(geometry.keyWidths.allSatisfy { $0 >= 0 })
        }
    }
}
