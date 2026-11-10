import Foundation
import XCTest

@testable import LayoutKit

final class LayoutKitTests: XCTestCase {
    func testCopyAndReplacePreserveOrderAndFailureSnapshot() throws {
        var registry = try LayoutRegistry()
        let original = try XCTUnwrap(registry.layout(id: "phone9"))
        let path = LayoutKeyPath.auxiliary(0, key: 0)
        let key = try XCTUnwrap(original.key(at: path))
        let edited = original.replacingKey(
            at: path,
            with: LayoutKey(
                label: key.label, secondaryLabel: "问号", width: 1.5, action: key.action,
                longPress: [.init(label: "？", action: .init(.literal, value: "？"))]))
        try registry.replace(edited)
        XCTAssertEqual(registry.layouts.map(\.id), BuiltinLayouts.all.map(\.id))
        XCTAssertEqual(try LayoutDefinition.decode(edited.encoded()), edited)
        let copy = try registry.copy(edited)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.rows, edited.rows)
        XCTAssertEqual(copy.auxiliaryAreas, edited.auxiliaryAreas)
        XCTAssertEqual(registry.layouts.map(\.id), BuiltinLayouts.all.map(\.id) + [copy.id])
        let snapshot = registry
        let invalid = edited.replacingKey(at: path, with: .init(label: "坏", action: .init(.code, value: "abc")))
        XCTAssertThrowsError(try registry.replace(invalid))
        XCTAssertThrowsError(try registry.copy(invalid))
        XCTAssertEqual(registry, snapshot)
        XCTAssertThrowsError(try registry.replace(edited.copy()))
        XCTAssertEqual(registry, snapshot)
        try registry.install(copy.renamed("导入替换").encoded(), replaceExisting: true)
        XCTAssertEqual(registry.layout(id: copy.id)?.name, "导入替换", "a same-ID import replaces in place")
        XCTAssertEqual(registry.layouts.last?.id, copy.id)
    }

    func testImportOrderAndBundledPresetsStay() throws {
        var registry = try LayoutRegistry()
        let custom = LayoutDefinition(
            id: "DIY / a", name: "DIY", input: .init(schemaID: "installed_schema"),
            rows: BuiltinLayouts.qwerty26.rows)
        try registry.install(custom.encoded())
        XCTAssertEqual(registry.layouts.last?.id, custom.id)
        XCTAssertThrowsError(try registry.install(custom.encoded()))
        try registry.remove(id: custom.id)
        XCTAssertNil(registry.layout(id: custom.id))
        XCTAssertThrowsError(try registry.remove(id: "qwerty26"), "bundled presets are the default main layouts")
        XCTAssertEqual(registry.usableLayouts { $0.id == "qwerty26" }.map(\.id), ["qwerty26"])
    }

    func testDefaultMainLayoutPrefersTheBoundLayoutThenThePreset() throws {
        func bound(_ id: String, to schemaID: String?) -> LayoutDefinition {
            LayoutDefinition(
                id: id, name: id, input: .init(schemaID: schemaID, builtinLayout: .qwerty26),
                rows: BuiltinLayouts.qwerty26.rows)
        }
        var registry = try LayoutRegistry(layouts: [BuiltinLayouts.merged14])
        let key = KeyboardCompositionKey(inputMethodID: "luna_pinyin", layout: .qwerty26)
        XCTAssertEqual(registry.defaultMainLayoutID(for: key), "qwerty26", "a preset missing from the catalog")
        XCTAssertEqual(registry.resolvedLayout(id: "qwerty26")?.id, "qwerty26")
        try registry.install(bound("mine", to: nil).encoded())
        XCTAssertEqual(registry.defaultMainLayoutID(for: key), "qwerty26", "an unbound copy needs a pairing")
        try registry.install(bound("luna-b", to: "luna_pinyin").encoded())
        try registry.install(bound("luna-a", to: "luna_pinyin").encoded())
        XCTAssertEqual(registry.defaultMainLayoutID(for: key), "luna-a", "the smallest ID, not catalog order")
        XCTAssertEqual(registry.defaultMainLayoutID(for: .init(inputMethodID: "other", layout: .qwerty26)), "qwerty26")
        XCTAssertEqual(
            Set(registry.mainLayoutCandidates(for: key).map(\.id)),
            ["qwerty26", "zhuyin41", "cangjie26", "romaji26", "kana12", "mine", "luna-a", "luna-b"])
    }

    func testRejectInvalidActionsIncludingAlternates() throws {
        let invalid =
            #"{"id":"x","name":"x","input":{"builtinLayout":"qwerty26"},"rows":[{"keys":[{"label":"a","action":{"type":"code","value":"a"},"longPress":[{"label":"run","action":{"type":"shell","value":"echo hi"}}]}]}]}"#
        XCTAssertThrowsError(try LayoutDefinition.decode(Data(invalid.utf8)))
        XCTAssertThrowsError(try LayoutAction(.code, value: "abc").validate())
        XCTAssertThrowsError(try LayoutAction(.modeSwitch, value: "runScript").validate())
        let key = try XCTUnwrap(BuiltinLayouts.qwerty26.rows.flatMap(\.keys).first { $0.label == "a" })
        XCTAssertEqual(key.longPress?.map(\.action.value), ["，", ","])
        XCTAssertEqual(key.action, .init(.code, value: "a"))
    }

    /// The merged 14-key must have executable long-press alternates (not just secondaryLabel text):
    /// the main key sends the cluster representative letter, long-press offers the rest; l/m offer punctuation.
    func testMerged14EveryKeyHasRealLongPressAlternate() throws {
        let keys = BuiltinLayouts.merged14.rows.dropLast().flatMap(\.keys)
        XCTAssertEqual(keys.count, 14)
        for key in keys {
            let options = try XCTUnwrap(key.longPress, "\(key.label) is missing long-press alternates")
            XCTAssertFalse(options.isEmpty, "\(key.label) has empty long-press alternates")
            for option in options {
                // Real executable actions (literal/code), not display-only labels.
                XCTAssertTrue(
                    [.literal, .code].contains(option.action.type),
                    "\(key.label) 副键动作不可执行：\(option.action.type)")
            }
        }
        // Merged pair: long-pressing the second letter types it directly; the cluster head stays the main key's code.
        func alt(_ label: String) throws -> [String] {
            let key = try XCTUnwrap(keys.first { $0.label == label })
            return (key.longPress ?? []).map { $0.action.value ?? "" }
        }
        XCTAssertEqual(try alt("ER"), ["r"])
        XCTAssertEqual(try alt("UI"), ["i"])
        XCTAssertEqual(try alt("ZX"), ["x"])
        XCTAssertEqual(try alt("QW"), ["w", "1", "!"])
        let l = try XCTUnwrap(keys.first { $0.label == "L" })
        let m = try XCTUnwrap(keys.first { $0.label == "M" })
        XCTAssertEqual(l.longPress?.map(\.action.value), ["，"])
        XCTAssertEqual(m.longPress?.map(\.action.value), ["。"])
        XCTAssertFalse(keys.contains { $0.action.type == .literal && $0.action.value == nil })
    }

    func testAllExamplesAndBuiltinsValidate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for builtin in BuiltinLayouts.all {
            XCTAssertEqual(try LayoutDefinition.decode(builtin.encoded()), builtin)
            let file = root.appendingPathComponent("Resources/Layouts/\(builtin.id).json")
            let example = try LayoutDefinition.decode(Data(contentsOf: file))
            XCTAssertEqual(example.input, builtin.input)
            XCTAssertEqual(example.rows.flatMap(\.keys).map(\.action), builtin.rows.flatMap(\.keys).map(\.action))
            XCTAssertEqual(
                example.rows.flatMap(\.keys).map(\.width), builtin.rows.flatMap(\.keys).map(\.width), builtin.id)
            if builtin.input.builtinLayout == .qwerty26 {
                XCTAssertEqual(
                    example.rows.flatMap(\.keys).map(\.longPress), builtin.rows.flatMap(\.keys).map(\.longPress))
            }
            // The letter and merged pads carry real long-press alternates (digits, partner letters,
            // punctuation). The zhuyin and cangjie boards type one symbol per cap and declare none,
            // so the requirement stays with the shapes that have menus; every layout still keeps the
            // example's alternates equal to the bundled definition above.
            if ["qwerty26", "merged14", "merged18", "phone9"].contains(builtin.id) {
                XCTAssertTrue(
                    example.rows.flatMap(\.keys).contains { !($0.longPress ?? []).isEmpty },
                    "\(builtin.id) 的示例必须带真实长按项")
            }
        }
        let areas = try XCTUnwrap(BuiltinLayouts.phone9.auxiliaryAreas)
        XCTAssertFalse(areas.contains { $0.role == .punctuation })
        XCTAssertTrue(areas.contains { $0.requiresEngineDisambiguation && $0.keys.isEmpty })
    }

    /// The author-facing T9 example (`Resources/Layouts/phone9.json`) must match the builtin declaration field for field,
    /// in particular `secondaryLabel` and `longPress`.
    ///
    /// The generic loop above only compares `input` and `action`, and `longPress` only for qwerty26, so
    /// the T9 first key's `secondaryLabel`/`longPress` were never checked. The example is the copy source for
    /// authors, so it must stay in sync.
    ///
    /// This asserts whole-definition equality (including `note`), which is stricter than per-field checks.
    func testT9ExampleMatchesBuiltinDeclarationIncludingFirstKeyDigit() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Resources/Layouts/phone9.json")
        let example = try LayoutDefinition.decode(Data(contentsOf: file))
        XCTAssertEqual(
            example, BuiltinLayouts.phone9,
            "the example must match the builtin phone9 (note, first-key badge and long-press)")
        // Pin the two fields explicitly again so they stay checked even if the equality assertion above is loosened.
        let first = example.rows[0].keys[0]
        XCTAssertEqual(first.secondaryLabel, "1", "the example's first key must have a digit 1 badge")
        XCTAssertEqual(first.longPress?.map(\.label), ["1"], "the example's first-key long-press must be 1")
        XCTAssertEqual(first.longPress?.map(\.action.value), ["1"], "long-press must type 1 directly")
        XCTAssertEqual(first.longPress?.map(\.action.type), [.literal])
        // Same style baseline as 2-9: badge = long-press = the key's digit (the first key 1 lines up with them).
        for key in example.rows.flatMap(\.keys) where key.action.type == .code {
            let digit = try XCTUnwrap(key.action.value)
            XCTAssertEqual(key.secondaryLabel, digit, "\(key.label) badge should equal its digit")
            XCTAssertEqual(
                key.longPress?.map(\.action.value), [digit],
                "\(key.label) 长按应直接输入其数字")
        }
    }

    func testStoreRoundTripAndFailedImportPreservesSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LayoutKit-\(UUID().uuidString)")
        // Only this test's newly-created directory is removed.
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(directoryURL: directory)
        var registry = try store.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try store.save(registry)
        XCTAssertEqual(try store.load(), registry)
        let replacement = BuiltinLayouts.phone9.renamed("我的九键")
        try registry.replace(replacement)
        let copy = try registry.copy(replacement)
        try store.save(registry)
        XCTAssertEqual(try store.load(), registry)
        let beforeFailedEdit = try Data(contentsOf: store.catalogURL)
        XCTAssertThrowsError(try registry.replace(replacement.renamed("")))
        XCTAssertThrowsError(try registry.copy(replacement.renamed("")))
        XCTAssertEqual(try Data(contentsOf: store.catalogURL), beforeFailedEdit)
        XCTAssertEqual(try store.load().layout(id: copy.id), copy)
        let source = directory.appendingPathComponent("import.json")
        let custom = LayoutDefinition(
            id: "custom", name: "Custom", input: .init(builtinLayout: .qwerty26),
            rows: BuiltinLayouts.qwerty26.rows)
        try custom.encoded().write(to: source)
        let imported = try store.importLayout(from: source)
        XCTAssertEqual(imported.layouts.last?.id, "custom")
        try Data("{}".utf8).write(to: source)
        XCTAssertThrowsError(try store.importLayout(from: source))
        XCTAssertEqual(try store.load(), imported)
    }
}

