import Foundation

/// User-model terminology for input configuration (the single literal source shared by Host and the keyboard extension).
///
/// User model (a generic Rime front end, not designed around any particular source). The host app
/// has two places to act: 输入方案 (what is installed) and 我的键盘 (what is on the keyboard).
///  - Input scheme: an installable unit of data (a source). A source can contain
///    any number of schemes with any names; the list always comes from the resource snapshot's enabled list.
///  - Input method: a concrete way of typing within a scheme (a schema, e.g. full pinyin,
///    Xiaohe Shuangpin, 9-key, shape-code, dialect). Display names come from the resource
///    snapshot; no schema ID is hard-coded. It is only a group heading in 我的键盘 and a read-only
///    list on a scheme's detail page, never a separate place to choose.
///  - Keyboard layout: a front-end keyboard capability (26 / 14 / 9 / custom key layout),
///    independent of source identity; whether an input method works with a layout is decided
///    only by resource capability (`availableCombinations` / `incompatibilityReason`).
///  - Keyboard appearance: colors / fonts / candidate-area light-dark (separate entry).
///  - Dictionary: supplementary vocabulary (separate entry).
///
/// Every user-facing wording is read from this package's compiled String Catalog
/// (`Resources/Localizable.xcstrings`; Simplified Chinese is the source language, Traditional
/// Chinese and Japanese are translated), so the interface language comes from the process instead
/// of literals compiled into the code.
///
/// Internal terms that must not appear in ordinary UI are listed in `bannedInternalTerms`;
/// the copy gate is `leaksInternalTerminology`.
public enum UserTerminology: Sendable {

    // MARK: - Objects and groups

    /// An installable/usable unit of data.
    public static var inputScheme: String { String(localized: "core.term.inputScheme", bundle: .module) }
    /// A concrete way of typing within a scheme (schema).
    public static var inputMethod: String { String(localized: "core.term.inputMethod", bundle: .module) }
    /// Front-end keyboard layout (26 / 14 / 9 / custom).
    public static var keyboardLayout: String { String(localized: "core.term.keyboardLayout", bundle: .module) }
    /// Colors/fonts/candidate-area light-dark.
    public static var keyboardAppearance: String {
        String(localized: "core.term.keyboardAppearance", bundle: .module)
    }
    /// Supplementary vocabulary.
    public static var dictionary: String { String(localized: "core.term.dictionary", bundle: .module) }
    /// Language model that predicts whole sentences from the composition.
    public static var grammarModel: String { String(localized: "core.term.grammarModel", bundle: .module) }
    /// A set of added "input method + keyboard layout" combinations (managed in the main app, switched by long-press in the keyboard).
    public static var userKeyboard: String { String(localized: "core.term.userKeyboard", bundle: .module) }
    /// The main layout plus the 123, symbol and ABC pages one keyboard in 我的键盘 uses.
    public static var pageComposition: String { String(localized: "core.term.pageComposition", bundle: .module) }
    /// The layout a keyboard opens on; the pages are reached from it.
    public static var mainLayout: String { String(localized: "core.term.mainLayout", bundle: .module) }
    /// Every 123, symbol and ABC page the user can pair with a keyboard.
    public static var pageLibrary: String { String(localized: "core.term.pageLibrary", bundle: .module) }
    /// The phone-style 1–9 digit grid.
    public static var phoneDigitPad: String { String(localized: "core.term.phoneDigitPad", bundle: .module) }
    /// The key that switches between Chinese and English (long-press switches keyboards).
    public static var languageKey: String { String(localized: "core.term.languageKey", bundle: .module) }
    /// The key that opens the system keyboard list.
    public static var globeKey: String { String(localized: "core.term.globeKey", bundle: .module) }

    /// Shown where a layout or page cannot be deleted because a keyboard's 页面搭配 uses it.
    /// `keyboards` are display names; with more than one only the first is named.
    public static func usedByKeyboards(_ keyboards: [String]) -> String? {
        guard let first = keyboards.first else { return nil }
        return keyboards.count == 1
            ? String(
                format: String(localized: "core.term.usedByOneKeyboard", bundle: .module), first)
            : String(
                format: String(localized: "core.term.usedByKeyboards", bundle: .module),
                first, String(keyboards.count))
    }

    // MARK: - Status (identical wording in Host and keyboard)

    /// Has become the current selection.
    public static var statusInUse: String { String(localized: "core.term.statusInUse", bundle: .module) }
    /// Installed but not the current selection.
    public static var statusNotApplied: String {
        String(localized: "core.term.statusNotApplied", bundle: .module)
    }

    // MARK: - Actions

