import Foundation

/// Compiled kana -> romaji table for the 12-key Japanese (kana12) layout.
///
/// kagiroi's speller converts the romanization to kana inside the composition, so the front end
/// only ever sends ordinary code keys and the composition already shows kana when a BackSpace
/// arrives. Every entry was verified against the frozen engine data: each surface types alone as
/// itself, and every ordered pair of surfaces types as the two surfaces concatenated (82 singles
/// and 82 x 82 ordered pairs, no failures), so two adjacent kana never get split differently.
/// The table is a Swift literal on purpose: the keyboard thread must never load JSON.
///
/// Surfaces the frozen data also produces but the 12-key grid cannot reach (ゔ, ゐ, ゑ, ゕ, ゖ,
/// いぇ, ...) are deliberately absent; adding one needs new native pair evidence first.
public enum Kana12RomajiTable {
    public struct Entry: Equatable, Sendable {
        public let kana: String
        public let romaji: String
    }

    /// The verified surfaces in native artifact order: base, dakuten, handakuten, small.
    public static let entries: [Entry] = [
        Entry(kana: "あ", romaji: "a"), Entry(kana: "い", romaji: "i"), Entry(kana: "う", romaji: "u"),
        Entry(kana: "え", romaji: "e"), Entry(kana: "お", romaji: "o"),
        Entry(kana: "か", romaji: "ka"), Entry(kana: "き", romaji: "ki"), Entry(kana: "く", romaji: "ku"),
        Entry(kana: "け", romaji: "ke"), Entry(kana: "こ", romaji: "ko"),
        Entry(kana: "さ", romaji: "sa"), Entry(kana: "し", romaji: "si"), Entry(kana: "す", romaji: "su"),
        Entry(kana: "せ", romaji: "se"), Entry(kana: "そ", romaji: "so"),
        Entry(kana: "た", romaji: "ta"), Entry(kana: "ち", romaji: "ti"), Entry(kana: "つ", romaji: "tu"),
        Entry(kana: "て", romaji: "te"), Entry(kana: "と", romaji: "to"),
        Entry(kana: "な", romaji: "na"), Entry(kana: "に", romaji: "ni"), Entry(kana: "ぬ", romaji: "nu"),
        Entry(kana: "ね", romaji: "ne"), Entry(kana: "の", romaji: "no"),
        Entry(kana: "は", romaji: "ha"), Entry(kana: "ひ", romaji: "hi"), Entry(kana: "ふ", romaji: "hu"),
        Entry(kana: "へ", romaji: "he"), Entry(kana: "ほ", romaji: "ho"),
        Entry(kana: "ま", romaji: "ma"), Entry(kana: "み", romaji: "mi"), Entry(kana: "む", romaji: "mu"),
        Entry(kana: "め", romaji: "me"), Entry(kana: "も", romaji: "mo"),
        Entry(kana: "や", romaji: "ya"), Entry(kana: "ゆ", romaji: "yu"), Entry(kana: "よ", romaji: "yo"),
        Entry(kana: "ら", romaji: "ra"), Entry(kana: "り", romaji: "ri"), Entry(kana: "る", romaji: "ru"),
        Entry(kana: "れ", romaji: "re"), Entry(kana: "ろ", romaji: "ro"),
        Entry(kana: "わ", romaji: "wa"), Entry(kana: "を", romaji: "wo"), Entry(kana: "ん", romaji: "nn"),
        // "-" is the key the verified kagiroi data converts to ー; it is not a Rime token.
        Entry(kana: "ー", romaji: "-"),
        Entry(kana: "が", romaji: "ga"), Entry(kana: "ぎ", romaji: "gi"), Entry(kana: "ぐ", romaji: "gu"),
        Entry(kana: "げ", romaji: "ge"), Entry(kana: "ご", romaji: "go"),
        Entry(kana: "ざ", romaji: "za"), Entry(kana: "じ", romaji: "zi"), Entry(kana: "ず", romaji: "zu"),
        Entry(kana: "ぜ", romaji: "ze"), Entry(kana: "ぞ", romaji: "zo"),
        Entry(kana: "だ", romaji: "da"), Entry(kana: "ぢ", romaji: "di"), Entry(kana: "づ", romaji: "du"),
        Entry(kana: "で", romaji: "de"), Entry(kana: "ど", romaji: "do"),
        Entry(kana: "ば", romaji: "ba"), Entry(kana: "び", romaji: "bi"), Entry(kana: "ぶ", romaji: "bu"),
        Entry(kana: "べ", romaji: "be"), Entry(kana: "ぼ", romaji: "bo"),
        Entry(kana: "ぱ", romaji: "pa"), Entry(kana: "ぴ", romaji: "pi"), Entry(kana: "ぷ", romaji: "pu"),
        Entry(kana: "ぺ", romaji: "pe"), Entry(kana: "ぽ", romaji: "po"),
        Entry(kana: "ぁ", romaji: "la"), Entry(kana: "ぃ", romaji: "li"), Entry(kana: "ぅ", romaji: "lu"),
        Entry(kana: "ぇ", romaji: "le"), Entry(kana: "ぉ", romaji: "lo"),
        Entry(kana: "ゃ", romaji: "lya"), Entry(kana: "ゅ", romaji: "lyu"), Entry(kana: "ょ", romaji: "lyo"),
        Entry(kana: "っ", romaji: "ltu"),
        // ゎ is only reachable through the 小゛゜ cycle (わ -> ゎ); the pair matrix proves it.
        Entry(kana: "ゎ", romaji: "lwa"),
    ]

    private static let lookup: [String: String] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.kana, $0.romaji) })

    /// The code to send to the engine for `kana`, or nil for a glyph outside the verified set.
    public static func romaji(for kana: String) -> String? {
        lookup[kana]
    }
}
