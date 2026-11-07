import Foundation
import QuickContentKit
import XCTest

final class ToolPanelTextTests: XCTestCase {
    func testTheParagraphStopsAtTheLastLineBreak() {
        XCTAssertEqual(ToolPanelText.paragraphBeforeCursor("上半段\n下半段"), "下半段")
        XCTAssertEqual(ToolPanelText.paragraphBeforeCursor("一\r\n二\n三"), "三")
    }

    func testATrailingLineBreakMeansNoParagraph() {
        XCTAssertNil(ToolPanelText.paragraphBeforeCursor("末段\n"))
        XCTAssertNil(ToolPanelText.paragraphBeforeCursor("末段\r\n"))
    }

    func testMissingContextHasNoParagraph() {
        XCTAssertNil(ToolPanelText.paragraphBeforeCursor(nil))
        XCTAssertNil(ToolPanelText.paragraphBeforeCursor(""))
    }

    func testSpacesAreNotAText() {
        XCTAssertNil(ToolPanelText.paragraphBeforeCursor("   "))
    }

    func testAShortTextIsKeptWhole() {
        let bounded = ToolPanelText.boundedPrefix("软件")
        XCTAssertEqual(bounded.text, "软件")
        XCTAssertFalse(bounded.wasTruncated)
    }

    func testThePrefixKeepsTheHead() {
        let long = String(repeating: "a", count: 1005)
        let bounded = ToolPanelText.boundedPrefix(long)
        XCTAssertEqual(bounded.text, String(long.prefix(1000)))
        XCTAssertTrue(bounded.wasTruncated)
    }

    func testTheSuffixKeepsTheTextNearestTheCursor() {
        let long = String(repeating: "a", count: 1005)
        let bounded = ToolPanelText.boundedSuffix(long)
        XCTAssertEqual(bounded.text, String(long.suffix(1000)))
        XCTAssertTrue(bounded.wasTruncated)
    }

    func testTruncationCountsCharactersNotUTF16Units() {
        let emoji = String(repeating: "\u{1F600}", count: 1002)
        let bounded = ToolPanelText.boundedPrefix(emoji)
        XCTAssertEqual(bounded.text.count, 1000)
        XCTAssertEqual(bounded.text, String(emoji.prefix(1000)))
        XCTAssertTrue(bounded.wasTruncated)
    }
}
