import KeyboardCore
import XCTest

/// J2.3 tap cycle and J2.4 小゛゜ replacement through the public model API. Effects are the
/// front end contract: append kana, replace the trailing kana with exactly one BackSpace, or
/// insert a literal directly. The model never talks to an engine; ownership is only kept while
/// the front end observes the composition this model predicted.
final class Kana12InputModelTests: XCTestCase {
    // MARK: - Harness

    private func romaji(_ kana: String) -> String {
        guard let romaji = Kana12RomajiTable.romaji(for: kana) else {
            XCTFail("No compiled romaji for \(kana)")
            return ""
        }
        return romaji
    }

    private func atEnd(_ composition: String) -> Kana12Observation {
        Kana12Observation(composition: composition.isEmpty ? nil : composition, caret: composition.count)
    }

    /// Drives the model the way the keyboard does: read the engine composition, press, then
    /// apply the effect so the next press observes the post-write text.
    private struct Simulator {
        var model: Kana12InputModel
        private(set) var composition = ""
        private var now: TimeInterval = 0

        init(flickOnly: Bool = false) {
            model = Kana12InputModel(flickOnly: flickOnly)
        }

        var observed: Kana12Observation {
            Kana12Observation(composition: composition.isEmpty ? nil : composition, caret: composition.count)
        }

        @discardableResult
        mutating func press(_ key: Kana12Key, _ direction: Kana12FlickDirection = .tap) -> Kana12Effect {
            now += 0.1
            let effect = model.press(key, direction: direction, at: now, observed: observed)
            switch effect {
            case .append(let kana, _):
                composition += kana
            case .replace(_, let kana, _):
                composition = String(composition.dropLast()) + kana
            case .literal:
                composition = ""
            case .none:
                break
            }
            return effect
        }
    }

    // MARK: - Grid and flick directions

    func testToggleIntervalIsEightTenthsAndFlickOnlyDefaultsOff() {
        XCTAssertEqual(Kana12InputModel.toggleInterval, 0.8)
        XCTAssertFalse(Kana12InputModel().flickOnly)
        XCTAssertTrue(Kana12InputModel(flickOnly: true).flickOnly)
    }

    func testFirstPressAppendsTheTapKanaWithItsValidatedRomaji() {
        let cases: [(Kana12Key, Kana12FlickDirection, String, String)] = [
            (.a, .tap, "あ", "a"),
            (.ka, .tap, "か", "ka"),
            (.ha, .tap, "は", "ha"),
            (.ya, .tap, "や", "ya"),
            (.ta, .down, "と", "to"),
            (.wa, .up, "ん", "nn"),
            (.wa, .right, "ー", "-"),
        ]
        for (key, direction, kana, code) in cases {
            var model = Kana12InputModel()
            XCTAssertEqual(
                model.press(key, direction: direction, at: 0, observed: nil),
                .append(kana: kana, romaji: code), "\(key) \(direction)")
        }
    }

    func testFlickDirectionsProduceTheJ2Glyphs() {
        let cases: [(Kana12Key, Kana12FlickDirection, Kana12Effect)] = [
            (.a, .left, .append(kana: "い", romaji: "i")),
            (.a, .up, .append(kana: "う", romaji: "u")),
            (.a, .right, .append(kana: "え", romaji: "e")),
            (.a, .down, .append(kana: "お", romaji: "o")),
            (.ya, .up, .append(kana: "ゆ", romaji: "yu")),
            (.ya, .down, .append(kana: "よ", romaji: "yo")),
            (.ya, .left, .literal("（")),
            (.ya, .right, .literal("）")),
            (.wa, .left, .append(kana: "を", romaji: "wo")),
            (.wa, .down, .none),
            (.punctuation, .tap, .literal("、")),
            (.punctuation, .left, .literal("。")),
            (.punctuation, .up, .literal("？")),
            (.punctuation, .right, .literal("！")),
            (.punctuation, .down, .literal("…")),
        ]
        for (key, direction, expected) in cases {
            var model = Kana12InputModel()
            XCTAssertEqual(
                model.press(key, direction: direction, at: 0, observed: nil), expected, "\(key) \(direction)")
        }
    }

