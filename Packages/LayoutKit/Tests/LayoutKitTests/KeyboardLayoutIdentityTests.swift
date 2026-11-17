import Foundation
import XCTest

@testable import LayoutKit

/// A keyboard may name the layout it types on. One saved before that keeps resolving exactly as it
/// did, and nothing stored is rewritten.
final class KeyboardLayoutIdentityTests: XCTestCase {
    private let shape = KeyboardCompositionKey(inputMethodID: "pinyin", layout: .qwerty26)

    private func userLayout(_ id: String, schemaID: String? = nil) -> LayoutDefinition {
        LayoutDefinition(
            id: id, name: "我的 26 键", input: LayoutInput(schemaID: schemaID, builtinLayout: .qwerty26),
            rows: BuiltinLayouts.qwerty26.rows)
    }

    /// The family rules the host injects for a Japanese input method.
    private let japanese = LayoutAvailability(
        allows: { definition, _ in !["zhuyin41", "cangjie26"].contains(definition.id) },
        preferredMainLayoutID: { _ in "romaji26" })

    func testTheKeyReadsBackItsThreeParts() {
        let key = KeyboardCompositionKey(inputMethodID: "pinyin", layout: .qwerty26, layoutID: "mine")
        XCTAssertEqual(key.rawValue, "pinyin:qwerty26#mine")
        XCTAssertEqual(KeyboardCompositionKey("pinyin:qwerty26#mine"), key)
        XCTAssertEqual(key.shapeKey, shape)
        XCTAssertEqual(shape.rawValue, "pinyin:qwerty26")
        XCTAssertNil(KeyboardCompositionKey("pinyin:qwerty26")?.layoutID)
    }

    func testIDsMayContainTheSeparators() {
        // The layout ID is everything after the first "#"; the shape follows the last ":" before it.
        let key = KeyboardCompositionKey("ns:scheme:phone9#a:b#c")
        XCTAssertEqual(key?.inputMethodID, "ns:scheme")
        XCTAssertEqual(key?.layout, .phone9)
        XCTAssertEqual(key?.layoutID, "a:b#c")
        XCTAssertEqual(key?.rawValue, "ns:scheme:phone9#a:b#c")
        XCTAssertNil(KeyboardCompositionKey("pinyin:qwerty26#"), "an empty layout ID is malformed")
        XCTAssertNil(KeyboardCompositionKey("pinyin#mine"), "the shape is required")
        XCTAssertNil(KeyboardCompositionKey(":qwerty26#mine"), "the input method is required")
        XCTAssertNil(KeyboardCompositionKey("pinyin:unknown#mine"))
    }

    func testAKeyboardWithoutALayoutAndWithoutAPairingOpensOnTheShapePreset() throws {
        let registry = try LayoutRegistry()
        XCTAssertEqual(registry.usableMainLayoutID(for: shape), "qwerty26")
        XCTAssertEqual(registry.composition(for: shape), KeyboardComposition(mainLayoutID: "qwerty26"))
        XCTAssertNil(registry.savedComposition(for: shape))
    }

    func testAKeyboardWithoutALayoutKeepsItsSavedPairing() throws {
        let mine = userLayout("mine")
        var registry = try LayoutRegistry(layouts: BuiltinLayouts.all + [mine])
        let saved = KeyboardComposition(mainLayoutID: "mine", numericPageID: KeyboardPagePresets.numericKeypad.id)
        try registry.setComposition(saved, for: shape.rawValue)
        XCTAssertEqual(registry.usableMainLayoutID(for: shape), "mine")
        XCTAssertEqual(registry.composition(for: shape), saved)
    }

