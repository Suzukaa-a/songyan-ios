import Foundation
import KeyboardCore

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

        // The schema's own switches are offered as it words them, except the one the 中/英 key flips.
        let wubi = SchemaOptionCapabilities.parse(
            resourceID: "r", schemaID: "wubi86",
            yaml: """
                switches:
                  - name: ascii_mode
                    reset: 0
                    states: [ 中文, 西文 ]
                  - name: full_shape
                    states: [ 半角, 全角 ]
                  - name: extended_charset
                    states: [ 常用, 增廣 ]
                  - name: ascii_punct
                    states: [ 。，, ．， ]
                """
        ) { _ in nil }
        try check(wubi.map(\.name) == ["full_shape", "extended_charset", "ascii_punct"])
        let declared = wubi.filter(\.isDeclared)
        try check(declared.map(\.name) == ["extended_charset", "ascii_punct"])
        try check(declared.map { [$0.disabledLabel, $0.enabledLabel] } == [["常用", "增廣"], ["。，", "．，"]])
        try check(declared.map(\.title) == ["常用 / 增廣", "。， / ．，"])
        try check(!wubi[0].isDeclared)
        print("PASS declared switches are offered with their state labels, ascii_mode is not")
        let own = SchemaOptionCapabilities.parse(
            resourceID: "r", schemaID: "s",
            yaml: """
                switches:
                  - options: [ pinyin, wubi_form, free ]
                    states: [ 拼音, 五笔, 自由 ]
                    reset: 1
                """
        ) { _ in nil }
        try check(own.map(\.name) == ["pinyin", "wubi_form", "free"])
        try check(own.allSatisfy { $0.isDeclared && $0.choiceGroup == ["pinyin", "wubi_form", "free"] })
        try check(own.map(\.choiceLabel) == ["拼音", "五笔", "自由"])
        print("PASS a group of the schema's own becomes one member per option")
        let bare = SchemaOptionCapabilities.parse(
            resourceID: "r", schemaID: "s",
            yaml: """
                switches:
                  - name: no_labels
                  - name: one_label
                    states: [ 只有一个 ]
                  - options: [ a, b ]
                """
        ) { _ in nil }
        try check(bare.isEmpty)
        print("PASS a switch without two labels or a group without labels stays out")

        // The menu lists every switch and group except ascii_mode: 半角/全角 and the 字形 group as well.
        let menuSchema = SchemaOptionCapabilities.parse(
            resourceID: "r", schemaID: "bopomofo",
            yaml: """
                switches:
                  - name: ascii_mode
                    states: [ 中文, 西文 ]
                  - name: full_shape
                    states: [ 半角, 全角 ]
                  - name: emoji
                  - options: [ zh_hant, zh_hans ]
                    states: [ 漢字, 汉字 ]
                  - name: extended_charset
                    states: [ 常用, 增廣 ]
                engine:
                  filters:
                    - simplifier@faces
                    - simplifier@trad
                    - simplifier@simp
                faces:
                  option_name: emoji
                  opencc_config: arbitrary.json
                trad:
                  option_name: zh_hant
                  opencc_config: s2t.json
                simp:
                  option_name: zh_hans
                  opencc_config: t2s.json
                """
        ) { $0 == "arbitrary.json" ? "Emoji 候选" : ($0 == "s2t.json" ? "繁体输出" : "简体输出") }
        let states = menuSchema.map { EngineOptionState(descriptor: $0, value: $0.name == "zh_hans") }
        let entries = SchemaOptionCapabilities.menuEntries(states)
        try check(!entries.contains { $0.name == "ascii_mode" })
        try check(entries.first { $0.name == "full_shape" }?.title == "半角")
        try check(entries.first { $0.name == "emoji" }?.title == "Emoji 候选")
        try check(entries.first { $0.name == "emoji" }?.subtitle == "关闭")
        try check(entries.filter { ["zh_hant", "zh_hans"].contains($0.name) }.map(\.title) == ["漢字", "汉字"])
        try check(entries.first { $0.name == "zh_hans" }?.subtitle == UserTerminology.userKeyboardCurrent)
        try check(entries.first { $0.name == "extended_charset" }?.title == "常用")
        print("PASS the menu lists full width, the script group and the schema's own switches, not ascii_mode")

        // The same switches as a deployment compiles them: quoted inline lists, abbreviations first.
        let compiled = SchemaOptionCapabilities.parse(
            resourceID: "r", schemaID: "bopomofo_tw",
            yaml: """
                switches:
                  - abbrev: ["中", "Ａ"]
                    name: ascii_mode
                    reset: 0
                    states: ["中文", "西文"]
                  - name: full_shape
                    states: ["半角", "全角"]
                  - abbrev: ["漢", "简", "港", "臺"]
                    options: [zh_hant, zh_hans, zh_hant_hk, zh_hant_tw]
                    reset: 3
                    states: ["傳統漢字", "简化字", "香港字形", "臺灣字形"]
                  - name: ascii_punct
                    states: ["。，", "．，"]
                engine:
                  filters:
                    - simplifier@zh_hans
                    - simplifier@zh_hant_hk
                    - simplifier@zh_hant_tw
                zh_hans:
                  option_name: zh_hans
                  opencc_config: t2s.json
                zh_hant_hk:
                  option_name: zh_hant_hk
                  opencc_config: t2hk.json
                zh_hant_tw:
                  option_name: zh_hant_tw
                  opencc_config: t2tw.json
                """
        ) { _ in "繁体输出" }
        let compiledEntries = SchemaOptionCapabilities.menuEntries(
            compiled.map { EngineOptionState(descriptor: $0, value: false) })
        try check(
            compiledEntries.map(\.title) == ["半角", "傳統漢字", "简化字", "香港字形", "臺灣字形", "。，"])
        print("PASS a compiled schema's switches all reach the menu")
    }
}
