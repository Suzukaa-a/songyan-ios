import Foundation
import XCTest

@testable import RimeBridge

/// The package owns its user-facing wording. `Sources/RimeBridge/Resources/Localizable.xcstrings`
/// carries Simplified Chinese (the source language) plus Traditional Chinese and Japanese, and
/// `RimeText` resolves an entry through the package's own bundle. These tests keep the catalog and
/// the code that reads it in step; the wording itself is reviewed, not asserted here.
final class LocalizationCatalogTests: XCTestCase {
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/RimeBridge/Resources/Localizable.xcstrings")

    /// Source language first; the two translations every entry must carry.
    private static let languages = ["zh-Hans", "zh-Hant", "ja"]

    /// `key` -> language -> value, read from the committed catalog, so a missing translation fails
    /// here instead of silently falling back to the key at runtime.
    private func catalog() throws -> [String: [String: String]] {
        let data = try Data(contentsOf: Self.catalogURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["sourceLanguage"] as? String, "zh-Hans")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        XCTAssertFalse(strings.isEmpty)
        var result: [String: [String: String]] = [:]
        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            var values: [String: String] = [:]
            for language in Self.languages {
                let unit = try XCTUnwrap(
                    (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any],
                    "\(key) has no \(language) entry")
                XCTAssertEqual(unit["state"] as? String, "translated", "\(key) \(language)")
                values[language] = try XCTUnwrap(unit["value"] as? String, "\(key) \(language)")
            }
            result[key] = values
        }
        return result
    }

    func testEveryEntryIsTranslatedAndJapaneseIsNotCopiedFromSimplified() throws {
        for (key, values) in try catalog() {
            let hans = try XCTUnwrap(values["zh-Hans"], key)
            let hant = try XCTUnwrap(values["zh-Hant"], key)
            let ja = try XCTUnwrap(values["ja"], key)
            XCTAssertFalse(hans.isEmpty, key)
            XCTAssertFalse(hant.isEmpty, key)
            XCTAssertFalse(ja.isEmpty, key)
            XCTAssertNotEqual(hans, ja, key)
        }
    }

    func testEveryTranslationCarriesTheSamePlaceholders() throws {
        for (key, values) in try catalog() {
            let hans = try XCTUnwrap(values["zh-Hans"], key)
            let hansPlaceholders = try placeholders(hans)
            for language in ["zh-Hant", "ja"] {
                let value = try XCTUnwrap(values[language], key)
                XCTAssertEqual(try placeholders(value), hansPlaceholders, "\(key) \(language) placeholders")
                // Every percent sign belongs to a positional placeholder; nothing is left stray.
                XCTAssertEqual(
                    value.filter { $0 == "%" }.count, hansPlaceholders.count, "\(key) \(language) percent")
            }
        }
    }

    /// Every positional placeholder (`%1$@`) of `value`, sorted, so two entries can be compared.
    private func placeholders(_ value: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: "%[0-9]+\\$(?:@|l?ld)")
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        }.sorted()
    }

    /// The compiled bundle resolves every translated language (a catalog the build did not compile
    /// would fail here).
    func testCompiledCatalogResolvesEveryTranslatedLanguage() throws {
        let entries = try catalog()
        for language in ["zh-Hant", "ja"] {
            let path = try XCTUnwrap(
                RimeText.catalog.path(forResource: language, ofType: "lproj"),
                "the package bundle has no \(language).lproj")
            let bundle = try XCTUnwrap(Bundle(path: path))
            for (key, values) in entries {
                let compiled = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertEqual(compiled, values[language], "\(key) \(language)")
            }
        }
    }

    /// Production values read the catalog and keep the same arguments in every language.
    func testUserFacingValuesComeFromTheCatalog() throws {
        let entries = try catalog()

        func renderings(_ key: String, _ arguments: CVarArg...) throws -> [String] {
            let values = try XCTUnwrap(entries[key], "missing catalog entry \(key)")
            return Self.languages.compactMap { language in
                values[language].map { String(format: $0, arguments: arguments) }
            }
        }

        XCTAssertTrue(
            try renderings("engine.error.snapshotUnavailable").contains(
                try XCTUnwrap(RimeEngineError.snapshotUnavailable.errorDescription)))
        // The templates that carry caller detail are filled from the catalog, not compiled in.
        for (key, detail) in [
            ("engine.error.initializationFailed", "cannot create session"),
            ("engine.error.syncFailed", "details"),
            ("engine.error.schemaSelectionFailed", "luna_pinyin"),
        ] {
            XCTAssertTrue(try renderings(key, detail).contains(try XCTUnwrap(RimeText.format(key, detail))), key)
        }
        XCTAssertEqual(
            RimeEngineError.initializationFailed("detail").errorDescription,
            RimeText.format("engine.error.initializationFailed", "detail"))

        // The wrapped detail is the sentence: the engine adds no prefix of its own around it.
        XCTAssertEqual(RimeEngineError.operationFailed("已停止输入").errorDescription, "已停止输入")
    }

    /// The request-range message formats integers through a `%@` template; handing it raw `Int`s
    /// crashed instead of reporting the invalid range.
    func testAnInvalidCandidateRequestReportsItsRange() throws {
        let scratch = FileManager.default.temporaryDirectory
        let engine = RimeEngine(configuration: .init(sharedDirectory: scratch, userDirectory: scratch))
        XCTAssertThrowsError(try engine.readCandidatePage(fromIndex: -3, count: 7)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("-3") && text.contains("7"), text)
        }
    }
}
