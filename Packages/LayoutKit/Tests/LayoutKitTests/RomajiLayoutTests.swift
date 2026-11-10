import Foundation
import XCTest

@testable import LayoutKit

/// The bundled Japanese romaji board: the QWERTY 26-key letters with ー, typed by the scheme's
/// minus code, right of L (where the system romaji keyboard has it), followed by the 26-key stand-in control row. The shell replaces that row
/// with its own automatic footer, so the input language names the space, Return and language keys
/// and puts 、 and 。 on either side of the space bar.
final class RomajiLayoutTests: XCTestCase {
    /// The cap of every key of the three letter rows, in drawn order. The long vowel mark sits
    /// right of L.
    private static let letterCaps = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l", "ー"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]
    /// The engine code of every letter key, in the same order: ー is the scheme's minus.
    private static let letterCodes = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l", "-"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func example() throws -> LayoutDefinition {
        let file = repositoryRoot.appendingPathComponent("Resources/Layouts/romaji26.json")
        return try LayoutDefinition.decode(Data(contentsOf: file))
    }

    private func bundled() throws -> LayoutDefinition {
        try XCTUnwrap(
            BuiltinLayouts.all.first { $0.id == "romaji26" },
            "the Japanese romaji keyboard must be a bundled layout, not only an example file")
    }

    private func japanesePolicy(showsSpaceSideMarks: Bool = true) -> KeyboardControlPolicy {
        KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: true, isPhoneLayout: false,
            usesASCIIPunctuation: false, script: .japanese, showsSpaceSideMarks: showsSpaceSideMarks)
    }

    func testTheExampleFileIsTheBundledDefinition() throws {
        XCTAssertEqual(try example(), try bundled())
    }

    func testTheKeyboardIsRegisteredAsABundledLayout() throws {
        let registry = try LayoutRegistry()
        XCTAssertEqual(registry.layout(id: "romaji26")?.name, "罗马字 26 键")
        XCTAssertEqual(registry.resolvedLayout(id: "romaji26")?.id, "romaji26")
        XCTAssertEqual(
            registry.usableLayouts { $0.id == "romaji26" }.map(\.id), ["romaji26"],
            "every catalog offers the keyboard, like the other bundled presets")
        var mutable = registry
        XCTAssertThrowsError(
            try mutable.remove(id: "romaji26"), "a bundled layout is reset, never deleted")
    }

    func testTheJapaneseBoardFollowsTheExistingPresets() {
        XCTAssertEqual(
            BuiltinLayouts.all.map(\.id),
            ["qwerty26", "merged14", "merged18", "phone9", "zhuyin41", "cangjie26", "romaji26", "kana12"],
            "the bundled order stays predictable for a host that lists the presets")
    }

    func testTheLetterRowsAreQwertyWithTheLongVowelKeyRightOfM() throws {
        let layout = try bundled()
        XCTAssertEqual(layout.rows.count, 4, "three letter rows and one control row")
        XCTAssertEqual(layout.rows.map { $0.keys.count }, [10, 10, 7, 5])
        XCTAssertEqual(layout.rows.dropLast().map { $0.keys.map(\.label) }, Self.letterCaps)
    }

    func testEveryLetterKeySendsItsLatinCodeAndTheLongVowelSendsMinus() throws {
        let rows = try bundled().rows.dropLast()
        XCTAssertEqual(
            rows.flatMap { $0.keys.map { $0.action.value ?? "" } }, Self.letterCodes.flatMap { $0 })
        for row in rows {
            for key in row.keys {
                XCTAssertEqual(key.action.type, .code, key.label)
                XCTAssertNoThrow(try key.action.validate(), key.label)
                XCTAssertNil(key.width, "every letter key is one unit wide")
            }
        }
        // ー must reach the scheme as the minus code, never as an inserted literal: the scheme turns
        // the code into the long vowel mark mid-composition.
        let longVowel = try XCTUnwrap(rows[1].keys.last)
        XCTAssertEqual(longVowel.label, "ー")
        XCTAssertEqual(longVowel.action, LayoutAction(.code, value: "-"))
        XCTAssertNil(longVowel.longPress, "the long vowel key has no alternate menu of its own")
    }

    func testTheLetterMenusStayTheBundledDefaultsSoTheInputLanguageNamesTheMarks() throws {
        // The identity transport keeps the bundled 26-key menus: the runtime replaces them with the
        // script's marks, so a Japanese board offers 、 。 「 」 and ー where a Chinese board does.
        let layout = try bundled()
        for (row, presetRow) in zip(layout.rows.dropLast(), BuiltinLayouts.qwerty26.rows.dropLast()) {
            XCTAssertEqual(Array(row.keys.prefix(presetRow.keys.count)), presetRow.keys)
        }
        XCTAssertEqual(AlternateKeyPolicy.defaultLetterLiterals(for: "a", script: .japanese), ["、"])
        XCTAssertEqual(AlternateKeyPolicy.defaultLetterLiterals(for: "c", script: .japanese), ["「", "『"])
        XCTAssertTrue(
            AlternateKeyPolicy.defaultLetterLiterals(for: "x", script: .japanese).contains("ー"))
    }

    func testTheControlRowIsTheBundledStandInSoTheShellDrawsItsAutomaticFooter() throws {
        // A declared bottom row equal to the preset's is replaced by the keyboard's own footer,
        // which is the only place the space-side marks and the automatic key names come from.
        let layout = try bundled()
        XCTAssertEqual(layout.rows.last, BuiltinLayouts.qwerty26.rows.last)
        XCTAssertEqual(
            layout.rows.last?.keys.map(\.action.type),
            [.modeSwitch, .globe, .space, .backspace, .enter])
        XCTAssertTrue(
            BuiltinLayouts.matchesMainShell(layout, as: .qwerty26),
            "the eight-key third row still counts as the main shell")
        XCTAssertTrue(
            BuiltinLayouts.matchesControlRowPolicy(layout, as: .qwerty26),
            "an unedited stand-in lets the keyboard draw its own footer")
    }

    func testTheSecondRowStillCountsAsTheMainShell() throws {
        let layout = try bundled()
        // The extra key is one more key in a main row; Shift and Delete are drawn outside the rows,
        // so the board keeps the shell's editing keys. Only the equal-column rule sees the change:
        // the letter rows draw at their declared weights instead of the preset's columns.
        XCTAssertTrue(BuiltinLayouts.matchesMainShell(layout, as: .qwerty26))
        XCTAssertFalse(BuiltinLayouts.matchesMainShellColumns(layout, as: .qwerty26))
        XCTAssertEqual(layout.rows[1].keys.count, 10)
        XCTAssertEqual(PhoneKeypadMetrics.mainRowCount, 3)
    }

    func testTheSpaceBarKeepsItsJapaneseSideMarks() throws {
        let policy = japanesePolicy()
        XCTAssertEqual(policy.utilityText, "、")
        XCTAssertEqual(KeyboardControlPolicy.fullStop, "。")
        let slots = policy.slots
        let space = try XCTUnwrap(slots.firstIndex(of: .space))
        XCTAssertEqual(slots[space - 1], .markLeft, "the comma sits left of the space bar")
        XCTAssertEqual(policy.key(at: .markLeft), .markLeft)
        XCTAssertEqual(policy.key(at: .markRight), .markRight)
        XCTAssertEqual(policy.utility, .punctuation("。"), "the right mark is the full stop")
        XCTAssertFalse(japanesePolicy(showsSpaceSideMarks: false).slots.contains(.markLeft))
    }

    func testSpaceReturnAndLanguageKeysFollowTheInputLanguage() throws {
        let policy = japanesePolicy()
        XCTAssertEqual(policy.spaceTitle(isComposing: false), "空白")
        XCTAssertEqual(policy.spaceTitle(isComposing: true), "変換")
        XCTAssertEqual(
            KeyLabelPolicy.returnTitle(script: .japanese, isComposing: true, intent: .lineBreak), "確定")
        XCTAssertEqual(
            KeyLabelPolicy.returnTitle(script: .japanese, isComposing: false, intent: .lineBreak), "改行")
        XCTAssertEqual(
            policy.languageTitle(for: nil), "あ/A",
            "the automatic language key draws both sides, as on Android")
        XCTAssertEqual(policy.languageCurrentSideIsFirst(for: nil), true)
        let english = KeyboardControlPolicy(
            page: .letters, isEnglishMode: true, hasGlobe: true, isPhoneLayout: false,
            usesASCIIPunctuation: false, script: .japanese, showsSpaceSideMarks: false)
        XCTAssertEqual(english.languageTitle(for: nil), "あ/A")
        XCTAssertEqual(english.languageCurrentSideIsFirst(for: nil), false)
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
