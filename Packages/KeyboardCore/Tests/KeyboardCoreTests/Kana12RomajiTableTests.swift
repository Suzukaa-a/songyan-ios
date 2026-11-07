import KeyboardCore
import XCTest

/// Locks the compiled kana -> romaji table to the native pair-matrix evidence: every listed
/// surface types alone and in every ordered pair through the frozen kagiroi speller, so the
/// table needs no runtime JSON and no correction on the keyboard thread.
final class Kana12RomajiTableTests: XCTestCase {
    /// The 82 verified surfaces in artifact order: 47 base (46 kana + ー), 20 dakuten,
    /// 5 handakuten, 10 small (including the optional ゎ).
    private let verified: [(kana: String, romaji: String)] = [
        ("あ", "a"), ("い", "i"), ("う", "u"), ("え", "e"), ("お", "o"),
        ("か", "ka"), ("き", "ki"), ("く", "ku"), ("け", "ke"), ("こ", "ko"),
        ("さ", "sa"), ("し", "si"), ("す", "su"), ("せ", "se"), ("そ", "so"),
        ("た", "ta"), ("ち", "ti"), ("つ", "tu"), ("て", "te"), ("と", "to"),
        ("な", "na"), ("に", "ni"), ("ぬ", "nu"), ("ね", "ne"), ("の", "no"),
        ("は", "ha"), ("ひ", "hi"), ("ふ", "hu"), ("へ", "he"), ("ほ", "ho"),
        ("ま", "ma"), ("み", "mi"), ("む", "mu"), ("め", "me"), ("も", "mo"),
        ("や", "ya"), ("ゆ", "yu"), ("よ", "yo"),
        ("ら", "ra"), ("り", "ri"), ("る", "ru"), ("れ", "re"), ("ろ", "ro"),
        ("わ", "wa"), ("を", "wo"), ("ん", "nn"), ("ー", "-"),
        ("が", "ga"), ("ぎ", "gi"), ("ぐ", "gu"), ("げ", "ge"), ("ご", "go"),
        ("ざ", "za"), ("じ", "zi"), ("ず", "zu"), ("ぜ", "ze"), ("ぞ", "zo"),
        ("だ", "da"), ("ぢ", "di"), ("づ", "du"), ("で", "de"), ("ど", "do"),
        ("ば", "ba"), ("び", "bi"), ("ぶ", "bu"), ("べ", "be"), ("ぼ", "bo"),
        ("ぱ", "pa"), ("ぴ", "pi"), ("ぷ", "pu"), ("ぺ", "pe"), ("ぽ", "po"),
        ("ぁ", "la"), ("ぃ", "li"), ("ぅ", "lu"), ("ぇ", "le"), ("ぉ", "lo"),
        ("ゃ", "lya"), ("ゅ", "lyu"), ("ょ", "lyo"), ("っ", "ltu"), ("ゎ", "lwa"),
    ]

    func testCompiledTableMatchesTheVerifiedArtifactExactly() {
        XCTAssertEqual(Kana12RomajiTable.entries.count, 82)
        XCTAssertEqual(Kana12RomajiTable.entries.map(\.kana), verified.map { $0.kana })
        XCTAssertEqual(Kana12RomajiTable.entries.map(\.romaji), verified.map { $0.romaji })
    }

    func testLookupReturnsEveryVerifiedRomaji() {
        for entry in verified {
            XCTAssertEqual(Kana12RomajiTable.romaji(for: entry.kana), entry.romaji, entry.kana)
        }
        XCTAssertNil(Kana12RomajiTable.romaji(for: ""))
        XCTAssertNil(Kana12RomajiTable.romaji(for: "abc"))
    }

    func testRomajiAreLowerCaseAsciiCodes() {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz-")
        for entry in Kana12RomajiTable.entries {
            XCTAssertFalse(entry.romaji.isEmpty, entry.kana)
            XCTAssertTrue(entry.romaji.allSatisfy { allowed.contains($0) }, entry.kana)
            XCTAssertTrue((1...3).contains(entry.romaji.count), entry.kana)
        }
    }

    /// Table entries must all be reachable from the 12-key grid, its tap cycles, or the
    /// 小゛゜ variant cycle; conversely every reachable glyph must have a code. This is what
    /// keeps the frozen data's unreachable archaic surfaces (ゔ, ゐ, ゑ, ゕ, ゖ, いぇ) out.
    func testTableMatchesTheGlyphsReachableFromTheGrid() {
        var reachable = Set<String>()
        for key in Kana12Key.allCases {
            for direction in Kana12FlickDirection.allCases {
                if let kana = Kana12Layout.kana(for: key, direction: direction) {
                    reachable.insert(kana)
                }
            }
            reachable.formUnion(Kana12Layout.toggleCycle(for: key))
        }
        var changed = true
        while changed {
            changed = false
            for kana in reachable {
                if let next = Kana12Layout.nextVariant(of: kana), !reachable.contains(next) {
                    reachable.insert(next)
                    changed = true
                }
            }
        }
        XCTAssertEqual(reachable, Set(Kana12RomajiTable.entries.map(\.kana)))
        for kana in reachable {
            XCTAssertNotNil(Kana12RomajiTable.romaji(for: kana), kana)
        }
    }

    func testUnreachableArchaicSurfacesAreNotInTheTable() {
        for kana in ["ゔ", "ゐ", "ゑ", "ゕ", "ゖ", "いぇ", "ヵ", "ヶ"] {
            XCTAssertNil(Kana12RomajiTable.romaji(for: kana), kana)
        }
    }
}
