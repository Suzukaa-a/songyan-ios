import Foundation
import XCTest

@testable import KeyboardCore

/// The package owns its user-facing wording. `Sources/KeyboardCore/Resources/Localizable.xcstrings`
/// carries Simplified Chinese (the source language) plus Traditional Chinese and Japanese, and the
/// production code reads an entry through the package's own compiled bundle. These tests keep the
/// catalog and the code that reads it in step; the wording itself is reviewed, not asserted here.
final class KeyboardCoreLocalizationTests: XCTestCase {
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/KeyboardCore/Resources/Localizable.xcstrings")

    /// Source language first; the two translations every entry must carry.
    private static let languages = ["zh-Hans", "zh-Hant", "ja"]

    /// Wording that is legitimately written the same in Simplified and Japanese (product terminology).
    private static let jaMayEqualHans: Set<String> = ["core.term.statusNotApplied"]

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
            if !Self.jaMayEqualHans.contains(key) { XCTAssertNotEqual(hans, ja, key) }
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

    /// A bundled layout or page carries the shipped Chinese name in its data; lists word it in the UI
    /// language while that name is unchanged, and never replace a name the user wrote.
    func testBundledLayoutsAndPagesAreNamedInTheAppLanguage() throws {
        let pages: [(id: String, shipped: String, key: String)] = [
            ("page.symbols.system", "默认符号页", "core.page.symbolsSystem"),
            ("page.symbols.categorized", "分类符号", "core.page.symbolsCategorized"),
            ("page.numeric.automatic", "自动 123", "core.page.numericAutomatic"),
            ("page.numeric.keypad", "数字九宫格", "core.page.numericKeypad"),
            ("page.english.qwerty", "英文 QWERTY", "core.page.englishQwerty"),
        ]
        for page in pages {
            let name = UserTerminology.pageListName(id: page.id, name: page.shipped, shippedName: page.shipped)
            XCTAssertTrue(try Self.renderings(page.key).contains(name), page.id)
            XCTAssertEqual(
                UserTerminology.pageListName(id: page.id, name: "我的符号", shippedName: page.shipped), "我的符号")
        }
        XCTAssertEqual(UserTerminology.pageListName(id: "mine", name: "我的符号", shippedName: nil), "我的符号")
        XCTAssertEqual(
            UserTerminology.layoutListName(id: "qwerty26", name: "26 键", shippedName: "26 键"),
            KeyboardLayoutKind.qwerty26.userTitle)
        XCTAssertEqual(
            UserTerminology.layoutListName(id: "qwerty26", name: "我的键盘", shippedName: "26 键"), "我的键盘")
        XCTAssertEqual(UserTerminology.layoutListName(id: "mine", name: "我的键盘", shippedName: nil), "我的键盘")
    }

    /// The installed list showed the built-in package under its manifest name, 内置输入方案, in every
    /// language; it is named from the catalog like the home screen names it.
    func testTheBuiltinPackageIsListedInTheAppLanguage() throws {
        let name = ProductionInputAvailability.packageDisplayName(
            id: ProductionInputAvailability.builtinPackageID,
            declaredName: ProductionInputAvailability.builtinDisplayName)
        XCTAssertTrue(try Self.renderings("core.status.builtinDisplayName").contains(name))
        XCTAssertEqual(ProductionInputAvailability.packageDisplayName(id: "kagiroi", declaredName: "カギロイ"), "カギロイ")
    }

