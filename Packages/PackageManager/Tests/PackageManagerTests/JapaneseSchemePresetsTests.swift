import XCTest

@testable import PackageManager

/// Pins the Rime patch an install writes for the kagiroi scheme. The scheme owns the
/// engine's minus/equal paging bindings, and its half-width comma and period are
/// candidate lists rather than direct commits; both keep J1.6 (romaji long vowel,
/// ',' and '.') unreachable. The patch is data written beside the frozen package
/// bytes: the frontend never rewrites a package file.
final class JapaneseSchemePresetsTests: XCTestCase {
    // MARK: Fixtures

    /// The source package (rime-kagiroi @ 808a1954). Its key_binder/bindings is an
    /// in-place __patch of preset sections, so the only declarative way to remove
    /// paging is to empty the preset's __append; the frontend cannot flatten the
    /// section itself.
    private let rawSchema = #"""
        schema:
          schema_id: kagiroi
          name: カギロイ

        switches:
          - name: ascii_mode
            reset: 0
            states: [ あ, 英字 ]

        engine:
          processors:
            - key_binder
            - speller
            - punctuator

        punctuator:
          __patch:
            - kagiroi:/punct/3_dan

        editor:
          bindings:
            Return: commit_script_text

        key_binder:
          import_preset: default
          bindings:
            __patch:
              - kagiroi:/key_bindings/paging_with_minus_equal
              - kagiroi:/key_bindings/kagiroi_switches
        """#

    /// The preset file the source schema patches. paging_with_minus_equal is the
    /// only place the paging bindings come from; kagiroi_switches carries the option
    /// shortcuts that must survive the patch.
    private let rawPreset = #"""
        key_bindings:
          paging_with_minus_equal:
            __append:
              - { when: paging, accept: minus, send: Page_Up }
              - { when: has_menu, accept: equal, send: Page_Down }
          kagiroi_switches:
            __append:
              - { when: composing, accept: "Control+u", set_option: hiragana }
              - { when: composing, accept: "Control+i", set_option: katakana }
              - { when: composing, accept: "Control+o", set_option: hw_katakana }
              - { when: has_menu, accept: "Control+q", toggle: emoji }

        punct:
          3_dan:
            full_shape:
              ' ' : { commit: '　' }
              ',' : { commit: 、 }
              '.' : { commit: 。 }
            half_shape:
              ',' : [ 、, ・, ， ]
              '.' : [ 。, …, ．, . ]
              '?' : { commit: ？ }
        """#

    /// The package's own default.yaml. It patched the same preset names without the
    /// paging sections, so keeping import_preset: default is safe for this shape.
    private let rawDefault = #"""
        schema_list:
          - schema: kagiroi

        key_binder:
          bindings:
            __patch:
              - key_bindings:/emacs_editing
              - key_bindings:/move_by_word_with_tab
              - key_bindings:/numbered_mode_switch
        """#

    /// The prebuilt package (the build branch): rime_deployer already expanded
    /// key_binder/bindings into one flat list, so the patch has to replace the list.
    /// import_preset: default is still present, and librime's legacy preset plugin
    /// appends the frontend prelude default.yaml bindings during the link phase,
    /// after custom patches; that prelude links paging_with_minus_equal again.
    private let compiledSchema = #"""
        schema:
          schema_id: kagiroi
          name: "カギロイ"

        switches:
          - name: full_shape
            states: ["半角", "全角"]

