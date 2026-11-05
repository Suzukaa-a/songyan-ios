import XCTest

@testable import LayoutKit

final class KeyFlickTests: XCTestCase {
    func testThresholdFollowsTheTallerOfDistanceAndKeyShare() {
        XCTAssertEqual(KeyFlick.threshold(keyHeight: 40), 24)
        XCTAssertEqual(KeyFlick.threshold(keyHeight: 80), 32)
    }

    func testVerticalFlickPicksItsDirectionOnlyPastTheThreshold() {
        XCTAssertEqual(KeyFlick.direction(rise: 30, dx: 3, threshold: 24), .up)
        XCTAssertEqual(KeyFlick.direction(rise: -30, dx: 3, threshold: 24), .down)
        XCTAssertNil(KeyFlick.direction(rise: 20, dx: 0, threshold: 24))
        XCTAssertNil(KeyFlick.direction(rise: -20, dx: 0, threshold: 24))
    }

    func testMostlySidewaysDragIsNotAFlick() {
        XCTAssertNil(KeyFlick.direction(rise: 30, dx: 30, threshold: 24))
        XCTAssertNil(KeyFlick.direction(rise: -30, dx: 45, threshold: 24))
    }

    func testComingBackGivesTheFlickBack() {
        XCTAssertTrue(KeyFlick.isGivenBack(rise: 5, direction: .up))
        XCTAssertFalse(KeyFlick.isGivenBack(rise: 25, direction: .up))
        XCTAssertTrue(KeyFlick.isGivenBack(rise: -5, direction: .down))
        XCTAssertFalse(KeyFlick.isGivenBack(rise: -25, direction: .down))
        XCTAssertTrue(KeyFlick.isGivenBack(rise: 12, direction: .down))
    }

    func testOnlyTheConfiguredDirectionTypes() {
        XCTAssertEqual(
            KeyFlick.release(rise: 30, direction: .up, configured: .up, hasTarget: true), .option)
        XCTAssertEqual(
            KeyFlick.release(rise: -30, direction: .down, configured: .down, hasTarget: true), .option)
        // The other direction voids the press even when the key has a target.
        XCTAssertEqual(
            KeyFlick.release(rise: -30, direction: .down, configured: .up, hasTarget: true), .nothing)
        XCTAssertEqual(
            KeyFlick.release(rise: -4, direction: .down, configured: .up, hasTarget: true), .nothing)
    }

    func testFlickWithNoTargetTypesNothingAndComingBackTaps() {
        XCTAssertEqual(
            KeyFlick.release(rise: 30, direction: .up, configured: .up, hasTarget: false), .nothing)
        XCTAssertEqual(
            KeyFlick.release(rise: 4, direction: .up, configured: .up, hasTarget: false), .tap)
        XCTAssertEqual(
            KeyFlick.release(rise: 4, direction: .up, configured: .up, hasTarget: true), .tap)
        XCTAssertEqual(
            KeyFlick.release(rise: -9, direction: .down, configured: .down, hasTarget: true), .tap)
    }

    func testTargetIsTheOptionShowingTheHint() {
        XCTAssertEqual(KeyFlick.targetIndex(optionLabels: ["1", "-"], hint: "1"), 0)
        XCTAssertEqual(KeyFlick.targetIndex(optionLabels: ["a", "b", "5"], hint: "5"), 2)
        XCTAssertEqual(KeyFlick.targetIndex(optionLabels: ["1", "-"], hint: "-"), 1)
    }

    func testNoMatchingOrNoHintMeansNoTarget() {
        XCTAssertNil(KeyFlick.targetIndex(optionLabels: ["1", "-"], hint: "9"))
        XCTAssertNil(KeyFlick.targetIndex(optionLabels: ["1", "-"], hint: nil))
        XCTAssertNil(KeyFlick.targetIndex(optionLabels: ["1", "-"], hint: ""))
        XCTAssertNil(KeyFlick.targetIndex(optionLabels: [], hint: "1"))
    }

    func testDigitKeyTypesItsDigitWhateverTheOptions() {
        XCTAssertEqual(KeyFlick.target(options: ["a", "b"], label: { $0 }, hint: "2", digit: "2"), "2")
        XCTAssertEqual(KeyFlick.target(options: ["x", "5"], label: { $0 }, hint: "5", digit: nil), "5")
        XCTAssertNil(KeyFlick.target(options: ["x"], label: { $0 }, hint: "5", digit: nil))
    }

    func testOnlyPlainCharacterKeysFlickWhenASettingIsOn() {
        func eligible(
            _ kind: LayoutAction.Kind, setting: KeyFlick.Setting = .up, merged: Bool = false
        ) -> Bool {
            KeyFlick.isEligible(actionType: kind, setting: setting, merged: merged)
        }
        XCTAssertTrue(eligible(.code))
        XCTAssertTrue(eligible(.literal))
        XCTAssertTrue(eligible(.code, setting: .down))
        XCTAssertFalse(eligible(.code, setting: .off))
        XCTAssertFalse(eligible(.code, merged: true), "merged keys keep their sideways swipe")
        XCTAssertFalse(eligible(.space))
        XCTAssertFalse(eligible(.backspace))
    }