/// The injected availability rules (the host passes the shared input-language policy): they filter
/// candidates, choose a family-preferred default, and let a saved pairing fall back at runtime without
/// deleting the user's layout or rewriting the stored pairing.
final class LayoutAvailabilityTests: XCTestCase {
    private func definition(
        _ id: String, schemaID: String? = nil, builtin: LayoutInput.Builtin? = .qwerty26
    ) -> LayoutDefinition {
        LayoutDefinition(
            id: id, name: id, input: .init(schemaID: schemaID, builtinLayout: builtin),
            rows: BuiltinLayouts.qwerty26.rows)
    }

    private func registryWith(_ extra: [LayoutDefinition]) throws -> LayoutRegistry {
        var registry = try LayoutRegistry()
        for layout in extra { try registry.install(layout.encoded()) }
        return registry
    }

    private func availability(
        allowing allowed: Set<String>, preferred: String? = nil
    ) -> LayoutAvailability {
        LayoutAvailability(
            allows: { definition, _ in allowed.contains(definition.id) },
            preferredMainLayoutID: { _ in preferred })
    }

    func testUnrestrictedAvailabilityKeepsEveryCandidate() throws {
        // zhuyin41, cangjie26, romaji26 and kana12 ship as bundled layouts: a catalog without a
        // stored copy still offers them, so the candidate list is every 26-key-shape layout it can
        // resolve.
        let registry = try registryWith([definition("mine")])
        let key = KeyboardCompositionKey(inputMethodID: "bopomofo", layout: .qwerty26)
        XCTAssertEqual(
            Set(registry.mainLayoutCandidates(for: key).map(\.id)),
            ["qwerty26", "zhuyin41", "cangjie26", "romaji26", "kana12", "mine"])
        XCTAssertEqual(registry.defaultMainLayoutID(for: key), "qwerty26")
        XCTAssertEqual(registry.usableMainLayoutID(for: key), "qwerty26")
    }

