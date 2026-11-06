import XCTest

@testable import LayoutKit

/// Automatic key faces of the three input languages. Only the native automatic face is named here:
/// an authored label always wins.
final class KeyLabelPolicyTests: XCTestCase {
    func testAuthoredAutomaticControlsFollowInputScript() {
        XCTAssertEqual(KeyLabelPolicy.symbolLockTitle(script: .simplifiedChinese), "锁定")
        XCTAssertEqual(KeyLabelPolicy.symbolLockTitle(script: .traditionalChinese), "鎖定")
        XCTAssertEqual(KeyLabelPolicy.symbolLockTitle(script: .japanese), "固定")
        XCTAssertEqual(KeyLabelPolicy.clearInputTitle(script: .simplifiedChinese), "重输")
        XCTAssertEqual(KeyLabelPolicy.clearInputTitle(script: .traditionalChinese), "重輸")
        XCTAssertEqual(KeyLabelPolicy.clearInputTitle(script: .japanese), "取消")
        XCTAssertEqual(KeyLabelPolicy.shiftTitle(script: .japanese), "⇧")
    }

    private func policy(
        _ script: KeyLabelScript, english: Bool = false, ascii: Bool = false,
        page: KeyboardControlPolicy.Page = .letters, phone: Bool = false
    ) -> KeyboardControlPolicy {
        KeyboardControlPolicy(
            page: page, isEnglishMode: english, hasGlobe: true, isPhoneLayout: phone,
            usesASCIIPunctuation: ascii, includesBottomEnter: !phone, script: script)
    }

    func testSimplifiedKeepsTodaysKeyNames() {
        XCTAssertEqual(KeyLabelPolicy.spaceTitle(script: .simplifiedChinese, isComposing: false), "空格")
        XCTAssertEqual(policy(.simplifiedChinese).languageTitle, "英文")
        XCTAssertEqual(policy(.simplifiedChinese, english: true).languageTitle, "中文")
        XCTAssertEqual(policy(.simplifiedChinese).symbolPageTitle, "符")
    }

    func testTraditionalSpaceAndActionsUseTraditionalNames() {
        XCTAssertEqual(KeyLabelPolicy.spaceTitle(script: .traditionalChinese, isComposing: false), "空白")
        XCTAssertEqual(KeyLabelPolicy.spaceTitle(script: .traditionalChinese, isComposing: true), "空白")
        let intents: [(KeyLabelPolicy.ReturnIntent, String)] = [
            (.lineBreak, "換行"), (.search, "搜尋"), (.send, "傳送"),
            (.go, "前往"), (.done, "完成"), (.next, "下一個"),
        ]
        for (intent, title) in intents {
            XCTAssertEqual(
                KeyLabelPolicy.returnTitle(script: .traditionalChinese, isComposing: false, intent: intent), title,
                title)
        }
        XCTAssertEqual(
            KeyLabelPolicy.returnTitle(script: .traditionalChinese, isComposing: true, intent: .lineBreak), "確認")
        XCTAssertEqual(KeyLabelPolicy.symbolPageTitle(script: .traditionalChinese), "符")
    }

    func testJapaneseIdleSpaceAndReturn() {
        XCTAssertEqual(KeyLabelPolicy.spaceTitle(script: .japanese, isComposing: false), "空白")
        XCTAssertEqual(KeyLabelPolicy.returnTitle(script: .japanese, isComposing: false, intent: .lineBreak), "改行")
        let intents: [(KeyLabelPolicy.ReturnIntent, String)] = [
            (.search, "検索"), (.send, "送信"), (.go, "開く"),
            (.done, "完了"), (.next, "次へ"),
        ]
        for (intent, title) in intents {
            XCTAssertEqual(
                KeyLabelPolicy.returnTitle(script: .japanese, isComposing: false, intent: intent), title, title)
        }
    }

    func testJapaneseComposingSpaceIsConversion() {
        XCTAssertEqual(KeyLabelPolicy.spaceTitle(script: .japanese, isComposing: true), "変換")
        XCTAssertEqual(
            KeyLabelPolicy.returnTitle(script: .japanese, isComposing: true, intent: .lineBreak), "確定")
    }