    /// Apply action: switch to a keyboard in 我的键盘, or to a scheme without one (custom pinyin).
    public static var startUsing: String { String(localized: "core.term.startUsing", bundle: .module) }
    /// Apply action when a newer version is installed.
    public static var startUsingNewVersion: String {
        String(localized: "core.term.startUsingNewVersion", bundle: .module)
    }
    /// Add entry.
    public static var addInputScheme: String { String(localized: "core.term.addInputScheme", bundle: .module) }

    // MARK: - Failure and retry (plain wording)

    /// Plain wording when reading the current selection fails (cause and retry entry are supplied in place by the caller).
    public static var readFailureWithRetry: String {
        String(localized: "core.term.readFailureWithRetry", bundle: .module)
    }

    /// Generic plain wording for an operation that did not complete. Raw errors show only in
    /// developer options; the ordinary flow shows no internal prefix or low-level error string.
    public static var genericOperationFailure: String {
        String(localized: "core.term.genericOperationFailure", bundle: .module)
    }

    // MARK: - Home summary

    /// Prefix of the in-use summaries.
    public static var inUsePrefix: String { String(localized: "core.term.inUsePrefix", bundle: .module) }

    /// Scheme summary: "In use: <scheme> · <input method> · <keyboard layout>" (Chinese wording).
    ///
    /// `scheme == nil` means there is no usable product input scheme (Release does not pass built-in package off as usable).
    public static func inUseSummary(scheme: String?, inputMethod: String?, layout: String?) -> String {
        guard let scheme, !scheme.isEmpty else { return ProductionInputAvailability.unconfiguredTitle }
        var parts = [scheme]
        if let inputMethod, !inputMethod.isEmpty, inputMethod != scheme { parts.append(inputMethod) }
        if let layout, !layout.isEmpty { parts.append(layout) }
        return "\(inUsePrefix)：\(parts.joined(separator: " · "))"
    }

    /// Home 我的键盘 row: the keyboard in use, "In use: <input method> · <keyboard layout>".
    /// Either part may be missing; with neither there is nothing to report.
    public static func currentKeyboardSummary(inputMethod: String?, layout: KeyboardLayoutKind?) -> String? {
        let parts = [inputMethod, layout.map(layoutName)].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return "\(inUsePrefix)：\(parts.joined(separator: " · "))"
    }

    /// Home 输入方案 row: how many schemes are installed and which one the keyboard uses.
    public static func installedSchemeSummary(count: Int, inUse: String?) -> String {
        let installed = installedSourceSummary(count: count)
        guard count > 0, let inUse, !inUse.isEmpty else { return installed }
        return String(
            format: String(localized: "core.term.installedSchemeSummary", bundle: .module),
            installed, inUsePrefix, inUse)
    }

    /// Installed source count. The installed source count is never called a "scheme count".
    public static func installedSourceSummary(count: Int) -> String {
        count <= 0
            ? ProductionInputAvailability.unconfiguredCountSummary
            : String(
                format: String(localized: "core.term.installedSourceSummary", bundle: .module),
                String(count))
    }

    // MARK: - Dynamic dimension display

    /// User-facing keyboard layout name (same in Host and keyboard).
    public static func layoutName(_ layout: KeyboardLayoutKind) -> String { layout.userTitle }

    /// User-facing name of a bundled physical keyboard layout, or nil for an id this build does
    /// not ship (a user layout keeps its own name). The words live in the app's compiled string
    /// catalog; the bundle stays injectable so probes read the real compiled resources instead of
    /// a translation copy kept in code.
    public static func builtinLayoutName(
        physicalLayoutID: String, in bundle: Bundle = .main
    ) -> String? {
        guard let key = builtinLayoutNameKey(physicalLayoutID) else { return nil }
        return String(localized: key, bundle: bundle)
    }

    /// The name a layout list shows. A bundled layout's stored name is the shipped data's Chinese,
    /// so while it is unchanged (keys edited or not) the UI language words it; a renamed board or
    /// the user's own layout keeps the name it was saved with. [shippedName] is the bundled preset's
    /// stored name for [id], nil for an id this build does not ship.
    public static func layoutListName(id: String, name: String, shippedName: String?) -> String {
        guard let shippedName, name == shippedName else { return name }
        if let kind = KeyboardLayoutKind(rawValue: id) { return kind.userTitle }
        return builtinLayoutName(physicalLayoutID: id) ?? name
    }

    /// The name a page list shows, by the same rule as `layoutListName`: the bundled pages are worded
    /// in the UI language, every other page keeps its saved name.
    public static func pageListName(id: String, name: String, shippedName: String?) -> String {
        guard let shippedName, name == shippedName else { return name }
        switch id {
        case "page.symbols.system": return String(localized: "core.page.symbolsSystem", bundle: .module)
        case "page.symbols.categorized": return String(localized: "core.page.symbolsCategorized", bundle: .module)
        case "page.numeric.automatic": return String(localized: "core.page.numericAutomatic", bundle: .module)
        case "page.numeric.keypad": return String(localized: "core.page.numericKeypad", bundle: .module)
        case "page.english.qwerty": return String(localized: "core.page.englishQwerty", bundle: .module)
        default: return name
        }
    }