    func testInjectedAvailabilityFiltersCandidatesAndDefault() throws {
        let registry = try registryWith([definition("bound-board", schemaID: "bopomofo"), definition("mine")])
        let key = KeyboardCompositionKey(inputMethodID: "bopomofo", layout: .qwerty26)
        // The definition is an explicit main-layout binding for this input method: it wins the default.
        XCTAssertEqual(registry.defaultMainLayoutID(for: key), "bound-board")
        // A family that does not own the bound layout may not use it, so both the candidate list
        // and the default fall back to the existing shape preset.
        let otherFamily = availability(allowing: ["qwerty26", "mine"])
        XCTAssertEqual(
            Set(registry.mainLayoutCandidates(for: key, availability: otherFamily).map(\.id)), ["qwerty26", "mine"])
        XCTAssertEqual(registry.defaultMainLayoutID(for: key, availability: otherFamily), "qwerty26")
        // The owning family keeps it; the preference only applies to an unbound definition.
        let owningFamily = availability(allowing: ["qwerty26", "bound-board", "mine"], preferred: "bound-board")
        XCTAssertEqual(registry.defaultMainLayoutID(for: key, availability: owningFamily), "bound-board")
        let unbound = try registryWith([definition("bound-board"), definition("mine")])
        XCTAssertEqual(unbound.defaultMainLayoutID(for: key), "qwerty26")
        XCTAssertEqual(
            unbound.defaultMainLayoutID(for: key, availability: owningFamily), "bound-board",
            "the family-preferred layout is used when its definition has no explicit schema binding")
    }

