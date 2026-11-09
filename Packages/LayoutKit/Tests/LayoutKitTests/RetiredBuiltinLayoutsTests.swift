import XCTest

@testable import LayoutKit

final class RetiredBuiltinLayoutsTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// A saved catalog whose layout `id` is replaced by `layout`, everything else as the bundle.
    private func catalog(replacing id: String, with layout: Data) throws -> Data {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(LayoutRegistry())) as? [String: Any])
        var layouts = try XCTUnwrap(root["layouts"] as? [[String: Any]])
        let index = try XCTUnwrap(layouts.firstIndex { $0["id"] as? String == id })
        layouts[index] = try XCTUnwrap(JSONSerialization.jsonObject(with: layout) as? [String: Any])
        root["layouts"] = layouts
        return try JSONSerialization.data(withJSONObject: root)
    }

    func testAStoredOldBundledLayoutBecomesTheCurrentOneInPlace() throws {
        let old = try fixture("romaji26-before-long-vowel-move")
        XCTAssertNotEqual(try LayoutDefinition.decode(old), BuiltinLayouts.romaji26)
        let data = try catalog(replacing: "romaji26", with: old)
        let loaded = try JSONDecoder().decode(LayoutRegistry.self, from: data)
        XCTAssertEqual(loaded.layouts, BuiltinLayouts.all)
    }

    func testAUserEditOfABundledLayoutIsKept() throws {
        var edited = try XCTUnwrap(
            JSONSerialization.jsonObject(with: BuiltinLayouts.qwerty26.encoded()) as? [String: Any])
        var rows = try XCTUnwrap(edited["rows"] as? [[String: Any]])
        var keys = try XCTUnwrap(rows[0]["keys"] as? [[String: Any]])
        keys[0]["label"] = "Q!"
        rows[0]["keys"] = keys
        edited["rows"] = rows
        let data = try catalog(replacing: "qwerty26", with: JSONSerialization.data(withJSONObject: edited))
        let loaded = try JSONDecoder().decode(LayoutRegistry.self, from: data)
        XCTAssertEqual(loaded.layout(id: "qwerty26")?.rows[0].keys[0].label, "Q!")
        XCTAssertEqual(loaded.layouts.dropFirst(), BuiltinLayouts.all.dropFirst())
    }

    func testACatalogOfTheCurrentBundleIsUnchanged() throws {
        let registry = try LayoutRegistry()
        let loaded = try JSONDecoder().decode(LayoutRegistry.self, from: JSONEncoder().encode(registry))
        XCTAssertEqual(loaded, registry)
    }

    func testUnknownAndGarbledRetiredEntriesAreSkipped() throws {
        let good = try String(decoding: BuiltinLayouts.qwerty26.encoded(), as: UTF8.self)
        let data = Data("""
            {"qwerty26": [\(good), {"id": 5}, "text", null], "gone": [{"x": 1}]}
            """.utf8)
        let versions = RetiredBuiltinLayouts.decodeVersions(data)
        XCTAssertEqual(versions["qwerty26"], [BuiltinLayouts.qwerty26])
        XCTAssertEqual(versions["gone"], [])
        XCTAssertEqual(RetiredBuiltinLayouts.decodeVersions(Data("[1]".utf8)), [:])
        XCTAssertEqual(RetiredBuiltinLayouts.decodeVersions(Data("nope".utf8)), [:])
    }

    func testEveryRetiredVersionInTheCommittedFileDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Layouts/retired/builtin-layouts.json")
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [Any]])
        let decoded = RetiredBuiltinLayouts.decodeVersions(try Data(contentsOf: url))
        for (id, entries) in raw { XCTAssertEqual(decoded[id]?.count, entries.count, id) }
    }
}