    private static func builtinLayoutNameKey(_ physicalLayoutID: String) -> String.LocalizationValue? {
        switch physicalLayoutID {
        case "zhuyin41": "layout.name.zhuyin41"
        case "cangjie26": "layout.name.cangjie26"
        case "romaji26": "layout.name.romaji26"
        case "kana12": "layout.name.kana12"
        default: nil
        }
    }

    /// Input method display name (from the resource snapshot, always dynamic).
    public static func inputMethodName(_ schema: KeyboardSchemaDescriptor) -> String { schema.displayName }

    /// Resolves the input method display name from the publication record. Returns nil when no
    /// user-readable name can be resolved; an internal schema ID is never shown as ordinary text.
    public static func inputMethodName(
        schemaID: String?,
        schemas: [KeyboardSchemaDescriptor]?
    ) -> String? {
        guard let schemaID else { return nil }
        if let named = schemas?.first(where: { $0.id == schemaID }), !named.name.isEmpty {
            return named.displayName
        }
        let normalized = KeyboardSchemaDescriptor(id: schemaID, name: "").displayName
        return normalized == schemaID ? nil : normalized
    }

    /// The "Input methods: A, B" line; nil when there are no input methods (no placeholder is invented).
    public static func inputMethodLine(_ names: [String]) -> String? {
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return "\(inputMethod)：\(cleaned.joined(separator: "、"))"
    }

    /// The "Keyboard layouts: 26-key, 9-key" line; nil when no layout is available.
    public static func keyboardLayoutLine(_ names: [String]) -> String? {
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return "\(keyboardLayout)：\(cleaned.joined(separator: "、"))"
    }

    /// Plain-language reason when the input method does not support a layout (avoids the banned terms).
    public static func layoutUnavailableReason(_ layout: KeyboardLayoutKind) -> String {
        String(
            format: String(localized: "core.term.layoutUnavailableReason", bundle: .module),
            layoutName(layout), keyboardLayout)
    }

    // MARK: - User keyboards (input method + keyboard layout)

    /// Add entry (main app).
    public static var addUserKeyboard: String { String(localized: "core.term.addUserKeyboard", bundle: .module) }
    /// Marks the current item in the switcher.
    public static var userKeyboardCurrent: String {
        String(localized: "core.term.userKeyboardCurrent", bundle: .module)
    }
    /// Plain-language explanation when the scheme offers no keyboard at all.
    public static var userKeyboardEmptyHint: String {
        String(localized: "core.term.userKeyboardEmptyHint", bundle: .module)
    }
    /// Hint row when the in-keyboard switcher is empty (not tappable; only says where to add).
    public static var userKeyboardSwitcherEmpty: String {
        String(localized: "core.term.userKeyboardSwitcherEmpty", bundle: .module)
    }

    /// Read-only explanation when the management transaction is not wired up (plain language).
    public static var userKeyboardReadOnlyNotice: String {
        String(localized: "core.term.userKeyboardReadOnlyNotice", bundle: .module)
    }

    // MARK: - User keyboard management page (main app)

    /// The keyboard is not using any input scheme (status sentence shared by home, onboarding, and the user keyboard page).
    public static var userKeyboardNoSource: String {
        String(localized: "core.term.userKeyboardNoSource", bundle: .module)
    }

    /// How to make the keyboard start using an input scheme. Schemes with 我的键盘 switch there;
    /// those without (custom pinyin) have their own "start using" button.
    public static var userKeyboardHowToStart: String {
        String(
            format: String(localized: "core.term.userKeyboardHowToStart", bundle: .module),
            inputScheme, userKeyboard, startUsing)
    }

    /// Full explanation for the user keyboard page's "not using any input scheme" state.
    public static var userKeyboardNeedsSourceHint: String { userKeyboardNoSource + userKeyboardHowToStart }

    /// Management page footnote: what the toggles and "Use" do, and how they relate to the in-keyboard switch list.
    public static var userKeyboardFootnote: String {
        String(
            format: String(localized: "core.term.userKeyboardFootnote", bundle: .module),
            languageKey, startUsing)
    }

    /// Saving in progress.
    public static var userKeyboardSaving: String {
        String(localized: "core.term.userKeyboardSaving", bundle: .module)
    }

    /// Explanation when saving is blocked because no keyboard is turned on in the draft.
    public static var userKeyboardSaveNeedsOne: String {
        String(localized: "core.term.userKeyboardSaveNeedsOne", bundle: .module)
    }

