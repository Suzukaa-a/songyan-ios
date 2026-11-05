import Foundation

/// Stable option names of the bundled scheme's exclusive script group (the Basic package declares
/// them in one `switches` radio group: 简体 / 繁體 / 臺灣 / 香港).
/// The bundled scheme runs under two resource ids: the installed package (`songyan-builtin`) and
/// the bundled fallback (`builtin`). They are one user-visible scheme, so its switch choice keeps
/// one option-store namespace; other sources are untouched.
public enum BuiltinScriptIdentity {
    public static let packageResourceID = "songyan-builtin"
    public static let fallbackResourceID = "builtin"

    public static func isBuiltin(_ resourceID: String) -> Bool {
        resourceID == packageResourceID || resourceID == fallbackResourceID
    }

    public static func optionStoreResourceID(_ resourceID: String) -> String {
        isBuiltin(resourceID) ? packageResourceID : resourceID
    }
}

public enum BuiltinScriptState: String, CaseIterable, Sendable {
    case simplified = "simplification"
    case traditional = "zht"
    case taiwan = "zh_tw"
    case hongKong = "zh_hk"

    public var optionName: String { rawValue }

    /// The labels the bundled scheme declares for its four states, in schema order. A scheme that
    /// words or reorders them itself is not the bundled group, so its own labels stay as written.
    public static let canonicalSchemaLabels = ["简体", "繁體", "臺灣", "香港"]

    /// The bundled scheme's one exclusive four-state group, recognized by the scheme it belongs to
    /// (the bundled source schemes) and its complete, unchanged declaration. nil for every other
    /// scheme, including a custom group that happens to reuse the same option names.
    public static func knownStates(
        schemaID: String, options: [String], labels: [String]
    ) -> [BuiltinScriptState]? {
        guard BuiltinTemplateSchemas.sourceSchemaIDs.contains(schemaID) else { return nil }
        guard options == allCases.map(\.optionName), labels == canonicalSchemaLabels else { return nil }
        return allCases
    }
}

/// A locale may seed a new installation, never replace an existing user's choice (including an
/// existing user who never touched the script switch: the schema's own reset keeps 简体).
public enum TraditionalDefault {
    /// The schema's group order; the persisted choice is keyed by its first member.
    public static let optionGroup: [String] = BuiltinScriptState.allCases.map(\.optionName)

    /// The state a brand-new install should start in, or nil when the install already has settings.
    public static func initialState(
        localeTags: [String], hasExistingSettings: Bool
    ) -> BuiltinScriptState? {
        if hasExistingSettings { return nil }
        let locale = Locale(identifier: localeTags.first ?? "")
        let script = locale.language.script?.identifier ?? ""
        let region = locale.language.region?.identifier ?? ""
        // CLDR returns an empty script for plain "zh-TW"/"zh-HK"/"zh-MO", so the region decides
        // there; an explicit script always wins (zh-Hans-TW stays simplified).
        let traditional =
            script == "Hant"
            || (script.isEmpty && locale.language.languageCode?.identifier == "zh"
                && TRADITIONAL_REGIONS.contains(region))
        guard traditional else { return .simplified }
        switch region {
        case "TW": return .taiwan
        case "HK", "MO": return .hongKong
        default: return .traditional
        }
    }

    /// Where the host records, before its own bootstrap writes, whether this app data predates the
    /// script switch. The keyboard boot reads it; without it the extension can only judge its own data.
    public static let installEraKey = "builtin.scriptDefault.installEra"

    /// nil keeps what the installation already has: an install that predates the switch (host era or
    /// the extension's own data) is never re-seeded. A saved script choice is decided per input
    /// method inside `BuiltinScriptDefault.seedIfNeeded`.
    public static func seedState(
        for evidence: BuiltinScriptBootstrapEvidence, localeTags: [String]
    ) -> BuiltinScriptState? {
        if evidence.hostEra == .legacy || evidence.hasLegacyLocalData { return nil }
        // Shared data proves an old install only when the host has not recorded this version's era:
        // on a fresh install the host publishes its first selection before the keyboard boots, and
        // that current-run selection must not make a new install look upgraded.
        if evidence.hostEra == nil && evidence.hasPriorSharedData { return nil }
        return initialState(localeTags: localeTags, hasExistingSettings: false)
    }

    private static let TRADITIONAL_REGIONS: Set<String> = ["TW", "HK", "MO"]
}

/// Before the first seed: an install that already existed keeps its old script output.
public enum BuiltinScriptInstallEra: String, Sendable {
    case legacy
    case current
}

/// The extension's own one-time era record: it has its own container even without Full Access, and
/// it is written before any source's engine writes the user directory, so this run's data (an
/// imported dictionary, a deploy) can never make the install look old on a later boot.
public enum BuiltinScriptEraRecord {
    public static let key = "builtin.scriptDefault.extensionEra"

