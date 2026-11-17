import Foundation
import XCTest

@testable import PackageManager

final class DictionaryLanguageTests: XCTestCase {
    private let simplified = "国际学习电脑发现开关门问题车站飞机书店经济贸易产业环境艺术图书馆"
    private let traditional = "國際學習電腦發現開關門問題車站飛機書店經濟貿易產業環境藝術圖書館"

    private func detect(_ texts: String...) -> String { DictionaryLanguage.detect(texts) }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testASimplifiedDictionaryIsSimplifiedChinese() {
        XCTAssertEqual(DictionaryLanguage.detect(simplified.map(String.init) + [simplified]), "zh-Hans")
    }

    func testATraditionalDictionaryIsTraditionalChinese() {
        XCTAssertEqual(DictionaryLanguage.detect(traditional.map(String.init) + [traditional]), "zh-Hant")
    }

    func testAMixedDictionaryFollowsTheSystemScript() {
        // Each script has plenty, but neither is twice the other.
        XCTAssertEqual(detect(simplified, traditional), "zh")
        // Too few script-specific characters to prove either side.
        XCTAssertEqual(detect("国", "中文"), "zh")
    }

    func testKanaEntriesMakeItJapaneseEvenWithKanjiAround() {
        let kanji = Array(repeating: "漢字", count: 40)
        XCTAssertEqual(DictionaryLanguage.detect(kanji + ["ひらがな", "カタカナ", "かな"]), "ja")
        // Under 5 % of the entries it is still Chinese.
        XCTAssertEqual(DictionaryLanguage.detect(Array(repeating: "字典", count: 100) + ["ひらがな"]), "zh")
    }

    func testHangulEntriesMakeItKorean() {
        XCTAssertEqual(detect("한국어", "사전", "English", "단어", "가나다"), "ko")
        XCTAssertEqual(DictionaryLanguage.detect(Array(repeating: "word", count: 10) + ["한"]), "none")
    }

    func testAnEnglishDictionaryForcesNothing() {
        XCTAssertEqual(detect("hello", "world", "dictionary"), "none")
        XCTAssertEqual(DictionaryLanguage.detect([String]()), "none")
    }

    func testTheDictionaryFileIsReadWithItsColumnsAndOneLevelOfImports() throws {
        let dir = try temporaryDirectory()
        try
            ("# header\n---\nname: main\nversion: \"1\"\nimport_tables:\n  - extra\n"
            + "columns:\n  - code\n  - text\n...\n" + "a\t国\n# comment\nb\t学\n")
            .write(to: dir.appendingPathComponent("main.dict.yaml"), atomically: true, encoding: .utf8)
        try ("---\nname: extra\n...\n" + simplified.map { "\($0)\tx" }.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("extra.dict.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(DictionaryLanguage.read(sourceDirectory: dir, name: "main"), "zh-Hans")
    }

    func testAMissingDictionaryCannotBeTold() throws {
        let dir = try temporaryDirectory()
        XCTAssertNil(DictionaryLanguage.read(sourceDirectory: dir, name: "nothing"))
        XCTAssertNil(DictionaryLanguage.read(sourceDirectory: dir, name: "../escape"))
        try "a\tb\n".write(
            to: dir.appendingPathComponent("headless.dict.yaml"), atomically: true, encoding: .utf8)
        XCTAssertNil(DictionaryLanguage.read(sourceDirectory: dir, name: "headless"))
    }

    func testTheDeploymentFillsTheLanguageOfThePrimaryDictionaryIntoTheProfile() throws {
        let build = try temporaryDirectory()
        let source = try temporaryDirectory()
        let fixture = try XCTUnwrap(
            Bundle.module.url(
                forResource: "wubi86.schema", withExtension: "yaml", subdirectory: "Fixtures/KeyProfiles"))
        try FileManager.default.copyItem(at: fixture, to: build.appendingPathComponent("wubi86.schema.yaml"))
        try ("---\nname: wubi86\n...\n" + simplified.map { "\($0)\ta" }.joined(separator: "\n") + "\n")
            .write(to: source.appendingPathComponent("wubi86.dict.yaml"), atomically: true, encoding: .utf8)
        let profiles = SchemaKeyProfiles.withLanguages(
            SchemaKeyProfiles.computeAll(buildDir: build, ids: ["wubi86"]), buildDir: build,
            sourceDirectories: [source])
        try SchemaKeyProfiles.write(profiles, buildDir: build)
        XCTAssertEqual(SchemaKeyProfiles.read(buildDir: build, ids: ["wubi86"])["wubi86"]?.language, "zh-Hans")
        XCTAssertEqual(SchemaKeyProfiles.read(buildDir: build, ids: ["wubi86"])["wubi86"]?.kind, .shapeCode)
    }
}
