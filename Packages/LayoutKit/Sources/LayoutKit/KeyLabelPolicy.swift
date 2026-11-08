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
    public static func symbolLockTitle(script: KeyLabelScript) -> String {
        switch script {
        case .simplifiedChinese: return "锁定"
        case .traditionalChinese: return "鎖定"
        case .japanese: return "固定"
        }
    }

    /// 更多 on the row-shaped symbol page.
    public static func symbolLibraryTitle(script: KeyLabelScript) -> String {
        switch script {
        case .simplifiedChinese, .traditionalChinese: return "更多"
        case .japanese: return "その他"
        }
    }

    public static func symbolLibraryAccessibilityLabel() -> String {
        String(localized: "key.page.symbolLibrary", bundle: .module)
    }

    public static func clearInputTitle(script: KeyLabelScript) -> String {
        switch script {
        case .simplifiedChinese: return "重输"
        case .traditionalChinese: return "重輸"
        case .japanese: return "取消"
        }
    }

    public static func shiftTitle(script: KeyLabelScript) -> String {
        switch script {
        case .simplifiedChinese: return "上档"
        case .traditionalChinese: return "上檔"
        case .japanese: return "⇧"
        }
    }

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

    /// Spoken names follow the app language, never the scheme's script: VoiceOver reads them in the
    /// user's language, while the drawn key faces follow the input language. Only a Japanese
    /// scheme's converting space keeps its own word.
    public static func spaceAccessibilityLabel(script: KeyLabelScript, isComposing: Bool) -> String {
        if script == .japanese && isComposing {
            return String(localized: "key.space.converting", bundle: .module)
        }
        return String(localized: "key.space", bundle: .module)
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

    public static func returnAccessibilityLabel(isComposing: Bool, intent: ReturnIntent) -> String {
        if isComposing { return String(localized: "key.return.confirmInput", bundle: .module) }
        switch intent {
        case .lineBreak: return String(localized: "key.return.lineBreak", bundle: .module)
        case .search: return String(localized: "key.return.search", bundle: .module)
        case .send: return String(localized: "key.return.send", bundle: .module)
        case .go: return String(localized: "key.return.go", bundle: .module)
        case .done: return String(localized: "key.return.done", bundle: .module)
        case .next: return String(localized: "key.return.next", bundle: .module)
        case .join: return String(localized: "key.return.join", bundle: .module)
        case .route: return String(localized: "key.return.route", bundle: .module)
        case .emergencyCall: return String(localized: "key.return.emergencyCall", bundle: .module)
        case .continueAction: return String(localized: "key.return.continue", bundle: .module)
        }
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

    /// A Japanese scheme names Japanese and English, never Chinese; the other schemes name the
    /// target. The wording itself is the app language's.
    public static func languageAccessibilityLabel(
        script: KeyLabelScript, action: KeyboardControlPolicy.LanguageAction,
        isEnglishMode: Bool, usesASCIIPunctuation: Bool
    ) -> String {
        switch action {
        case .returnToLetters:
            return String(localized: "key.language.returnToLetters", bundle: .module)
        case .toggleLanguage:
            if script == .japanese {
                return isEnglishMode
                    ? String(localized: "key.language.englishToJapanese", bundle: .module)
                    : String(localized: "key.language.japaneseToEnglish", bundle: .module)
            }
            return isEnglishMode
                ? String(localized: "key.language.toChinese", bundle: .module)
                : String(localized: "key.language.toEnglish", bundle: .module)
        case .toggleSymbols:
            if script == .japanese {
                return usesASCIIPunctuation
                    ? String(localized: "key.symbols.englishToJapanese", bundle: .module)
                    : String(localized: "key.symbols.japaneseToEnglish", bundle: .module)
            }
            return usesASCIIPunctuation
                ? String(localized: "key.symbols.toChinese", bundle: .module)
                : String(localized: "key.symbols.toEnglish", bundle: .module)
        }
    }

    // MARK: Page keys

    /// The decorated "符" key opens the symbol page; Japanese spells it 記号.
    public static func symbolPageTitle(script: KeyLabelScript) -> String {
        script == .japanese ? "記号" : "符"
    }

    public static let numericPageTitle = "123"

    public static func pageSwitchAccessibilityLabel(
        target: LayoutAction.PageTarget, isBundledPhonePad: Bool
    ) -> String {
        switch target {
        case .letters: return String(localized: "key.language.returnToLetters", bundle: .module)
        case .numeric: return String(localized: "key.page.numeric", bundle: .module)
        case .symbols:
            return isBundledPhonePad
                ? String(localized: "key.page.symbols", bundle: .module)
                : String(localized: "key.page.moreSymbols", bundle: .module)
        }
    }
}