    func testSettingResolvesStoredValueAndMigratesTheOldSwitch() {
        XCTAssertEqual(KeyFlick.Setting.resolve(stored: "off", legacyEnabled: nil), .off)
        XCTAssertEqual(KeyFlick.Setting.resolve(stored: "up", legacyEnabled: nil), .up)
        XCTAssertEqual(KeyFlick.Setting.resolve(stored: "down", legacyEnabled: false), .down)
        XCTAssertEqual(KeyFlick.Setting.resolve(stored: "sideways", legacyEnabled: nil), .up)
        XCTAssertEqual(KeyFlick.Setting.resolve(stored: 3, legacyEnabled: nil), .up)
        XCTAssertEqual(KeyFlick.Setting.resolve(stored: nil, legacyEnabled: nil), .up)
        XCTAssertEqual(KeyFlick.Setting.resolve(stored: nil, legacyEnabled: true), .up)
        XCTAssertEqual(KeyFlick.Setting.resolve(stored: nil, legacyEnabled: false), .off)
        XCTAssertNil(KeyFlick.Setting.off.direction)
        XCTAssertEqual(KeyFlick.Setting.up.direction, .up)
        XCTAssertEqual(KeyFlick.Setting.down.direction, .down)
    }

    func testProgressRunsFromTouchSlopToThresholdAndHoldsWhileArmed() {
        XCTAssertEqual(KeyFlick.progress(travel: 0, threshold: 24, armed: false), 0)
        XCTAssertEqual(KeyFlick.progress(travel: 8, threshold: 24, armed: false), 0)
        XCTAssertEqual(KeyFlick.progress(travel: 16, threshold: 24, armed: false), 0.5, accuracy: 1e-9)
        XCTAssertEqual(KeyFlick.progress(travel: 24, threshold: 24, armed: false), 1)
        XCTAssertEqual(KeyFlick.progress(travel: -10, threshold: 24, armed: false), 0)
        XCTAssertEqual(KeyFlick.progress(travel: 12, threshold: 24, armed: true), 1)
    }

    func testSidewaysProgressNeedsAMostlySidewaysMoveUntilAPick() {
        XCTAssertEqual(
            KeyFlick.sidewaysProgress(dx: -13, dy: 2, lockDistance: 18, picked: false), 0.5, accuracy: 1e-9)
        XCTAssertEqual(
            KeyFlick.sidewaysProgress(dx: 13, dy: 2, lockDistance: 18, picked: false), 0.5, accuracy: 1e-9)
        XCTAssertEqual(KeyFlick.sidewaysProgress(dx: 5, dy: 2, lockDistance: 18, picked: false), 0)
        XCTAssertEqual(KeyFlick.sidewaysProgress(dx: 12, dy: 20, lockDistance: 18, picked: false), 0)
        XCTAssertEqual(KeyFlick.sidewaysProgress(dx: 30, dy: 0, lockDistance: 18, picked: false), 1)
        XCTAssertEqual(KeyFlick.sidewaysProgress(dx: 1, dy: 40, lockDistance: 18, picked: true), 1)
    }
}

final class EasedProgressTests: XCTestCase {
    func testGlidesToTheTargetAndLandsAtNinetyMilliseconds() {
        var eased = EasedProgress()
        XCTAssertEqual(eased.value(at: 0), 0)
        eased.setTarget(1, at: 1, reduceMotion: false)
        XCTAssertEqual(eased.value(at: 1), 0, accuracy: 1e-9)
        // Ease-out quadratic: halfway in time is three quarters of the way.
        XCTAssertEqual(eased.value(at: 1.045), 0.75, accuracy: 1e-9)
        XCTAssertFalse(eased.isSettled(at: 1.089))
        XCTAssertEqual(eased.value(at: 1.09), 1)
        XCTAssertTrue(eased.isSettled(at: 1.09))
        XCTAssertEqual(eased.value(at: 5), 1)
    }

    func testRetargetingRestartsFromTheCurrentDrawnValue() {
        var eased = EasedProgress()
        eased.setTarget(1, at: 0, reduceMotion: false)
        let drawn = eased.value(at: 0.045)
        XCTAssertFalse(eased.setTarget(1, at: 0.045, reduceMotion: false), "same target keeps the glide")
        XCTAssertTrue(eased.setTarget(0, at: 0.045, reduceMotion: false))
        XCTAssertEqual(eased.value(at: 0.045), drawn, accuracy: 1e-9)
        XCTAssertLessThan(eased.value(at: 0.06), drawn)
        XCTAssertEqual(eased.value(at: 0.045 + EasedProgress.duration), 0)
    }

    func testReduceMotionJumpsToTheTarget() {
        var eased = EasedProgress()
        eased.setTarget(0.6, at: 2, reduceMotion: true)
        XCTAssertEqual(eased.value(at: 2), 0.6)
        XCTAssertTrue(eased.isSettled(at: 2))
    }
}

final class LongPressDelaySettingTests: XCTestCase {
    func testMissingOrOutOfRangeValueFollowsTheLayout() {
        XCTAssertNil(LongPressDelaySetting.resolve(nil))
        XCTAssertNil(LongPressDelaySetting.resolve("300"))
        XCTAssertNil(LongPressDelaySetting.resolve(0))
        XCTAssertNil(LongPressDelaySetting.resolve(149))
        XCTAssertNil(LongPressDelaySetting.resolve(1001))
    }

    func testInRangeValueIsKept() {
        XCTAssertEqual(LongPressDelaySetting.resolve(150), 150)
        XCTAssertEqual(LongPressDelaySetting.resolve(400), 400)
        XCTAssertEqual(LongPressDelaySetting.resolve(1000), 1000)
    }

    func testOverrideWinsOverTheLayoutAndTheLayoutOverTheDefault() {
        XCTAssertEqual(LongPressDelaySetting.effectiveDelay(layout: 0.5, override: 300), 0.3, accuracy: 1e-9)
        XCTAssertEqual(LongPressDelaySetting.effectiveDelay(layout: 0.5, override: nil), 0.5)
        XCTAssertEqual(LongPressDelaySetting.effectiveDelay(layout: nil, override: nil), 0.35)
    }

    func testEveryChoiceIsInRange() {
        for choice in LongPressDelaySetting.choices {
            XCTAssertEqual(LongPressDelaySetting.resolve(choice), choice)
        }
    }
}
