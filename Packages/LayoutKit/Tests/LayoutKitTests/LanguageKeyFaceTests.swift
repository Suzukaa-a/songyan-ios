import XCTest

@testable import LayoutKit

/// The automatic language key follows the scheme's language: Chinese and Japanese keep their faces,
/// Korean shows 한/A and an unknown language shows 文/A, with neutral spoken wording for both.
final class LanguageKeyFaceTests: XCTestCase {
    private func policy(
        _ page: KeyboardControlPolicy.Page = .letters, english: Bool = false, ascii: Bool = false,
        script: KeyLabelScript = .simplifiedChinese, face: LanguageKeyFace = .byScript
    ) -> KeyboardControlPolicy {
        KeyboardControlPolicy(
            page: page, isEnglishMode: english, hasGlobe: true, isPhoneLayout: false,
            usesASCIIPunctuation: ascii, usesCategorySymbolPage: false, script: script,
            languageFace: face)
    }

    func testTitlesFollowTheSchemeLanguage() {
        XCTAssertEqual(policy().languageTitle, "中/英")
        XCTAssertEqual(policy(script: .traditionalChinese).languageTitle, "中/英")
        XCTAssertEqual(policy(script: .japanese).languageTitle, "あ/A")
        for page in [KeyboardControlPolicy.Page.letters, .numeric, .symbols] {
            XCTAssertEqual(policy(page, face: .korean).languageTitle, "한/A", "\(page)")
            XCTAssertEqual(policy(page, face: .unspecified).languageTitle, "文/A", "\(page)")
        }
    }

    func testReturnKeyAndSidesAreUnchanged() {
        let returning = KeyboardControlPolicy(
            page: .symbols, isEnglishMode: false, hasGlobe: true, isPhoneLayout: false,
            usesASCIIPunctuation: false, usesCategorySymbolPage: true, languageFace: .korean)
        XCTAssertEqual(returning.languageTitle, "返回")
        XCTAssertNil(returning.languageCurrentSideIsFirst(for: nil))
        XCTAssertEqual(policy(english: true, face: .unspecified).languageCurrentSideIsFirst(for: nil), false)
        XCTAssertEqual(policy(face: .korean).languageCurrentSideIsFirst(for: nil), true)
    }

    func testGenericSpokenWordingNamesTheInputMethodNotChinese() {
        for face in [LanguageKeyFace.korean, .unspecified] {
            XCTAssertEqual(policy(face: face).languageAccessibilityLabel, "输入方式的语言，轻点切换为英文")
            XCTAssertEqual(
                policy(english: true, face: face).languageAccessibilityLabel, "英文，轻点切换回输入方式的语言")
            XCTAssertEqual(
                policy(.numeric, face: face).languageAccessibilityLabel, "输入方式的标点，轻点切换为英文标点")
            XCTAssertEqual(
                policy(.numeric, ascii: true, face: face).languageAccessibilityLabel, "英文标点，轻点切换回输入方式的标点")
        }
        XCTAssertEqual(policy().languageAccessibilityLabel, "切换到英文")
    }
}