    func testSavedPairingFallsBackAtRuntimeWithoutDeletingUserData() throws {
        var registry = try LayoutRegistry()
        let key = KeyboardCompositionKey(inputMethodID: "bopomofo", layout: .qwerty26)
        try registry.setComposition(KeyboardComposition(mainLayoutID: "zhuyin41"), for: key.rawValue)
        // A family that no longer owns the saved layout runs the shape preset instead.
        let otherFamily = availability(allowing: ["qwerty26"])
        XCTAssertEqual(registry.usableMainLayoutID(for: key, availability: otherFamily), "qwerty26")
        XCTAssertEqual(
            registry.composition(for: key).mainLayoutID, "zhuyin41",
            "a fallback never rewrites or deletes the saved pairing, layout or source data")
        XCTAssertEqual(
            registry.usableMainLayoutID(
                for: key, availability: availability(allowing: ["qwerty26", "zhuyin41"], preferred: "zhuyin41")),
            "zhuyin41")
    }

    func testExplicitSchemaBindingWinsOverFamilyPreference() throws {
        let key = KeyboardCompositionKey(inputMethodID: "bopomofo", layout: .qwerty26)
        let bound = try registryWith([definition("zz-explicit", schemaID: "bopomofo")])
        XCTAssertEqual(
            bound.defaultMainLayoutID(
                for: key,
                availability: availability(allowing: ["qwerty26", "zz-explicit", "zhuyin41"], preferred: "zhuyin41")),
            "zz-explicit",
            "an explicit schema binding is not overridden by the family preference")
        // A preferred ID bound to another input method never applies to this keyboard.
        let foreign = try registryWith([definition("zz-foreign", schemaID: "cangjie5")])
        XCTAssertEqual(
            foreign.defaultMainLayoutID(
                for: key, availability: availability(allowing: ["zz-foreign"], preferred: "zz-foreign")),
            "qwerty26")
    }

