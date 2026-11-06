import Foundation
import XCTest

@testable import LayoutKit

/// The bundled 倉頡 (Cangjie) 26-key keyboard: the familiar QWERTY positions, each cap the radical
/// that letter stands for and the corner label the letter itself, then the shared control row.
final class CangjieLayoutTests: XCTestCase {
    /// The radical each letter stands for and the letter it sits on, row by row (letter order).
    private static let rows: [(letter: String, radical: String)] = [
        ("q", "手"), ("w", "田"), ("e", "水"), ("r", "口"), ("t", "廿"),
        ("y", "卜"), ("u", "山"), ("i", "戈"), ("o", "人"), ("p", "心"),
        ("a", "日"), ("s", "尸"), ("d", "木"), ("f", "火"), ("g", "土"),
        ("h", "竹"), ("j", "十"), ("k", "大"), ("l", "中"),
        ("z", "重"), ("x", "難"), ("c", "金"), ("v", "女"), ("b", "月"),
        ("n", "弓"), ("m", "一"),
    ]
    /// Two of the radicals only exist in the traditional forms, so a simplified copy would be a
    /// different keyboard.
    private static let traditionalOnlyRadicals = ["難", "重"]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func example() throws -> LayoutDefinition {
        let file = repositoryRoot.appendingPathComponent("Resources/Layouts/cangjie26.json")
        return try LayoutDefinition.decode(Data(contentsOf: file))
    }

    private func bundled() throws -> LayoutDefinition {
        try XCTUnwrap(
            BuiltinLayouts.all.first { $0.id == "cangjie26" },
            "the cangjie keyboard must be a bundled layout, not only an example file")
    }

    func testTheExampleFileIsTheBundledDefinition() throws {
        XCTAssertEqual(try example(), try bundled())
    }

    func testTheKeyboardIsRegisteredAsABundledLayout() throws {
        let registry = try LayoutRegistry()
        XCTAssertEqual(registry.layout(id: "cangjie26")?.name, "仓颉 26 键")
        XCTAssertEqual(registry.resolvedLayout(id: "cangjie26")?.id, "cangjie26")
        XCTAssertEqual(
            registry.usableLayouts { $0.id == "cangjie26" }.map(\.id), ["cangjie26"],
            "every catalog offers the keyboard, like the other bundled presets")
        var mutable = registry
        XCTAssertThrowsError(
            try mutable.remove(id: "cangjie26"), "a bundled layout is reset, never deleted")
        // The traditional boards follow the four existing presets, so a catalog's preset order stays
        // predictable for a host that lists them.
        XCTAssertEqual(BuiltinLayouts.all.suffix(2).map(\.id), ["zhuyin41", "cangjie26"])
    }

    func testTheThreeLetterRowsHaveTenNineSevenKeys() throws {
        let layout = try bundled()
        XCTAssertEqual(layout.rows.count, 4, "three letter rows and one control row")
        XCTAssertEqual(layout.rows.map { $0.keys.count }, [10, 9, 7, 5])
    }

    func testEveryCapDrawsItsRadical() throws {
        let caps = try bundled().rows.dropLast().flatMap(\.keys).map(\.label)
        XCTAssertEqual(caps, Self.rows.map(\.radical))
    }

    func testEveryKeySendsItsLatinLetter() throws {
        for (key, expected) in zip(try bundled().rows.dropLast().flatMap(\.keys), Self.rows) {
            XCTAssertEqual(key.action, LayoutAction(.code, value: expected.letter), key.label)
            XCTAssertNoThrow(try key.action.validate())
        }
    }

    func testTheCornerLabelIsTheLetterOfTheKey() throws {
        for (key, expected) in zip(try bundled().rows.dropLast().flatMap(\.keys), Self.rows) {
            XCTAssertEqual(key.secondaryLabel, expected.letter.uppercased(), key.label)
            XCTAssertNil(key.width, "every cap is one unit wide")
            XCTAssertNil(key.titleMode, "the radical is the face")
            XCTAssertNil(key.longPress, "a radical cap carries no alternate")
        }
    }

    func testTheSpokenFaceIsTheRadicalNotTheLetter() throws {
        // The accessibility layer reads the stored label as the spoken name, so each cap must be
        // named by its radical while the corner keeps the letter. A letter typed as the label would
        // make VoiceOver read "A" for a 日 key.
        for key in try bundled().rows.dropLast().flatMap(\.keys) {
            XCTAssertEqual(key.label.count, 1, key.label)
            XCTAssertFalse(key.label.allSatisfy(\.isASCII), "the label is the radical, not the letter")
            XCTAssertNotEqual(key.label, key.secondaryLabel)
        }
        for radical in Self.traditionalOnlyRadicals {
            XCTAssertTrue(
                try bundled().rows.flatMap(\.keys).contains { $0.label == radical },
                "the traditional form \(radical) is the stored cap")
        }
    }

    func testTheKeyCodesAreExactlyTheLatinAlphabet() throws {
        let codes = try bundled().rows.dropLast().flatMap(\.keys).compactMap { $0.action.value }
        XCTAssertEqual(Set(codes), Set("abcdefghijklmnopqrstuvwxyz".map(String.init)))
        XCTAssertEqual(codes.count, 26)
    }

    func testTheKeyboardKeepsTheStandardTwentySixKeyShell() throws {
        let layout = try bundled()
        // The letter rows are the bundled 26-key geometry, so the host keeps its familiar Shift,
        // Delete and stagger instead of drawing a second, differently aligned shell.
        XCTAssertTrue(BuiltinLayouts.matchesMainShell(layout, as: .qwerty26))
        XCTAssertTrue(BuiltinLayouts.matchesMainShellColumns(layout, as: .qwerty26))
        XCTAssertNil(BuiltinLayouts.handSplit(for: layout), "no saved hand cut belongs to this board")
        XCTAssertEqual(layout.input, LayoutInput(builtinLayout: .qwerty26))
        XCTAssertNil(layout.input.schemaID)
    }

    func testTheControlRowCarriesItsOwnLanguageKeys() throws {
        let controlRow = try XCTUnwrap(try bundled().rows.last)
        XCTAssertTrue(controlRow.keys.allSatisfy { $0.action.type != .code && $0.action.type != .literal })
        XCTAssertEqual(
            controlRow.keys.map(\.action.type),
            [.globe, .pageSwitch, .languageSwitch, .space, .enter])
        XCTAssertEqual(controlRow.keys.first { $0.action.type == .space }?.width, 4)
        XCTAssertTrue(try bundled().hasInputModeSwitchKey)
    }

    func testTheRadicalsTypeTheDocumentedWord() throws {
        // 你 is onf in cangjie5: the caps that send o, n and f are 人, 弓 and 火.
        let keys = try bundled().rows.dropLast().flatMap(\.keys)
        let byCode = Dictionary(uniqueKeysWithValues: keys.map { ($0.action.value ?? "", $0.label) })
        XCTAssertEqual(["o", "n", "f"].map { byCode[$0] ?? "" }, ["人", "弓", "火"])
    }

    func testTheKeyboardNeedsTheCandidateBar() throws {
        let layout = try bundled()
        XCTAssertTrue(layout.sendsEngineCode)
        XCTAssertEqual(layout.effectiveCandidateArea, .init(candidates: true, reading: false))
        XCTAssertNil(layout.note)
    }
}
