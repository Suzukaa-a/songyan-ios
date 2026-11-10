import Foundation
import XCTest

@testable import LayoutKit

/// The bundled Japanese twelve-key (kana12) board: the J2 4 x 3 kana grid between a leading rail
/// (composition caret left, 記号, あ/A, the system keyboard switch) and a trailing rail (delete,
/// space, Return spanning two rows). A kana cap carries its row id, not one Latin key: the flick,
/// toggle and romaji spelling of a row live in the kana input model. The board declares all four
/// rows itself, so neither the 26-key Shift/Delete chrome nor the automatic footer is injected.
final class Kana12PresetTests: XCTestCase {
    /// The tap glyph of each grid cell with the row id the kana handler spells into the engine, in
    /// drawn order.
    private static let grid: [(cap: String, rowID: String)] = [
        ("あ", "a"), ("か", "ka"), ("さ", "sa"),
        ("た", "ta"), ("な", "na"), ("は", "ha"),
        ("ま", "ma"), ("や", "ya"), ("ら", "ra"),
    ]
    /// The bottom row puts the modifier and the punctuation cap around わ.
    private static let bottomCaps = ["小゛゜", "わ", "、。?!"]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func example() throws -> LayoutDefinition {
        let file = repositoryRoot.appendingPathComponent("Resources/Layouts/kana12.json")
        return try LayoutDefinition.decode(Data(contentsOf: file))
    }

    private func bundled() throws -> LayoutDefinition {
        try XCTUnwrap(
            BuiltinLayouts.all.first { $0.id == "kana12" },
            "the Japanese twelve-key board must be a bundled layout, not only an example file")
    }

    func testTheExampleFileIsTheBundledDefinition() throws {
        // Strict: the author-facing JSON and the bundled declaration are the same data, field for
        // field, so editing either alone is caught here.
        XCTAssertEqual(try example(), try bundled())
    }

    func testTheKeyboardIsRegisteredAsABundledLayout() throws {
        let registry = try LayoutRegistry()
        XCTAssertEqual(registry.layout(id: "kana12")?.name, "假名 12 键")
        XCTAssertEqual(registry.resolvedLayout(id: "kana12")?.id, "kana12")
        XCTAssertEqual(
            registry.usableLayouts { $0.id == "kana12" }.map(\.id), ["kana12"],
            "every catalog offers the board, like the other bundled presets")
        var mutable = registry
        XCTAssertThrowsError(
            try mutable.remove(id: "kana12"), "a bundled layout is reset, never deleted")
    }

    func testTheBundledOrderKeepsTheExistingSevenPresetsAndAppendsTheBoard() {
        XCTAssertEqual(
            BuiltinLayouts.all.map(\.id),
            ["qwerty26", "merged14", "merged18", "phone9", "zhuyin41", "cangjie26", "romaji26", "kana12"],
            "the eight bundled presets keep a predictable order for a host that lists them")
    }

    func testTheGridIsTheFourByThreeJ2Layout() throws {
        let layout = try bundled()
        XCTAssertEqual(layout.rows.count, 4, "four rows: three kana rows and the modifier/punctuation row")
        XCTAssertEqual(layout.rows.map { $0.keys.count }, [3, 3, 3, 3], "three caps per row")
        XCTAssertEqual(
            layout.rows.dropLast().flatMap { $0.keys.map(\.label) }, Self.grid.map(\.cap))
        XCTAssertEqual(layout.rows.last?.keys.map(\.label), Self.bottomCaps)
    }

    func testEveryKanaCapCarriesItsRowsTapSpelling() throws {
        let taps = try bundled().rows.dropLast().flatMap(\.keys)
        XCTAssertEqual(taps.map { $0.action.value ?? "" }, Self.grid.map(\.rowID))
        for (key, expected) in zip(taps, Self.grid) {
            XCTAssertEqual(key.action, LayoutAction(.kana, value: expected.rowID), key.label)
            XCTAssertNoThrow(try key.action.validate(), expected.rowID)
            XCTAssertNil(key.secondaryLabel, "\(key.label) carries no corner label")
            XCTAssertNil(key.longPress, "\(key.label) has no alternate menu")
            XCTAssertNil(key.titleMode, "the authored kana glyph is the face")
            // The board never claims a Latin key: a romaji spelling is not one engine code, it is
            // the kana handler's business, so no cap is a `.code` key.
            XCTAssertNotEqual(key.action.type, .code, key.label)
        }
    }

