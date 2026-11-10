import XCTest

@testable import LayoutKit

final class LayoutKeyGlobeRowTests: XCTestCase {
    private func key(_ type: LayoutAction.Kind, width: Double? = nil) -> LayoutKey {
        LayoutKey(label: type.rawValue, width: width, action: LayoutAction(type))
    }

    func testGlobeWidthGoesToReturnWhenRowHasSpace() {
        let row = [key(.globe), key(.pageSwitch), key(.space, width: 4), key(.enter, width: 1.5)]
        let shown = row.withoutGlobe()
        XCTAssertEqual(shown.map(\.action.type), [.pageSwitch, .space, .enter])
        XCTAssertEqual(shown.map(\.widthWeight), [1, 4, 2.5])
    }

    func testRowWithoutGlobeIsUnchanged() {
        let row = [key(.pageSwitch), key(.space, width: 4), key(.enter, width: 1.5)]
        XCTAssertEqual(row.withoutGlobe(), row)
    }

    func testRowWithoutSpaceOnlyLosesGlobe() {
        let row = [key(.globe, width: 2), key(.pageSwitch), key(.enter, width: 1.5)]
        let shown = row.withoutGlobe()
        XCTAssertEqual(shown.map(\.action.type), [.pageSwitch, .enter])
        XCTAssertEqual(shown.map(\.widthWeight), [1, 1.5])
    }
}
