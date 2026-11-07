import Foundation
import XCTest

@testable import PackageManager

/// The package owns its user-facing wording. `Sources/PackageManager/Resources/Localizable.xcstrings`
/// carries Simplified Chinese (the source language) plus Traditional Chinese and Japanese, and
/// `PackageText` resolves an entry through the package's own bundle. These tests keep the catalog and
/// the code that reads it in step; the wording itself is reviewed, not asserted here.
final class LocalizationCatalogTests: XCTestCase {
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/PackageManager/Resources/Localizable.xcstrings")

    /// Source language first; the two translations every entry must carry.
    private static let languages = ["zh-Hans", "zh-Hant", "ja"]

    /// Wording that is legitimately written the same in Simplified and Traditional Chinese.
    private static let hantMayEqualHans: [String: String] = [
        "rimeConfig.error.fileName": "「%1$@」",
        "rimeConfig.error.line": "第 %1$@ 行",
        "recipe.description.fuzzyPinyin": "模糊音",
    ]
    /// Entries where Japanese shares the Simplified form (a quoted placeholder only).
    private static let jaMayEqualHans: Set<String> = ["rimeConfig.error.fileName"]

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
            if let pinned = Self.hantMayEqualHans[key] {
                XCTAssertEqual(hans, pinned, key)
                XCTAssertEqual(hant, pinned, key)
            } else {
                XCTAssertNotEqual(hans, hant, key)
            }
            if !Self.jaMayEqualHans.contains(key) { XCTAssertNotEqual(hans, ja, key) }
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

    /// The compiled bundle resolves every translated language (a key that only lives in the source
    /// tree, or a catalog the build did not compile, would fail here).
    func testCompiledCatalogResolvesEveryTranslatedLanguage() throws {
        let entries = try catalog()
        for language in ["zh-Hant", "ja"] {
            let path = try XCTUnwrap(
                PackageText.catalog.path(forResource: language, ofType: "lproj"),
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
        let everyValue = Set(entries.values.flatMap { $0.values })

        func renderings(_ key: String, _ arguments: CVarArg...) throws -> [String] {
            let values = try XCTUnwrap(entries[key], "missing catalog entry \(key)")
            return Self.languages.compactMap { language in
                values[language].map { String(format: $0, arguments: arguments) }
            }
        }

        XCTAssertTrue(everyValue.contains(PackageText.string("recipe.error.busy")))
        XCTAssertTrue(
            try renderings("recipe.error.busy").contains(RecipeInstallError.busy.userFacingDescription))
        XCTAssertTrue(
            try renderings("recipe.error.downloadFailed").contains(RecipeInstallError.http(500).userFacingDescription))
        XCTAssertTrue(
            try renderings("modelState.currentInstallation")
                .contains(ModelPublicationState.currentInstallation.message))
        XCTAssertTrue(
            try renderings("grammarState.awaitingLoad", "wanxiang.gram")
                .contains(GrammarModelStatus.awaitingLoad(model: "wanxiang.gram").message))
        XCTAssertTrue(
            try renderings("rimeConfig.error.scriptNameTaken", "my_script")
                .contains(try XCTUnwrap(RimeScriptNameTaken(name: "my_script").errorDescription)))
        XCTAssertTrue(
            try renderings("rimeConfig.error.tooMany")
                .contains(try XCTUnwrap(UserConfigError(nil, .tooMany).errorDescription)))

        // Two nested entries compose the file/line sentence; the arguments keep their order everywhere.
        let fileError = UserConfigError("a.custom.yaml", .invalidYAML, line: 3)
        let expected = Self.languages.compactMap { language -> String? in
            guard let name = entries["rimeConfig.error.fileName"]?[language],
                let place = entries["rimeConfig.error.line"]?[language],
                let sentence = entries["rimeConfig.error.invalidYAML"]?[language]
            else { return nil }
            return String(format: sentence, String(format: name, "a.custom.yaml"), String(format: place, "3"))
        }
        XCTAssertTrue(expected.contains(try XCTUnwrap(fileError.errorDescription)))

        // The wrapper and the reason it wraps are both localized, with the filenames preserved.
        let missing = DictionaryImportError.missingDependencies(["words.dict.yaml", "extra.dict.yaml"])
        XCTAssertTrue(
            try renderings("dictionary.error.missingFiles", "words.dict.yaml、extra.dict.yaml")
                .contains(try XCTUnwrap(missing.errorDescription)))
    }
}
