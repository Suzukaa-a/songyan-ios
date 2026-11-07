import Foundation

/// The display language of an input method. It follows the scheme, not the system or app
/// language, so one keyboard keeps its keys and punctuation when the app UI language changes.
public enum InputLanguage: String, Sendable, Equatable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
}

/// The keyboard family a scheme belongs to. `generic` adds no restriction: a scheme this table
/// does not know keeps today's behaviour and is never guessed to be pinyin or zhuyin.
public enum InputSchemeFamily: String, Sendable, Equatable {
    case generic
    case japanese
    case zhuyin
    case cangjieRadicals
    case latinPhonetic
}

/// What the front end needs to know about one scheme's input language.
public struct InputLanguageProfile: Equatable, Sendable {
    public let language: InputLanguage
    public let family: InputSchemeFamily

    public init(language: InputLanguage, family: InputSchemeFamily) {
        self.language = language
        self.family = family
    }
}

/// One ordered table decides the language and family of a scheme. A known family wins over the
/// scheme's declared conversion, so a zhuyin scheme showing simplified output stays zhuyin.
/// Unknown facts fail closed to today's simplified behaviour instead of guessing.
public enum InputLanguageResolver {
    /// `alphabet` is the scheme's `speller/alphabet`; empty means unknown.
    /// `declaredConversion` is the OpenCC config the scheme currently declares as active
    /// (`s2t` and the like), or nil when no conversion is active. Only the exact bare names in
    /// the table count: paths and extensions belong to the caller, and an unknown name must not
    /// become traditional output.
    public static func resolve(
        schemaID: String, alphabet: String, declaredConversion: String? = nil
    ) -> InputLanguageProfile {
        if schemaID.hasPrefix("kagiroi") {
            return InputLanguageProfile(language: .japanese, family: .japanese)
        }
        if schemaID.hasPrefix("bopomofo") || isBopomofoAlphabet(alphabet) {
            return InputLanguageProfile(language: .traditionalChinese, family: .zhuyin)
        }
        if schemaID.hasPrefix("cangjie") || schemaID.hasPrefix("quick") {
            return InputLanguageProfile(language: .traditionalChinese, family: .cangjieRadicals)
        }
        if schemaID.hasPrefix("jyut6ping3") {
            return InputLanguageProfile(language: .traditionalChinese, family: .latinPhonetic)
        }
        if let declaredConversion, traditionalConversions.contains(declaredConversion) {
            return InputLanguageProfile(language: .traditionalChinese, family: .generic)
        }
        return InputLanguageProfile(language: .simplifiedChinese, family: .generic)
    }

    /// 大千 layouts start with the contiguous row `1qaz2wsx`; the punctuation keys follow the
    /// schema's own order, so every one of `-;,./` must be present rather than that exact string.
    private static func isBopomofoAlphabet(_ alphabet: String) -> Bool {
        alphabet.contains("1qaz2wsx") && Set("-;,./").isSubset(of: Set(alphabet))
    }

    /// OpenCC configs whose output is traditional Chinese. `t2s` converts the other way, and
    /// anything not listed here is unknown, so neither is treated as traditional output.
    private static let traditionalConversions: Set<String> = [
        "s2t", "s2tw", "s2twp", "s2hk", "t2tw", "t2hk",
    ]
}

/// Physical keyboard availability, shared by the host app and the keyboard.
///
/// A keyboard shape is a front-end capability, not a brand: the 26-key shape serves every scheme
/// family, while the folded layouts stay with the schemes that keep today's behaviour (`generic`).
/// Future physical layouts are authored as layout definitions; their IDs are reserved here so an
/// unregistered definition is never offered and a registered one is only offered to its own
/// family. Unknown IDs keep the legacy behaviour, so an ordinary user layout is never restricted.
public enum InputLayoutPolicy {
    /// The scheme family for a schema ID, using the declared alphabet when it is known. This is the
    /// same resolver the running session uses, so every surface agrees on the family.
    public static func family(schemaID: String, alphabet: String = "") -> InputSchemeFamily {
        InputLanguageResolver.resolve(schemaID: schemaID, alphabet: alphabet).family
    }

    /// The family from one source's own descriptor snapshot. The same schema ID may exist in
    /// several sources with different alphabets, so callers pass the descriptors of the keyboard's
    /// source; this never searches other sources, and a missing descriptor keeps the ID-only facts.
    public static func family(
        schemaID: String, descriptors: [KeyboardSchemaDescriptor]
    ) -> InputSchemeFamily {
        let alphabet = descriptors.first { $0.id == schemaID }?.alphabet ?? ""
        return family(schemaID: schemaID, alphabet: alphabet)
    }

    /// Whether a physical shape may be used by a scheme of this family.
    public static func allows(kind: KeyboardLayoutKind, family: InputSchemeFamily) -> Bool {
        switch kind {
        case .qwerty26: return true
        case .merged14, .merged18, .phone9: return family == .generic || family == .latinPhonetic
        }
    }

    /// Whether any folded (14 / 18 / 9-key) layout may be generated for a scheme of this family.
    /// Families with their own physical layout (zhuyin, cangjie radicals, japanese) never offer the
    /// folded shapes; generic and latin-phonetic schemes fold like any other.
    public static func allowsCompactLayouts(family: InputSchemeFamily) -> Bool {
        KeyboardLayoutKind.allCases.filter(\.requiresSpellingDisplay).contains {
            allows(kind: $0, family: family)
        }
    }

    /// The family a reserved physical layout ID belongs to; nil keeps the legacy behaviour.
    public static func family(ofPhysicalLayoutID id: String) -> InputSchemeFamily? {
        switch id {
        case "zhuyin41": return .zhuyin
        case "cangjie26": return .cangjieRadicals
        case "romaji26", "kana12": return .japanese
        default: return nil
        }
    }

    /// Whether a layout definition ID may be used by a scheme of this family.
    public static func allows(physicalLayoutID id: String, family: InputSchemeFamily) -> Bool {
        guard let owner = InputLayoutPolicy.family(ofPhysicalLayoutID: id) else { return true }
        return owner == family
    }

    /// The physical layout a family prefers once its definition is registered; nil keeps the shape
    /// preset as the default.
    public static func preferredPhysicalLayoutID(family: InputSchemeFamily) -> String? {
        switch family {
        case .zhuyin: return "zhuyin41"
        case .cangjieRadicals: return "cangjie26"
        case .japanese: return "romaji26"
        case .latinPhonetic, .generic: return nil
        }
    }
}
