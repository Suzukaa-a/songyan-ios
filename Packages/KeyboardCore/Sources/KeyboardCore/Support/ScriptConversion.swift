import Foundation

/// The scheme's own declared script conversion. Only a config that converts script decides the
/// input language: other active simplifiers (emoji, or a converter this table does not know)
/// must neither be guessed at nor hide the script switch that is really on.
public enum ScriptConversion {
    /// OpenCC configs whose output is traditional Chinese.
    public static let traditionalConfigs: Set<String> = ["s2t", "s2tw", "s2twp", "s2hk", "t2tw", "t2hk"]
    /// OpenCC configs whose output is simplified Chinese.
    public static let simplifiedConfigs: Set<String> = ["t2s", "tw2s", "tw2sp", "hk2s"]

    /// The bare config name of a schema declaration: a path and a `.json` extension are the
    /// schema's spelling, not part of the name.
    public static func bareConfigName(_ declared: String) -> String? {
        let trimmed = declared.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = (trimmed as NSString).lastPathComponent
        let base = name.hasSuffix(".json") ? String(name.dropLast(".json".count)) : name
        return base.isEmpty ? nil : base
    }

    /// The active declared script config, or nil when none is active or the active configs
    /// disagree on the direction. Several converters pointing the same way are not a conflict.
    /// An unknown config is not script evidence, so it is ignored rather than failing the switch.
    public static func activeDeclaredConfig(in options: [EngineOptionState]) -> String? {
        var active = Set<String>()
        for option in options where option.value {
            guard let declared = option.descriptor.declaredConversion,
                let bare = bareConfigName(declared),
                traditionalConfigs.contains(bare) || simplifiedConfigs.contains(bare)
            else { continue }
            active.insert(bare)
        }
        let simplified = active.intersection(simplifiedConfigs)
        let traditional = active.subtracting(simplifiedConfigs)
        // Several converters that agree on the direction are not a conflict; the resolver only
        // decides the script from one name, so any of them stands for the group.
        if simplified.isEmpty { return traditional.sorted().first }
        if traditional.isEmpty { return simplified.sorted().first }
        // Traditional and simplified converters are on together: no single script is proven.
        return nil
    }
}
