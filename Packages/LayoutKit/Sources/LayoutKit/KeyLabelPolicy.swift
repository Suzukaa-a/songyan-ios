import Foundation

/// The input language a key face follows. It is the scheme's language, never the system or app
/// language: the same keyboard keeps its names when the app UI changes.
public enum KeyLabelScript: String, Sendable, Equatable, CaseIterable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
}

/// Automatic key names and accessibility wording for the three input languages. Only a key whose
/// face is the native automatic one reads this; an author label always wins.
extension LayoutKey {
    /// The caption an automatic space key draws. A key whose effective title mode is the author's
    /// own — a legacy space without a title mode included — keeps its stored label untouched.
    public func automaticSpaceTitle(policy: KeyboardControlPolicy, isComposing: Bool) -> String {
        displayedTitleMode == .automatic ? policy.spaceTitle(isComposing: isComposing) : label
    }
}

public enum KeyLabelPolicy {
    /// The action a host Return key will perform, independent of UIKit's return-key types.
    public enum ReturnIntent: Sendable, Equatable, CaseIterable {
        case lineBreak
        case search
        case send
        case go
        case done
        case next
        case join
        case route
        case emergencyCall
        case continueAction
    }

    // MARK: Space

    /// The automatic space caption follows the scheme's input language in every input mode; only
    /// an author label replaces it.
    public static func spaceTitle(script: KeyLabelScript, isComposing: Bool) -> String {
        switch script {
        case .simplifiedChinese: return "空格"
        case .traditionalChinese: return "空白"
        case .japanese: return isComposing ? "変換" : "空白"
        }
    }

    /// The native space bar speaks its face; only the converting Japanese face needs its own word.
    public static func spaceAccessibilityLabel(script: KeyLabelScript, isComposing: Bool) -> String {
        spaceTitle(script: script, isComposing: isComposing)
    }

    // MARK: Return

    public static func returnTitle(script: KeyLabelScript, isComposing: Bool, intent: ReturnIntent) -> String {
        if isComposing {
            switch script {
            case .simplifiedChinese: return "确认"
            case .traditionalChinese: return "確認"
            case .japanese: return "確定"
            }
        }
        switch script {
        case .simplifiedChinese:
            switch intent {
            case .lineBreak: return "换行"
            case .search: return "搜索"
            case .send: return "发送"
            case .go: return "前往"
            case .done: return "完成"
            case .next: return "下一项"
            case .join: return "加入"
            case .route: return "路线"
            case .emergencyCall: return "紧急呼叫"
            case .continueAction: return "继续"
            }
        case .traditionalChinese:
            switch intent {
            case .lineBreak: return "換行"
            case .search: return "搜尋"
            case .send: return "傳送"
            case .go: return "前往"
            case .done: return "完成"
            case .next: return "下一個"
            case .join: return "加入"
            case .route: return "路線"
            case .emergencyCall: return "緊急呼叫"
            case .continueAction: return "繼續"
            }
        case .japanese:
            switch intent {
            case .lineBreak: return "改行"
            case .search: return "検索"
            case .send: return "送信"
            case .go: return "開く"
            case .done: return "完了"
            case .next: return "次へ"
            case .join: return "参加"
            case .route: return "経路"
            case .emergencyCall: return "緊急通報"
            case .continueAction: return "続行"
            }
        }
    }

    public static func returnAccessibilityLabel(
        script: KeyLabelScript, isComposing: Bool, intent: ReturnIntent
    ) -> String {
        if isComposing {
            switch script {
            case .simplifiedChinese: return "确认输入"
            case .traditionalChinese: return "確認輸入"
            case .japanese: return "確定"
            }
        }
        return returnTitle(script: script, isComposing: false, intent: intent)
    }

    // MARK: Language key

    public static func languageTitle(
        script: KeyLabelScript, action: KeyboardControlPolicy.LanguageAction,
        isEnglishMode: Bool, usesASCIIPunctuation: Bool
    ) -> String {
        switch action {
        case .returnToLetters:
            return script == .japanese ? "戻る" : "返回"
        case .toggleLanguage, .toggleSymbols:
            // The auto face names the target, not the current state.
            let showsLatin: Bool = action == .toggleLanguage ? isEnglishMode : usesASCIIPunctuation
            switch script {
            case .simplifiedChinese: return showsLatin ? "中文" : "英文"
            case .traditionalChinese: return showsLatin ? "中文" : "英文"
            case .japanese: return showsLatin ? "あ" : "A"
            }
        }
    }

    public static func languageAccessibilityLabel(
        script: KeyLabelScript, action: KeyboardControlPolicy.LanguageAction,
        isEnglishMode: Bool, usesASCIIPunctuation: Bool
    ) -> String {
        switch action {
        case .returnToLetters:
            switch script {
            case .simplifiedChinese: return "返回主键盘"
            case .traditionalChinese: return "返回主鍵盤"
            case .japanese: return "文字キーボードに戻る"
            }
        case .toggleLanguage:
            switch script {
            case .simplifiedChinese: return isEnglishMode ? "切换到中文" : "切换到英文"
            case .traditionalChinese: return isEnglishMode ? "切換到中文" : "切換到英文"
            case .japanese: return isEnglishMode ? "かな入力に切り替え" : "英字入力に切り替え"
            }
        case .toggleSymbols:
            switch script {
            case .simplifiedChinese: return usesASCIIPunctuation ? "切换到中文符号" : "切换到英文符号"
            case .traditionalChinese: return usesASCIIPunctuation ? "切換到中文符號" : "切換到英文符號"
            case .japanese: return usesASCIIPunctuation ? "和文記号に切り替え" : "欧文記号に切り替え"
            }
        }
    }

    // MARK: Page keys

    /// The decorated "符" key opens the symbol page; Japanese spells it 記号.
    public static func symbolPageTitle(script: KeyLabelScript) -> String {
        script == .japanese ? "記号" : "符"
    }

    public static let numericPageTitle = "123"

    public static func pageSwitchAccessibilityLabel(
        script: KeyLabelScript, target: LayoutAction.PageTarget, isBundledPhonePad: Bool
    ) -> String {
        switch target {
        case .letters:
            switch script {
            case .simplifiedChinese: return "返回主键盘"
            case .traditionalChinese: return "返回主鍵盤"
            case .japanese: return "文字キーボードに戻る"
            }
        case .numeric:
            switch script {
            case .simplifiedChinese: return "打开数字符号页"
            case .traditionalChinese: return "開啟數字符號頁"
            case .japanese: return "数字・記号ページを開く"
            }
        case .symbols:
            if isBundledPhonePad {
                switch script {
                case .simplifiedChinese: return "打开符号页"
                case .traditionalChinese: return "開啟符號頁"
                case .japanese: return "記号ページを開く"
                }
            }
            switch script {
            case .simplifiedChinese: return "打开更多符号页"
            case .traditionalChinese: return "開啟更多符號頁"
            case .japanese: return "記号ページを開く"
            }
        }
    }
}
