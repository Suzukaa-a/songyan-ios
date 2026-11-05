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
