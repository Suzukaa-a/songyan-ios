import LayoutKit
import XCTest

@testable import CandidateKit

/// Wide-surface geometry: threshold, three docks, real widths (never scale), and malformed input.
final class KeyboardWideContentPolicyTests: XCTestCase {
    func testDockResolvesMissingAndUnknownToCenter() {
        XCTAssertEqual(KeyboardContentDock.resolve(nil), .center)
        XCTAssertEqual(KeyboardContentDock.resolve(""), .center)
        XCTAssertEqual(KeyboardContentDock.resolve("Center"), .center)
        XCTAssertEqual(KeyboardContentDock.resolve("LEFT"), .center)
        XCTAssertEqual(KeyboardContentDock.resolve("left"), .left)
        XCTAssertEqual(KeyboardContentDock.resolve("right"), .right)
        XCTAssertEqual(KeyboardContentDock.allCases, [.left, .center, .right])
    }

    func testPhoneSizedSurfacesStayFullWidthForEveryDockAndCap() {
        for width in [0.0, 1, 320, 375, 600] {
            for cap in [nil, 444.0, 520.0] {
                for dock in KeyboardContentDock.allCases {
                    let plan = KeyboardWideContentPolicy.plan(
                        panelWidth: width, maximumContentWidth: cap, dock: dock)
                    XCTAssertEqual(plan, .inactive(panelWidth: width), "width \(width) cap \(String(describing: cap))")
                    XCTAssertEqual(plan.contentWidth, width)
                    XCTAssertEqual(plan.leadingInset, 0)
                    XCTAssertEqual(plan.trailingInset, 0)
                }
            }
        }
    }

    func testSurfaceAboveThresholdActivatesAtTheCap() {
        for width in [600.1, 744.0, 834, 1024, 1366] {
            for cap in [444.0, 520.0] {
                for dock in KeyboardContentDock.allCases {
                    let plan = KeyboardWideContentPolicy.plan(
                        panelWidth: width, maximumContentWidth: cap, dock: dock)
                    XCTAssertTrue(plan.active, "width \(width) cap \(cap)")
                    XCTAssertEqual(plan.contentWidth, cap, accuracy: 0.001)
                    XCTAssertEqual(
                        plan.contentWidth + plan.leadingInset + plan.trailingInset, width,
                        accuracy: 0.001)
                    XCTAssertGreaterThanOrEqual(plan.leadingInset, 0)
                    XCTAssertGreaterThanOrEqual(plan.trailingInset, 0)
                    XCTAssertTrue(plan.contentWidth.isFinite)
                    XCTAssertTrue(plan.leadingInset.isFinite)
                    XCTAssertTrue(plan.trailingInset.isFinite)
                }
            }
        }
    }

    func testDockingPlacesTheCappedContentAtEachEdge() {
        let width = 834.0
        let cap = 520.0
        let left = KeyboardWideContentPolicy.plan(
            panelWidth: width, maximumContentWidth: cap, dock: .left)
        XCTAssertEqual(left.leadingInset, 0, accuracy: 0.001)
        XCTAssertEqual(left.trailingInset, width - cap, accuracy: 0.001)

        let right = KeyboardWideContentPolicy.plan(
            panelWidth: width, maximumContentWidth: cap, dock: .right)
        XCTAssertEqual(right.leadingInset, width - cap, accuracy: 0.001)
        XCTAssertEqual(right.trailingInset, 0, accuracy: 0.001)

        let center = KeyboardWideContentPolicy.plan(
            panelWidth: width, maximumContentWidth: cap, dock: .center)
        XCTAssertEqual(center.leadingInset, (width - cap) / 2, accuracy: 0.001)
        XCTAssertEqual(center.trailingInset, (width - cap) / 2, accuracy: 0.001)

        // Odd leftover pixels stay split within half a point and still tile exactly.
        let odd = KeyboardWideContentPolicy.plan(
            panelWidth: 833, maximumContentWidth: 444, dock: .center)
        XCTAssertEqual(odd.contentWidth, 444, accuracy: 0.001)
        XCTAssertLessThanOrEqual(abs(odd.leadingInset - odd.trailingInset), 0.5)
        XCTAssertEqual(
            odd.contentWidth + odd.leadingInset + odd.trailingInset, 833, accuracy: 0.001)
    }

