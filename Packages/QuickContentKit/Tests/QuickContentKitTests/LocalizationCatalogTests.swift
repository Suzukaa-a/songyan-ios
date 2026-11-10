import Foundation
import XCTest

@testable import QuickContentKit

/// The package owns its user-facing wording. `Sources/QuickContentKit/Resources/Localizable.xcstrings`
/// carries Simplified Chinese (the source language) plus Traditional Chinese and Japanese, and the
/// production code reads an entry through the package's own compiled bundle. These tests keep the
/// catalog and the code that reads it in step; the wording itself is reviewed, not asserted here.
final class LocalizationCatalogTests: XCTestCase {
    func testEveryEntryHasSimplifiedTraditionalAndJapanese() throws {
        for (key, values) in try LocalizedCatalog.entries() {
            let hans = try XCTUnwrap(values["zh-Hans"], "\(key) has no zh-Hans entry")
            let hant = try XCTUnwrap(values["zh-Hant"], "\(key) has no zh-Hant entry")
            let ja = try XCTUnwrap(values["ja"], "\(key) has no ja entry")
            XCTAssertFalse(hans.isEmpty, key)
            XCTAssertFalse(hant.isEmpty, key)
            XCTAssertFalse(ja.isEmpty, key)
            XCTAssertNotEqual(hans, ja, key)
        }
    }

    func testTranslationsCarryTheSamePlaceholders() throws {
        for (key, values) in try LocalizedCatalog.entries() {
            let expected = placeholders(try XCTUnwrap(values["zh-Hans"], key))
            for (language, value) in values where language != "zh-Hans" {
                XCTAssertEqual(placeholders(value), expected, "\(key) \(language) placeholders")
            }
        }
    }

    func testUserFacingFailuresComeFromTheCatalog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let contentStore = LocalQuickContentStore(directory: directory)
        XCTAssertThrowsError(try contentStore.importPhrases(Data("broken".utf8))) { error in
            Self.assertLocalized(error, "quickContent.error.unreadable")
        }
        XCTAssertThrowsError(try contentStore.savePhrase(CommonPhrase(text: " "))) { error in
            Self.assertLocalized(error, "quickContent.error.textInvalid")
        }
        XCTAssertThrowsError(
            try QuickContentFileReader.read(directory, maximumBytes: 1024, sizeError: "unused")
        ) { error in
            Self.assertLocalized(error, "quickContent.error.notAFile")
        }

        XCTAssertThrowsError(try SymbolCatalog.decode(Data(repeating: 0x20, count: 256 * 1024 + 1))) { error in
            Self.assertLocalized(error, "symbol.error.fileTooLarge")
        }
        let duplicatedText = Data(
            #"{"version":1,"items":[{"id":"a","text":"→","name":"右箭头","aliases":[],"category":"arrows"},{"id":"b","text":"→","name":"左箭头","aliases":[],"category":"arrows"}]}"#
                .utf8)
        XCTAssertThrowsError(try SymbolCatalog.decode(duplicatedText)) { error in
            Self.assertLocalized(error, "symbol.error.duplicateText", "→")
        }

        let recentStore = RecentSymbolStore(directory: directory)
        XCTAssertNil(recentStore.save(["one"]))
        try Data(repeating: 0x20, count: 16 * 1024 + 1)
            .write(to: directory.appendingPathComponent("recent.json"))
        XCTAssertEqual(
            recentStore.read { error in Self.assertLocalized(error, "symbol.error.recentTooLarge") }, [])
    }

    /// The thrown text is one language's rendering of `key`; the process language decides which.
    private static func assertLocalized(
        _ error: Error, _ key: String, _ arguments: CVarArg...,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let message = error.localizedDescription
        let expected = (try? LocalizedCatalog.renderings(key, arguments: arguments)) ?? []
        XCTAssertTrue(expected.contains(message), "\(key): \(message)", file: file, line: line)
    }

    /// Every positional placeholder of `value`, sorted, so two entries can be compared.
    private func placeholders(_ value: String) -> [String] {
        (try? NSRegularExpression(pattern: "%[0-9]+\\$(?:@|l?ld)"))
            .map { expression in
                let range = NSRange(value.startIndex..<value.endIndex, in: value)
                return expression.matches(in: value, range: range).compactMap { match in
                    Range(match.range, in: value).map { String(value[$0]) }
                }.sorted()
            } ?? []
    }
}
