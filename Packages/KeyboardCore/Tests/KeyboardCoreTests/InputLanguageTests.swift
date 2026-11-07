import Foundation
import XCTest

@testable import KeyboardCore

/// The schema table that decides an input method's display language and keyboard family.
/// Rows are ordered: the family is decided first and never changes, while a declared simplifying
/// conversion turns a Chinese family's language to simplified (zhuyin stays zhuyin).
final class InputLanguageTests: XCTestCase {
    /// 大千 keyboard: the first row is contiguous, the tone keys 6 3 4 7 and the punctuation
    /// keys may be written in any order.
    private let bopomofoAlphabet = "1qaz2wsxedcrfv5tgbyhnujm8ik,9ol.0p;/- 6347"
    private let latinAlphabet = "abcdefghijklmnopqrstuvwxyz"

    private var simplified: InputLanguageProfile {
        InputLanguageProfile(language: .simplifiedChinese, family: .generic)
    }

    private var traditional: InputLanguageProfile {
        InputLanguageProfile(language: .traditionalChinese, family: .generic)
    }

    private var traditionalZhuyin: InputLanguageProfile {
        InputLanguageProfile(language: .traditionalChinese, family: .zhuyin)
    }

    private func profile(
        _ schemaID: String, _ alphabet: String = "", conversion: String? = nil
    ) -> InputLanguageProfile {
        InputLanguageResolver.resolve(
            schemaID: schemaID, alphabet: alphabet, declaredConversion: conversion)
    }

    func testKagiroiIsJapanese() {
        XCTAssertEqual(
            profile("kagiroi"), InputLanguageProfile(language: .japanese, family: .japanese))
        XCTAssertEqual(
            profile("kagiroi_romaji"), InputLanguageProfile(language: .japanese, family: .japanese))
    }

    func testKagiroiTakesPriorityOverTraditionalConversion() {
        XCTAssertEqual(
            profile("kagiroi", bopomofoAlphabet, conversion: "s2t"),
            InputLanguageProfile(language: .japanese, family: .japanese))
    }

    func testBopomofoPrefixIsTraditionalZhuyin() {
        XCTAssertEqual(profile("bopomofo"), traditionalZhuyin)
        XCTAssertEqual(profile("bopomofo_tw", bopomofoAlphabet), traditionalZhuyin)
        XCTAssertEqual(profile("bopomofo_tw", bopomofoAlphabet, conversion: "s2t"), traditionalZhuyin)
    }

    func testSimplifyingConversionKeepsFamilyButMakesChineseFamiliesSimplified() {
        for config in ["t2s", "tw2s", "tw2sp", "hk2s"] {
            XCTAssertEqual(
                profile("bopomofo_tw", bopomofoAlphabet, conversion: config),
                InputLanguageProfile(language: .simplifiedChinese, family: .zhuyin), config)
            XCTAssertEqual(
                profile("cangjie5", latinAlphabet, conversion: config),
                InputLanguageProfile(language: .simplifiedChinese, family: .cangjieRadicals), config)
            XCTAssertEqual(
                profile("quick5", latinAlphabet, conversion: config),
                InputLanguageProfile(language: .simplifiedChinese, family: .cangjieRadicals), config)
            XCTAssertEqual(
                profile("jyut6ping3", latinAlphabet, conversion: config),
                InputLanguageProfile(language: .simplifiedChinese, family: .latinPhonetic), config)
            XCTAssertEqual(
                profile("kagiroi", latinAlphabet, conversion: config),
                InputLanguageProfile(language: .japanese, family: .japanese), config)
        }
        // An unknown converter is not script evidence.
        XCTAssertEqual(
            profile("cangjie5", latinAlphabet, conversion: "t2hkf"),
            InputLanguageProfile(language: .traditionalChinese, family: .cangjieRadicals))
    }

    func testBopomofoAlphabetIsTraditionalZhuyin() {
        XCTAssertEqual(profile("custom_zhuyin", bopomofoAlphabet), traditionalZhuyin)
        // The upstream alphabet swaps the punctuation keys; only their presence is required.
        let reordered = "1qaz2wsxedcrfv5tgbyhnujm8ik/.,;9ol0p- 6347"
        XCTAssertEqual(profile("custom_zhuyin", reordered), traditionalZhuyin)
    }

    func testBopomofoAlphabetNeedsEveryPunctuationKey() {
        for key in "-;,./" {
            let alphabet = bopomofoAlphabet.replacingOccurrences(of: String(key), with: "")
            XCTAssertEqual(profile("custom_zhuyin", alphabet), simplified, "missing \(key)")
        }
        // The first row must be contiguous; a reordered row is not the 大千 layout.
        XCTAssertEqual(
            profile("custom_zhuyin", "1aqz2wsxedcrfv5tgbyhnujm8ik,9ol.0p;/- 6347"), simplified)
    }

