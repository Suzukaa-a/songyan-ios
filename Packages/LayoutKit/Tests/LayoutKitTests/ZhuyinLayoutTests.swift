import Foundation
import XCTest

@testable import LayoutKit

/// The bundled 大千 (Daqian) 41-key zhuyin keyboard: four letter rows of 11 / 10 / 10 / 10 keys,
/// each cap a bopomofo symbol and each action the ASCII key that symbol sits on, followed by the
/// control row. The engine receives the ASCII codes; no cap shows them.
final class ZhuyinLayoutTests: XCTestCase {
    /// The ASCII key of every cap, in drawn order. Keys 2, 3, 4 and 5 carry the tone marks and the
    /// space bar carries the first tone, so the rows mix symbols and codes exactly as the physical
    /// 大千 keyboard does.
    private static let letterCodes = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-"],
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";"],
        ["z", "x", "c", "v", "b", "n", "m", ",", ".", "/"],
    ]
    /// The symbol each cap draws, in the same order.
    private static let keyCaps = [
        ["ㄅ", "ㄉ", "ˇ", "ˋ", "ㄓ", "ˊ", "˙", "ㄚ", "ㄞ", "ㄢ", "ㄦ"],
        ["ㄆ", "ㄊ", "ㄍ", "ㄐ", "ㄔ", "ㄗ", "ㄧ", "ㄛ", "ㄟ", "ㄣ"],
        ["ㄇ", "ㄋ", "ㄎ", "ㄑ", "ㄕ", "ㄘ", "ㄨ", "ㄜ", "ㄠ", "ㄤ"],
        ["ㄈ", "ㄌ", "ㄏ", "ㄒ", "ㄖ", "ㄙ", "ㄩ", "ㄝ", "ㄡ", "ㄥ"],
    ]
    /// Every code the scheme accepts except the space that types the first tone: the target set of
    /// the 大千 keymap in the pinned rime-bopomofo tree, verified key by key when this test was
    /// written. Kept here so the suite never reads a downloaded tree.
    private static let engineAlphabet = Set(",-./0123456789;abcdefghijklmnopqrstuvwxyz".map(String.init))

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func example() throws -> LayoutDefinition {
        let file = repositoryRoot.appendingPathComponent("Resources/Layouts/zhuyin41.json")
        return try LayoutDefinition.decode(Data(contentsOf: file))
    }

    private func bundled() throws -> LayoutDefinition {
        try XCTUnwrap(
            BuiltinLayouts.all.first { $0.id == "zhuyin41" },
            "the zhuyin keyboard must be a bundled layout, not only an example file")
    }

    private func traditionalPolicy() -> KeyboardControlPolicy {
        KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: true, isPhoneLayout: false,
            usesASCIIPunctuation: false, script: .traditionalChinese)
    }

    func testTheExampleFileIsTheBundledDefinition() throws {
        XCTAssertEqual(try example(), try bundled())
    }

    func testTheKeyboardIsRegisteredAsABundledLayout() throws {
        let registry = try LayoutRegistry()
        XCTAssertEqual(registry.layout(id: "zhuyin41")?.name, "注音 41 键")
        XCTAssertEqual(registry.resolvedLayout(id: "zhuyin41")?.id, "zhuyin41")
        XCTAssertEqual(
            registry.usableLayouts { $0.id == "zhuyin41" }.map(\.id), ["zhuyin41"],
            "every catalog offers the keyboard, like the other bundled presets")
        var mutable = registry
        XCTAssertThrowsError(
            try mutable.remove(id: "zhuyin41"), "a bundled layout is reset, never deleted")
    }

    func testTheFourLetterRowsHaveElevenTenTenTenKeys() throws {
        let layout = try bundled()
        XCTAssertEqual(layout.rows.count, 5, "four letter rows and one control row")
        XCTAssertEqual(layout.rows.map { $0.keys.count }, [11, 10, 10, 10, 6])
    }

    func testEveryCapDrawsItsZhuyinSymbol() throws {
        let rows = try bundled().rows.dropLast()
        XCTAssertEqual(rows.count, Self.keyCaps.count)
        for (row, caps) in zip(rows, Self.keyCaps) {
            XCTAssertEqual(row.keys.map(\.label), caps)
        }
    }

    func testEveryLetterKeySendsTheCodeOfItsPosition() throws {
        let rows = try bundled().rows.dropLast()
        for (row, codes) in zip(rows, Self.letterCodes) {
            for (key, code) in zip(row.keys, codes) {
                XCTAssertEqual(key.action, LayoutAction(.code, value: code), key.label)
                XCTAssertNil(key.secondaryLabel, "a zhuyin cap shows its symbol only")
                XCTAssertNil(key.longPress, "a zhuyin cap carries no alternate")
                XCTAssertNil(key.width, "every cap is one unit wide")
                XCTAssertNil(key.titleMode, "the stored symbol is the face")
            }
        }
    }

    func testTheKeyCodesAreExactlyTheBopomofoAlphabet() throws {
        let keys = try bundled().rows.dropLast().flatMap(\.keys)
        XCTAssertEqual(keys.count, 41)
        let codes = keys.compactMap { key -> String? in
            guard key.action.type == .code else { return nil }
            return key.action.value
        }
        XCTAssertEqual(codes.count, 41, "every cap of the letter rows sends an engine code")
        XCTAssertEqual(Set(codes), Self.engineAlphabet)
        XCTAssertEqual(Set(codes).count, codes.count, "two caps must not send the same code")
        for code in codes {
            // This one-byte printable rule is what lets a definition send digits and - ; , . /.
            XCTAssertNoThrow(try LayoutAction(.code, value: code).validate(), code)
        }
    }

    func testTheControlRowSendsNoEngineCode() throws {
        let controlRow = try XCTUnwrap(try bundled().rows.last)
        XCTAssertTrue(controlRow.keys.allSatisfy { $0.action.type != .code && $0.action.type != .literal })
        XCTAssertEqual(
            controlRow.keys.map(\.action.type),
            [.globe, .pageSwitch, .languageSwitch, .space, .backspace, .enter])
        XCTAssertEqual(controlRow.keys.first { $0.action.type == .pageSwitch }?.action.pageSwitchTarget, .numeric)
        XCTAssertEqual(controlRow.keys.first { $0.action.type == .space }?.width, 4)
    }

    func testTheControlKeysFollowTheInputLanguage() throws {
        let controlRow = try XCTUnwrap(try bundled().rows.last)
        for key in controlRow.keys {
            XCTAssertEqual(key.titleMode, .automatic, key.label)
        }
        let space = try XCTUnwrap(controlRow.keys.first { $0.action.type == .space })
        XCTAssertEqual(space.automaticSpaceTitle(policy: traditionalPolicy(), isComposing: false), "空白")
        let simplified = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: true, isPhoneLayout: false,
            usesASCIIPunctuation: true, script: .simplifiedChinese)
        XCTAssertEqual(space.automaticSpaceTitle(policy: simplified, isComposing: false), "空格")
        // A legacy space without a title mode keeps its stored label, so the bar must declare one.
        XCTAssertEqual(
            LayoutKey(label: "空格", action: LayoutAction(.space)).automaticSpaceTitle(
                policy: traditionalPolicy(), isComposing: false),
            "空格")
        let language = try XCTUnwrap(controlRow.keys.first { $0.action.type == .languageSwitch })
        XCTAssertEqual(language.action.languageSwitchBehavior, nil, "the key follows the page")
        XCTAssertNil(language.longPress, "the native keyboard menu stays available")
    }

    func testTheKeyboardOffersTheSystemSwitchKey() throws {
        let layout = try bundled()
        XCTAssertTrue(layout.hasInputModeSwitchKey, "every bundled layout can leave the keyboard")
        XCTAssertNoThrow(try layout.validateRequiredInputModeSwitchKey(true))
    }

    func testTheKeyboardNeedsTheCandidateBar() throws {
        let layout = try bundled()
        XCTAssertEqual(layout.input, LayoutInput(builtinLayout: .qwerty26), "the encoding kind stays 26-key")
        XCTAssertNil(layout.input.schemaID, "several schemes share this board")
        XCTAssertNil(layout.note)
        XCTAssertTrue(layout.sendsEngineCode)
        XCTAssertEqual(layout.effectiveCandidateArea, .init(candidates: true, reading: false))
    }
}
