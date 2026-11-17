import XCTest

@testable import KeyboardCore

/// A keyboard is an input method, the shape it runs on and the layout it types on. The layout may
/// be any layout: a shipped shape, a shipped board or the user's own.
final class PublishedKeyboardLayoutTests: XCTestCase {
    private let copied = "0fd7d991-9160-4016-a88f-3df09fd773cb"

    func testAUserLayoutIsAKeyboardOfItsOwnBesideTheShippedOne() {
        let plain = PublishedKeyboard(schemaID: "pinyin", layout: .qwerty26, board: "qwerty26")
        let mine = PublishedKeyboard(schemaID: "pinyin", layout: .qwerty26, board: copied)
        XCTAssertEqual(mine.id, "pinyin:qwerty26#" + copied)
        XCTAssertNotEqual(plain, mine)
        XCTAssertEqual(plain.combinationID, mine.combinationID)
        XCTAssertEqual(PublishedKeyboard.adding(mine, to: [plain]), [plain, mine])
        // Both run on the same resources, so only a folded shape asks for generated data, once.
        XCTAssertTrue(PublishedKeyboard.generationTasks(for: [plain, mine]).isEmpty)
        let folded = [
            PublishedKeyboard(schemaID: "pinyin", layout: .phone9, board: "phone9"),
            PublishedKeyboard(schemaID: "pinyin", layout: .phone9, board: "my-nine"),
        ]
        XCTAssertEqual(PublishedKeyboard.generationTasks(for: folded), [folded[0]])
    }

    func testTheIDReadsBack() {
        for keyboard in [
            PublishedKeyboard(schemaID: "pinyin", layout: .merged14),
            PublishedKeyboard(schemaID: "pinyin", layout: .qwerty26, board: copied),
            PublishedKeyboard(schemaID: "ns:scheme", layout: .phone9, board: "a:b#c"),
        ] {
            XCTAssertEqual(PublishedKeyboard(id: keyboard.id), keyboard, keyboard.id)
        }
        let parsed = PublishedKeyboard(id: "ns:scheme:phone9#a:b#c")
        XCTAssertEqual(parsed?.schemaID, "ns:scheme")
        XCTAssertEqual(parsed?.layout, .phone9)
        XCTAssertEqual(parsed?.board, "a:b#c")
        for malformed in ["pinyin", "pinyin:qwerty26#", ":qwerty26", "pinyin:nine#x", "pinyin#x"] {
            XCTAssertNil(PublishedKeyboard(id: malformed), malformed)
        }
    }

    func testACandidateCarriesItsLayoutIntoTheKeyboard() {
        let shape = UserKeyboardCandidate(inputMethodID: "pinyin", inputMethodName: "全拼", layout: .qwerty26)
        XCTAssertEqual(shape.id, "pinyin:qwerty26")
        XCTAssertNil(shape.keyboard().board)
        let mine = UserKeyboardCandidate(
            inputMethodID: "pinyin", inputMethodName: "全拼", layout: .qwerty26, board: copied)
        XCTAssertEqual(mine.id, "pinyin:qwerty26#" + copied)
        XCTAssertEqual(
            mine.keyboard().published, PublishedKeyboard(schemaID: "pinyin", layout: .qwerty26, board: copied))
    }

    func testTheTitleNamesAUserLayoutByItsSavedName() {
        let mine = UserKeyboard(inputMethodID: "pinyin", inputMethodName: "全拼", layout: .qwerty26, board: copied)
        let name = mine.layoutName(mainLayoutID: copied, savedName: "26 键 副本")
        XCTAssertEqual(name, "26 键 副本")
        XCTAssertEqual(mine.title(physicalLayoutName: name), "全拼 · 26 键 副本")
        // The shape's own layout keeps the shape name.
        let plain = UserKeyboard(inputMethodID: "pinyin", inputMethodName: "全拼", layout: .qwerty26, board: "qwerty26")
        XCTAssertNil(plain.layoutName(mainLayoutID: "qwerty26", savedName: "26 键"))
        XCTAssertEqual(plain.title(physicalLayoutName: nil), plain.title)
        // A keyboard saved without a layout that reaches the copy through its pairing reads as before.
        let older = UserKeyboard(inputMethodID: "pinyin", inputMethodName: "全拼", layout: .qwerty26)
        XCTAssertNil(older.layoutName(mainLayoutID: copied, savedName: "26 键 副本"))
        // The named layout could not be used, so the keyboard fell back to another one.
        XCTAssertNil(mine.layoutName(mainLayoutID: "qwerty26", savedName: "26 键"))
        XCTAssertNil(mine.layoutName(mainLayoutID: nil, savedName: nil))
    }

    func testCyclingAndTheCurrentMarkTellLayoutsOfOneShapeApart() {
        let plain = UserKeyboard(inputMethodID: "pinyin", inputMethodName: "全拼", layout: .qwerty26, board: "qwerty26")
        let mine = UserKeyboard(inputMethodID: "pinyin", inputMethodName: "全拼", layout: .qwerty26, board: copied)
        let combinations = [
            KeyboardResourceSet.Combination(
                schemaID: "pinyin", engineSchemaID: "pinyin", layout: .qwerty26, name: "全拼")
        ]
        let runnable = UserKeyboardRoster.runnable([plain, mine], combinations: combinations)
        XCTAssertEqual(runnable, [plain, mine])
        XCTAssertTrue(mine.isCurrent(schemaID: "pinyin", layout: .qwerty26, board: copied))
        XCTAssertFalse(plain.isCurrent(schemaID: "pinyin", layout: .qwerty26, board: copied))
        XCTAssertEqual(
            UserKeyboardRoster.cycleTarget(
                currentSchemaID: "pinyin", currentLayout: .qwerty26, currentBoard: "qwerty26", in: runnable),
            mine)
        XCTAssertEqual(
            UserKeyboardRoster.cycleTarget(
                currentSchemaID: "pinyin", currentLayout: .qwerty26, currentBoard: copied, in: runnable),
            plain)
    }

    /// The rosters of a publication record written before keyboards named their layout.
    func testOlderRecordsDecodeToTheSameKeyboards() throws {
        let json = """
            [{"layout":"qwerty26","schemaID":"kagiroi"},{"board":"kana12","layout":"qwerty26","schemaID":"kagiroi"},
             {"layout":"qwerty26","schemaID":"songyan_quanpin"},{"layout":"phone9","schemaID":"songyan_quanpin"},
             {"layout":"merged14","schemaID":"songyan_flypy"}]
            """
        let keyboards = try JSONDecoder().decode([PublishedKeyboard].self, from: Data(json.utf8))
        XCTAssertEqual(
            keyboards.map(\.id),
            [
                "kagiroi:qwerty26", "kagiroi:qwerty26#kana12", "songyan_quanpin:qwerty26",
                "songyan_quanpin:phone9", "songyan_flypy:merged14",
            ])
        // Writing them again changes nothing: a keyboard without a layout stays one.
        let again = try JSONDecoder().decode(
            [PublishedKeyboard].self, from: JSONEncoder().encode(keyboards))
        XCTAssertEqual(again, keyboards)
        XCTAssertEqual(keyboards.filter { $0.board == nil }.count, 4)
    }
}
