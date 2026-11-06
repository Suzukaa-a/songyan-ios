import Foundation
import XCTest

@testable import QuickContentKit

/// The committed `Localizable.xcstrings`, read as data so the tests compare production wording with
/// the file the build compiles instead of a copy kept in the test.
enum LocalizedCatalog {
    /// The committed catalog, next to the package sources.
    private static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/QuickContentKit/Resources/Localizable.xcstrings")

    /// `key` -> language -> value, for every entry of the committed catalog. Only localizations
    /// marked translated are returned; the caller decides which languages an entry must carry.
    static func entries() throws -> [String: [String: String]] {
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["sourceLanguage"] as? String, "zh-Hans")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        XCTAssertFalse(strings.isEmpty)
        var result: [String: [String: String]] = [:]
        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            var values: [String: String] = [:]
            for (language, rawLocalization) in localizations {
                let unit = try XCTUnwrap(
                    (rawLocalization as? [String: Any])?["stringUnit"] as? [String: Any],
                    "\(key) \(language) has no stringUnit")
                XCTAssertEqual(unit["state"] as? String, "translated", "\(key) \(language)")
                if let value = unit["value"] as? String { values[language] = value }
            }
            result[key] = values
        }
        return result
    }

    /// Every translated value of `key`, in no particular order.
    static func values(_ key: String) throws -> [String] {
        let entry = try XCTUnwrap(try entries()[key], "missing catalog entry \(key)")
        return Array(entry.values)
    }

    /// Every language's rendering of `key` with its positional placeholders filled in.
    static func renderings(_ key: String, arguments: [CVarArg] = []) throws -> [String] {
        try values(key).map { String(format: $0, arguments: arguments) }
    }
}
