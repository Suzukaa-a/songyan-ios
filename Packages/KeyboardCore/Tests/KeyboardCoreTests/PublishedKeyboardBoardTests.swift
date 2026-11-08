import XCTest

@testable import KeyboardCore

/// A keyboard may name the physical board it types on. Romaji and kana of one input method are two
/// keyboards that share the 26-key shape, its pairing and its resources.
final class PublishedKeyboardBoardTests: XCTestCase {
    private let romaji = PublishedKeyboard(schemaID: "jp", layout: .qwerty26, board: "romaji26")
    private let kana = PublishedKeyboard(schemaID: "jp", layout: .qwerty26, board: "kana12")
    private let legacy = PublishedKeyboard(schemaID: "jp", layout: .qwerty26)

    func testBoardIsPartOfIdentityButNotOfTheCombination() {
        XCTAssertEqual(legacy.id, "jp:qwerty26")
        XCTAssertEqual(romaji.id, "jp:qwerty26#romaji26")
        XCTAssertEqual(kana.id, "jp:qwerty26#kana12")
        XCTAssertEqual(Set([legacy.id, romaji.id, kana.id]).count, 3)
        XCTAssertEqual([legacy, romaji, kana].map(\.combinationID), Array(repeating: "jp:qwerty26", count: 3))
        XCTAssertNotEqual(romaji, kana)
        XCTAssertNotEqual(romaji, legacy)
    }

