import Foundation

/// The text a new file of the user's starts as. It is the user's file content, not interface text.
public enum RimeConfigTemplates {
    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s*[\\r\\n]+\\s*", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// A new `xxx.custom.yaml`: valid YAML that patches nothing, with two comment lines and a commented example.
    public static func customPatch() -> String {
        [
            "# " + oneLine("在 patch 下写要改的项，改完回到松烟轻点「应用更改」。"),
            "# " + oneLine("例：每页显示 7 个候选"),
            "# patch:",
            "#   menu/page_size: 7",
            "patch: {}",
        ].joined(separator: "\n") + "\n"
    }

    /// A new script: a comment on how to name it from a configuration file, the line that does it, and a
    /// filter that passes every candidate through.
    public static func script(name: String) -> String {
        let hint = "在配置文件里写上 lua_filter@*\(name) 就会用到它（也可以是 lua_translator、lua_processor、lua_segmentor）。"
        return [
            "-- " + oneLine(hint),
            "-- engine/filters/+: [lua_filter@*\(name)]",
            "return {",
            "  func = function(input, env)",
            "    for cand in input:iter() do",
            "      yield(cand)",
            "    end",
            "  end,",
            "}",
        ].joined(separator: "\n") + "\n"
    }
}

/// Commented-out grammar model parameters appended to the file an input method's grammar settings open,
/// so the user sees what can be tuned. Comments only: nothing changes until the user removes the `#`.
/// The lines work under whatever `patch:` the file already has, and the heading says so.
public enum GrammarParameterExample {
    static let parameters = [
        "grammar/collocation_max_length: 6",
        "grammar/collocation_min_length: 2",
        "grammar/collocation_penalty: -14",
        "grammar/non_collocation_penalty: -6",
        "grammar/weak_collocation_penalty: -100",
        "grammar/rear_penalty: -18",
        "translator/contextual_suggestions: false",
        "translator/max_homophones: 8",
    ]

    /// Which heading fits the file: it has no `patch:`, one with entries, or the empty `patch: {}` of a new file.
    public enum Heading: Sendable {
        case newPatch, underPatch, emptyPatch

        var text: String {
            switch self {
            case .newPatch: return "语法模型参数示例（去掉行首的 # 后生效）："
            case .underPatch: return "语法模型参数示例（去掉行首的 # 后生效，这些行要放在上面的 patch: 下面）："
            case .emptyPatch: return "语法模型参数示例（先把上面的 patch: {} 改成 patch:，再去掉行首的 # 后生效）："
            }
        }
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The heading `text` needs, or nil when it already holds grammar parameters (written or as this example).
    public static func heading(for text: String) -> Heading? {
        if matches("grammar/|(?m)^\\s+grammar:", text) { return nil }
        if matches("(?m)^patch:\\s*\\{\\s*\\}\\s*(#.*)?$", text) { return .emptyPatch }
        if matches("(?m)^patch:\\s*(#.*)?$", text) { return .underPatch }
        return .newPatch
    }

    /// `text` with the example appended; unchanged when it has grammar parameters already.
    public static func appended(to text: String) -> String {
        guard let heading = heading(for: text) else { return text }
        var body = "# " + heading.text + "\n"
        if heading == .newPatch { body += "# patch:\n" }
        for line in parameters { body += "#   " + line + "\n" }
        let separator = text.isEmpty || text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
        return text + separator + body
    }
}
