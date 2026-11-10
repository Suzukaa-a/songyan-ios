import XCTest

@testable import KeyboardCore

/// Every family lists the physical boards it may pick as its main layout, the preferred one first.
final class InputLayoutPolicyBoardsTests: XCTestCase {
    func testJapaneseOffersRomajiFirstThenKana() {
        XCTAssertEqual(InputLayoutPolicy.boards(of: .japanese), ["romaji26", "kana12"])
    }

    func testZhuyinAndCangjieOfferTheirOneBoard() {
        XCTAssertEqual(InputLayoutPolicy.boards(of: .zhuyin), ["zhuyin41"])
        XCTAssertEqual(InputLayoutPolicy.boards(of: .cangjieRadicals), ["cangjie26"])
    }

    func testTheLatinFamiliesKeepTheShippedShapes() {
        XCTAssertEqual(InputLayoutPolicy.boards(of: .latinPhonetic), [])
        XCTAssertEqual(InputLayoutPolicy.boards(of: .generic), [])
    }

    func testEveryBoardBelongsToItsFamily() {
        for family in [InputSchemeFamily.japanese, .zhuyin, .cangjieRadicals] {
            for board in InputLayoutPolicy.boards(of: family) {
                XCTAssertTrue(InputLayoutPolicy.allows(physicalLayoutID: board, family: family))
            }
        }
    }
}