    func testAKeyboardWithoutALayoutOpensOnItsFamilyBoard() throws {
        let registry = try LayoutRegistry()
        let key = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26)
        XCTAssertEqual(registry.usableMainLayoutID(for: key, availability: japanese), "romaji26")
        XCTAssertEqual(registry.usableMainLayoutID(for: key, board: nil, availability: japanese), "romaji26")
    }

    func testAKeyboardWithoutALayoutKeepsABoardSavedAsItsMainLayout() throws {
        var registry = try LayoutRegistry()
        let key = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26)
        try registry.setComposition(KeyboardComposition(mainLayoutID: "kana12"), for: key.rawValue)
        XCTAssertEqual(registry.usableMainLayoutID(for: key, availability: japanese), "kana12")
    }

    func testAKeyboardOpensOnTheLayoutItNames() throws {
        let mine = userLayout("mine")
        var registry = try LayoutRegistry(layouts: BuiltinLayouts.all + [mine])
        // The shape's pairing picks another layout; a keyboard that names its own ignores that.
        try registry.setComposition(KeyboardComposition(mainLayoutID: "qwerty26"), for: shape.rawValue)
        let own = KeyboardCompositionKey(inputMethodID: "pinyin", layout: .qwerty26, layoutID: "mine")
        XCTAssertEqual(registry.usableMainLayoutID(for: own), "mine")
        XCTAssertEqual(registry.usableMainLayoutID(for: shape, board: "mine"), "mine")
        XCTAssertEqual(registry.composition(for: own).mainLayoutID, "mine")
        let preset = KeyboardCompositionKey(inputMethodID: "pinyin", layout: .qwerty26, layoutID: "qwerty26")
        XCTAssertEqual(registry.usableMainLayoutID(for: preset), "qwerty26")
    }

    func testALayoutTheKeyboardCannotUseFallsBackToTheShapePairing() throws {
        let other = userLayout("for-other", schemaID: "other")
        var registry = try LayoutRegistry(layouts: BuiltinLayouts.all + [other, userLayout("mine")])
        try registry.setComposition(KeyboardComposition(mainLayoutID: "mine"), for: shape.rawValue)
        for unusable in ["for-other", "phone9", "deleted"] {
            XCTAssertEqual(registry.usableMainLayoutID(for: shape, board: unusable), "mine", unusable)
        }
        // The family rules still apply to a named layout.
        let key = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26, layoutID: "zhuyin41")
        XCTAssertEqual(registry.usableMainLayoutID(for: key, availability: japanese), "romaji26")
    }

    func testLayoutsOfOneShapeShareThePagesSavedBeforeTheyWereSeparateKeyboards() throws {
        var registry = try LayoutRegistry()
        let slot = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26)
        let shared = KeyboardComposition(mainLayoutID: "romaji26", numericPageID: KeyboardPagePresets.numericKeypad.id)
        try registry.setComposition(shared, for: slot.rawValue)
        for board in ["romaji26", "kana12"] {
            let key = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26, layoutID: board)
            let composition = registry.composition(for: key)
            XCTAssertEqual(composition.mainLayoutID, board)
            XCTAssertEqual(composition.numericPageID, shared.numericPageID)
            XCTAssertEqual(registry.savedComposition(for: key)?.numericPageID, shared.numericPageID)
        }
    }

    func testSavingAKeyboardsOwnPagesLeavesTheSharedOnesAlone() throws {
        var registry = try LayoutRegistry()
        let slot = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26)
        let shared = KeyboardComposition(mainLayoutID: "romaji26", numericPageID: KeyboardPagePresets.numericKeypad.id)
        try registry.setComposition(shared, for: slot.rawValue)
        let kana = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26, layoutID: "kana12")
        let own = KeyboardComposition(mainLayoutID: "kana12")
        try registry.setComposition(own, for: kana.rawValue)
        XCTAssertEqual(registry.composition(for: kana), own)
        XCTAssertEqual(registry.compositions[slot.rawValue], shared)
        let romaji = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26, layoutID: "romaji26")
        XCTAssertEqual(registry.composition(for: romaji).numericPageID, shared.numericPageID)
        // The catalog round trip keeps both entries.
        let decoded = try JSONDecoder().decode(LayoutRegistry.self, from: JSONEncoder().encode(registry))
        XCTAssertEqual(decoded.compositions, registry.compositions)
        XCTAssertEqual(decoded.keyboards(usingLayout: "kana12"), [kana])
    }

    func testAnOwnPairingMustKeepTheNamedLayoutAsItsMainLayout() throws {
        var registry = try LayoutRegistry(layouts: BuiltinLayouts.all + [userLayout("mine")])
        XCTAssertThrowsError(
            try registry.setComposition(KeyboardComposition(mainLayoutID: "qwerty26"), for: "pinyin:qwerty26#mine"))
        XCTAssertThrowsError(
            try registry.setComposition(KeyboardComposition(mainLayoutID: "phone9"), for: "pinyin:qwerty26#phone9"),
            "a layout of another shape")
        XCTAssertThrowsError(
            try registry.setComposition(KeyboardComposition(mainLayoutID: "gone"), for: "pinyin:qwerty26#gone"))
        XCTAssertNoThrow(
            try registry.setComposition(KeyboardComposition(mainLayoutID: "mine"), for: "pinyin:qwerty26#mine"))
    }

    func testALayoutAPairingNamesCannotBeRemovedAndPruningDropsItsKeyboard() throws {
        var registry = try LayoutRegistry(layouts: BuiltinLayouts.all + [userLayout("mine")])
        try registry.setComposition(KeyboardComposition(mainLayoutID: "mine"), for: "pinyin:qwerty26#mine")
        XCTAssertThrowsError(try registry.remove(id: "mine"))
        // A keyboard in 我的键盘 counts as a user of its layout even without a saved pairing.
        let unsaved = KeyboardCompositionKey(inputMethodID: "other", layout: .qwerty26, layoutID: "mine")
        XCTAssertEqual(
            registry.keyboards(usingLayout: "mine", among: [unsaved]).map(\.rawValue),
            ["other:qwerty26#mine", "pinyin:qwerty26#mine"])
        XCTAssertEqual(registry.pruneCompositions { $0 == "pinyin" }, 1)
        XCTAssertNoThrow(try registry.remove(id: "mine"))
    }

    // MARK: - Files written before keyboards named their layout

    /// `layouts.json` as an install wrote it before this change: 内置全拼 26 键 paired with a copied
    /// layout and the keypad 123 page, nothing saved for the Japanese keyboards.
    private func snapshot() throws -> LayoutRegistry {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/IOS/Fixtures/pre-layout-keyboards/layouts.json")
        let registry = try JSONDecoder().decode(LayoutRegistry.self, from: Data(contentsOf: url))
        try registry.validate()
        return registry
    }

    func testAnOlderCatalogResolvesTheSameLayoutsAndPages() throws {
        let registry = try snapshot()
        let copied = "0fd7d991-9160-4016-a88f-3df09fd773cb"
        XCTAssertEqual(Array(registry.compositions.keys), ["songyan_quanpin:qwerty26"])
        let quanpin = KeyboardCompositionKey(inputMethodID: "songyan_quanpin", layout: .qwerty26)
        XCTAssertEqual(registry.usableMainLayoutID(for: quanpin), copied)
        XCTAssertEqual(registry.composition(for: quanpin).numericPageID, KeyboardPagePresets.numericKeypad.id)
        for (schema, layout) in [("songyan_quanpin", LayoutInput.Builtin.phone9), ("songyan_flypy", .merged14)] {
            let key = KeyboardCompositionKey(inputMethodID: schema, layout: layout)
            XCTAssertEqual(registry.usableMainLayoutID(for: key), layout.rawValue)
            XCTAssertEqual(registry.composition(for: key), KeyboardComposition(mainLayoutID: layout.rawValue))
        }
        let kagiroi = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26)
        XCTAssertEqual(registry.usableMainLayoutID(for: kagiroi, board: nil, availability: japanese), "romaji26")
        XCTAssertEqual(registry.usableMainLayoutID(for: kagiroi, board: "kana12", availability: japanese), "kana12")
        // Loading and saving it again writes the same pairings back.
        let saved = try JSONDecoder().decode(LayoutRegistry.self, from: JSONEncoder().encode(registry))
        XCTAssertEqual(saved.compositions, registry.compositions)
    }

    func testAKeyboardAddedOnTheCopiedLayoutStartsFromTheOlderPages() throws {
        var registry = try snapshot()
        let copied = "0fd7d991-9160-4016-a88f-3df09fd773cb"
        let own = KeyboardCompositionKey(inputMethodID: "songyan_quanpin", layout: .qwerty26, layoutID: copied)
        XCTAssertEqual(registry.composition(for: own).numericPageID, KeyboardPagePresets.numericKeypad.id)
        let plain = KeyboardCompositionKey(inputMethodID: "songyan_quanpin", layout: .qwerty26, layoutID: "qwerty26")
        XCTAssertEqual(registry.usableMainLayoutID(for: plain), "qwerty26")
        var pages = registry.composition(for: plain)
        pages.numericPageID = KeyboardPagePresets.numericAutomatic.id
        try registry.setComposition(pages, for: plain.rawValue)
        XCTAssertEqual(registry.composition(for: own).numericPageID, KeyboardPagePresets.numericKeypad.id)
        XCTAssertEqual(registry.usableMainLayoutID(for: own.shapeKey), copied)
    }
}
