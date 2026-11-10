import Foundation
import XCTest

@testable import LayoutKit

/// The package owns its user-facing wording. `Sources/LayoutKit/Resources/Localizable.xcstrings`
/// carries Simplified Chinese (the source language) plus Traditional Chinese and Japanese, and the
/// production code reads an entry through the package's own compiled bundle. These tests keep the
/// catalog and the code that reads it in step; the wording itself is reviewed, not asserted here.
final class LayoutKitLocalizationTests: XCTestCase {
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LayoutKit/Resources/Localizable.xcstrings")

    /// Source language first; the two translations every entry must carry.
    private static let languages = ["zh-Hans", "zh-Hant", "ja"]

    /// `key` -> language -> value, read from the committed catalog, so a missing translation fails
    /// here instead of silently falling back to the key at runtime.
    private static func catalog() throws -> [String: [String: String]] {
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["sourceLanguage"] as? String, "zh-Hans")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        XCTAssertFalse(strings.isEmpty)
        var result: [String: [String: String]] = [:]
        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            var values: [String: String] = [:]
            for language in languages {
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

    /// Every language's rendering of `key` with the given arguments; a produced value must match one
    /// of them, which proves the running code reads the catalog instead of a copy kept in source.
    private static func renderings(_ key: String, _ arguments: CVarArg...) throws -> [String] {
        let values = try XCTUnwrap(try catalog()[key], "missing catalog entry \(key)")
        return languages.compactMap { language in
            values[language].map { String(format: $0, arguments: arguments) }
        }
    }

    func testEveryEntryIsTranslatedAndJapaneseIsNotCopiedFromSimplified() throws {
        for (key, values) in try Self.catalog() {
            let hans = try XCTUnwrap(values["zh-Hans"], key)
            let hant = try XCTUnwrap(values["zh-Hant"], key)
            let ja = try XCTUnwrap(values["ja"], key)
            XCTAssertFalse(hans.isEmpty, key)
            XCTAssertFalse(hant.isEmpty, key)
            XCTAssertFalse(ja.isEmpty, key)
            XCTAssertNotEqual(hans, ja, key)
        }
    }

    /// The Traditional value must preserve every ASCII character of the source (digits, spaces,
    /// placeholders), which is what the generation gate checks before it rewrites zh-Hant.
    func testPlaceholdersAndAsciiTextSurviveTranslation() throws {
        for (key, values) in try Self.catalog() {
            let hans = try XCTUnwrap(values["zh-Hans"], key)
            let hant = try XCTUnwrap(values["zh-Hant"], key)
            let ja = try XCTUnwrap(values["ja"], key)
            XCTAssertEqual(
                Self.asciiOnly(hant), Self.asciiOnly(hans), "\(key) zh-Hant changes ASCII text")
            XCTAssertEqual(Self.placeholders(hant), Self.placeholders(hans), "\(key) zh-Hant placeholders")
            XCTAssertEqual(Self.placeholders(ja), Self.placeholders(hans), "\(key) ja placeholders")
        }
    }

    func testActionValidationMessagesComeFromTheCatalog() throws {
        func assertMessage(_ action: LayoutAction, _ key: String) throws {
            do {
                try action.validate()
                XCTFail("expected \(key) to be refused")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                XCTAssertTrue(
                    try Self.renderings(key).contains(try XCTUnwrap(message)),
                    "\(key): \(String(describing: message))")
            }
        }
        try assertMessage(LayoutAction(.literal), "layout.error.literalEmpty")
        try assertMessage(LayoutAction(.code, value: "ab"), "layout.error.codeValue")
        try assertMessage(LayoutAction(.pageSwitch, value: "nope"), "layout.error.pageSwitchTarget")
        try assertMessage(LayoutAction(.kana, value: "nope"), "layout.error.kanaRow")
        try assertMessage(LayoutAction(.space, value: "x"), "layout.error.functionKeyValue")
    }

    func testLayoutAndPageMessagesComeFromTheCatalog() throws {
        let duplicate = try XCTUnwrap(LayoutError.duplicateID("x").errorDescription)
        XCTAssertTrue(try Self.renderings("layout.error.duplicateID").contains(duplicate))
        let unknown = try XCTUnwrap(LayoutError.unknownID("x").errorDescription)
        XCTAssertTrue(try Self.renderings("layout.error.unknownID").contains(unknown))
        XCTAssertTrue(
            try Self.renderings("layout.error.halvesShape").contains(LayoutSplitMessage.halvesShape))
        XCTAssertTrue(
            try Self.renderings("layout.error.halvesOnlyOnLayout")
                .contains(LayoutSplitMessage.halvesOnlyOnLayout))
        XCTAssertTrue(
            try Self.renderings("page.kind.numeric").contains(KeyboardPageKind.numeric.title))
        XCTAssertTrue(
            try Self.renderings("page.kind.symbols").contains(KeyboardPageKind.symbols.title))
    }

    func testHintMessagesComposeFromTheCatalog() throws {
        var snapshot = ShuangpinHintSnapshot()
        snapshot.selectedPresetID = ""
        do {
            try snapshot.validate()
            XCTFail("expected the empty selection to be refused")
        } catch {
            let message = try XCTUnwrap((error as? LocalizedError)?.errorDescription)
            // The nested field and reason are themselves localized, so compose per language.
            let entries = try Self.catalog()
            let composed = Self.languages.compactMap { language -> String? in
                guard let field = entries["shinpin.field.currentPreset"]?[language],
                    let reason = entries["shinpin.reason.selectPreset"]?[language],
                    let sentence = entries["shinpin.error.settingsUnusable"]?[language]
                else { return nil }
                return String(format: sentence, field, reason)
            }
            XCTAssertTrue(composed.contains(message), "\(message)")
        }

        let preset = ShuangpinHintPreset(id: "", name: "name", hints: [:])
        do {
            try preset.validate()
            XCTFail("expected the empty identifier to be refused")
        } catch {
            let message = try XCTUnwrap((error as? LocalizedError)?.errorDescription)
            let entries = try Self.catalog()
            let composed = Self.languages.compactMap { language -> String? in
                guard let field = entries["shinpin.field.id"]?[language],
                    let reason = entries["shinpin.reason.requiredMaxBytes"]?[language],
                    let sentence = entries["shinpin.error.fieldUnusable"]?[language]
                else { return nil }
                return String(
                    format: sentence, field,
                    String(format: reason, String(ShuangpinHintPreset.maximumIDBytes)))
            }
            XCTAssertTrue(composed.contains(message), "\(message)")
        }
    }

    private static func asciiOnly(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value < 128 }.map(Character.init))
    }

    private static func placeholders(_ value: String) -> [String] {
        (try? NSRegularExpression(pattern: "%[0-9]+\\$@"))
            .map { expression in
                let range = NSRange(value.startIndex..<value.endIndex, in: value)
                return expression.matches(in: value, range: range).compactMap { match in
                    Range(match.range, in: value).map { String(value[$0]) }
                }.sorted()
            } ?? []
    }
}
