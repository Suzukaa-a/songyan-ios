import XCTest

@testable import PackageManager

/// What a user's configuration may name: nothing that leaves the data folders.
final class UserConfigSafetyTests: XCTestCase {
    private func load(_ yaml: String) throws -> BoundedYAML.TextNode? { try BoundedYAML.loadAsText(yaml: yaml) }
    private func unsafe(_ yaml: String) throws -> String? { UserConfigSafety.unsafeReference(try load(yaml)) }

    func testPathsFollowTheImportRules() {
        for path in ["lua/date.lua", "a b/c.yaml", "opencc/emoji.json"] {
            XCTAssertTrue(UserConfigSafety.safePath(path), path)
        }
        for path in [
            "", "/etc/passwd", "../x", "a/../x", "a//b", "a\\b", "c:/x", "a\u{0}b", "a\nb",
            String(repeating: "x/", count: 40) + "y", String(repeating: "n", count: 300),
        ] {
            XCTAssertFalse(UserConfigSafety.safePath(path), path)
        }
    }

    func testOrdinaryPatchesAndSchemasHaveNoUnsafeReference() throws {
        XCTAssertNil(
            try unsafe(
                """
                patch:
                  menu/page_size: 7
                  translator/dictionary: rime_ice
                  grammar/language: wanxiang-lts-zh-hans
                  "speller/algebra/+": [ "derive/^([a-z]+)$/$1x/" ]
                  __include: default:/menu
                """))
        XCTAssertNil(try unsafe("import_tables:\n  - cn_dicts/base\n  - cn_dicts/ext\nuse_preset_vocabulary: true\n"))
        XCTAssertNil(try unsafe("schema:\n  dependencies:\n    - luna_pinyin\ntranslator:\n  db: custom\n"))
    }

    func testNamesThatLeaveTheDataFoldersAreFound() throws {
        for yaml in [
            "translator:\n  dictionary: ../../../etc/passwd\n",
            "patch:\n  translator/dictionary: /data/secret\n",
            "__include: ../../x:/menu\n",
            "__patch:\n  - ../x:/patch\n",
            "__patch: [\"/abs:/x\"]\n",
            "import_preset: \"..\\\\x\"\n",
            "import_tables:\n  - ../x\n",
            "speller:\n  prism: ../prism\n",
            "translator:\n  user_dict: /var/mobile/x\n",
            "translator:\n  vocabulary: ../../essay\n",
            "patch:\n  opencc_config: ../x.json\n",
            "predictor:\n  db: ../../db\n",
            "grammar:\n  language: ../../model\n",
            "patch:\n  grammar/language: c:/x\n",
            "key: 1\nnested:\n  list:\n    - translator:\n        dictionary: a/../../b\n",
        ] {
            XCTAssertNotNil(try unsafe(yaml), yaml)
        }
        // A reference to its own file has no file part, and a plain name is fine.
        XCTAssertNil(try unsafe("__include: menu\n"))
    }

    func testDeepFlowNestingIsRefusedAndQuotesAndCommentsAreNotCounted() {
        XCTAssertTrue(UserConfigSafety.tooDeep("a: " + String(repeating: "[", count: 100) + "\n"))
        XCTAssertTrue(
            UserConfigSafety.tooDeep(
                "a: " + String(repeating: "{b: ", count: 100) + "1" + String(repeating: "}", count: 100) + "\n"))
        XCTAssertFalse(UserConfigSafety.tooDeep("a: [[1, 2], {b: [3]}]\n"))
        XCTAssertFalse(UserConfigSafety.tooDeep("a: \"" + String(repeating: "[", count: 200) + "\"\n"))
        XCTAssertFalse(UserConfigSafety.tooDeep("a: 1 # " + String(repeating: "[", count: 200) + "\n"))
    }

    func testLuaComponentEntriesAreFoundAnywhere() throws {
        let root = try load(
            """
            engine:
              filters:
                - lua_filter@*my.filter
                - uniquifier
              processors:
                - lua_processor@date_proc
            patch:
              "engine/translators/+": [lua_translator@*t]
            note: not a lua_filter@x entry in prose
            """)
        XCTAssertEqual(
            UserConfigSafety.luaComponents(root),
            ["lua_filter@*my.filter", "lua_processor@date_proc", "lua_translator@*t"])
    }

