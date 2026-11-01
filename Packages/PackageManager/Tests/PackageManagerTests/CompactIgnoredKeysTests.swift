import Foundation
import KeyboardCore
import XCTest
import Yams

@testable import PackageManager

/// Sources that declare keys a compact layout never sends (tone digits, `\`, ...),
/// modelled on rime_wanxiang's `wanxiang` schema.
final class CompactIgnoredKeysTests: XCTestCase {
    private static let toneAlphabet = "zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA1234567890`;/\\"

    private func spelling(_ text: String) -> CompactSchemaAdapter.ProjectedSpelling {
        .init(text: text, isNormal: true, isCorrection: false)
    }

    /// Tone-marked tokens spelled with a trailing tone digit (7890 for tones 1–4) and
    /// without one, as the wanxiang algebra derives them.
    private var toneProjection: CompactSchemaAdapter.SourceProjection {
        .init(
            sourceSchema: "tone", translatorNamespace: "translator", dictionary: "d",
            alphabet: Self.toneAlphabet, algebra: [], separator: " ",
            producerClass: "script_translator",
            syllables: [
                .init(token: "nǐ", spellings: [spelling("ni9"), spelling("ni")]),
                .init(token: "hǎo", spellings: [spelling("hao9"), spelling("hao")]),
                .init(token: "mā", spellings: [spelling("ma7"), spelling("ma")]),
                .init(token: "dà", spellings: [spelling("da0"), spelling("da")]),
            ])
    }

    private var toneSource: Data {
        Data(
            """
            schema: {schema_id: tone, name: tone}
            engine:
              translators: [punct_translator, script_translator, "lua_translator@*calc", "table_translator@mixed"]
            speller:
              alphabet: "zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA1234567890`;/\\\\"
              algebra:
                - 'xform/^([a-z]+)$/$10/'
                - 'derive/(.+)(\\d)/$1/'
            translator: {dictionary: d}
            mixed: {dictionary: mixed}
            """.utf8)
    }

    private func speller(_ data: Data) throws -> [String: Any] {
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
        return try XCTUnwrap(root["speller"] as? [String: Any])
    }

    /// librime's `erase` drops a spelling only when the pattern matches all of it.
    private func erased(_ text: String) throws -> Bool {
        let rule = CompactSchemaAdapter.sourceDigitSpellingErase
        let pattern = String(rule.dropFirst("erase/".count).dropLast())
        let regex = try NSRegularExpression(pattern: pattern)
        let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        return match?.range == NSRange(text.startIndex..., in: text)
    }

    func testToneDigitsAndBackslashNoLongerDisqualifyTheSource() throws {
        XCTAssertEqual(try CompactSchemaAdapter.adaptability(compiled: toneSource, sourceID: "tone"), .adaptable)
        for fold in [CompactFold.merged14, .merged18] {
            let physical = try XCTUnwrap(
                CompactSchemaAdapter.physicalFold(sourceAlphabet: Self.toneAlphabet, fold: fold))
            XCTAssertEqual(physical.ignoredCharacters, "0123456789\\")
            XCTAssertTrue(physical.typeableAlphabet.contains("`"))
            XCTAssertTrue(physical.typeableAlphabet.contains("W"), "paired uppercase stays a source key")
        }
        let nine = try XCTUnwrap(CompactSchemaAdapter.physicalFold(sourceAlphabet: Self.toneAlphabet, fold: .phone9))
        XCTAssertEqual(nine.ignoredCharacters, "01\\")
    }

    func testLetterGroupCompanionLeavesIgnoredKeysOut() throws {
        for fold in [CompactFold.merged14, .merged18] {
            let data = try CompactSchemaAdapter.generate(
                compiled: toneSource, sourceID: "tone", fold: fold,
                displayCapability: nil, sourceProjection: toneProjection)
            let speller = try speller(data)
            let alphabet = try XCTUnwrap(speller["alphabet"] as? String)
            XCTAssertFalse(alphabet.contains("\\"), "a key the layout never sends is not accepted")
            let algebra = try XCTUnwrap(speller["algebra"] as? [String])
            XCTAssertFalse(algebra.contains(CompactSchemaAdapter.sourceDigitSpellingErase))
            XCTAssertTrue(algebra.contains("derive/w/q/") || algebra.contains("derive/e/w/"))
        }
    }