    func testTheBottomRowCarriesTheModifierAndThePunctuationCap() throws {
        let bottom = try XCTUnwrap(try bundled().rows.last?.keys)
        XCTAssertEqual(bottom.map(\.label), Self.bottomCaps)
        // 小゛゜ is the canonical kana renderer's Japanese variant key: it edits the kana just
        // typed. A shift or a literal would type something else entirely.
        XCTAssertEqual(bottom[0].action, LayoutAction(.kanaModifier))
        XCTAssertNil(bottom[0].action.value, "the modifier edits, it does not name a row")
        XCTAssertNil(bottom[0].titleMode, "the authored 小゛゜ cap must not draw the ASCII shift face")
        XCTAssertNoThrow(try bottom[0].action.validate())
        // わ taps its own row.
        XCTAssertEqual(bottom[1].action, LayoutAction(.kana, value: "wa"))
        // 標点 taps 、; the other four marks are flick targets of the kana model.
        XCTAssertEqual(bottom[2].action, LayoutAction(.literal, value: "、"))
        XCTAssertNil(bottom[2].titleMode)
    }

    func testTheLeadingRailCarriesTheCursorSymbolsLanguageAndSystemSwitch() throws {
        let leading = try XCTUnwrap(try bundled().auxiliaryAreas?.first { $0.position == .leading })
        XCTAssertEqual(leading.role, .editing, "the rail edits the composition, it is not a symbol pad")
        XCTAssertEqual(
            leading.keys.map(\.action.type),
            [.cursorLeft, .pageSwitch, .languageSwitch, .globe],
            "the rail runs top to bottom: caret left, 記号, あ/A, system switch")
        // A kind of its own rather than a code: the controller sends the engine's own Left key so a
        // replacement typed after the caret move cannot overtake it.
        XCTAssertEqual(leading.keys[0].action, LayoutAction(.cursorLeft))
        XCTAssertNil(leading.keys[0].action.value)
        XCTAssertNoThrow(try leading.keys[0].action.validate())
        XCTAssertEqual(leading.keys[1].action, LayoutAction.pageSwitch(.symbols))
        XCTAssertEqual(leading.keys[2].action, LayoutAction.languageSwitch())
        XCTAssertEqual(leading.keys[3].action, LayoutAction(.globe))
        XCTAssertTrue(leading.keys.allSatisfy { $0.width == nil }, "each rail key is one row tall")
    }

    func testTheTrailingRailCarriesDeleteSpaceAndATwoRowReturn() throws {
        let trailing = try XCTUnwrap(try bundled().auxiliaryAreas?.first { $0.position == .trailing })
        XCTAssertEqual(trailing.role, .editing)
        XCTAssertEqual(
            trailing.keys.map(\.action.type), [.backspace, .space, .enter],
            "the rail runs top to bottom: delete, space, Return")
        // A rail key's width is its vertical span; Return covers the lower two rows, which is the
        // existing field, not a new height metadata.
        XCTAssertEqual(trailing.keys.map(\.width), [nil, nil, 2])
        XCTAssertEqual(
            trailing.keys.map { $0.width ?? 1 }.reduce(0, +), 4,
            "the rail spans the same four rows as the grid")
    }

    func testOnlyTheSystemControlsAreAutomatic() throws {
        let layout = try bundled()
        for key in layout.rows.flatMap(\.keys) {
            XCTAssertNil(key.titleMode, "the authored Japanese cap \(key.label) is its own face")
        }
        let automatic = (layout.auxiliaryAreas ?? []).flatMap(\.keys).filter { $0.titleMode == .automatic }
        XCTAssertEqual(
            automatic.map(\.label), ["記号", "あ/A", "🌐", "⌫", "空格", "⏎"],
            "every system control lets the host draw its live face for the input language")
        let authored = (layout.auxiliaryAreas ?? []).flatMap(\.keys).filter { $0.titleMode == nil }
        XCTAssertEqual(authored.map(\.label), ["←"], "only the named caret key keeps a stored face")
    }

    func testTheBoardDeclaresItsOwnRowsSoNoShellOrFooterIsInjected() throws {
        let layout = try bundled()
        // The fourth row types kana and marks, so it is content, not a control row: the automatic
        // footer never replaces it and no 26-key Shift/Delete chrome is wrapped around the grid.
        XCTAssertFalse(
            BuiltinLayouts.matchesMainShell(layout, as: .qwerty26),
            "the four kana rows are the whole board, not a 26-key main shell")
        XCTAssertFalse(BuiltinLayouts.matchesControlRowPolicy(layout, as: .qwerty26))
        XCTAssertFalse(BuiltinLayouts.matchesMainShellColumns(layout, as: .qwerty26))
        XCTAssertNil(BuiltinLayouts.handSplit(for: layout))
        XCTAssertTrue(
            layout.rows.last?.keys.contains { $0.action.type == .kana } ?? false,
            "a control row would be all non-encoding keys; the kana row is not one")
    }

    func testTheSystemSwitchStaysReachableWithoutAShellRow() throws {
        // The grid owns all four rows, so the globe cannot live in a footer: the leading rail is its
        // only entry point, and the App Store requirement is satisfied by data.
        let layout = try bundled()
        XCTAssertTrue(layout.hasInputModeSwitchKey)
        XCTAssertNoThrow(try layout.validateRequiredInputModeSwitchKey(true))
        XCTAssertFalse(layout.rows.flatMap(\.keys).contains { $0.action.type == .globe })
    }