        key_binder:
          bindings:
            - {accept: "Control+p", send: Up, when: composing}
            - {accept: "Control+n", send: Down, when: composing}
            - {accept: "Control+b", send: Left, when: composing}
            - {accept: "Control+f", send: Right, when: composing}
            - {accept: "Control+a", send: Home, when: composing}
            - {accept: "Control+e", send: End, when: composing}
            - {accept: "Control+d", send: Delete, when: composing}
            - {accept: "Control+k", send: "Shift+Delete", when: composing}
            - {accept: "Control+h", send: BackSpace, when: composing}
            - {accept: "Control+g", send: Escape, when: composing}
            - {accept: "Control+bracketleft", send: Escape, when: composing}
            - {accept: "Control+y", send: Page_Up, when: composing}
            - {accept: "Alt+v", send: Page_Up, when: composing}
            - {accept: "Control+v", send: Page_Down, when: composing}
            - {accept: ISO_Left_Tab, send: "Shift+Left", when: composing}
            - {accept: "Shift+Tab", send: "Shift+Left", when: composing}
            - {accept: Tab, send: "Shift+Right", when: composing}
            - {accept: "Control+Shift+1", select: .next, when: always}
            - {accept: "Control+Shift+2", toggle: ascii_mode, when: always}
            - {accept: "Control+Shift+3", toggle: full_shape, when: always}
            - {accept: "Control+Shift+4", toggle: simplification, when: always}
            - {accept: "Control+Shift+5", toggle: extended_charset, when: always}
            - {accept: "Control+Shift+exclam", select: .next, when: always}
            - {accept: "Control+Shift+at", toggle: ascii_mode, when: always}
            - {accept: "Control+Shift+numbersign", toggle: full_shape, when: always}
            - {accept: "Control+Shift+dollar", toggle: simplification, when: always}
            - {accept: "Control+Shift+percent", toggle: extended_charset, when: always}
            - {accept: minus, send: Page_Up, when: paging}
            - {accept: equal, send: Page_Down, when: has_menu}
            - {accept: "Control+u", set_option: hiragana, when: composing}
            - {accept: "Control+i", set_option: katakana, when: composing}
            - {accept: "Control+o", set_option: hw_katakana, when: composing}
            - {accept: "Control+q", toggle: emoji, when: has_menu}
          import_preset: default

