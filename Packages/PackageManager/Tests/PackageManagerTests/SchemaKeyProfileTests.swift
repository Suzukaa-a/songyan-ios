import Foundation
import KeyboardCore
import XCTest

@testable import PackageManager

/// The profile of each shared fixture schema equals the hand-checked expectation both platforms read.
final class SchemaKeyProfileTests: XCTestCase {
    private static let fixtures = [
        "bopomofo", "cangjie5", "double_pinyin_flypy", "jyut6ping3", "lua_only", "luna_pinyin", "melt_eng",
        "rime_ice", "stroke", "terra_pinyin", "thai_kedmanee", "wubi86",
    ]

    private func resource(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/KeyProfiles"), name)
        return try Data(contentsOf: url)
    }

    private func schema(_ name: String) throws -> String {
        String(decoding: try resource("\(name).schema.yaml"), as: UTF8.self)
    }

    func testEveryFixtureSchemaGetsItsExpectedProfile() throws {
        for name in Self.fixtures {
            let expected = try XCTUnwrap(SchemaKeyProfile.decodeOne(try resource("\(name).profile.json")), name)
            XCTAssertEqual(SchemaKeyProfiles.compute(compiledSchema: try schema(name)), expected, name)
        }
    }

    func testKindsFollowThePrimaryTranslator() throws {
        XCTAssertEqual(SchemaKeyProfiles.compute(compiledSchema: try schema("wubi86")).kind, .shapeCode)
        XCTAssertEqual(SchemaKeyProfiles.compute(compiledSchema: try schema("stroke")).kind, .strokes)
        XCTAssertEqual(SchemaKeyProfiles.compute(compiledSchema: try schema("rime_ice")).kind, .syllabic)
        XCTAssertEqual(SchemaKeyProfiles.compute(compiledSchema: try schema("lua_only")).kind, .unknown)
    }

    func testAnUnreadableSchemaIsUnknown() {
        XCTAssertEqual(SchemaKeyProfiles.compute(compiledSchema: "{{{ not yaml"), SchemaKeyProfile(kind: .unknown))
        XCTAssertEqual(SchemaKeyProfiles.compute(compiledSchema: ""), SchemaKeyProfile(kind: .unknown))
    }

    func testAnOldKindNameReadsAsSyllabicAndAnUnknownOneAsUnknown() throws {
        XCTAssertEqual(SchemaKeyProfile.decodeOne(Data(#"{"kind":"nonLatin"}"#.utf8))?.kind, .syllabic)
        XCTAssertEqual(SchemaKeyProfile.decodeOne(Data(#"{"kind":"future"}"#.utf8))?.kind, .unknown)
    }

    func testTheFileRoundTripsAndABuildWithoutOneIsComputed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["wubi86", "stroke"] {
            try schema(name).write(
                to: dir.appendingPathComponent("\(name).schema.yaml"), atomically: true, encoding: .utf8)
        }
        let computed = SchemaKeyProfiles.read(buildDir: dir, ids: ["wubi86", "stroke", "missing"])
        XCTAssertEqual(computed["wubi86"]?.kind, .shapeCode)
        XCTAssertEqual(computed["missing"]?.kind, .unknown)
        try SchemaKeyProfiles.write(buildDir: dir, ids: ["wubi86", "stroke"])
        let decoded = try XCTUnwrap(
            SchemaKeyProfile.decode(try Data(contentsOf: dir.appendingPathComponent(SchemaKeyProfile.fileName))))
        XCTAssertEqual(decoded, computed.filter { $0.key != "missing" })
        // The file wins over the schema once written.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("wubi86.schema.yaml"))
        XCTAssertEqual(SchemaKeyProfiles.read(buildDir: dir, ids: ["wubi86"])["wubi86"]?.kind, .shapeCode)
    }
}