    func testProductionValuesComeFromTheCatalog() throws {
        XCTAssertTrue(try Self.renderings("core.term.inputScheme").contains(UserTerminology.inputScheme))
        XCTAssertTrue(try Self.renderings("core.term.startUsing").contains(UserTerminology.startUsing))
        XCTAssertTrue(
            try Self.renderings("core.term.userKeyboardNoSource")
                .contains(UserTerminology.userKeyboardNoSource))
        XCTAssertTrue(
            try Self.renderings("core.term.userKeyboardListUnchanged")
                .contains(UserTerminology.userKeyboardListUnchanged))
        XCTAssertTrue(
            try Self.renderings("core.term.installedSourceSummary", "2")
                .contains(UserTerminology.installedSourceSummary(count: 2)))
        // A bundled scheme and its companions are named in the app language, not by their YAML name.
        let quanpin = try Self.renderings("core.builtin.quanpinName")
        XCTAssertTrue(
            quanpin.contains(KeyboardSchemaDescriptor(id: BuiltinTemplateSchemas.quanpin, name: "内置全拼").displayName))
        for adapter in BuiltinTemplateSchemas.adapters {
            let key =
                adapter.sourceSchemaID == BuiltinTemplateSchemas.quanpin
                ? "core.builtin.quanpinName" : "core.builtin.flypyName"
            let descriptor = KeyboardSchemaDescriptor(
                id: adapter.schemaID, name: BuiltinTemplateSchemas.names[adapter.sourceSchemaID] ?? "")
            XCTAssertTrue(try Self.renderings(key).contains(descriptor.displayName), adapter.schemaID)
            XCTAssertEqual(descriptor.humanReadableName, descriptor.displayName, adapter.schemaID)
        }
        XCTAssertNil(BuiltinTemplateSchemas.localizedName(for: "rime_ice"))
        // The Japanese clause separator is 、: a hard-coded Chinese comma used to join the two parts.
        let summaryEntries = try Self.catalog()
        let summaryRenderings = Self.languages.compactMap { language -> String? in
            guard let sentence = summaryEntries["core.term.installedSchemeSummary"]?[language],
                let installed = summaryEntries["core.term.installedSourceSummary"]?[language],
                let inUse = summaryEntries["core.term.inUsePrefix"]?[language]
            else { return nil }
            return String(format: sentence, String(format: installed, "2"), inUse, "内置全拼")
        }
        XCTAssertTrue(
            summaryRenderings.contains(UserTerminology.installedSchemeSummary(count: 2, inUse: "内置全拼")))
        XCTAssertFalse(try XCTUnwrap(summaryEntries["core.term.installedSchemeSummary"]?["ja"]).contains("，"))
        // The reason composes two catalog terms, so render it per language from the catalog itself.
        let reasonEntries = try Self.catalog()
        let reasonRenderings = Self.languages.compactMap { language -> String? in
            guard let sentence = reasonEntries["core.term.layoutUnavailableReason"]?[language],
                let name = reasonEntries["core.layout.phone9Title"]?[language],
                let layoutTerm = reasonEntries["core.term.keyboardLayout"]?[language]
            else { return nil }
            return String(format: sentence, name, layoutTerm)
        }
        XCTAssertTrue(
            reasonRenderings.contains(UserTerminology.layoutUnavailableReason(.phone9)))
        XCTAssertTrue(
            try Self.renderings("core.term.userKeyboardNowUsing", "测试键盘")
                .contains(UserTerminology.userKeyboardNowUsing("测试键盘")))
        XCTAssertTrue(
            try Self.renderings("core.term.userKeyboardSaved", "3")
                .contains(UserTerminology.userKeyboardSaved(count: 3)))
        XCTAssertTrue(
            try Self.renderings("core.error.sourceInUse")
                .contains(InstalledSourceDeletionPolicy.refusedMessage))
        XCTAssertTrue(
            try Self.renderings("core.status.nothingCommitted")
                .contains(OperationFailureState.nothingCommitted.stateLine))
        XCTAssertTrue(
            try Self.renderings("core.status.unconfiguredTitle")
                .contains(ProductionInputAvailability.unconfiguredTitle))
        XCTAssertTrue(
            try Self.renderings("core.import.tooLarge").contains(RimeSnapshotImportSummary.tooLarge))
        XCTAssertTrue(
            try Self.renderings("core.quickInsert.time").contains(QuickInsertDateFormat.time.title))
        XCTAssertTrue(
            try Self.renderings("core.layout.merged14Title")
                .contains(KeyboardLayoutKind.merged14.userTitle))
        XCTAssertTrue(
            try Self.renderings("core.layout.phone9Detail")
                .contains(KeyboardLayoutKind.phone9.detail))
        let backup = try XCTUnwrap(
            LearningBackupArchiveError.unsupportedVersion(2).errorDescription)
        XCTAssertTrue(try Self.renderings("core.backup.error.unsupportedVersion", "2").contains(backup))
        let store = try XCTUnwrap(LearningTransferStoreError.storeMissing.errorDescription)
        XCTAssertTrue(try Self.renderings("core.learning.error.storeMissing").contains(store))
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