    /// On the 9-key layout a tone digit would read as a letter key once the letters fold
    /// (`hao9` -> `4269`, the code of `hao` + w/x/y/z), so digit spellings are erased first.
    func testNineKeyCompanionErasesToneSpellingsBeforeTheFold() throws {
        let data = try CompactSchemaAdapter.generate(
            compiled: toneSource, sourceID: "tone", fold: .phone9,
            displayCapability: nil, sourceProjection: toneProjection)
        let speller = try speller(data)
        let algebra = try XCTUnwrap(speller["algebra"] as? [String])
        let erase = try XCTUnwrap(algebra.firstIndex(of: CompactSchemaAdapter.sourceDigitSpellingErase))
        let fold = try XCTUnwrap(algebra.firstIndex { $0.hasPrefix("xlit/") })
        let sourceRule = try XCTUnwrap(algebra.firstIndex(of: "derive/(.+)(\\d)/$1/"))
        XCTAssertLessThan(sourceRule, erase, "the source's own rules produce the tone spellings first")
        XCTAssertEqual(erase + 1, fold, "nothing runs between the erase and the fold")
        let alphabet = try XCTUnwrap(speller["alphabet"] as? String)
        XCTAssertFalse(alphabet.contains("\\"))

        // Tone spellings go, toneless ones and the alias rewrite targets stay.
        for tone in ["ni9", "hao9", "ma7", "da0", "h9"] { XCTAssertTrue(try erased(tone), tone) }
        for plain in ["ni", "hao", "ma", "da", "`", "h"] { XCTAssertFalse(try erased(plain), plain) }
        let aliases = CompactSchemaAdapter.tokenAliasAssignments(toneProjection).map(\.alias)
        XCTAssertFalse(aliases.isEmpty)
        for alias in aliases { XCTAssertFalse(try erased(alias), alias) }
        // The source's `derive/(.+)(\d)/$1/` also shortens aliases; those keep a `0`,
        // which no compact key sends, so they stay unreachable by typing.
        XCTAssertFalse(try erased("90"))
        XCTAssertFalse(CompactFold.phone9.keysSent.contains("0"))
        // The rewrite capability still binds the alias layer.
        XCTAssertTrue(
            CompactSchemaAdapter.tokenAliasLockAuthorized(sourceProjection: toneProjection, companion: data))
    }

    /// A telephone-digit source's digits mean what the keys mean: nothing is erased.
    func testNumericCodeSourceKeepsItsDigitSpellings() throws {
        let numeric = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "t9", translatorNamespace: "translator", dictionary: "d",
            alphabet: "23456789abcdefghijklmnopqrstuvwxyz", algebra: [], separator: "'",
            producerClass: "script_translator",
            syllables: [
                .init(token: "ni", spellings: [spelling("64")]),
                .init(token: "hao", spellings: [spelling("426")]),
            ])
        XCTAssertFalse(CompactSchemaAdapter.erasesSourceDigitSpellings(numeric))
        XCTAssertTrue(CompactSchemaAdapter.erasesSourceDigitSpellings(toneProjection))
        let source = Data(
            """
            schema: {schema_id: t9, name: t9}
            engine: {translators: [script_translator]}
            speller:
              alphabet: "23456789abcdefghijklmnopqrstuvwxyz"
              algebra: ['xlit/abcdefghijklmnopqrstuvwxyz/22233344455566677778889999/']
            translator: {dictionary: d}
            """.utf8)
        let data = try CompactSchemaAdapter.generate(
            compiled: source, sourceID: "t9", fold: .phone9,
            displayCapability: nil, sourceProjection: numeric)
        let algebra = try XCTUnwrap(try speller(data)["algebra"] as? [String])
        XCTAssertFalse(algebra.contains(CompactSchemaAdapter.sourceDigitSpellingErase))

        // Its spellings are all digits, so a letter-group layout reaches none of them.
        let plan = try CompactSchemaAdapter.CompanionPlan(
            compiled: source, sourceID: "t9", projection: numeric, sourceDelimiter: "'")
        XCTAssertNil(try plan.companion(fold: .merged14))
        XCTAssertNil(try plan.companion(fold: .merged18))
        XCTAssertNotNil(try plan.companion(fold: .phone9))
    }

    func testToneSourceGetsACompanionForEveryCompactLayout() throws {
        let plan = try CompactSchemaAdapter.CompanionPlan(
            compiled: toneSource, sourceID: "tone", projection: toneProjection, sourceDelimiter: " '")
        for fold in [CompactFold.merged14, .merged18, .phone9] {
            XCTAssertNotNil(try plan.companion(fold: fold), fold.id)
        }
        // A source whose every spelling needs an ignored key gets none.
        let toneOnly = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "tone", translatorNamespace: "translator", dictionary: "d",
            alphabet: Self.toneAlphabet, algebra: [], separator: " ",
            producerClass: "script_translator",
            syllables: [.init(token: "nǐ", spellings: [spelling("ni9")])])
        let unreachable = try CompactSchemaAdapter.CompanionPlan(
            compiled: toneSource, sourceID: "tone", projection: toneOnly, sourceDelimiter: " '")
        XCTAssertNil(try unreachable.companion(fold: .merged14))
        XCTAssertNil(try unreachable.companion(fold: .phone9))
    }
}