    func testMissingOrOversizedCapStaysFullWidth() {
        for width in [602.0, 744, 834, 1366] {
            for cap in [nil, width, width + 1, 0, -1, .nan, .infinity] {
                let plan = KeyboardWideContentPolicy.plan(
                    panelWidth: width, maximumContentWidth: cap, dock: .center)
                XCTAssertEqual(plan, .inactive(panelWidth: width), "width \(width) cap \(String(describing: cap))")
                XCTAssertEqual(plan.contentWidth, width)
                XCTAssertEqual(plan.leadingInset, 0)
                XCTAssertEqual(plan.trailingInset, 0)
            }
        }
    }

    func testUncappedLayoutsKeepFullWidthAtEverySurface() {
        for width in [320.0, 600, 602, 834, 1024, 1366] {
            let plan = KeyboardWideContentPolicy.plan(
                panelWidth: width, maximumContentWidth: nil, dock: .center)
            XCTAssertEqual(plan, .inactive(panelWidth: width), "width \(width)")
            XCTAssertEqual(plan.contentWidth, width)
        }
    }

    func testMalformedPanelWidthsNormalizeToFiniteFullWidth() {
        for width in [Double.nan, .infinity, -.infinity, -1, -0.5] {
            let plan = KeyboardWideContentPolicy.plan(
                panelWidth: width, maximumContentWidth: 444, dock: .left)
            XCTAssertFalse(plan.active)
            XCTAssertEqual(plan.contentWidth, 0)
            XCTAssertEqual(plan.leadingInset, 0)
            XCTAssertEqual(plan.trailingInset, 0)
            XCTAssertTrue(plan.contentWidth.isFinite)
            XCTAssertTrue(plan.leadingInset.isFinite)
            XCTAssertTrue(plan.trailingInset.isFinite)
        }
        XCTAssertEqual(KeyboardWideContentPlan.inactive(panelWidth: .nan), .inactive(panelWidth: 0))
    }

    func testOneHandAndWideContentRangesNeverOverlap() {
        for width in stride(from: 300.0, through: 1200.0, by: 1.0) {
            let oneHand = KeyboardOneHandLayoutPolicy.plan(
                mode: .left, panelWidth: width, isAvailable: true)
            let wide = KeyboardWideContentPolicy.plan(
                panelWidth: width, maximumContentWidth: 520, dock: .center)
            XCTAssertFalse(oneHand.active && wide.active, "width \(width)")
            if width > KeyboardSurfaceWidth.phoneMaximum {
                XCTAssertFalse(oneHand.active, "width \(width)")
            } else {
                XCTAssertFalse(wide.active, "width \(width)")
            }
        }
    }

    func testEveryWideTilingIsRealFramesNotScaling() {
        for width in stride(from: 601.0, through: 1100.0, by: 7.0) {
            for cap in [444.0, 520.0] {
                let plan = KeyboardWideContentPolicy.plan(
                    panelWidth: width, maximumContentWidth: cap, dock: .right)
                XCTAssertTrue(plan.active)
                XCTAssertEqual(plan.contentWidth, cap, accuracy: 0.001)
                XCTAssertEqual(
                    plan.contentWidth + plan.leadingInset + plan.trailingInset, width,
                    accuracy: 0.001)
                XCTAssertGreaterThan(plan.leadingInset, 0)
            }
        }
    }

    // MARK: Side margin and the user's widths

    func testSideMarginKeepsTheKeyAreaAtLeast280() {
        XCTAssertEqual(KeyboardWideContentPolicy.sideMargin(panelWidth: 411, requested: 96), 65.5, accuracy: 1e-9)
        XCTAssertEqual(KeyboardWideContentPolicy.sideMargin(panelWidth: 411, requested: 24), 24)
        // A surface already that narrow keeps its full width.
        XCTAssertEqual(KeyboardWideContentPolicy.sideMargin(panelWidth: 270, requested: 96), 0)
        XCTAssertEqual(KeyboardWideContentPolicy.sideMargin(panelWidth: 280, requested: 96), 0)
        XCTAssertEqual(KeyboardWideContentPolicy.sideMargin(panelWidth: .nan, requested: 96), 0)
        let plan = KeyboardWideContentPolicy.plan(
            panelWidth: 411, maximumContentWidth: nil, dock: .center, sideMargin: 65.5)
        XCTAssertEqual(plan.contentWidth, 280, accuracy: 1e-9)
    }