    func testPatchOperatorsAndListSelectorsDoNotHideAFileKey() throws {
        for yaml in [
            "patch:\n  translator/user_dict/=: /var/mobile/leak\n",
            "patch:\n  translator/user_dict/+: ../../leak\n",
            "patch:\n  translator/dictionary/+: /abs\n",
            "patch:\n  schema_list/@0/schema: ../../x\n",
            "patch:\n  schema_list/@next/schema: /abs\n",
            "patch:\n  schema_list/@before 0/schema: ../x\n",
            "patch:\n  schema_list/@last/schema/=: ../x\n",
            "patch:\n  schema/dependencies/@after 1: ../x\n",
            "patch:\n  translator:\n    user_dict:\n      __append: ../x\n",
            "patch:\n  translator:\n    db:\n      __merge: /abs\n",
            "patch:\n  predictor/db/=: ../../x\n",
        ] {
            XCTAssertNotNil(try unsafe(yaml), yaml)
        }
        // Appending a list of plain names is an ordinary patch.
        XCTAssertNil(try unsafe("patch:\n  schema_list/+:\n    - schema: extra\n  translator/packs/+: [a, b]\n"))
        XCTAssertNil(try unsafe("patch:\n  translator/user_dict/=: my_words\n"))
    }

    func testSchemaListEntriesDependenciesAndPacksAreChecked() throws {
        XCTAssertNotNil(try unsafe("schema_list:\n  - schema: ../../edit/live\n"))
        XCTAssertNotNil(try unsafe("schema:\n  dependencies:\n    - ../x\n"))
        XCTAssertNotNil(try unsafe("translator:\n  packs:\n    - /abs/pack\n"))
        XCTAssertNil(
            try unsafe(
                "schema_list:\n  - schema: rime_ice\nschema:\n  schema_id: rime_ice\n  dependencies: [luna_pinyin]\n"))
    }

    func testExplicitScalarTagsCannotHideAValueFromTheChecks() throws {
        // Every scalar is its text, whatever tag it carries, as yaml-cpp reads it.
        XCTAssertNotNil(try unsafe("translator:\n  dictionary: !!null ../../x\n  user_dict: !!bool /abs\n"))
        XCTAssertNotNil(try unsafe("translator:\n  dictionary: !!int ../../x\n"))
        XCTAssertEqual(
            UserConfigSafety.luaComponents(try load("engine:\n  filters:\n    - !!null lua_filter@x\n")),
            ["lua_filter@x"])
    }

    func testABareLuaComponentNameCountsToo() throws {
        let root = try load("engine:\n  filters:\n    - lua_filter\n    - lua_filters_not\n    - lua_translator@t\n")
        XCTAssertEqual(UserConfigSafety.luaComponents(root), ["lua_filter", "lua_translator@t"])
    }

    func testAnEscapedSpellingOfAComponentIsStillOne() throws {
        let root = try load("patch:\n  engine/filters/+: [\"\\x6Cua_filter@*x\"]\n")
        XCTAssertEqual(UserConfigSafety.luaComponents(root), ["lua_filter@*x"])
    }

    func testARepeatedKeyIsKeptSoTheHiddenPairIsChecked() throws {
        let doubled =
            "__patch:\n  translator/user_dict: /abs/leak\n  engine/filters/@next: lua_filter@*x\n__patch: {}\n"
        guard case .map(let entries)? = try load(doubled) else { return XCTFail("a mapping") }
        XCTAssertEqual(entries.map(\.key).sorted(), ["__patch", "__patch/="])
        XCTAssertNotNil(UserConfigSafety.unsafeReference(try load(doubled)))
        XCTAssertEqual(
            UserConfigSafety.luaComponents(try load("a:\n  f: lua_filter@*x\na: {}\n")), ["lua_filter@*x"])
        XCTAssertNotNil(try unsafe("__include: /abs/edit/evil:/\n__include: ok\n"))
        // Schemas that repeat a key on purpose are still readable.
        XCTAssertNil(try unsafe("menu:\n  page_size: 5\nmenu:\n  page_size: 7\n"))
    }

    func testStringsAreNeverBuiltFromAppendedPieces() throws {
        for yaml in [
            "patch:\n  engine/filters/@next: lu\n  engine/filters/@last/+: \"a_filter@*x\"\n",
            "patch:\n  menu/foo/+: text\n",
            "patch:\n  a:\n    __append: text\n",
            "patch:\n  a:\n    __merge: text\n",
        ] {
            XCTAssertNotNil(try unsafe(yaml), yaml)
        }
        XCTAssertNil(try unsafe("patch:\n  engine/filters/+:\n    - uniquifier\n  a:\n    __append: [x]\n"))
    }

    func testAliasBombsAreRefusedNotExpanded() {
        var lines = ["l0: &l0 [x, x, x, x, x, x, x, x, x, x]"]
        for level in 1...9 {
            lines.append(
                "l\(level): &l\(level) [" + Array(repeating: "*l\(level - 1)", count: 10).joined(separator: ", ") + "]")
        }
        XCTAssertThrowsError(try BoundedYAML.loadAsText(yaml: lines.joined(separator: "\n") + "\n")) {
            XCTAssertTrue($0 is BoundedYAML.LimitExceeded)
        }
    }
}
