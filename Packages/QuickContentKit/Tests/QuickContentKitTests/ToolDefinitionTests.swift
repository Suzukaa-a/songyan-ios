import Foundation
import QuickContentKit
import XCTest

final class ToolDefinitionTests: XCTestCase {
    // MARK: - Fixtures

    private static let fullNameTable = #"{"zh-Hans":"Hans","zh-Hant":"Hant","ja":"JA","en":"EN"}"#

    private func definitionJSON(
        steps: String,
        formatVersion: String = "1",
        id: String = #""sample""#,
        name: String? = nil,
        extra: String = ""
    ) -> String {
        let resolvedName = name ?? Self.fullNameTable
        return #"{"formatVersion":\#(formatVersion),"id":\#(id),"name":\#(resolvedName),"steps":[\#(steps)]\#(extra)}"#
    }

    private func decode(_ json: String) throws -> ToolDefinition {
        try ToolDefinition.decode(Data(json.utf8))
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("songyan-tool-definition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func assertRejected(
        _ json: String,
        reason expected: ToolDefinitionError.Reason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try decode(json)
            XCTFail("expected \(expected) for \(json)", file: file, line: line)
        } catch let error as ToolDefinitionError {
            XCTAssertEqual(error.reason, expected, json, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error) for \(json)", file: file, line: line)
        }
    }