    /// Host-side evidence that the app already held built-in data before this bootstrap: an
    /// installation, its bundled-revision record (content revision is not an install time), or any
    /// prior user setting. Fresh means none of them.
    public static func hostIndicatesExistingInstall(
        installed: Bool, recorded: Bool, userSettings: Bool
    ) -> Bool {
        installed || recorded || userSettings
    }

    public static func decideAndRecord(
        hostEra: BuiltinScriptInstallEra?, userDirectory: URL, defaults: UserDefaults,
        savedLayoutKey: String = ""
    ) -> BuiltinScriptInstallEra {
        if let recorded = defaults.string(forKey: key).flatMap(BuiltinScriptInstallEra.init(rawValue:)) {
            return recorded
        }
        let privateData =
            !((try? FileManager.default.contentsOfDirectory(atPath: userDirectory.path)) ?? []).isEmpty
        let savedLayout =
            !savedLayoutKey.isEmpty && defaults.string(forKey: savedLayoutKey) != nil
        let era: BuiltinScriptInstallEra =
            (privateData || savedLayout || hostEra == .legacy) ? .legacy : .current
        defaults.set(era.rawValue, forKey: key)
        return era
    }
}

/// What the process can prove about an install before it writes anything: the host's pre-bootstrap
/// era record and the process's own pre-existing engine data. A saved script choice is per input
/// method, so `BuiltinScriptDefault.seedIfNeeded` keeps it through its own read step.
public struct BuiltinScriptBootstrapEvidence: Sendable {
    public var hostEra: BuiltinScriptInstallEra?
    /// This process's own engine data (a deploy or learning store written before this boot).
    public var hasLegacyLocalData: Bool
    /// Shared/publication data that may also be this run's first selection, so the host era decides.
    public var hasPriorSharedData: Bool

    public init(
        hostEra: BuiltinScriptInstallEra? = nil,
        hasLegacyLocalData: Bool = false,
        hasPriorSharedData: Bool = false
    ) {
        self.hostEra = hostEra
        self.hasLegacyLocalData = hasLegacyLocalData
        self.hasPriorSharedData = hasPriorSharedData
    }
}

/// Writes the locale default into the persisted switch choice of a new installation. The caller
/// supplies the evidence that this is a first install and the writer that persists one group choice
/// per built-in input method; an existing install returns nil and never touches the store.
public enum BuiltinScriptDefault {
    public static func descriptor(
        resourceID: String, schemaID: String, state: BuiltinScriptState
    ) -> EngineOptionDescriptor {
        EngineOptionDescriptor(
            resourceID: resourceID, schemaID: schemaID, name: state.optionName,
            title: "字形", disabledLabel: state.optionName, enabledLabel: state.optionName,
            choiceGroup: TraditionalDefault.optionGroup, choiceLabel: state.optionName)
    }

    /// What the one seeding rule actually did per input method; a schema it could not read or write
    /// is reported, never claimed.
    public struct SeedOutcome: Equatable, Sendable {
        public let state: BuiltinScriptState
        public let seededSchemaIDs: [String]
        public let failedSchemaIDs: [String]
        public var isComplete: Bool { failedSchemaIDs.isEmpty }
    }

    /// The single seeding rule: the keyboard boot and the production-source probe both call this.
    /// `readChoice` reports whether an input method already has a group choice; a read failure means
    /// the choice is unknown, so that input method is reported and its stored file is never
    /// overwritten. `write` persists one descriptor. Returns nil when this is not a first install.
    @discardableResult
    public static func seedIfNeeded(
        evidence: BuiltinScriptBootstrapEvidence, localeTags: [String],
        resourceID: String, schemaIDs: [String],
        readChoice: (String) throws -> Bool,
        write: (EngineOptionDescriptor) throws -> Void
    ) -> SeedOutcome? {
        guard let state = TraditionalDefault.seedState(for: evidence, localeTags: localeTags)
        else { return nil }
        var seeded: [String] = []
        var failed: [String] = []
        for schemaID in schemaIDs {
            let hasChoice: Bool
            do {
                hasChoice = try readChoice(schemaID)
            } catch {
                // Unknown is not "no choice": keeping the stored file is the only safe answer.
                failed.append(schemaID)
                continue
            }
            guard !hasChoice else { continue }
            let option = descriptor(resourceID: resourceID, schemaID: schemaID, state: state)
            do {
                try write(option)
                seeded.append(schemaID)
            } catch {
                failed.append(schemaID)
            }
        }
        return SeedOutcome(state: state, seededSchemaIDs: seeded, failedSchemaIDs: failed)
    }
}
