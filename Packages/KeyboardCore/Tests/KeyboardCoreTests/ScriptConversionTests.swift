import XCTest

@testable import KeyboardCore

/// Which declared conversion config decides the script of a scheme, and how the bare config name
/// is read from a schema's spelling.
final class ScriptConversionTests: XCTestCase {
    private func descriptor(_ name: String, declared: String?) -> EngineOptionDescriptor {
        EngineOptionDescriptor(
            resourceID: "res", schemaID: "rime_ice", name: name, title: name,
            disabledLabel: "关闭", enabledLabel: "开启", declaredConversion: declared)
    }

    private func option(_ name: String, _ value: Bool, declared: String?) -> EngineOptionState {
        EngineOptionState(descriptor: descriptor(name, declared: declared), value: value)
    }

    func testUnrelatedActiveSimplifierDoesNotHideTheScriptSwitch() {
        // 雾凇 keeps emoji and 简繁 on together; only the script config may decide the language.
        let both = [
            option("emoji", true, declared: "emoji"),
            option("traditionalization", true, declared: "s2t"),
        ]
        XCTAssertEqual(ScriptConversion.activeDeclaredConfig(in: both), "s2t")
        XCTAssertEqual(
            InputLanguageResolver.resolve(
                schemaID: "rime_ice", alphabet: "abcdefghijklmnopqrstuvwxyz", declaredConversion: "s2t"
            )
            .language,
            .traditionalChinese)

        let emojiOnly = [
            option("emoji", true, declared: "emoji"),
            option("traditionalization", false, declared: "s2t"),
        ]
        XCTAssertNil(ScriptConversion.activeDeclaredConfig(in: emojiOnly))
        XCTAssertEqual(
            InputLanguageResolver.resolve(
                schemaID: "rime_ice", alphabet: "abcdefghijklmnopqrstuvwxyz", declaredConversion: nil
            )
            .language,
            .simplifiedChinese)
    }

    func testSeveralConvertersPointingTheSameWayAreNotAConflict() {
        let traditional = [
            option("traditionalization", true, declared: "s2t.json"),
            option("taiwan", true, declared: "s2tw.json"),
        ]
        let hantConfig = ScriptConversion.activeDeclaredConfig(in: traditional)
        XCTAssertNotNil(hantConfig)
        XCTAssertEqual(
            InputLanguageResolver.resolve(
                schemaID: "rime_ice", alphabet: "abcdefghijklmnopqrstuvwxyz", declaredConversion: hantConfig
            ).language,
            .traditionalChinese)

        let simplified = [
            option("simplification", true, declared: "t2s.json"),
            option("taiwan_simplified", true, declared: "tw2s.json"),
        ]
        let hansConfig = ScriptConversion.activeDeclaredConfig(in: simplified)
        XCTAssertNotNil(hansConfig)
        XCTAssertEqual(
            InputLanguageResolver.resolve(
                schemaID: "rime_ice", alphabet: "abcdefghijklmnopqrstuvwxyz", declaredConversion: hansConfig
            ).language,
            .simplifiedChinese)
    }

    func testConflictingScriptConfigsFailClosed() {
        let options = [
            option("traditionalization", true, declared: "s2t"),
            option("hk_simplified", true, declared: "hk2s.json"),
        ]
        XCTAssertNil(ScriptConversion.activeDeclaredConfig(in: options))
        XCTAssertEqual(
            InputLanguageResolver.resolve(
                schemaID: "rime_ice", alphabet: "abcdefghijklmnopqrstuvwxyz",
                declaredConversion: ScriptConversion.activeDeclaredConfig(in: options)
            ).language,
            .simplifiedChinese)
    }

    func testUnknownScriptConverterIsIgnored() {
        XCTAssertNil(ScriptConversion.activeDeclaredConfig(in: [option("hk", true, declared: "t2hkf.json")]))
        let mixed = [
            option("hk", true, declared: "t2hkf.json"),
            option("traditionalization", true, declared: "s2t"),
        ]
        XCTAssertEqual(ScriptConversion.activeDeclaredConfig(in: mixed), "s2t")
    }

    func testBareConfigNameReadsTheSchemaSpelling() {
        XCTAssertEqual(ScriptConversion.bareConfigName("s2tw.json"), "s2tw")
        XCTAssertEqual(ScriptConversion.bareConfigName("opencc/t2tw.json"), "t2tw")
        XCTAssertEqual(ScriptConversion.bareConfigName("emoji.json"), "emoji")
        XCTAssertEqual(ScriptConversion.bareConfigName(" t2hk.json "), "t2hk")
        XCTAssertNil(ScriptConversion.bareConfigName(""))
        XCTAssertNil(ScriptConversion.bareConfigName("  "))
    }

    func testChoiceGroupMemberUsesItsOwnDeclaredConfig() {
        // 注音 lists zh_hans / zh_hant_hk / zh_hant_tw as radio members, each with its config.
        let options = [
            option("zh_hans", false, declared: "t2s.json"),
            option("zh_hant_hk", false, declared: "t2hk.json"),
            option("zh_hant_tw", true, declared: "t2tw.json"),
        ]
        XCTAssertEqual(ScriptConversion.activeDeclaredConfig(in: options), "t2tw")
        XCTAssertEqual(
            InputLanguageResolver.resolve(
                schemaID: "bopomofo_tw", alphabet: "", declaredConversion: "t2tw"
            ).language,
            .traditionalChinese)
    }
}