    /// I-D1/I-D3 give the automatic space caption per input language with no ASCII-mode exception.
    func testAutomaticSpaceFollowsTheInputLanguageInASCIIMode() {
        XCTAssertEqual(policy(.simplifiedChinese, english: true).spaceTitle(isComposing: false), "空格")
        XCTAssertEqual(policy(.traditionalChinese, english: true).spaceTitle(isComposing: false), "空白")
        XCTAssertEqual(policy(.japanese, english: true).spaceTitle(isComposing: false), "空白")
        XCTAssertEqual(policy(.japanese, english: true).spaceTitle(isComposing: true), "変換")
    }

    func testJapaneseLanguageKeyNamesTheTarget() {
        XCTAssertEqual(policy(.japanese).languageTitle, "A")
        XCTAssertEqual(policy(.japanese, english: true).languageTitle, "あ")
        XCTAssertEqual(policy(.traditionalChinese).languageTitle, "英文")
    }

    func testSymbolPageKeyIsFuForBothChineseScriptsAndKigoInJapanese() {
        XCTAssertEqual(policy(.simplifiedChinese, page: .numeric).pageTitle, "符")
        XCTAssertEqual(policy(.traditionalChinese, page: .numeric).pageTitle, "符")
        XCTAssertEqual(policy(.japanese, page: .numeric).pageTitle, "記号")
        XCTAssertEqual(KeyLabelPolicy.numericPageTitle, "123")
        XCTAssertEqual(policy(.japanese).pageTitle, "123")
    }

    /// A legacy space key without a title mode is the author's own label (displayedTitleMode
    /// reports custom), so the Japanese policy must not rename it.
    func testLegacySpaceKeyWithoutATitleModeKeepsItsAuthorLabel() {
        let legacy = LayoutKey(label: "我的空格", width: 4, action: LayoutAction(.space))
        XCTAssertEqual(legacy.displayedTitleMode, .custom)
        XCTAssertEqual(
            legacy.automaticSpaceTitle(policy: policy(.japanese), isComposing: false), "我的空格")
        let automatic = LayoutKey(
            label: "空格", width: 4, action: LayoutAction(.space), titleMode: .automatic)
        XCTAssertEqual(automatic.displayedTitleMode, .automatic)
        XCTAssertEqual(
            automatic.automaticSpaceTitle(policy: policy(.japanese), isComposing: false), "空白")
        XCTAssertEqual(
            automatic.automaticSpaceTitle(policy: policy(.japanese), isComposing: true), "変換")
    }

    func testSwitchingBackToSimplifiedRestoresTheSpaceBarName() {
        XCTAssertEqual(policy(.japanese).spaceTitleForTests, "空白")
        XCTAssertEqual(policy(.simplifiedChinese).spaceTitleForTests, "空格")
    }

    func testAccessibilityFollowsTheInputLanguage() {
        XCTAssertEqual(
            KeyLabelPolicy.spaceTitle(script: .japanese, isComposing: true),
            KeyLabelPolicy.spaceAccessibilityLabel(script: .japanese, isComposing: true))
        XCTAssertEqual(
            KeyLabelPolicy.returnAccessibilityLabel(
                script: .traditionalChinese, isComposing: true, intent: .lineBreak), "確認輸入")
        XCTAssertEqual(
            KeyLabelPolicy.returnAccessibilityLabel(script: .japanese, isComposing: true, intent: .lineBreak), "確定")
        XCTAssertEqual(
            KeyLabelPolicy.languageAccessibilityLabel(
                script: .traditionalChinese, action: .toggleLanguage, isEnglishMode: false,
                usesASCIIPunctuation: false), "切換到英文")
        XCTAssertEqual(
            KeyLabelPolicy.languageAccessibilityLabel(
                script: .japanese, action: .toggleLanguage, isEnglishMode: false,
                usesASCIIPunctuation: false), "英字入力に切り替え")
        XCTAssertEqual(
            KeyLabelPolicy.pageSwitchAccessibilityLabel(
                script: .japanese, target: .symbols, isBundledPhonePad: false), "記号ページを開く")
        XCTAssertEqual(
            KeyLabelPolicy.pageSwitchAccessibilityLabel(
                script: .traditionalChinese, target: .numeric, isBundledPhonePad: false), "開啟數字符號頁")
    }
}

extension KeyboardControlPolicy {
    /// The wordless space face, read through the policy so a test sees the same caption the key draws.
    var spaceTitleForTests: String {
        spaceTitle(isComposing: false)
    }
}