    private func assertFileRejected(
        _ url: URL,
        reason expected: ToolDefinitionError.Reason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try ToolDefinition.decode(contentsOf: url)
            XCTFail("expected \(expected) for \(url.path)", file: file, line: line)
        } catch let error as ToolDefinitionError {
            XCTAssertEqual(error.reason, expected, url.path, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error) for \(url.path)", file: file, line: line)
        }
    }

    // MARK: - Format version

    func testUnsupportedFormatVersionRejected() {
        assertRejected(
            definitionJSON(steps: #"{"type":"width","mode":"toHalf"}"#, formatVersion: "2"),
            reason: .unsupportedFormatVersion("2"))
        assertRejected(
            definitionJSON(steps: #"{"type":"width","mode":"toHalf"}"#, formatVersion: "0"),
            reason: .unsupportedFormatVersion("0"))
        assertRejected(
            definitionJSON(steps: #"{"type":"width","mode":"toHalf"}"#, formatVersion: #""1""#),
            reason: .invalidField(path: "$.formatVersion"))
    }

    func testMissingFormatVersionRejected() {
        assertRejected(
            #"{"id":"sample","name":\#(Self.fullNameTable),"steps":[{"type":"width","mode":"toHalf"}]}"#,
            reason: .missingField(path: "$.formatVersion"))
    }

    // MARK: - Step set

    func testUnknownStepTypeRejected() {
        let steps = [
            #"{"type":"width","mode":"toHalf"}"#,
            #"{"type":"translate","target":"ja"}"#,
        ].joined(separator: ",")
        assertRejected(
            definitionJSON(steps: steps),
            reason: .unsupportedStepType(step: 2, type: "translate"))
    }

    func testStepCountLimit() {
        let step = #"{"type":"width","mode":"toHalf"}"#
        let sixteen = Array(repeating: step, count: 16).joined(separator: ",")
        let seventeen = Array(repeating: step, count: 17).joined(separator: ",")
        XCTAssertNoThrow(try decode(definitionJSON(steps: sixteen)))
        assertRejected(definitionJSON(steps: seventeen), reason: .tooManySteps(count: 17))
    }

    func testZeroStepsRejected() {
        assertRejected(definitionJSON(steps: ""), reason: .noSteps)
    }

    // MARK: - Step parameters

    func testInvalidRegexRejected() {
        assertRejected(
            definitionJSON(steps: #"{"type":"replace","pattern":"(","replacement":"x"}"#),
            reason: .invalidRegex(step: 1))
        let steps = [
            #"{"type":"width","mode":"toHalf"}"#,
            #"{"type":"replace","pattern":"[","replacement":"x"}"#,
        ].joined(separator: ",")
        assertRejected(definitionJSON(steps: steps), reason: .invalidRegex(step: 2))
        XCTAssertNoThrow(
            try decode(
                definitionJSON(
                    steps: #"{"type":"replace","pattern":"([A-Za-z]+)","replacement":"$1"}"#)))
    }

    func testUnavailableOpenCCConfigRejected() {
        assertRejected(
            definitionJSON(steps: #"{"type":"opencc","config":"hw2s"}"#),
            reason: .unavailableOpenCCConfig(step: 1, config: "hw2s"))
        assertRejected(
            definitionJSON(steps: #"{"type":"opencc","config":"S2T"}"#),
            reason: .unavailableOpenCCConfig(step: 1, config: "S2T"))
        assertRejected(
            definitionJSON(steps: #"{"type":"opencc","config":"s2twp "}"#),
            reason: .unavailableOpenCCConfig(step: 1, config: "s2twp "))
    }

    func testShippedOpenCCConfigsAreTheAvailableSet() throws {
        // Mirrors Resources/EngineResources/opencc/*.json: only these configs ship with the app.
        let expected: Set<String> = [
            "hk2s", "hk2t", "jp2t", "s2hk", "s2t", "s2tw", "s2twp", "t2hk", "t2jp", "t2s", "t2tw",
            "tw2s", "tw2sp", "tw2t",
        ]
        XCTAssertEqual(Set(OpenCCToolConfig.allCases.map(\.rawValue)), expected)
        for config in OpenCCToolConfig.allCases {
            XCTAssertNoThrow(
                try decode(definitionJSON(steps: #"{"type":"opencc","config":"\#(config.rawValue)"}"#)),
                config.rawValue)
        }

        // The bundled data, not the enum, is the source of truth for what is available.
        let repositoryOpenCC =
            URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/EngineResources/opencc")
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: repositoryOpenCC.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw XCTSkip("repository OpenCC resources are not available next to the package")
        }
        let shipped = try FileManager.default.contentsOfDirectory(atPath: repositoryOpenCC.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
        XCTAssertEqual(Set(shipped), expected)
    }

    func testMapStepValidation() {
        XCTAssertNoThrow(
            try decode(
                definitionJSON(steps: #"{"type":"map","table":{"A":"B","🇯🇵":"JP","C":""}}"#)))
        assertRejected(
            definitionJSON(steps: #"{"type":"map","table":{}}"#),
            reason: .invalidField(path: "$.steps[0].table"))
        assertRejected(
            definitionJSON(steps: #"{"type":"map","table":{"AB":"x"}}"#),
            reason: .invalidField(path: "$.steps[0].table.AB"))
        assertRejected(
            definitionJSON(steps: #"{"type":"map","table":{"A":"0123456789abcdefg"}}"#),
            reason: .invalidField(path: "$.steps[0].table.A"))
        let entries = (0..<(ToolDefinitionLimits.maximumMapEntries + 1))
            .map { #""\#(String(UnicodeScalar(UInt32(0x4E00 + $0))!))":"x""# }
            .joined(separator: ",")
        assertRejected(
            definitionJSON(steps: #"{"type":"map","table":{\#(entries)}}"#),
            reason: .invalidField(path: "$.steps[0].table"))
    }

    func testTemplateStepValidation() {
        XCTAssertNoThrow(try decode(definitionJSON(steps: #"{"type":"template","pattern":"<{text}>"}"#)))
        assertRejected(
            definitionJSON(steps: #"{"type":"template","pattern":"plain"}"#),
            reason: .invalidField(path: "$.steps[0].pattern"))
        assertRejected(
            definitionJSON(steps: #"{"type":"template","pattern":"{text}{text}"}"#),
            reason: .invalidField(path: "$.steps[0].pattern"))
        let tooLong = String(repeating: "a", count: ToolDefinitionLimits.maximumPatternUTF16CodeUnits)
        assertRejected(
            definitionJSON(steps: #"{"type":"template","pattern":"\#(tooLong){text}"}"#),
            reason: .invalidField(path: "$.steps[0].pattern"))
    }

    func testPatternAndReplacementBounds() {
        let tooLong = String(repeating: "a", count: ToolDefinitionLimits.maximumPatternUTF16CodeUnits + 1)
        assertRejected(
            definitionJSON(steps: #"{"type":"replace","pattern":"\#(tooLong)","replacement":"x"}"#),
            reason: .invalidField(path: "$.steps[0].pattern"))
        assertRejected(
            definitionJSON(steps: #"{"type":"replace","pattern":"a","replacement":"\#(tooLong)"}"#),
            reason: .invalidField(path: "$.steps[0].replacement"))
        let atLimit = String(repeating: "a", count: ToolDefinitionLimits.maximumPatternUTF16CodeUnits)
        XCTAssertNoThrow(
            try decode(definitionJSON(steps: #"{"type":"replace","pattern":"\#(atLimit)","replacement":""}"#)))
    }

    func testCaseAndWidthModesAreClosedSets() {
        XCTAssertNoThrow(try decode(definitionJSON(steps: #"{"type":"case","mode":"upper"}"#)))
        XCTAssertNoThrow(try decode(definitionJSON(steps: #"{"type":"case","mode":"lower"}"#)))
        XCTAssertNoThrow(try decode(definitionJSON(steps: #"{"type":"case","mode":"capitalize"}"#)))
        XCTAssertNoThrow(try decode(definitionJSON(steps: #"{"type":"width","mode":"toHalf"}"#)))
        XCTAssertNoThrow(try decode(definitionJSON(steps: #"{"type":"width","mode":"toFull"}"#)))
        assertRejected(
            definitionJSON(steps: #"{"type":"case","mode":"UPPER"}"#),
            reason: .invalidField(path: "$.steps[0].mode"))
        assertRejected(
            definitionJSON(steps: #"{"type":"width","mode":"half"}"#),
            reason: .invalidField(path: "$.steps[0].mode"))
        assertRejected(
            definitionJSON(steps: #"{"type":"width","mode":1}"#),
            reason: .invalidField(path: "$.steps[0].mode"))
    }

    // MARK: - Fields, unknown data and defaults

    func testUnknownFieldsAreIgnored() throws {
        let definition = try decode(
            definitionJSON(
                steps: #"{"type":"opencc","config":"s2t","comment":"ignored","flags":{"x":1}}"#,
                name: #"{"zh-Hans":"Hans","zh-Hant":"Hant","ja":"JA","en":"EN","ko":"KO"}"#,
                extra: #","schemaVersion":7,"future":{"a":true}"#))
        XCTAssertEqual(definition.name, ["zh-Hans": "Hans", "zh-Hant": "Hant", "ja": "JA", "en": "EN"])
        XCTAssertEqual(definition.steps, [.opencc(config: .s2t)])
    }

    func testMissingRequiredFieldsRejected() {
        assertRejected(
            #"{"formatVersion":1,"name":\#(Self.fullNameTable),"steps":[{"type":"width","mode":"toHalf"}]}"#,
            reason: .missingField(path: "$.id"))
        assertRejected(
            #"{"formatVersion":1,"id":"sample","steps":[{"type":"width","mode":"toHalf"}]}"#,
            reason: .missingField(path: "$.name"))
        assertRejected(
            #"{"formatVersion":1,"id":"sample","name":\#(Self.fullNameTable)}"#,
            reason: .missingField(path: "$.steps"))
        assertRejected(
            definitionJSON(steps: #"{"mode":"toHalf"}"#),
            reason: .missingField(path: "$.steps[0].type"))
        assertRejected(
            definitionJSON(steps: #"{"type":"opencc"}"#),
            reason: .missingField(path: "$.steps[0].config"))
        assertRejected(
            definitionJSON(steps: #"{"type":"replace","replacement":"x"}"#),
            reason: .missingField(path: "$.steps[0].pattern"))
        assertRejected(
            definitionJSON(steps: #"{"type":"replace","pattern":"a"}"#),
            reason: .missingField(path: "$.steps[0].replacement"))
        assertRejected(
            definitionJSON(steps: #"{"type":"map"}"#),
            reason: .missingField(path: "$.steps[0].table"))
        assertRejected(
            definitionJSON(steps: #"{"type":"case"}"#),
            reason: .missingField(path: "$.steps[0].mode"))
        assertRejected(
            definitionJSON(steps: #"{"type":"template"}"#),
            reason: .missingField(path: "$.steps[0].pattern"))
    }

    func testMalformedFieldTypesRejected() {
        assertRejected(
            definitionJSON(steps: #"{"type":"width","mode":"toHalf"}"#, name: "[]"),
            reason: .invalidField(path: "$.name"))
        assertRejected(
            definitionJSON(steps: #"{"type":"width","mode":"toHalf"}"#, name: #"{"en":5}"#),
            reason: .invalidField(path: "$.name"))
        assertRejected(
            definitionJSON(steps: #"{"type":7}"#),
            reason: .invalidField(path: "$.steps[0].type"))
        assertRejected(
            definitionJSON(steps: #"[]"#),
            reason: .invalidField(path: "$.steps[0]"))
        assertRejected(
            definitionJSON(steps: #"{"type":"map","table":[]}"#),
            reason: .invalidField(path: "$.steps[0].table"))
    }

    func testInvalidIdentifierRejected() {
        let tooLong = String(repeating: "a", count: ToolDefinitionLimits.maximumIdentifierUTF8Bytes + 1)
        for identifier in ["\"\"", #""a b""#, #""id/with/slash""#, #""tööl""#, #""\#(tooLong)""#] {
            assertRejected(
                definitionJSON(steps: #"{"type":"width","mode":"toHalf"}"#, id: identifier),
                reason: .invalidField(path: "$.id"))
        }
        XCTAssertNoThrow(
            try decode(definitionJSON(steps: #"{"type":"width","mode":"toHalf"}"#, id: #""tool_01-A""#)))
    }

    func testInvalidNameTableRejected() {
        let tooLong = String(repeating: "x", count: ToolDefinitionLimits.maximumNameCharacters + 1)
        let cases: [(String, String)] = [
            ("{}", "$.name"),
            (#"{"en":"   "}"#, "$.name.en"),
            (#"{"ko":"KO"}"#, "$.name"),
            (#"{"en":"\#(tooLong)"}"#, "$.name.en"),
        ]
        for (name, path) in cases {
            assertRejected(
                definitionJSON(steps: #"{"type":"width","mode":"toHalf"}"#, name: name),
                reason: .invalidField(path: path))
        }
    }

    func testNameValuesAreTrimmed() throws {
        let definition = try decode(
            definitionJSON(
                steps: #"{"type":"width","mode":"toHalf"}"#, name: #"{"en":"  EN  "}"#))
        XCTAssertEqual(definition.name, ["en": "EN"])
    }

    // MARK: - Name fallback

    func testNameFallbackOrder() throws {
        let step = #"{"type":"width","mode":"toHalf"}"#
        let four = try decode(definitionJSON(steps: step, name: Self.fullNameTable))
        XCTAssertEqual(four.displayName(preferredLanguageTags: ["zh-Hant"]), "Hant")
        XCTAssertEqual(four.displayName(preferredLanguageTags: ["EN"]), "EN")
        XCTAssertEqual(four.displayName(preferredLanguageTags: ["ja"]), "JA")
        XCTAssertEqual(four.displayName(preferredLanguageTags: ["fr-FR"]), "Hans")
        XCTAssertEqual(four.displayName(preferredLanguageTags: []), "Hans")
        // Only exact tags count: a regional tag does not match its base language.
        XCTAssertEqual(four.displayName(preferredLanguageTags: ["ja-JP"]), "Hans")

        let noHans = try decode(
            definitionJSON(steps: step, name: #"{"zh-Hant":"Hant","ja":"JA","en":"EN"}"#))
        XCTAssertEqual(noHans.displayName(preferredLanguageTags: ["fr-FR"]), "EN")
        XCTAssertEqual(noHans.displayName(preferredLanguageTags: ["zh-Hant"]), "Hant")

        let onlyJa = try decode(definitionJSON(steps: step, name: #"{"ja":"JA"}"#))
        XCTAssertEqual(onlyJa.displayName(preferredLanguageTags: []), "JA")
    }

    // MARK: - Round trip and encoding

    func testValidDefinitionRoundTrips() throws {
        let definition = try decode(
            definitionJSON(
                steps: [
                    #"{"type":"opencc","config":"s2twp"}"#,
                    #"{"type":"replace","pattern":"(\\d+)","replacement":"[$1]"}"#,
                    #"{"type":"map","table":{"A":"B"}}"#,
                    #"{"type":"case","mode":"capitalize"}"#,
                    #"{"type":"width","mode":"toFull"}"#,
                    #"{"type":"template","pattern":"<{text}>"}"#,
                ].joined(separator: ",")))
        let encoded = try definition.encoded()
        XCTAssertEqual(try ToolDefinition.decode(encoded), definition)
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(json?["formatVersion"] as? Int, 1)
        XCTAssertEqual(json?["id"] as? String, "sample")
        XCTAssertNotNil(json?["steps"] as? [[String: Any]])
    }

    func testEncodingRejectsInvalidDefinition() {
        let step: ToolStep = .width(mode: .toHalf)
        let cases: [(ToolDefinition, ToolDefinitionError.Reason)] = [
            (ToolDefinition(id: "", name: ["en": "EN"], steps: [step]), .invalidField(path: "$.id")),
            (ToolDefinition(id: "ok", name: [:], steps: [step]), .invalidField(path: "$.name")),
            (ToolDefinition(id: "ok", name: ["en": "EN"], steps: []), .noSteps),
            (
                ToolDefinition(
                    id: "ok", name: ["en": "EN"],
                    steps: Array(repeating: step, count: ToolDefinitionLimits.maximumSteps + 1)),
                .tooManySteps(count: ToolDefinitionLimits.maximumSteps + 1)
            ),
            (
                ToolDefinition(
                    formatVersion: 2, id: "ok", name: ["en": "EN"], steps: [step]),
                .unsupportedFormatVersion("2")
            ),
            (
                ToolDefinition(
                    id: "ok", name: ["en": "EN"],
                    steps: [.replace(pattern: "(", replacement: "x")]),
                .invalidRegex(step: 1)
            ),
        ]
        for (definition, reason) in cases {
            XCTAssertThrowsError(try definition.encoded()) { error in
                XCTAssertEqual((error as? ToolDefinitionError)?.reason, reason)
            }
        }
        XCTAssertNoThrow(
            try ToolDefinition(id: "ok", name: ["en": "EN"], steps: [.opencc(config: .s2t)]).encoded())
    }

    // MARK: - File reading

    func testDecodeFromFileAppliesByteBudgetAndRegularFileRule() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sample.songyantool.json")
            try Data(definitionJSON(steps: #"{"type":"width","mode":"toHalf"}"#).utf8).write(to: file)
            XCTAssertNoThrow(try ToolDefinition.decode(contentsOf: file))

            let folder = directory.appendingPathComponent("folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            assertFileRejected(folder, reason: .notAFile)
            assertFileRejected(
                directory.appendingPathComponent("missing.songyantool.json"), reason: .notAFile)

            let oversized = directory.appendingPathComponent("oversized.songyantool.json")
            try Data(repeating: 0x20, count: ToolDefinitionLimits.maximumFileBytes + 1)
                .write(to: oversized)
            assertFileRejected(
                oversized,
                reason: .fileTooLarge(maximumKilobytes: ToolDefinitionLimits.maximumFileBytes / 1024))
        }
    }

    func testDecodeFromDataAppliesByteBudget() {
        let oversized = Data(repeating: 0x20, count: ToolDefinitionLimits.maximumFileBytes + 1)
        XCTAssertThrowsError(try ToolDefinition.decode(oversized)) { error in
            XCTAssertEqual(
                (error as? ToolDefinitionError)?.reason,
                .fileTooLarge(maximumKilobytes: ToolDefinitionLimits.maximumFileBytes / 1024))
        }
    }

    // MARK: - Human messages

    func testEveryRejectionMessageIsHumanAndLocalized() {
        let reasons: [ToolDefinitionError.Reason] = [
            .notAFile,
            .fileTooLarge(maximumKilobytes: 64),
            .unreadable,
            .unsupportedFormatVersion("2"),
            .missingField(path: "$.name"),
            .invalidField(path: "$.steps[0].pattern"),
            .noSteps,
            .tooManySteps(count: 17),
            .unsupportedStepType(step: 2, type: "translate"),
            .unavailableOpenCCConfig(step: 3, config: "hw2s"),
            .invalidRegex(step: 4),
        ]
        let languages = ToolLanguage.allCases
        XCTAssertEqual(
            Set(languages.map(\.rawValue)), ["zh-Hans", "zh-Hant", "ja", "en"])
        for reason in reasons {
            let error = ToolDefinitionError(reason: reason)
            var messages: [String] = []
            for language in languages {
                let message = error.message(in: language)
                XCTAssertFalse(message.isEmpty, "\(reason) has no \(language) message")
                XCTAssertFalse(message.contains("%"), "\(reason) has an unfilled placeholder")
                XCTAssertFalse(message.contains("{"), "\(reason) has an unsubstituted placeholder")
                XCTAssertFalse(
                    message.hasPrefix("tool.error."),
                    "\(reason) fell back to its catalog key in \(language)")
                XCTAssertEqual(message, message.trimmingCharacters(in: .whitespacesAndNewlines))
                messages.append(message)
            }
            XCTAssertEqual(
                Set(messages).count, languages.count,
                "\(reason) must read differently in each language")
            XCTAssertTrue(
                messages.contains(error.errorDescription ?? ""),
                "\(reason) localizedDescription must pick one of the four messages")
        }
    }

    func testEachReasonReadsInTheRequestedInterfaceLanguage() {
        // Each marker appears in one language's entry only, so a pass proves the explicit
        // per-language bundle was used instead of the source language or the process language.
        let cases: [(ToolDefinitionError.Reason, [ToolLanguage: String])] = [
            (
                .notAFile,
                [
                    .simplifiedChinese: "文件",
                    .traditionalChinese: "檔案",
                    .japanese: "ファイル",
                    .english: "location",
                ]
            ),
            (
                .invalidRegex(step: 4),
                [
                    .simplifiedChinese: "匹配规则",
                    .traditionalChinese: "比對規則",
                    .japanese: "置換ルール",
                    .english: "match rule",
                ]
            ),
        ]
        for (reason, markers) in cases {
            let error = ToolDefinitionError(reason: reason)
            for (language, marker) in markers {
                XCTAssertTrue(
                    error.message(in: language).contains(marker),
                    "\(reason) in \(language) must contain \(marker)")
            }
        }
    }

    func testFailureDetailsAreFilledInEveryLanguage() {
        let cases: [(ToolDefinitionError.Reason, [String])] = [
            (.fileTooLarge(maximumKilobytes: 64), ["64"]),
            (.unsupportedFormatVersion("2"), ["2"]),
            (.missingField(path: "$.name"), ["$.name"]),
            (.invalidField(path: "$.steps[0].pattern"), ["$.steps[0].pattern"]),
            (.tooManySteps(count: 17), ["17", String(ToolDefinitionLimits.maximumSteps)]),
            (.unsupportedStepType(step: 2, type: "translate"), ["2", "translate"]),
            (.unavailableOpenCCConfig(step: 3, config: "hw2s"), ["3", "hw2s"]),
            (.invalidRegex(step: 4), ["4"]),
        ]
        for (reason, details) in cases {
            for language in ToolLanguage.allCases {
                let message = ToolDefinitionError(reason: reason).message(in: language)
                for detail in details {
                    XCTAssertTrue(
                        message.contains(detail),
                        "\(reason) in \(language) is missing \(detail): \(message)")
                }
                XCTAssertFalse(
                    message.contains("%"),
                    "\(reason) in \(language) has an unfilled placeholder: \(message)")
            }
        }
    }

    func testLanguageResolutionFollowsPreferredTags() {
        XCTAssertEqual(ToolLanguage.resolve(preferredLanguageTags: ["en-US", "ja"]), .english)
        XCTAssertEqual(ToolLanguage.resolve(preferredLanguageTags: ["zh-Hant-TW", "en"]), .traditionalChinese)
        XCTAssertEqual(ToolLanguage.resolve(preferredLanguageTags: ["zh-Hant-TW"]), .traditionalChinese)
        XCTAssertEqual(ToolLanguage.resolve(preferredLanguageTags: ["zh-Hans-US"]), .simplifiedChinese)
        XCTAssertEqual(ToolLanguage.resolve(preferredLanguageTags: ["ja-JP"]), .japanese)
        XCTAssertEqual(ToolLanguage.resolve(preferredLanguageTags: ["en-US"]), .english)
        XCTAssertEqual(ToolLanguage.resolve(preferredLanguageTags: ["fr-FR"]), .simplifiedChinese)
        XCTAssertEqual(ToolLanguage.resolve(preferredLanguageTags: []), .simplifiedChinese)
    }
}
