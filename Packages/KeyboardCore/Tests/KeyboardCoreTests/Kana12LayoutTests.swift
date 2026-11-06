import KeyboardCore
import XCTest

/// Pins the J2.2 grid and the J2.3/J2.4 cycles: 4x3 kana keys, flick directions exact,
/// tap cycles, and the 小゛゜ variant chain per row.
final class Kana12LayoutTests: XCTestCase {
    private let expectedOutputs: [Kana12Key: [Kana12FlickDirection: Kana12KeyOutput]] = [
        .a: [.tap: .kana("あ"), .left: .kana("い"), .up: .kana("う"), .right: .kana("え"), .down: .kana("お")],
        .ka: [.tap: .kana("か"), .left: .kana("き"), .up: .kana("く"), .right: .kana("け"), .down: .kana("こ")],
        .sa: [.tap: .kana("さ"), .left: .kana("し"), .up: .kana("す"), .right: .kana("せ"), .down: .kana("そ")],
        .ta: [.tap: .kana("た"), .left: .kana("ち"), .up: .kana("つ"), .right: .kana("て"), .down: .kana("と")],
        .na: [.tap: .kana("な"), .left: .kana("に"), .up: .kana("ぬ"), .right: .kana("ね"), .down: .kana("の")],
        .ha: [.tap: .kana("は"), .left: .kana("ひ"), .up: .kana("ふ"), .right: .kana("へ"), .down: .kana("ほ")],
        .ma: [.tap: .kana("ま"), .left: .kana("み"), .up: .kana("む"), .right: .kana("め"), .down: .kana("も")],
        .ya: [.tap: .kana("や"), .left: .literal("（"), .up: .kana("ゆ"), .right: .literal("）"), .down: .kana("よ")],
        .ra: [.tap: .kana("ら"), .left: .kana("り"), .up: .kana("る"), .right: .kana("れ"), .down: .kana("ろ")],
        // J2.2 gives わ行 only tap/left/up/right; down has no verified glyph, so it stays empty
        // instead of inventing ～ or ゎ on a flick.
        .wa: [.tap: .kana("わ"), .left: .kana("を"), .up: .kana("ん"), .right: .kana("ー")],
        .punctuation: [
            .tap: .literal("、"), .left: .literal("。"), .up: .literal("？"), .right: .literal("！"), .down: .literal("…"),
        ],
        .modifier: [:],
    ]

    private let expectedToggleCycles: [Kana12Key: [String]] = [
        .a: ["あ", "い", "う", "え", "お", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ"],
        .ka: ["か", "き", "く", "け", "こ", "が", "ぎ", "ぐ", "げ", "ご"],
        .sa: ["さ", "し", "す", "せ", "そ", "ざ", "じ", "ず", "ぜ", "ぞ"],
        .ta: ["た", "ち", "つ", "て", "と", "だ", "ぢ", "づ", "で", "ど"],
        .na: ["な", "に", "ぬ", "ね", "の"],
        .ha: ["は", "ひ", "ふ", "へ", "ほ", "ば", "び", "ぶ", "べ", "ぼ", "ぱ", "ぴ", "ぷ", "ぺ", "ぽ"],
        .ma: ["ま", "み", "む", "め", "も"],
        .ya: ["や", "ゆ", "よ", "ゃ", "ゅ", "ょ"],
        .ra: ["ら", "り", "る", "れ", "ろ"],
        .wa: ["わ", "を", "ん", "ー", "ゎ"],
        .punctuation: [],
        .modifier: [],
    ]

    /// The 小゛゜ chain for every row; only these kana react to the modifier.
    private let expectedVariantCycles: [[String]] = [
        ["あ", "ぁ"], ["い", "ぃ"], ["う", "ぅ"], ["え", "ぇ"], ["お", "ぉ"],
        ["か", "が"], ["き", "ぎ"], ["く", "ぐ"], ["け", "げ"], ["こ", "ご"],
        ["さ", "ざ"], ["し", "じ"], ["す", "ず"], ["せ", "ぜ"], ["そ", "ぞ"],
        ["た", "だ"], ["ち", "ぢ"], ["つ", "っ", "づ"], ["て", "で"], ["と", "ど"],
        ["は", "ば", "ぱ"], ["ひ", "び", "ぴ"], ["ふ", "ぶ", "ぷ"], ["へ", "べ", "ぺ"], ["ほ", "ぼ", "ぽ"],
        ["や", "ゃ"], ["ゆ", "ゅ"], ["よ", "ょ"], ["わ", "ゎ"],
    ]

    func testFlickGridMatchesTheJ2LayoutExactly() {
        for key in Kana12Key.allCases {
            for direction in Kana12FlickDirection.allCases {
                XCTAssertEqual(
                    Kana12Layout.output(for: key, direction: direction),
                    expectedOutputs[key]?[direction],
                    "\(key) \(direction)")
            }
        }
    }

    func testKanaAndLiteralHelpersSplitTheGridOutput() {
        XCTAssertEqual(Kana12Layout.kana(for: .ya, direction: .left), nil)
        XCTAssertEqual(Kana12Layout.literal(for: .ya, direction: .left), "（")
        XCTAssertEqual(Kana12Layout.literal(for: .ya, direction: .right), "）")
        XCTAssertEqual(Kana12Layout.kana(for: .wa, direction: .right), "ー")
        XCTAssertEqual(Kana12Layout.kana(for: .wa, direction: .down), nil)
        XCTAssertNil(Kana12Layout.output(for: .modifier, direction: .tap))
    }

    func testTapCyclesMatchTheJ2Rows() {
        for key in Kana12Key.allCases {
            XCTAssertEqual(Kana12Layout.toggleCycle(for: key), expectedToggleCycles[key], "\(key)")
        }
        for (key, cycle) in expectedToggleCycles {
            for kana in cycle {
                XCTAssertNotNil(Kana12RomajiTable.romaji(for: kana), "\(key): \(kana)")
            }
        }
    }

    func testVariantChainsMatchTheVerifiedCycles() {
        for cycle in expectedVariantCycles {
            XCTAssertEqual(followVariantChain(from: cycle[0]), cycle)
            for kana in cycle {
                XCTAssertNotNil(Kana12RomajiTable.romaji(for: kana), kana)
            }
        }
    }

    func testKanaWithoutVariantsDoNotReactToTheModifier() {
        let variantFree = ["な", "に", "ぬ", "ね", "の", "ま", "み", "む", "め", "も", "ら", "り", "る", "れ", "ろ", "を", "ん", "ー"]
        for kana in variantFree {
            XCTAssertNil(Kana12Layout.nextVariant(of: kana), kana)
        }
        for (kana, next) in [
            ("つ", "っ"), ("っ", "づ"), ("づ", "つ"), ("は", "ば"), ("ば", "ぱ"), ("ぱ", "は"), ("あ", "ぁ"), ("ぁ", "あ"), ("わ", "ゎ"),
            ("ゎ", "わ"),
        ] {
            XCTAssertEqual(Kana12Layout.nextVariant(of: kana), next, kana)
        }
        XCTAssertNil(Kana12Layout.nextVariant(of: "ゔ"))
    }

    private func followVariantChain(from start: String) -> [String] {
        var chain = [start]
        var current = start
        while let next = Kana12Layout.nextVariant(of: current), next != start, !chain.contains(next) {
            chain.append(next)
            current = next
        }
        return chain
    }
}