    /// Accessibility values of the toggle.
    public static var userKeyboardAdded: String { String(localized: "core.term.userKeyboardAdded", bundle: .module) }
    public static var userKeyboardNotAdded: String {
        String(localized: "core.term.userKeyboardNotAdded", bundle: .module)
    }
    /// The management page toggles edit a draft; before saving they must not be read as "added".
    public static var userKeyboardSelected: String {
        String(localized: "core.term.userKeyboardSelected", bundle: .module)
    }
    public static var userKeyboardNotSelected: String {
        String(localized: "core.term.userKeyboardNotSelected", bundle: .module)
    }
    public static var userKeyboardDraftHint: String {
        String(localized: "core.term.userKeyboardDraftHint", bundle: .module)
    }

    /// Accessibility label of the toggle: reads both input method and layout (group titles are not read per item).
    public static func userKeyboardToggleLabel(inputMethod: String, layout: KeyboardLayoutKind) -> String {
        let name = inputMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? layoutName(layout) : "\(name)，\(layoutName(layout))"
    }

    /// Message after "Use" switched the keyboard.
    public static func userKeyboardNowUsing(_ title: String) -> String {
        String(format: String(localized: "core.term.userKeyboardNowUsing", bundle: .module), title)
    }

    /// Message for a successful save.
    public static func userKeyboardSaved(count: Int) -> String {
        String(
            format: String(localized: "core.term.userKeyboardSaved", bundle: .module),
            String(max(0, count)))
    }

    /// Sentence appended after a failed or rejected write: the list is unchanged.
    public static var userKeyboardListUnchanged: String {
        String(localized: "core.term.userKeyboardListUnchanged", bundle: .module)
    }

    /// Plain message for a failed user keyboard operation.
    ///
    /// The publication transaction's structured error (`UserKeyboardPublicationError`, always
    /// thrown before any write) carries a plain-language reason: it is used as-is, with a note
    /// that the list is unchanged. Other errors may carry internal detail, so only the caller's
    /// generic message is used; an empty reason or one containing internal terms also falls back.
    public static func userKeyboardFailureMessage(_ error: Error, fallback: String) -> String {
        guard let publication = error as? UserKeyboardPublicationError,
            let raw = publication.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty, leaksInternalTerminology(raw) == nil
        else { return fallback }
        let ended = raw.last.map { "。！？.!?".contains($0) } ?? false
        return (ended ? raw : raw + "。") + userKeyboardListUnchanged
    }

    // MARK: - Trial typing (main app)

    /// General explanation on the trial page: what is typed and how to change keyboards.
    public static var tryUsesCurrentScheme: String {
        String(localized: "core.term.tryUsesCurrentScheme", bundle: .module)
    }

    /// Source detail only knows the published selection. `howToUse` is an imperative phrase
    /// without a trailing period (see `tryHowToUseViaUserKeyboard` etc.).
    public static func trySourceContext(name: String, inUse: Bool, howToUse: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label =
            trimmed.isEmpty
            ? String(format: String(localized: "core.term.thisInputScheme", bundle: .module), inputScheme)
            : "「\(trimmed)」"
        return inUse
            ? String(
                format: String(localized: "core.term.trySourceInUse", bundle: .module), label)
            : String(
                format: String(localized: "core.term.trySourceNotInUse", bundle: .module),
                label, howToUse)
    }

    /// Switch to it via the source's own "user keyboard".
    public static var tryHowToUseViaUserKeyboard: String {
        String(
            format: String(localized: "core.term.tryHowToUseViaUserKeyboard", bundle: .module),
            userKeyboard, startUsing)
    }

    /// Switch to it via "start using".
    public static var tryHowToUseViaStartUsing: String {
        String(format: String(localized: "core.term.tryHowToUseViaStartUsing", bundle: .module), startUsing)
    }

    /// Accessibility label/hint of the tools entry.
    public static var keyboardUtilitiesOpenLabel: String {
        String(localized: "core.term.keyboardUtilitiesOpenLabel", bundle: .module)
    }

    /// Tools entry in the "ABC/Chinese" long-press menu (separate from the candidate bar).
    public static var keyboardMoreTools: String {
        String(localized: "core.term.keyboardMoreTools", bundle: .module)
    }
    /// Entry from the keyboard's own settings to the app that owns the rest of the configuration.
    public static var openHostApp: String { String(localized: "core.term.openHostApp", bundle: .module) }

    // MARK: - Copy gate

    /// Internal terms banned from ordinary UI (case-insensitive match).
    public static let bannedInternalTerms = [
        "schema", "recipe", "resource", "deploy", "prism", "algebra", "generation",
        "键型", "键盘样式", "方案配对",
        "部署", "发布", "配方", "绑定", "幂等", "共享容器", "processor", "lua_",
    ]

    /// Returns the first internal term leaked in the text; nil if none.
    public static func leaksInternalTerminology(_ text: String) -> String? {
        bannedInternalTerms.first { text.localizedCaseInsensitiveContains($0) }
    }
}