    func testCangjiePrefixIsTraditionalRadicals() {
        let radicals = InputLanguageProfile(language: .traditionalChinese, family: .cangjieRadicals)
        XCTAssertEqual(profile("cangjie5", latinAlphabet), radicals)
        XCTAssertEqual(profile("cangjie"), radicals)
        XCTAssertEqual(profile("cangjie5", latinAlphabet, conversion: "s2t"), radicals)
    }

    func testQuickPrefixIsTraditionalRadicals() {
        let radicals = InputLanguageProfile(language: .traditionalChinese, family: .cangjieRadicals)
        XCTAssertEqual(profile("quick5", latinAlphabet), radicals)
        XCTAssertEqual(profile("quick"), radicals)
    }

    func testJyutpingPrefixIsTraditionalLatinPhonetic() {
        let latinPhonetic = InputLanguageProfile(language: .traditionalChinese, family: .latinPhonetic)
        XCTAssertEqual(profile("jyut6ping3", latinAlphabet), latinPhonetic)
        XCTAssertEqual(profile("jyut6ping3_hk", latinAlphabet), latinPhonetic)
    }

    func testTraditionalConvertersKeepFamily() {
        let configs = ["s2t", "s2tw", "s2twp", "s2hk", "t2tw", "t2hk"]
        for config in configs {
            XCTAssertEqual(profile("user_scheme", latinAlphabet, conversion: config), traditional, config)
            XCTAssertEqual(
                profile("cangjie5", latinAlphabet, conversion: config),
                InputLanguageProfile(language: .traditionalChinese, family: .cangjieRadicals),
                "the family row wins over the conversion row")
        }
    }

    func testNonTraditionalConvertersKeepSimplified() {
        // The parameter is a bare OpenCC config name; path and extension are not guessed, and
        // only the six listed names mean traditional output (t2hkf is not one of them).
        let configs = ["t2s", "t2hkf", "s2t.json", "opencc/s2twp.json", "S2T", "emoji", "unknown", ""]
        for config in configs {
            XCTAssertEqual(profile("user_scheme", latinAlphabet, conversion: config), simplified, config)
        }
        XCTAssertEqual(profile("rime_ice", latinAlphabet, conversion: "t2s"), simplified)
        XCTAssertEqual(profile("rime_ice", latinAlphabet), simplified)
    }

    func testUnknownSchemaKeepsLegacyBehavior() {
        for schemaID in ["", "user_scheme", "custom_pinyin", "wubi86", "stroke_hspnz"] {
            XCTAssertEqual(profile(schemaID), simplified, schemaID)
            XCTAssertEqual(profile(schemaID, latinAlphabet), simplified, schemaID)
        }
        XCTAssertEqual(profile("custom_pinyin", latinAlphabet, conversion: "unknown"), simplified)
    }

    func testLunaPinyinKeepsSimplified() {
        XCTAssertEqual(profile("luna_pinyin", latinAlphabet), simplified)
        XCTAssertEqual(profile("luna_pinyin_simp", latinAlphabet), simplified)
    }

    /// Families with their own physical layout keep it, so the host must not generate compact
    /// companions for them. Latin-phonetic schemes (jyut6ping3) fold like generic ones.
    func testKnownFamiliesNeverOfferCompactLayouts() {
        for schemaID in [
            "bopomofo_tw", "bopomofo", "cangjie5", "cangjie", "quick5", "kagiroi",
            "kagiroi_romaji",
        ] {
            let family = InputLayoutPolicy.family(schemaID: schemaID, alphabet: bopomofoAlphabet)
            XCTAssertFalse(InputLayoutPolicy.allowsCompactLayouts(family: family), schemaID)
        }
        XCTAssertTrue(InputLayoutPolicy.allowsCompactLayouts(family: .generic))
        XCTAssertTrue(InputLayoutPolicy.allowsCompactLayouts(family: .latinPhonetic))
        // A bopomofo-shaped alphabet without the prefix is still the zhuyin family.
        let alphabetOnly = InputLayoutPolicy.family(schemaID: "custom_zhuyin", alphabet: bopomofoAlphabet)
        XCTAssertFalse(InputLayoutPolicy.allowsCompactLayouts(family: alphabetOnly))
    }

    func testRimeIceTraditionalSwitchIsTraditional() {
        XCTAssertEqual(profile("rime_ice", latinAlphabet, conversion: "s2t"), traditional)
        XCTAssertEqual(profile("rime_ice", latinAlphabet, conversion: "s2twp"), traditional)
        XCTAssertEqual(profile("rime_ice", latinAlphabet), simplified)
    }
}
