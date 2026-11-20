import XCTest

@testable import KeyboardCore

/// A layout's own grouping becomes a fold of its own; the bundled grouping stays the bundled fold.
final class CompactFoldOfTests: XCTestCase {
    private func groups(_ keys: String...) -> [Character: Character] {
        var map: [Character: Character] = [:]
        for key in keys { for code in key { map[code] = key.first! } }
        return map
    }

    private var bundled14: [Character: Character] {
        groups("qw", "er", "ty", "ui", "op", "as", "df", "gh", "jk", "l", "zx", "cv", "bn", "m")
    }

    func testTheBundledGroupingIsTheBundledFold() {
        XCTAssertEqual(CompactFold.of(kind: .merged14, map: bundled14), .merged14)
        XCTAssertEqual(CompactFold.of(kind: .phone9, map: CompactFold.phone9.map), .phone9)
        XCTAssertTrue(CompactFold.merged14.isBuiltin)
    }

    func testAnotherGroupingGetsItsOwnIdAndKeepsTheKeyCount() throws {
        let moved = groups("q", "wer", "ty", "ui", "op", "as", "df", "gh", "jk", "l", "zx", "cv", "bn", "m")
        let fold = try XCTUnwrap(CompactFold.of(kind: .merged14, map: moved))
        XCTAssertNotNil(fold.id.range(of: "^14u[0-9a-f]{8}$", options: .regularExpression), fold.id)
        XCTAssertEqual(fold.keyCount, "14")
        XCTAssertFalse(fold.isBuiltin)
        XCTAssertEqual(fold.map["e"], "w")
        XCTAssertEqual(CompactFold.of(kind: .merged14, map: moved)?.id, fold.id)
        let other = groups("qwe", "r", "ty", "ui", "op", "as", "df", "gh", "jk", "l", "zx", "cv", "bn", "m")
        XCTAssertNotEqual(CompactFold.of(kind: .merged14, map: other)?.id, fold.id)
    }

    func testAnOwnGroupingReadsBackFromTheRegistry() throws {
        var map = CompactFold.merged14.map
        map[";"] = "q"
        let fold = try XCTUnwrap(CompactFold.of(kind: .merged14, map: map))
        let adapter = KeyboardResourceSet.EncodingAdapter(
            sourceSchemaID: "pinyin", schemaID: "x", layout: .merged14, fold: fold)
        let read = try JSONDecoder().decode(
            KeyboardResourceSet.EncodingAdapter.self, from: JSONEncoder().encode(adapter))
        XCTAssertEqual(read.compactFold, fold)
        // A bundled companion stores nothing of its fold and reads back as the bundled one.
        let bundled = KeyboardResourceSet.EncodingAdapter(
            sourceSchemaID: "pinyin", schemaID: "y", layout: .merged14, fold: .merged14)
        XCTAssertNil(bundled.fold)
        XCTAssertEqual(bundled.compactFold, .merged14)
    }

    func testCompanionTasksFollowEachKeyboardsGrouping() throws {
        var map = CompactFold.merged14.map
        map["w"] = "e"
        let own = try XCTUnwrap(CompactFold.of(kind: .merged14, map: map))
        let bundled = PublishedKeyboard(schemaID: "pinyin", layout: .merged14, board: "merged14")
        let custom = PublishedKeyboard(schemaID: "pinyin", layout: .merged14, board: "mine")
        let broken = PublishedKeyboard(schemaID: "pinyin", layout: .phone9, board: "broken")
        let tasks = PublishedKeyboard.companionTasks(
            for: [bundled, custom, custom, broken, PublishedKeyboard(schemaID: "pinyin", layout: .qwerty26)]
        ) { keyboard in
            switch keyboard.board {
            case "mine": return [.merged14: own]
            case "broken": return [.phone9: CompactFold?.none]
            default: return [:]
            }
        }
        XCTAssertEqual(tasks.map(\.key), ["pinyin:merged14", "pinyin:merged14:" + own.id])
    }