    /// The public default path the host and the keyboard consume: with nothing saved, a registered
    /// family-preferred physical definition must be what the keyboard resolves, never the shape
    /// preset that `composition(for:)` materialises for an unsaved pairing.
    func testFamilyPreferredLayoutIsUsedWhenNothingIsSaved() throws {
        let key = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26)
        // The Japanese board ships with the app, so the family preference resolves it unasked.
        let bundled = try registryWith([])
        let preferred = availability(allowing: ["qwerty26", "romaji26"], preferred: "romaji26")
        XCTAssertEqual(
            bundled.usableMainLayoutID(for: key, availability: preferred), "romaji26",
            "an unsaved keyboard still resolves the registered family layout")
        // A family-preferred layout this build does not ship falls back to the shape preset.
        let unshipped = availability(allowing: ["qwerty26", "unshipped26"], preferred: "unshipped26")
        XCTAssertEqual(
            try registryWith([]).usableMainLayoutID(for: key, availability: unshipped), "qwerty26")
    }

    /// A really saved, valid pairing still wins over the family preference.
    func testSavedValidPairingWinsOverFamilyPreference() throws {
        var registry = try registryWith([definition("mine")])
        let key = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26)
        try registry.setComposition(KeyboardComposition(mainLayoutID: "mine"), for: key.rawValue)
        let preferred = availability(allowing: ["qwerty26", "romaji26", "mine"], preferred: "romaji26")
        XCTAssertEqual(registry.usableMainLayoutID(for: key, availability: preferred), "mine")
    }

    /// A keyboard that names a board types on it, whatever the shared pairing says; a board that is
    /// disallowed, unknown or for another shape falls back to the pairing's path untouched.
    func testBoardKeyboardUsesItsBoardAndFallsBackToThePairing() throws {
        var registry = try registryWith([definition("mine")])
        let key = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26)
        try registry.setComposition(KeyboardComposition(mainLayoutID: "mine"), for: key.rawValue)
        let japanese = availability(allowing: ["qwerty26", "romaji26", "kana12", "mine"], preferred: "romaji26")
        XCTAssertEqual(registry.usableMainLayoutID(for: key, board: "kana12", availability: japanese), "kana12")
        XCTAssertEqual(registry.usableMainLayoutID(for: key, board: "romaji26", availability: japanese), "romaji26")
        XCTAssertEqual(
            registry.usableMainLayoutID(for: key, board: nil, availability: japanese), "mine",
            "no board keeps the pairing's main layout")
        // The family does not allow the board.
        XCTAssertEqual(
            registry.usableMainLayoutID(
                for: key, board: "kana12", availability: availability(allowing: ["qwerty26", "mine"])),
            "mine")
        // The board does not resolve.
        XCTAssertEqual(registry.usableMainLayoutID(for: key, board: "no-such-board", availability: japanese), "mine")
        // The board is for another shape (kana12 is a 26-key transport board).
        let nine = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .phone9)
        XCTAssertEqual(
            registry.usableMainLayoutID(for: nine, board: "kana12", availability: japanese),
            registry.usableMainLayoutID(for: nine, availability: japanese))
        XCTAssertEqual(registry.composition(for: key).mainLayoutID, "mine", "nothing is rewritten")
    }

    /// A saved pairing whose definition is gone or may not be used falls back to the preferred
    /// registered definition, and the stored pairing is left untouched.
    func testUnusableSavedPairingFallsBackToFamilyPreferred() throws {
        var registry = try registryWith([])
        let key = KeyboardCompositionKey(inputMethodID: "kagiroi", layout: .qwerty26)
        try registry.setComposition(KeyboardComposition(mainLayoutID: "zhuyin41"), for: key.rawValue)
        // This family may not use the saved zhuyin definition: the preferred bundled romaji one is
        // the fallback, and the stored pairing is not rewritten.
        let preferred = availability(allowing: ["qwerty26", "romaji26"], preferred: "romaji26")
        XCTAssertEqual(registry.usableMainLayoutID(for: key, availability: preferred), "romaji26")
        XCTAssertEqual(registry.composition(for: key).mainLayoutID, "zhuyin41")
    }
}