    func testSideMarginIsBlankOnBothSidesOfTheKeyArea() {
        let none = KeyboardWideContentPolicy.plan(
            panelWidth: 411, maximumContentWidth: nil, dock: .center, sideMargin: 0)
        XCTAssertEqual(none, .inactive(panelWidth: 411))
        let phone = KeyboardWideContentPolicy.plan(
            panelWidth: 411, maximumContentWidth: nil, dock: .center, sideMargin: 24)
        XCTAssertTrue(phone.active)
        XCTAssertEqual(phone.contentWidth, 363, accuracy: 1e-9)
        XCTAssertEqual(phone.leadingInset, 24, accuracy: 1e-9)
        XCTAssertEqual(phone.trailingInset, 24, accuracy: 1e-9)
        // The cap and the dock work on the width left after the margins.
        let tablet = KeyboardWideContentPolicy.plan(
            panelWidth: 1024, maximumContentWidth: 444, dock: .left, sideMargin: 40)
        XCTAssertEqual(tablet.contentWidth, 444, accuracy: 1e-9)
        XCTAssertEqual(tablet.leadingInset, 40, accuracy: 1e-9)
        XCTAssertEqual(tablet.trailingInset, 1024 - 444 - 40, accuracy: 1e-9)
    }

    func testAMarginCanBringASurfaceUnderTheCapThreshold() {
        // 620 is wide, so a 444 cap bites; a 20 margin leaves 580, a phone-sized key area with no cap.
        let capped = KeyboardWideContentPolicy.plan(panelWidth: 620, maximumContentWidth: 444, dock: .center)
        XCTAssertEqual(capped.contentWidth, 444, accuracy: 1e-9)
        let withMargin = KeyboardWideContentPolicy.plan(
            panelWidth: 620, maximumContentWidth: 444, dock: .center, sideMargin: 20)
        XCTAssertEqual(withMargin.contentWidth, 580, accuracy: 1e-9)
        XCTAssertEqual(withMargin.leadingInset, 20, accuracy: 1e-9)
    }

    func testAMarginPreventsASplitAtTheUsersThreshold() {
        let split = LayoutSplitConfiguration()
        // Default threshold: 700 splits, but with a 60 margin the key area is 580 and does not.
        XCTAssertTrue(split.isActive(width: 700))
        let margin = KeyboardWideContentPolicy.sideMargin(panelWidth: 700, requested: 60)
        XCTAssertFalse(split.isActive(width: 700 - 2 * margin))
        // Equal to the user's threshold means no split; one point more splits.
        XCTAssertFalse(split.isActive(width: 580, automaticAbove: 580))
        XCTAssertTrue(split.isActive(width: 581, automaticAbove: 580))
    }

    func testWidthSettingsSnapIntoTheOfferedChoices() {
        XCTAssertEqual(KeyboardWidthSettings.standard.splitWidth, 600)
        XCTAssertEqual(KeyboardWidthSettings.standard.sideMargin, 0)
        XCTAssertEqual(KeyboardWidthSettings(splitWidth: 100, sideMargin: -5).splitWidth, 400)
        XCTAssertEqual(KeyboardWidthSettings(splitWidth: 100, sideMargin: -5).sideMargin, 0)
        XCTAssertEqual(KeyboardWidthSettings(splitWidth: 5000, sideMargin: 500).splitWidth, 1200)
        XCTAssertEqual(KeyboardWidthSettings(splitWidth: 5000, sideMargin: 500).sideMargin, 96)
        XCTAssertEqual(KeyboardWidthSettings(splitWidth: 619, sideMargin: 7).splitWidth, 600)
        XCTAssertEqual(KeyboardWidthSettings(splitWidth: 619, sideMargin: 7).sideMargin, 4)
        XCTAssertEqual(KeyboardWidthSettings.defaultSplitWidth, Int(KeyboardSurfaceWidth.phoneMaximum))
    }
}
