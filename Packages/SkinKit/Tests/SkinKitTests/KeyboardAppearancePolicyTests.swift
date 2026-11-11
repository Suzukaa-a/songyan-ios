import XCTest

@testable import SkinKit

/// `KeyboardAppearancePolicy`: every skin follows the system surface, never the document's own light/dark choice.
final class KeyboardAppearancePolicyTests: XCTestCase {
    /// A forced light/dark field wins until the surface trait is known; `.unspecified` uses the SwiftUI colour scheme.
    func testHostFieldIsOnlyAFallbackBeforeTheSurfaceTraitIsKnown() {
        for systemDark in [false, true] {
            XCTAssertFalse(KeyboardAppearancePolicy.resolvedDark(hostAppearance: .light, systemDark: systemDark))
            XCTAssertTrue(KeyboardAppearancePolicy.resolvedDark(hostAppearance: .dark, systemDark: systemDark))
            XCTAssertEqual(
                KeyboardAppearancePolicy.resolvedDark(hostAppearance: .unspecified, systemDark: systemDark),
                systemDark)
        }
    }

    func testResolvedKeyboardSurfaceWinsOverStaleHostProxy() {
        // UIKit has already resolved the keyboard surface; a proxy value can briefly disagree with its
        // actual light/dark trait during a live system change.
        for host in HostKeyboardAppearance.allCases {
            XCTAssertTrue(
                KeyboardAppearancePolicy.resolvedDark(hostAppearance: host, systemDark: true, systemTraitKnown: true))
            XCTAssertFalse(
                KeyboardAppearancePolicy.resolvedDark(hostAppearance: host, systemDark: false, systemTraitKnown: true))
        }
    }
}
