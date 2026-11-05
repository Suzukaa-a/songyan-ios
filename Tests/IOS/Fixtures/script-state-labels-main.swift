import Foundation
import KeyboardCore

@main struct Probe {
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        if try !value() { fatalError("FAIL: " + label) }
        print("PASS: " + label)
    }

    static func main() async throws {
        let compiledCatalog = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let openccKind: (String) -> String? = { _ in "繁体输出" }
        let bundledYAML = """
            switches:
              - options: [simplification, zht, zh_tw, zh_hk]
                states: [简体, 繁體, 臺灣, 香港]
                reset: 0
            engine:
              filters:
                - simplifier@zht
                - simplifier@zh_tw
                - simplifier@zh_hk
            zht:
              option_name: zht
              opencc_config: s2t.json
            zh_tw:
              option_name: zh_tw
              opencc_config: s2twp.json
            zh_hk:
              option_name: zh_hk
              opencc_config: s2hk.json
            """
        let bundled = SchemaOptionCapabilities.parse(
            resourceID: "songyan-builtin", schemaID: "songyan_quanpin",
            yaml: bundledYAML, openccKind: openccKind)
        try check(
            bundled.map(\.name) == ["simplification", "zht", "zh_tw", "zh_hk"],
            "the bundled scheme keeps its four members")
        try check(
            bundled.map(\.knownScriptState) == [.simplified, .traditional, .taiwan, .hongKong],
            "the bundled scheme's four states are recognized")
        try check(
            bundled.map(\.choiceLabel) == ["简体", "繁體", "臺灣", "香港"],
            "the schema's own labels stay on the descriptors")

        let customYAML = bundledYAML.replacingOccurrences(
            of: "states: [简体, 繁體, 臺灣, 香港]", with: "states: [簡体, 通繁, 臺繁, 港繁]")
        let custom = SchemaOptionCapabilities.parse(
            resourceID: "scheme-abc", schemaID: "songyan_quanpin",
            yaml: customYAML, openccKind: openccKind)
        try check(
            custom.count == 4 && custom.allSatisfy { $0.knownScriptState == nil },
            "a scheme that words its own states is not recognized")
        try check(
            custom.map(\.choiceLabel) == ["簡体", "通繁", "臺繁", "港繁"],
            "a custom group keeps its own labels")

        let foreign = SchemaOptionCapabilities.parse(
            resourceID: "scheme-abc", schemaID: "luna_pinyin",
            yaml: bundledYAML, openccKind: openccKind)
        try check(
            foreign.count == 4 && foreign.allSatisfy { $0.knownScriptState == nil },
            "a scheme outside the bundled ones is never recognized")

        // The words the UI shows come from the compiled catalog through the shared adapter.
        guard let catalogBundle = Bundle(path: compiledCatalog.path) else {
            fatalError("FAIL: compiled catalog bundle unreadable")
        }
        for state in BuiltinScriptState.allCases {
            print("LABEL \(state.optionName) \(ScriptStateLabels.label(for: state, in: catalogBundle))")
        }

        // Selection keeps exactly one of the four states and reads it back from real files.
        let storeDirectory = compiledCatalog.deletingLastPathComponent()
            .appendingPathComponent("option-store", isDirectory: true)
        for (index, state) in BuiltinScriptState.allCases.enumerated() {
            let member = bundled[index]
            _ = try await OptionPreferenceCache(store: OptionStore(directory: storeDirectory))
                .beginSave(true, for: member).value.result.get()
            let reopened = OptionStore(directory: storeDirectory)
            try check(try reopened.value(for: member) == true, "\(state.optionName) persists as selected")
            for other in bundled where other.name != member.name {
                try check(try reopened.value(for: other) == false, "\(state.optionName) clears \(other.name)")
            }
        }
        let groupFile = storeDirectory.appendingPathComponent(
            ["songyan-builtin", "songyan_quanpin", "simplification"]
                .map { name in name.utf8.map { String(format: "%02x", $0) }.joined() }
                .joined(separator: "/") + ".json")
        try check(
            FileManager.default.fileExists(atPath: groupFile.path),
            "one choice per input method is stored under the group's first name")
        print("script state labels checks passed")
    }
}
