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
        // A flick down that drifted back above the origin is a tap too.
        XCTAssertTrue(KeyFlick.isGivenBack(rise: 12, direction: .down))
    }

    func testFlickWithNothingToTypeThatWayTypesNothing() {
        // Down on a key with one option (or any 9-key digit): the release must not type the key below.
        XCTAssertEqual(KeyFlick.release(rise: -30, direction: .down, hasOption: false), .nothing)
        XCTAssertEqual(KeyFlick.release(rise: 30, direction: .up, hasOption: false), .nothing)
        XCTAssertEqual(KeyFlick.release(rise: -30, direction: .down, hasOption: true), .option)
        // Coming back near the key undoes it, with or without an option.
        XCTAssertEqual(KeyFlick.release(rise: -4, direction: .down, hasOption: false), .tap)
        XCTAssertEqual(KeyFlick.release(rise: 4, direction: .up, hasOption: true), .tap)
    }

    func testUpTypesTheFirstOptionAndDownTheSecond() {
        let options = ["1", "-"]
        XCTAssertEqual(KeyFlick.option(in: options, direction: .up), "1")
        XCTAssertEqual(KeyFlick.option(in: options, direction: .down), "-")
        XCTAssertNil(KeyFlick.option(in: ["1"], direction: .down))
        XCTAssertNil(KeyFlick.option(in: [String](), direction: .up))
    }

    func testOnlyPlainCharacterKeysFlickWhenEnabled() {
        func eligible(
            _ kind: LayoutAction.Kind, enabled: Bool = true, merged: Bool = false, digit: Bool = false
        ) -> Bool {
            KeyFlick.isEligible(actionType: kind, enabled: enabled, merged: merged, ownsUpwardFlick: digit)
        }
        XCTAssertTrue(eligible(.code))
        XCTAssertTrue(eligible(.literal))
        XCTAssertFalse(eligible(.code, enabled: false))
        XCTAssertFalse(eligible(.code, merged: true), "merged keys keep their sideways swipe")
        XCTAssertFalse(eligible(.code, digit: true), "nine-key digits keep their own flick")
        XCTAssertFalse(eligible(.space))
        XCTAssertFalse(eligible(.backspace))
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