    func testTheGridIsNeitherATelephoneKeypadNorASpellingPad() throws {
        let layout = try bundled()
        XCTAssertFalse(PhoneKeypadStructure.matches(layout), "no digit keys, no T9 shell")
        XCTAssertNil(LetterGroupLayout.groups(in: layout), "the caps are kana, not the Latin alphabet")
        XCTAssertFalse(CompactSpellingLayout.matches(layout), "no merged or phone-spelling disambiguation")
        XCTAssertEqual(CompactSpellingLayout.mainRows(in: layout), layout.rows, "all four rows are main rows")
        XCTAssertNil(layout.t9FirstKeyBehavior)
        XCTAssertNil(layout.t9QuickSymbols)
    }

    func testTheBoardAsksForTheCandidateBarWithoutAReadingRow() throws {
        let layout = try bundled()
        XCTAssertEqual(
            layout.input, LayoutInput(builtinLayout: .qwerty26),
            "the encoding kind stays the 26-key one: the board is identified by its id")
        XCTAssertNil(layout.input.schemaID, "several schemes share this board")
        XCTAssertNil(layout.note)
        // The kana rows reach the engine through the kana batch, so the board still needs the
        // candidate bar even though no key is a Latin code key.
        XCTAssertTrue(layout.sendsEngineCode)
        XCTAssertEqual(layout.effectiveCandidateArea, .init(candidates: true, reading: false))
    }

    func testTheBoardBecomesAnotherCandidateButNeverTheDefaultOrASavedPairing() throws {
        var registry = try LayoutRegistry()
        let key = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26)
        // Unbound boards only appear in the pairing list; the shape's preset stays the default.
        XCTAssertEqual(registry.defaultMainLayoutID(for: key), "qwerty26")
        XCTAssertTrue(
            registry.mainLayoutCandidates(for: key).map(\.id).contains("kana12"),
            "the board is offered for every 26-key-shape keyboard")
        let saved = KeyboardComposition(mainLayoutID: "romaji26")
        try registry.setComposition(saved, for: key.rawValue)
        XCTAssertEqual(registry.usableMainLayoutID(for: key), "romaji26", "a saved pairing is untouched")
        XCTAssertEqual(registry.composition(for: key), saved)
    }

    // MARK: - The new action kinds

    func testTheKanaKindsUseTheirOwnWireFormAndRejectForeignValues() {
        // The wire values are the decoder contract: an older build rejects these kinds instead of
        // drawing a kana cap as a Latin key, so they must never be folded into `.code`.
        XCTAssertEqual(LayoutAction.Kind.kana.rawValue, "kana")
        XCTAssertEqual(LayoutAction.Kind.kanaModifier.rawValue, "kanaModifier")
        XCTAssertEqual(LayoutAction.Kind.cursorLeft.rawValue, "cursorLeft")
        for rowID in LayoutAction.kanaRowIDs {
            XCTAssertNoThrow(try LayoutAction.kana(rowID).validate(), rowID)
        }
        XCTAssertEqual(LayoutAction.kanaRowIDs, Self.grid.map(\.rowID) + ["wa", "punctuation"])
        for unknown in ["", "kya", "A", "ka ", "かな", "left"] {
            XCTAssertThrowsError(try LayoutAction.kana(unknown).validate(), unknown)
        }
        for kind in [LayoutAction.Kind.kanaModifier, .cursorLeft] {
            XCTAssertNoThrow(try LayoutAction(kind).validate(), kind.rawValue)
            XCTAssertThrowsError(
                try LayoutAction(kind, value: "a").validate(), "\(kind.rawValue) carries no value")
        }
    }

    func testALatinCodeKeyStillTakesExactlyOneASCIICharacter() {
        // The kana repertoire must not loosen the existing code key: one engine key per cap stays
        // the rule, and a romaji spelling or a named key is not one.
        XCTAssertNoThrow(try LayoutAction(.code, value: "k").validate())
        XCTAssertNoThrow(try LayoutAction(.code, value: "-").validate())
        for invalid in ["ka", "Left", "kana", ""] {
            XCTAssertThrowsError(try LayoutAction(.code, value: invalid).validate(), invalid)
        }
    }

    func testTheBuiltInRowsOnlyUseTheKanaKindsTheyDeclare() throws {
        for (key, expected) in zip(try bundled().rows.dropLast().flatMap(\.keys), Self.grid) {
            XCTAssertEqual(key.action, LayoutAction.kana(expected.rowID))
            XCTAssertTrue(key.action.isEngineInput, "a kana cap does reach the engine")
        }
        XCTAssertFalse(LayoutAction.cursorLeft.isEngineInput, "the caret key types nothing")
        XCTAssertFalse(LayoutAction.kanaModifier.isEngineInput, "the modifier types nothing itself")
    }
}
