import Foundation

@main struct Probe {
    static func check(_ value: @autoclosure () throws -> Bool) throws {
        let passed = try value()
        precondition(passed)
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let opencc = root.appendingPathComponent("opencc")
        try FileManager.default.createDirectory(at: opencc, withIntermediateDirectories: true)
        let dictionary = opencc.appendingPathComponent("table.txt")
        try "开心\t😄\n".write(to: dictionary, atomically: true, encoding: .utf8)
        let config = """
            {"name":"Emoji","segmentation":{"type":"mmseg","dict":{"type":"text","file":"table.txt"}},
             "conversion_chain":[{"dict":{"type":"group","dicts":[{"type":"text","file":"table.txt"}]}}]}
            """
        try config.write(to: opencc.appendingPathComponent("arbitrary.json"), atomically: true, encoding: .utf8)
        try check(SchemaOptionCapabilities.verifiedOpenCC("arbitrary.json", sharedDirectory: root) == "Emoji 候选")
        try config.replacingOccurrences(of: "\"Emoji\"", with: "\"Cantonese to Emoji\"").write(
            to: opencc.appendingPathComponent("arbitrary.json"), atomically: true, encoding: .utf8)
        try check(SchemaOptionCapabilities.verifiedOpenCC("arbitrary.json", sharedDirectory: root) == "Emoji 候选")
        try FileManager.default.removeItem(at: dictionary)
        try check(SchemaOptionCapabilities.verifiedOpenCC("arbitrary.json", sharedDirectory: root) == nil)
        print("PASS arbitrary OpenCC filename uses config semantics and rejects missing nested dependency")
        let yaml = """
            switches:
              - options:
                  - unchanged
                  - traditional
                  - hongkong
                  - taiwan
                states:
                  - 简体
                  - 通繁
                  - 港繁
                  - 臺繁
              - name: emoji
            engine:
              filters:
                - simplifier@trad
                - simplifier@hk
                - simplifier@tw
                - simplifier@faces
            trad:
              option_name: traditional
              opencc_config: custom-a.json
            hk:
              option_name: hongkong
              opencc_config: t2hk.json
            tw:
              option_name: taiwan
              opencc_config: t2tw.json
            faces:
              option_name: emoji
              opencc_config: arbitrary.json
            """
        let descriptors = SchemaOptionCapabilities.parse(resourceID: "r", schemaID: "s", yaml: yaml) { config in
            config == "arbitrary.json" ? "Emoji 候选" : "繁体输出"
        }
        let group = Array(descriptors.prefix(4))
        try check(group.map(\.name) == ["unchanged", "traditional", "hongkong", "taiwan"])
        try check(group.map(\.choiceLabel) == ["简体", "通繁", "港繁", "臺繁"])
        try check(group.allSatisfy { $0.choiceGroup == group.map(\.name) })
        try check(descriptors.last?.title == "Emoji 候选")
        print("PASS original radio order, untranslated labels, and no-conversion member survive")
        let store = OptionStore(directory: root.appendingPathComponent("options"))
        let cache = OptionPreferenceCache(store: store)
        try await cache.beginRefresh(group).value
        try check(try cache.value(for: group[0]) == nil)
        let first = try await cache.beginSave(true, for: group[1]).value
        try first.result.get()
        for (index, descriptor) in group.enumerated() {
            try check(try store.value(for: descriptor) == (index == 1))
            try check(try cache.value(for: descriptor) == (index == 1))
        }
        let second = cache.beginSave(true, for: group[2])
        let third = cache.beginSave(true, for: group[3])
        _ = try await second.value
        try (await third.value).result.get()
        for (index, descriptor) in group.enumerated() {
            try check(try store.value(for: descriptor) == (index == 3))
            try check(try cache.value(for: descriptor) == (index == 3))
        }
        try await cache.beginRefresh(group).value
        try check(try cache.value(for: group[3]) == true)
        print("PASS group saves and cache restore keep exactly the last selected member")
        let defaults = SchemaOptionCapabilities.parse(
            resourceID: "r", schemaID: "s",
            yaml: """
                switches:
                  - name: simplification
                engine:
                  filters:
                    - simplifier
                """
        ) { $0 == "t2s.json" ? "简体输出" : nil }
        try check(defaults.first?.title == "简体输出")
        print("PASS bare simplifier uses librime default t2s.json")
    }
}