    func testCodableRoundTripWithAndWithoutBoard() throws {
        let decoder = JSONDecoder()
        for keyboard in [legacy, romaji, kana] {
            let data = try JSONEncoder().encode(keyboard)
            XCTAssertEqual(try decoder.decode(PublishedKeyboard.self, from: data), keyboard)
        }
        let withoutBoard = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: withoutBoard, as: UTF8.self).contains("board"), "nil board is not encoded")
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(kana), as: UTF8.self).contains("\"board\""))
    }

    func testLegacyRecordWithoutBoardDecodesToNil() throws {
        let json = Data(#"{"schemaID":"jp","layout":"qwerty26"}"#.utf8)
        let decoded = try JSONDecoder().decode(PublishedKeyboard.self, from: json)
        XCTAssertNil(decoded.board)
        XCTAssertEqual(decoded, legacy)
        XCTAssertEqual(decoded.id, "jp:qwerty26")
    }

    func testBoardsOfOneCombinationNeedNoExtraGenerationAndStayDistinctInTheList() {
        XCTAssertFalse(romaji.needsGeneratedAdapter)
        XCTAssertEqual(PublishedKeyboard.generationTasks(for: [romaji, kana]), [])
        XCTAssertEqual(PublishedKeyboard.resolve(published: [romaji, kana, romaji]), [romaji, kana])
        XCTAssertEqual(PublishedKeyboard.adding(kana, to: [romaji]), [romaji, kana])
        XCTAssertEqual(PublishedKeyboard.removing(romaji, from: [romaji, kana]), [kana])
        XCTAssertEqual(PublishedKeyboard.selectionAfterRemoval(from: [kana], current: romaji), kana)
    }

    func testResourceSetKeepsEveryBoardOfAPublishedCombination() {
        let base = URL(fileURLWithPath: "/tmp/board-set")
        let set = KeyboardResourceSet(
            id: "board-set", name: "", sharedDirectory: base, userDirectory: base,
            layoutEntries: [], prebuiltDirectory: base,
            schemas: [KeyboardSchemaDescriptor(id: "jp", name: "日本語", alphabet: "abcdefghijklmnopqrstuvwxyz")],
            selectedSchemaID: "jp", publishedKeyboards: [romaji, kana])
        let combinations = set.availableCombinations
        XCTAssertEqual(combinations.map(\.id), ["jp:qwerty26"], "one combination serves both boards")
        XCTAssertEqual(set.publishedCombinations([romaji, kana]).map(\.id), ["jp:qwerty26"])
        XCTAssertEqual(set.publishedKeyboards, [romaji, kana])
    }

    func testRosterListsBothBoardsWithTheirOwnTitlesAndCycles() {
        let combinations = [
            KeyboardResourceSet.Combination(
                schemaID: "jp", engineSchemaID: "jp", layout: .qwerty26, name: "日本語")
        ]
        let keyboards = [romaji, kana].map {
            UserKeyboard(inputMethodID: "jp", inputMethodName: "x", layout: .qwerty26, board: $0.board)
        }
        let runnable = UserKeyboardRoster.runnable(keyboards, combinations: combinations)
        XCTAssertEqual(runnable.map(\.id), ["jp:qwerty26#romaji26", "jp:qwerty26#kana12"])
        XCTAssertTrue(runnable.allSatisfy { $0.inputMethodName == "日本語" })
        XCTAssertEqual(
            UserKeyboardRoster.cycleTarget(
                currentSchemaID: "jp", currentLayout: .qwerty26, currentBoard: "romaji26", in: runnable)?.board,
            "kana12")
        XCTAssertEqual(
            UserKeyboardRoster.cycleTarget(
                currentSchemaID: "jp", currentLayout: .qwerty26, currentBoard: "kana12", in: runnable)?.board,
            "romaji26")
        // A running board outside the list falls to the first entry, like any unknown current keyboard.
        XCTAssertEqual(
            UserKeyboardRoster.cycleTarget(
                currentSchemaID: "jp", currentLayout: .qwerty26, currentBoard: nil, in: runnable)?.board,
            "romaji26")
    }

    func testIsCurrentComparesTheBoardAndNilMatchesTheBoardlessKeyboardOnly() {
        let withBoard = UserKeyboard(inputMethodID: "jp", inputMethodName: "", layout: .qwerty26, board: "kana12")
        let without = UserKeyboard(inputMethodID: "jp", inputMethodName: "", layout: .qwerty26)
        XCTAssertTrue(withBoard.isCurrent(schemaID: "jp", layout: .qwerty26, board: "kana12"))
        XCTAssertFalse(withBoard.isCurrent(schemaID: "jp", layout: .qwerty26, board: "romaji26"))
        XCTAssertFalse(withBoard.isCurrent(schemaID: "jp", layout: .qwerty26, board: nil))
        XCTAssertTrue(without.isCurrent(schemaID: "jp", layout: .qwerty26, board: nil))
        XCTAssertFalse(without.isCurrent(schemaID: "jp", layout: .qwerty26, board: "kana12"))
        XCTAssertEqual(
            UserKeyboardRoster.currentTitle(
                schemaID: "jp", layout: .qwerty26, board: "kana12", in: [without, withBoard]), withBoard.title)
    }

    func testBackfillingNamesKeepsTheBoard() {
        let blank = UserKeyboard(inputMethodID: "jp", inputMethodName: " ", layout: .qwerty26, board: "kana12")
        let filled = UserKeyboardRoster.backfillingNames(
            [blank], from: [UserKeyboardCandidate(inputMethodID: "jp", inputMethodName: "日本語", layout: .qwerty26)])
        XCTAssertEqual(filled.first?.board, "kana12")
        XCTAssertEqual(filled.first?.inputMethodName, "日本語")
    }

    func testRouteIdentityAndSelectionChangeCarryTheBoard() {
        let url = URL(fileURLWithPath: "/tmp/route")
        func key(_ board: String?) -> KeyboardRouteKey {
            KeyboardRouteKey(
                resourceID: "r", publicationGeneration: "g", sharedDirectory: url, userDirectory: url,
                prebuiltDirectory: url, sourceSchemaID: "jp", layout: .qwerty26, board: board)
        }
        XCTAssertNotEqual(key("romaji26"), key("kana12"))
        XCTAssertNotEqual(key(nil), key("kana12"))
        XCTAssertEqual(key("kana12"), key("kana12"))
        XCTAssertEqual(KeyboardSelectionChange(schemaID: "jp", layout: .qwerty26, board: "kana12").board, "kana12")
        XCTAssertNil(KeyboardSelectionChange(schemaID: "jp", layout: .qwerty26).board)
    }
}