        punctuator:
          full_shape:
            " ": {commit: "　"}
            ",": {commit: "、"}
            .: {commit: "。"}
            "?": {commit: "？"}
            "[": ["「", "【", "〔", "［"]
          half_shape:
            ",": ["、", "・", "，"]
            .: ["。", "…", "．", .]
            "?": {commit: "？"}
            "[": ["「", "【", "〔", "［"]
        """#

    /// The prebuilt package ships the preset file too; the patch generator has to
    /// recognize the compiled shape from the schema, not from the preset's absence.
    private var rawPackageFiles: [String: Data] {
        [
            "kagiroi.schema.yaml": Data(rawSchema.utf8),
            "kagiroi.yaml": Data(rawPreset.utf8),
            "default.yaml": Data(rawDefault.utf8),
        ]
    }

    private var compiledPackageFiles: [String: Data] {
        [
            "kagiroi.schema.yaml": Data(compiledSchema.utf8),
            "kagiroi.yaml": Data(rawPreset.utf8),
        ]
    }

    private var unknownPackageFiles: [String: Data] {
        [
            "sample.schema.yaml": Data(
                """
                schema:
                  schema_id: sample
                key_binder:
                  import_preset: default
                """.utf8)
        ]
    }

    // MARK: Raw package

    func testRawPackageEmptiesThePagingPresetAndCommitsHalfShapePunctuation() throws {
        let files = try supplemented(rawPackageFiles)
        // Package bytes are frozen; the patch file is the only thing an install adds.
        for (path, data) in rawPackageFiles {
            XCTAssertEqual(files[path], data, "the install rewrote \(path)")
        }

        let patch = try patchEntries(files)
        XCTAssertEqual(
            Set(patch.map { $0.key }),
            Set([
                "key_bindings/paging_with_minus_equal/__append",
                "punctuator/half_shape/,",
                "punctuator/half_shape/.",
            ]))
        XCTAssertTrue(
            items(try patchValue(files, "key_bindings/paging_with_minus_equal/__append")).isEmpty,
            "the paging preset must be emptied, not rewritten")
        try assertHalfShapeCommits(files)
        try assertNoPagingBindings(files)
    }

    // MARK: Build branch

    /// The build branch ships the source schema and preset but no default.yaml, so
    /// import_preset reaches the frontend prelude's, which links the paging pair again
    /// under has_menu. Emptying kagiroi's own preset left minus on Page_Up there.
    func testBuildBranchWithoutItsOwnDefaultReplacesTheSectionWithTheExpandedLinks() throws {
        let files = try supplemented([
            "kagiroi.schema.yaml": Data(rawSchema.utf8),
            "kagiroi.yaml": Data(rawPreset.utf8),
        ])
        let patch = try patchEntries(files)
        XCTAssertEqual(
            Set(patch.map { $0.key }),
            Set(["key_binder", "punctuator/half_shape/,", "punctuator/half_shape/."]))
        let section = try XCTUnwrap(try patchValue(files, "key_binder"))
        XCTAssertEqual(entries(section).map { $0.key }, ["bindings"])
        let accepts = items(value(section, "bindings")).compactMap { bindingAccept($0) }
        XCTAssertFalse(accepts.contains("minus"))
        XCTAssertFalse(accepts.contains("equal"))
        // The prelude's editing bindings come first, kagiroi's option shortcuts after.
        let editing = try XCTUnwrap(accepts.firstIndex(of: "Control+p"), "emacs editing must survive")
        let options = try XCTUnwrap(accepts.firstIndex(of: "Control+u"), "kagiroi switches must survive")
        XCTAssertLessThan(editing, options)
        try assertHalfShapeCommits(files)
        try assertNoPagingBindings(files)
    }

    // MARK: Prebuilt package

    func testCompiledPackageReplacesTheWholeKeyBinderSection() throws {
        let files = try supplemented(compiledPackageFiles)
        let schema = try parse(Data(compiledSchema.utf8))
        let patch = try patchEntries(files)

        // Only the two punctuation keys and the key_binder section may be patched.
        XCTAssertEqual(
            Set(patch.map { $0.key }),
            Set(["key_binder", "punctuator/half_shape/,", "punctuator/half_shape/."]))

        // The prelude default.yaml re-adds paging_with_minus_equal during librime's
        // link phase, so the compiled shape must drop key_binder/import_preset. A
        // null entry disappears while the patch literal loads (a no-op), so the
        // whole section is replaced: the retained bindings go in, the import is
        // simply absent.
        guard let section = try patchValue(files, "key_binder") else {
            return XCTFail("the compiled shape must replace the key_binder section")
        }
        let keyBinder = entries(section)
        XCTAssertEqual(keyBinder.map { $0.key }, ["bindings"])
        let actual = items(keyBinder.first(where: { $0.key == "bindings" })?.value)

        let fixtureBindings = items(value(schema, "key_binder").flatMap { value($0, "bindings") })
        let expected = fixtureBindings.filter { !isPagingBinding($0) }
        XCTAssertEqual(expected.count, fixtureBindings.count - 2)
        XCTAssertEqual(actual.count, expected.count, "every binding but the paging pair must be kept")
        for (expectedBinding, actualBinding) in zip(expected, actual) {
            XCTAssertTrue(
                same(expectedBinding, actualBinding),
                "binding \(bindingAccept(expectedBinding) ?? "?") was dropped or changed")
        }

        let accepts = actual.compactMap { bindingAccept($0) }
        XCTAssertFalse(accepts.contains("minus"))
        XCTAssertFalse(accepts.contains("equal"))
        // The option shortcuts and the cursor/editing bindings are what makes the
        // replacement list risky to regenerate: all of them must survive verbatim.
        for accept in ["Control+u", "Control+i", "Control+o", "Control+q"] {
            XCTAssertTrue(accepts.contains(accept), "\(accept) must survive the patch")
        }
        XCTAssertTrue(accepts.contains("Control+y"))
        XCTAssertTrue(accepts.contains("Control+v"))

        try assertHalfShapeCommits(files)
        try assertNoPagingBindings(files)
    }

    // MARK: Idempotency and coexistence

    func testSupplementIsIdempotentForBothPackageShapes() throws {
        for package in [rawPackageFiles, compiledPackageFiles] {
            let once = try supplemented(package)
            let twice = try supplemented(once)
            XCTAssertEqual(twice, once)
        }
    }

    func testAnExistingCustomPatchKeepsItsOtherKeys() throws {
        // A scheme author (or a re-imported source) may already ship a custom patch;
        // the install adds its own entries instead of replacing the file.
        let author = Data(
            """
            patch:
              "menu/page_size": 7
              "switcher/hotkeys":
                - F4
              "style/color_scheme": kagiroi
            """.utf8)
        for installed in [rawPackageFiles, compiledPackageFiles] {
            var package = installed
            package["kagiroi.custom.yaml"] = author

            let files = try supplemented(package)

            XCTAssertEqual(try committedText(files, "punctuator/half_shape/,"), "、")
            XCTAssertEqual(try committedText(files, "punctuator/half_shape/."), "。")
            XCTAssertTrue(items(try patchValue(files, "switcher/hotkeys")).compactMap { scalar($0) } == ["F4"])
            XCTAssertEqual(scalar(try patchValue(files, "menu/page_size")), "7")
            XCTAssertEqual(scalar(try patchValue(files, "style/color_scheme")), "kagiroi")
            try assertNoPagingBindings(files)
            XCTAssertEqual(try supplemented(files), files)
        }
    }

    func testUnknownSchemeGetsNoPresetPatch() throws {
        let files = try supplemented(unknownPackageFiles)

        XCTAssertNil(files["kagiroi.custom.yaml"])
        XCTAssertFalse(files.keys.contains { $0.hasSuffix(".custom.yaml") })
        XCTAssertEqual(try supplemented(files), files)
    }

    // MARK: Helpers

    private typealias YAMLNode = BoundedYAML.TextNode

    private func supplemented(_ files: [String: Data]) throws -> [String: Data] {
        var files = files
        try SharedRimePresets.supplement(&files)
        return files
    }

    private func parse(_ data: Data) throws -> YAMLNode {
        try XCTUnwrap(BoundedYAML.loadAsText(yaml: String(decoding: data, as: UTF8.self)))
    }

    private func entries(_ node: YAMLNode) -> [(key: String, value: YAMLNode)] {
        guard case .map(let entries) = node else { return [] }
        return entries
    }

    private func value(_ node: YAMLNode, _ key: String) -> YAMLNode? {
        entries(node).first { $0.key == key }?.value
    }

    private func scalar(_ node: YAMLNode?) -> String? {
        guard case .scalar(let text)? = node else { return nil }
        return text
    }

    private func items(_ node: YAMLNode?) -> [YAMLNode] {
        guard case .list(let items)? = node else { return [] }
        return items
    }

    private func patchEntries(_ files: [String: Data]) throws -> [(key: String, value: YAMLNode)] {
        let data = try XCTUnwrap(files["kagiroi.custom.yaml"], "the install did not write a kagiroi patch")
        let root = try parse(data)
        return entries(try XCTUnwrap(value(root, "patch"), "the patch file has no patch: node"))
    }

    private func patchValue(_ files: [String: Data], _ key: String) throws -> YAMLNode? {
        try patchEntries(files).first { $0.key == key }?.value
    }

    private func committedText(_ files: [String: Data], _ key: String) throws -> String? {
        guard let entry = try patchValue(files, key) else { return nil }
        return scalar(value(entry, "commit"))
    }

    /// Half-width comma and period must commit directly; the package's full-width
    /// punctuation and every other symbol stay untouched.
    private func assertHalfShapeCommits(
        _ files: [String: Data], comma: String = "、", period: String = "。",
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(try committedText(files, "punctuator/half_shape/,"), comma, file: file, line: line)
        XCTAssertEqual(try committedText(files, "punctuator/half_shape/."), period, file: file, line: line)
        for entry in try patchEntries(files) where entry.key.hasPrefix("punctuator/") {
            XCTAssertFalse(entry.key.contains("full_shape"), "full-width punctuation must stay as shipped")
            XCTAssertTrue(
                ["punctuator/half_shape/,", "punctuator/half_shape/."].contains(entry.key),
                "only half-width comma and period may be patched, not \(entry.key)",
                file: file, line: line)
        }
    }

    private func bindingAccept(_ binding: YAMLNode) -> String? {
        scalar(value(binding, "accept"))
    }

    private func isPagingBinding(_ binding: YAMLNode) -> Bool {
        guard let accept = bindingAccept(binding)?.lowercased(), accept == "minus" || accept == "equal" else {
            return false
        }
        guard let send = scalar(value(binding, "send")) else { return false }
        return send == "Page_Up" || send == "Page_Down"
    }

    /// Collects every paging binding the patch would add. The paging entries must be
    /// removed, not copied into the replacement list.
    private func pagingBindings(_ node: YAMLNode) -> [YAMLNode] {
        switch node {
        case .scalar:
            return []
        case .list(let items):
            return items.flatMap { pagingBindings($0) }
        case .map(let entries):
            var found = isPagingBinding(node) ? [node] : []
            for entry in entries {
                found += pagingBindings(entry.value)
            }
            return found
        }
    }

    private func assertNoPagingBindings(
        _ files: [String: Data], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let data = try XCTUnwrap(files["kagiroi.custom.yaml"], "the install did not write a kagiroi patch")
        XCTAssertTrue(
            pagingBindings(try parse(data)).isEmpty, "the patch still carries minus/equal paging",
            file: file, line: line)
    }

    /// Structural equality that ignores mapping key order, the way both Yams and
    /// yaml-cpp load an unordered mapping.
    private func same(_ lhs: YAMLNode, _ rhs: YAMLNode) -> Bool {
        switch (lhs, rhs) {
        case (.scalar(let left), .scalar(let right)):
            return left == right
        case (.list(let left), .list(let right)):
            return left.count == right.count && zip(left, right).allSatisfy { pair in same(pair.0, pair.1) }
        case (.map(let left), .map(let right)):
            guard left.count == right.count else { return false }
            return left.allSatisfy { entry in
                right.first { $0.key == entry.key }.map { same(entry.value, $0.value) } ?? false
            }
        default:
            return false
        }
    }
}