    func testTheIdIsTheOneAndroidGivesTheSameGrouping() {
        // java.util.zip.CRC32 of "abc"; both platforms name a grouping's companion alike.
        XCTAssertEqual(CRC32.checksum(Array("abc".utf8)), 0x3524_41C2)
    }

    func testANineKeyGroupingOfItsOwnSendsDigits() throws {
        var custom = CompactFold.phone9.map
        custom["c"] = "3"
        let fold = try XCTUnwrap(CompactFold.of(kind: .phone9, map: custom))
        XCTAssertEqual(fold.keyCount, "9")
        XCTAssertTrue(fold.isPhoneDigits)
        XCTAssertEqual(fold.map["c"], "3")
    }

    func testAGroupingThatCannotFoldIsRefused() {
        var stray = bundled14
        stray["w"] = "x"
        XCTAssertNil(CompactFold.of(kind: .merged14, map: stray))
        var onOne = CompactFold.phone9.map
        onOne["a"] = "1"
        XCTAssertNil(CompactFold.of(kind: .phone9, map: onOne))
        XCTAssertNil(CompactFold.of(kind: .qwerty26, map: bundled14))
    }

    func testCodesOtherThanLettersFoldTheSameWay() throws {
        let strokes: [Character: Character] = ["h": "h", "s": "h", "p": "p", "n": "p", "z": "z"]
        let fold = try XCTUnwrap(CompactFold.of(kind: .merged14, map: strokes))
        XCTAssertEqual(fold.map["s"], "h")
        XCTAssertEqual(fold.keysSent, ["h", "p", "z"])
    }

    func testMoreMergedKeysThanExactTokensDoNotFold() {
        let marks = Array("!#%*+<>@^_|~&=$`,.;:?/-'()")
        var crowded: [Character: Character] = [:]
        for (letter, mark) in zip("abcdefghijklmnopqrstuvwxyz", marks) {
            crowded[letter] = letter
            crowded[mark] = letter
        }
        XCTAssertNil(CompactFold.of(kind: .merged14, map: crowded))
    }

    func testADrawnLayoutRunsOnlyOnItsOwnCompanion() throws {
        let own = try XCTUnwrap(
            CompactFold.of(
                kind: .merged14,
                map: groups("q", "wer", "ty", "ui", "op", "as", "df", "gh", "jk", "l", "zx", "cv", "bn", "m")))
        let adapters: [KeyboardResourceSet.EncodingAdapter] = [
            .init(sourceSchemaID: "pinyin", schemaID: "keyboard_0123456789abcdef0123_14", layout: .merged14),
            .init(
                sourceSchemaID: "pinyin", schemaID: "keyboard_0123456789abcdef0123_" + own.id, layout: .merged14,
                fold: own),
        ]
        XCTAssertEqual(
            KeyboardResourceSet.engineRoute(source: "pinyin", layout: .merged14, adapters: adapters, bindings: [])?
                .schemaID(source: "pinyin"), "keyboard_0123456789abcdef0123_14")
        XCTAssertEqual(
            KeyboardResourceSet.engineRoute(
                source: "pinyin", layout: .merged14, adapters: adapters, bindings: [], folds: [.merged14: own])?
                .schemaID(source: "pinyin"), "keyboard_0123456789abcdef0123_" + own.id)
        // A drawn layout that does not fold runs on nothing; one without its companion neither.
        XCTAssertNil(
            KeyboardResourceSet.engineRoute(
                source: "pinyin", layout: .merged14, adapters: adapters, bindings: [],
                folds: [.merged14: CompactFold?.none] as [KeyboardLayoutKind: CompactFold?]))
        XCTAssertNil(
            KeyboardResourceSet.engineRoute(
                source: "pinyin", layout: .merged14, adapters: Array(adapters.prefix(1)), bindings: [],
                folds: [.merged14: own]))
    }
}