    func testPunctuationAndBracketFlicksAreLiteralsNotRimeKeyTokens() {
        for (key, direction) in [
            (Kana12Key.ya, Kana12FlickDirection.left), (.ya, .right), (.punctuation, .tap), (.punctuation, .down),
        ] {
            var model = Kana12InputModel()
            let effect = model.press(key, direction: direction, at: 0, observed: nil)
            guard case .literal = effect else {
                return XCTFail("\(key) \(direction) must be a literal effect, got \(effect)")
            }
            XCTAssertEqual(effect.backspaces, 0)
            XCTAssertNil(effect.romaji)
        }
    }

    // MARK: - J2.3 tap cycle

    func testRepeatedTapsCycleEveryKanaRowAndWrap() {
        let cycles: [(Kana12Key, [String])] = [
            (.a, ["あ", "い", "う", "え", "お", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ"]),
            (.ka, ["か", "き", "く", "け", "こ", "が", "ぎ", "ぐ", "げ", "ご"]),
            (.sa, ["さ", "し", "す", "せ", "そ", "ざ", "じ", "ず", "ぜ", "ぞ"]),
            (.ta, ["た", "ち", "つ", "て", "と", "だ", "ぢ", "づ", "で", "ど"]),
            (.na, ["な", "に", "ぬ", "ね", "の"]),
            (.ha, ["は", "ひ", "ふ", "へ", "ほ", "ば", "び", "ぶ", "べ", "ぼ", "ぱ", "ぴ", "ぷ", "ぺ", "ぽ"]),
            (.ma, ["ま", "み", "む", "め", "も"]),
            (.ya, ["や", "ゆ", "よ", "ゃ", "ゅ", "ょ"]),
            (.ra, ["ら", "り", "る", "れ", "ろ"]),
            (.wa, ["わ", "を", "ん", "ー", "ゎ"]),
        ]
        for (key, cycle) in cycles {
            var simulator = Simulator()
            for index in 0...cycle.count {
                let expectedKana = cycle[index % cycle.count]
                let effect = simulator.press(key)
                if index == 0 {
                    XCTAssertEqual(effect, .append(kana: expectedKana, romaji: romaji(expectedKana)), "\(key)")
                } else {
                    let previous = cycle[(index - 1) % cycle.count]
                    XCTAssertEqual(
                        effect,
                        .replace(previousKana: previous, kana: expectedKana, romaji: romaji(expectedKana)),
                        "\(key) step \(index)")
                    XCTAssertEqual(effect.backspaces, 1)
                }
                XCTAssertEqual(simulator.composition, expectedKana)
            }
        }
    }

    func testToggleStopsAtTheEightTenthsBoundary() {
        var model = Kana12InputModel()
        XCTAssertEqual(
            model.press(.a, at: 0.5, observed: Kana12Observation()), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(
            model.press(.a, at: 1.3, observed: atEnd("あ")), .append(kana: "あ", romaji: "a"))
    }

    func testToggleContinuesJustInsideTheBoundary() {
        var model = Kana12InputModel()
        XCTAssertEqual(
            model.press(.a, at: 0.5, observed: Kana12Observation()), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(
            model.press(.a, at: 1.29, observed: atEnd("あ")),
            .replace(previousKana: "あ", kana: "い", romaji: "i"))
    }

    func testNonMonotonicTimestampStartsAFreshCycle() {
        var model = Kana12InputModel()
        XCTAssertEqual(
            model.press(.a, at: 1.0, observed: Kana12Observation()), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(
            model.press(.a, at: 0.5, observed: atEnd("あ")), .append(kana: "あ", romaji: "a"))
    }

    func testAnotherKeyEndsTheTapCycle() {
        var simulator = Simulator()
        XCTAssertEqual(simulator.press(.a), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(simulator.press(.ka), .append(kana: "か", romaji: "ka"))
        XCTAssertEqual(simulator.press(.a), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(simulator.composition, "あかあ")
    }

    func testFlickOnlySuppressesTheTapCycleButNotTheModifier() {
        var simulator = Simulator(flickOnly: true)
        XCTAssertEqual(simulator.press(.a), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(simulator.press(.a), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(simulator.composition, "ああ")
        simulator = Simulator(flickOnly: true)
        XCTAssertEqual(simulator.press(.a), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "あ", kana: "ぁ", romaji: "la"))
    }

    func testTapCycleRestartsAfterAFlick() {
        var simulator = Simulator()
        XCTAssertEqual(simulator.press(.a), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(simulator.press(.a, .left), .append(kana: "い", romaji: "i"))
        XCTAssertEqual(simulator.press(.a), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(simulator.composition, "あいあ")
    }

    func testPunctuationKeyDoesNotTapCycle() {
        var simulator = Simulator()
        for _ in 0..<3 {
            XCTAssertEqual(simulator.press(.punctuation), .literal("、"))
            XCTAssertEqual(simulator.composition, "")
        }
    }

    // MARK: - J2.4 小゛゜ modifier

    func testModifierCyclesTsuThroughSmallTsuAndDzu() {
        var simulator = Simulator()
        XCTAssertEqual(simulator.press(.ta, .up), .append(kana: "つ", romaji: "tu"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "つ", kana: "っ", romaji: "ltu"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "っ", kana: "づ", romaji: "du"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "づ", kana: "つ", romaji: "tu"))
        XCTAssertEqual(simulator.composition, "つ")
    }

    func testModifierCyclesHaRowDakutenAndHandakuten() {
        var simulator = Simulator()
        XCTAssertEqual(simulator.press(.ha), .append(kana: "は", romaji: "ha"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "は", kana: "ば", romaji: "ba"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "ば", kana: "ぱ", romaji: "pa"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "ぱ", kana: "は", romaji: "ha"))
    }

    func testModifierCyclesSmallVowels() {
        var simulator = Simulator()
        XCTAssertEqual(simulator.press(.a), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "あ", kana: "ぁ", romaji: "la"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "ぁ", kana: "あ", romaji: "a"))
    }

    func testModifierCyclesYoonAndWa() {
        var simulator = Simulator()
        XCTAssertEqual(simulator.press(.ya), .append(kana: "や", romaji: "ya"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "や", kana: "ゃ", romaji: "lya"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "ゃ", kana: "や", romaji: "ya"))
        var wa = Simulator()
        XCTAssertEqual(wa.press(.wa), .append(kana: "わ", romaji: "wa"))
        XCTAssertEqual(wa.press(.modifier), .replace(previousKana: "わ", kana: "ゎ", romaji: "lwa"))
        XCTAssertEqual(wa.press(.modifier), .replace(previousKana: "ゎ", kana: "わ", romaji: "wa"))
    }

    func testModifierAlsoReversesDakuten() {
        var simulator = Simulator()
        XCTAssertEqual(simulator.press(.ka), .append(kana: "か", romaji: "ka"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "か", kana: "が", romaji: "ga"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "が", kana: "か", romaji: "ka"))
    }

    func testModifierDoesNothingForKanaWithoutVariants() {
        var simulator = Simulator()
        XCTAssertEqual(simulator.press(.wa, .up), .append(kana: "ん", romaji: "nn"))
        XCTAssertEqual(simulator.press(.modifier), .none)
        XCTAssertEqual(simulator.press(.modifier), .none)
        XCTAssertEqual(simulator.composition, "ん")
        var choonpu = Simulator()
        XCTAssertEqual(choonpu.press(.wa, .right), .append(kana: "ー", romaji: "-"))
        XCTAssertEqual(choonpu.press(.modifier), .none)
    }

    func testModifierReplacesOnlyTheLastKanaOfTheComposition() {
        var simulator = Simulator()
        XCTAssertEqual(simulator.press(.a), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(simulator.press(.ka), .append(kana: "か", romaji: "ka"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "か", kana: "が", romaji: "ga"))
        XCTAssertEqual(simulator.composition, "あが")
    }

    // MARK: - Composition ownership

    func testModifierRequiresTheModelsOwnTrailingKana() {
        var model = Kana12InputModel()
        XCTAssertEqual(
            model.press(.modifier, at: 0, observed: Kana12Observation(composition: "か", caret: 1)), .none)
        XCTAssertEqual(
            model.press(.a, at: 1, observed: Kana12Observation()), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(
            model.press(.modifier, at: 2, observed: Kana12Observation(composition: "あか", caret: 2)), .none)
    }

    func testModifierRequiresTheSameCaretAndNoSelection() {
        var model = Kana12InputModel()
        XCTAssertEqual(
            model.press(.a, at: 0, observed: Kana12Observation()), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(
            model.press(.modifier, at: 1, observed: Kana12Observation(composition: "あ", caret: 0)), .none)
        var selected = Kana12InputModel()
        XCTAssertEqual(
            selected.press(.a, at: 0, observed: Kana12Observation()), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(
            selected.press(
                .modifier, at: 1, observed: Kana12Observation(composition: "あ", caret: 1, hasSelection: true)),
            .none)
    }

    func testCommitOrClearInvalidatesTheModifier() {
        var model = Kana12InputModel()
        XCTAssertEqual(
            model.press(.a, at: 0, observed: Kana12Observation()), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(model.press(.modifier, at: 1, observed: nil), .none)
    }

    func testSynchronizeDropsOwnershipAfterACursorMoveEvenIfTheCaretReturns() {
        var model = Kana12InputModel()
        XCTAssertEqual(
            model.press(.a, at: 0, observed: Kana12Observation()), .append(kana: "あ", romaji: "a"))
        let end = atEnd("あ")
        model.synchronize(end)
        XCTAssertEqual(
            model.press(.modifier, at: 1, observed: end),
            .replace(previousKana: "あ", kana: "ぁ", romaji: "la"))
        model.synchronize(Kana12Observation(composition: "ぁ", caret: 0))
        XCTAssertEqual(
            model.press(.modifier, at: 2, observed: Kana12Observation(composition: "ぁ", caret: 1)), .none)
    }

    func testSynchronizeWithNoCompositionDropsOwnership() {
        var model = Kana12InputModel()
        XCTAssertEqual(
            model.press(.a, at: 0, observed: Kana12Observation()), .append(kana: "あ", romaji: "a"))
        model.synchronize(nil)
        XCTAssertEqual(
            model.press(.modifier, at: 1, observed: Kana12Observation(composition: "あ", caret: 1)), .none)
    }

    func testLiteralEffectEndsCompositionOwnership() {
        var simulator = Simulator()
        XCTAssertEqual(simulator.press(.a), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(simulator.press(.punctuation), .literal("、"))
        XCTAssertEqual(simulator.press(.modifier), .none)
    }

    func testUnknownObservationNeverReplaces() {
        var model = Kana12InputModel()
        XCTAssertEqual(model.press(.a, at: 0, observed: nil), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(model.press(.a, at: 0.1, observed: nil), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(model.press(.modifier, at: 0.2, observed: nil), .none)
    }

    func testMidCompositionCaretDoesNotArmReplacement() {
        var model = Kana12InputModel()
        XCTAssertEqual(
            model.press(.a, at: 0, observed: Kana12Observation()), .append(kana: "あ", romaji: "a"))
        let mid = Kana12Observation(composition: "あ", caret: 0)
        XCTAssertEqual(model.press(.ka, at: 1, observed: mid), .append(kana: "か", romaji: "ka"))
        XCTAssertEqual(
            model.press(.modifier, at: 2, observed: Kana12Observation(composition: "かあ", caret: 1)), .none)
    }

    func testResetDropsCycleAndOwnership() {
        var simulator = Simulator()
        XCTAssertEqual(simulator.press(.a), .append(kana: "あ", romaji: "a"))
        simulator.model.reset()
        XCTAssertEqual(simulator.press(.a), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(simulator.composition, "ああ")
        var model = Kana12InputModel()
        XCTAssertEqual(
            model.press(.a, at: 0, observed: Kana12Observation()), .append(kana: "あ", romaji: "a"))
        model.reset()
        XCTAssertEqual(
            model.press(.modifier, at: 1, observed: Kana12Observation(composition: "あ", caret: 1)), .none)
    }

    // MARK: - Front end contract

    func testPredictionSurvivesReplacementAndKeepsTheLastKana() {
        var simulator = Simulator()
        XCTAssertEqual(simulator.press(.a), .append(kana: "あ", romaji: "a"))
        XCTAssertEqual(simulator.press(.a), .replace(previousKana: "あ", kana: "い", romaji: "i"))
        XCTAssertEqual(simulator.press(.ka), .append(kana: "か", romaji: "ka"))
        XCTAssertEqual(simulator.press(.modifier), .replace(previousKana: "か", kana: "が", romaji: "ga"))
        XCTAssertEqual(simulator.composition, "いが")
    }

    /// One BackSpace always replaces one kana, whatever the romaji lengths: kagiroi's speller
    /// converts inside the composition, so つ (tu) -> っ (ltu) and や (ya) -> ゃ (lya) are one
    /// BackSpace each, never one per romaji character.
    func testEveryReplacementUsesExactlyOneBackspaceAndValidatedRomaji() {
        var replacements: [Kana12Effect] = []
        var toggles = 0
        for key in Kana12Key.allCases {
            let cycle = Kana12Layout.toggleCycle(for: key)
            guard !cycle.isEmpty else { continue }
            var simulator = Simulator()
            for _ in 0...cycle.count {
                let effect = simulator.press(key)
                if case .replace = effect {
                    replacements.append(effect)
                    toggles += 1
                }
            }
        }
        var modifiers = 0
        for key in Kana12Key.allCases {
            for direction in Kana12FlickDirection.allCases {
                guard let kana = Kana12Layout.kana(for: key, direction: direction) else { continue }
                var simulator = Simulator()
                XCTAssertEqual(simulator.press(key, direction), .append(kana: kana, romaji: romaji(kana)))
                var previous = kana
                while let next = Kana12Layout.nextVariant(of: previous) {
                    let effect = simulator.press(.modifier)
                    XCTAssertEqual(
                        effect, .replace(previousKana: previous, kana: next, romaji: romaji(next)),
                        "\(previous) -> \(next)")
                    XCTAssertEqual(effect.backspaces, 1)
                    replacements.append(effect)
                    modifiers += 1
                    previous = next
                    if previous == kana { break }
                }
            }
        }
        XCTAssertEqual(toggles, 81)
        XCTAssertEqual(modifiers, 64)
        XCTAssertEqual(replacements.count, 145)
        for effect in replacements {
            XCTAssertEqual(effect.backspaces, 1)
            guard let kana = effect.kana, let code = effect.romaji else {
                return XCTFail("replacement must carry kana and romaji: \(effect)")
            }
            XCTAssertEqual(Kana12RomajiTable.romaji(for: kana), code)
        }
    }

    func testEffectAccessorsDescribeTheFrontEndSteps() {
        let append = Kana12Effect.append(kana: "あ", romaji: "a")
        XCTAssertEqual(append.kana, "あ")
        XCTAssertEqual(append.romaji, "a")
        XCTAssertEqual(append.backspaces, 0)
        let replace = Kana12Effect.replace(previousKana: "つ", kana: "っ", romaji: "ltu")
        XCTAssertEqual(replace.kana, "っ")
        XCTAssertEqual(replace.romaji, "ltu")
        XCTAssertEqual(replace.backspaces, 1)
        XCTAssertNil(Kana12Effect.literal("、").kana)
        XCTAssertNil(Kana12Effect.literal("、").romaji)
        XCTAssertEqual(Kana12Effect.none.backspaces, 0)
    }
}
