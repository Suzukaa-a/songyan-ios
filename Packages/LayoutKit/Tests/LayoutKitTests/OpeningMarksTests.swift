import XCTest

@testable import LayoutKit

/// Which branch a bilingual 123 / symbol page opens in, what a key shows there, and how the page
/// editor's key fields keep that face.
final class OpeningMarksTests: XCTestCase {
    func testTheMarksFollowTheInputLanguageUnlessTheUserOrThePageChoseABranch() {
        // English input opens the English marks, Chinese input the Chinese ones.
        XCTAssertEqual(.opening(flipped: nil, pageDefault: nil, asciiInput: true), KeyboardNumericMarks.ascii)
        XCTAssertEqual(.opening(flipped: nil, pageDefault: nil, asciiInput: false), KeyboardNumericMarks.chinese)
        // The page's own choice beats the input language, and the 中/英 key beats both.
        XCTAssertEqual(.opening(flipped: nil, pageDefault: .chinese, asciiInput: true), KeyboardNumericMarks.chinese)
        XCTAssertEqual(.opening(flipped: nil, pageDefault: .ascii, asciiInput: false), KeyboardNumericMarks.ascii)
        XCTAssertEqual(.opening(flipped: .ascii, pageDefault: .chinese, asciiInput: false), KeyboardNumericMarks.ascii)
        XCTAssertEqual(.opening(flipped: .chinese, pageDefault: .ascii, asciiInput: true), KeyboardNumericMarks.chinese)
    }

    func testACopyOfAnAutomaticPageKeepsFollowingTheInputLanguageUnlessAskedOtherwise() {
        XCTAssertNil(KeyboardPagePresets.numericAutomatic.copy(name: "我的").defaultSymbolMarks)
        XCTAssertNil(KeyboardPagePresets.symbolsSystem.copy(name: "我的").defaultSymbolMarks)
        XCTAssertEqual(
            KeyboardPagePresets.numericAutomatic.copy(name: "我的", numericMarks: .ascii).defaultSymbolMarks, .ascii)
        // An authored page keeps the branch it was saved with.
        let pinned = KeyboardPagePresets.numericAutomatic.copy(name: "我的", numericMarks: .ascii)
        XCTAssertEqual(pinned.copy(name: "再一份").defaultSymbolMarks, .ascii)
    }

    func testEveryMarkOfTheBilingualRowsTypesBothBranchesAndShowsTheBranch() {
        for numeric in [true, false] {
            let page: (Bool) -> KeyboardPageDefinition = {
                numeric ? KeyboardPagePresets.numericRowsPage(ascii: $0) : KeyboardPagePresets.symbolRowsPage(ascii: $0)
            }
            let chinese = page(false).rows.flatMap(\.keys)
            let ascii = page(true).rows.flatMap(\.keys)
            XCTAssertEqual(chinese.map(\.action), ascii.map(\.action))
            for (c, a) in zip(chinese, ascii) {
                XCTAssertEqual(c.titleMode, .automatic)
                XCTAssertEqual(c.label, c.action.literalValue(usesASCIIPunctuation: false))
                XCTAssertEqual(a.label, a.action.literalValue(usesASCIIPunctuation: true))
            }
        }
    }

    func testFillingTheEnglishVariantMakesTheKeyFollowTheBranchUnlessTheAuthorTypedATitle() {
        let plain = LayoutKey(label: "，", action: .init(.literal, value: "，"))
        let both = plain.editingAction(.init(.literal, value: "，", asciiValue: ","), allowsTitleMode: true)
        XCTAssertEqual(both.titleMode, .automatic)
        XCTAssertEqual(both.action.literalValue(usesASCIIPunctuation: true), ",")
        // Clearing the variant leaves one text for both branches; the face stays live.
        let cleared = both.editingAction(.init(.literal, value: "，"), allowsTitleMode: true)
        XCTAssertNil(cleared.action.asciiValue)
        // A title typed by hand wins.
        let named = both.editingLabel("逗号", allowsTitleMode: true)
        XCTAssertEqual(named.titleMode, .custom)
        XCTAssertEqual(
            named.editingAction(.init(.literal, value: "，", asciiValue: ";"), allowsTitleMode: true).titleMode,
            .custom)
    }

    func testTheCategorizedAndEnglishPagesHaveNoBranchToChoose() {
        XCTAssertNil(KeyboardPagePresets.symbolsCategorized.copy(name: "分类").defaultSymbolMarks)
        XCTAssertNil(KeyboardPagePresets.englishQwerty.copy(name: "英文").defaultSymbolMarks)
    }
}
