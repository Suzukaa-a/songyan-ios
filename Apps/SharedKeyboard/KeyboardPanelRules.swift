import CandidateKit
import CoreGraphics
import KeyboardCore
import LayoutKit

/// Key-area decisions the live panel and the host previews derive from the same plain values, so a
/// preview cannot drift from the keyboard it shows. Lazy arguments keep the panel's short-circuits:
/// a typing page never resolves page facts it does not read.
enum KeyboardPanelRules {
    /// Main activation is settled on the width before the optional tools rail. Other pages keep its
    /// spacing without its row cuts unless they carry their own split.
    static func activeSplit(
        main: LayoutSplitConfiguration?, mainWidth: Double, showsMainLetters: Bool,
        pageSplit: @autoclosure () -> LayoutSplitConfiguration?, contentWidth: Double,
        showsEnglishLetters: Bool = false, authoredPage: KeyboardPageDefinition? = nil,
        splitAbove: Double = KeyboardSurfaceWidth.phoneMaximum
    ) -> ActiveLayoutSplit? {
        ActiveLayoutSplit.drawn(
            main: main, mainWidth: mainWidth, showsMainLetters: showsMainLetters,
            showsEnglishLetters: showsEnglishLetters, authoredPage: authoredPage,
            pageSplit: pageSplit(), contentWidth: contentWidth, automaticAbove: splitAbove)
    }

    /// The blank margin on each side of a keyboard `panelWidth` wide under the user's width settings.
    /// `systemInsetsSides`: the system already keeps room beside the keyboard (iPhone landscape).
    static func sideMargin(
        panelWidth: Double, settings: KeyboardWidthSettings, systemInsetsSides: Bool = false
    ) -> Double {
        KeyboardWideContentPolicy.sideMargin(
            panelWidth: panelWidth,
            percent: settings.effectiveSideMarginPercent(systemInsetsSides: systemInsetsSides),
            largeAbove: Double(settings.splitWidth))
    }

    /// The width cap a physical layout uses on a wide surface. A main split that really splits at the
    /// full keyboard width keeps the full surface instead of silently cancelling the opt-in. `rawWidth`
    /// is the key area's (the surface after the user's side margins); `fullWidth` decides the split.
    static func wideMaximumContentWidth(
        rawWidth: Double, fullWidth: Double, mainSplit: @autoclosure () -> LayoutSplitConfiguration?,
        layout: KeyboardLayoutKind?,
        splitAbove: Double = KeyboardSurfaceWidth.phoneMaximum
    ) -> Double? {
        guard rawWidth > KeyboardSurfaceWidth.phoneMaximum else { return nil }
        if let split = mainSplit(), split.isActive(width: fullWidth, automaticAbove: splitAbove) { return nil }
        switch layout {
        case .phone9: return KeyboardWideContentPolicy.phoneNineMaximumContentWidth
        case .merged14, .merged18: return KeyboardWideContentPolicy.mergedMaximumContentWidth
        case .qwerty26, nil: return nil
        }
    }

    /// #+= opens the categorised grid when the paired page is categorised, or on a phone keypad
    /// (its 123 page is a digit pad, with no rows for a second page to share); otherwise it is the
    /// row-shaped page that shares the 123 page's geometry.
    static func showsCategorySymbolPage(
        page: KeyboardPage, authoredPage: @autoclosure () -> KeyboardPageDefinition?,
        mainIsPhoneKeypad: @autoclosure () -> Bool
    ) -> Bool {
        guard page == .symbols else { return false }
        return KeyboardPageResolver.symbolPresentation(
            page: authoredPage(), mainLayoutIsPhoneKeypad: mainIsPhoneKeypad()) == .categorized
    }

    /// The bundled 9-key, and every categorised symbol page except an imported phone keypad's
    /// (which keeps its declared rails), draw the fixed ⌫ / 重输 / ⏎ column and the phone bottom row.
    static func usesFixedEditingRail(
        showsCategorySymbolPage: Bool, hasAuthoredPage: @autoclosure () -> Bool,
        mainIsPhoneKeypad: @autoclosure () -> Bool, mainIsBuiltinPhonePad: @autoclosure () -> Bool
    ) -> Bool {
        showsCategorySymbolPage
            ? (!mainIsPhoneKeypad() || mainIsBuiltinPhonePad())
            : (mainIsBuiltinPhonePad() && !hasAuthoredPage())
    }

    /// The key-area shell the panel and the main-layout preview draw. Order matters: an authored
    /// chrome page owns its whole shell, a phone keypad's 123 page and the categorised #+= grid
    /// come before the letter shells, and the phone pad wins over the bundled 26-key shell.
    static func keyAreaRenderer(
        page: KeyboardPage, isEnglishMode: Bool, authoredPage: KeyboardPageDefinition?,
        facts: DefinitionResolutionMemo.Facts, showsCategorySymbolPage: @autoclosure () -> Bool,
        splitHalves: Bool = false
    ) -> KeyAreaRenderer {
        if authoredPage?.chrome != nil { return .authoredChromePage }
        if authoredPage == nil && page == .numeric && facts.isPhone { return .phoneDigitPad }
        if showsCategorySymbolPage() { return .categorySymbolPage }
        if authoredPage != nil { return .authoredRows }
        guard page == .letters else { return .symbolRows }
        if !isEnglishMode && facts.isPhone { return .phonePad }
        // The Chinese letters of a split layout draw its own split keys; English follows the rows.
        if !isEnglishMode && splitHalves && facts.splitLetters != nil { return .splitHalves }
        if isEnglishMode || facts.isBundledQwertyMainShell { return .standardQwerty }
        return facts.isBundledMergedPad ? .mergedPad : .configuredRows
    }

    /// The phone treatment belongs to the visible shell: an English QWERTY letter page uses the
    /// shared symbol entry and bottom Return even when the Chinese definition is a phone pad.
    static func phoneShellVisible(
        usesStandardT9: Bool, page: KeyboardPage, hasAuthoredPage: @autoclosure () -> Bool,
        mainIsPhoneKeypad: @autoclosure () -> Bool, showsCategorySymbolPage: @autoclosure () -> Bool
    ) -> Bool {
        usesStandardT9 || (!hasAuthoredPage() && mainIsPhoneKeypad() && page != .letters)
            || showsCategorySymbolPage()
    }

    /// Imported phone letter pages keep their declared bottom controls; Return stays off the bottom
    /// row while a visible phone rail already carries it.
    static func controlPolicy(
        page: KeyboardPage, isEnglishMode: Bool, hasGlobe: Bool, usesASCIIPunctuation: Bool,
        phoneShellVisible: Bool, usesFixedEditingRail: Bool,
        declaredTrailingReturn: @autoclosure () -> Bool, showsCategorySymbolPage: Bool,
        numericPageReachesSymbols: Bool = true,
        script: KeyLabelScript = .simplifiedChinese,
        showsSpaceSideMarks: Bool = false,
        offersSymbolLibrary: Bool = false
    ) -> KeyboardControlPolicy {
        let trailingHasReturn = !usesFixedEditingRail && phoneShellVisible && declaredTrailingReturn()
        return KeyboardControlPolicy(
            page: page, isEnglishMode: isEnglishMode, hasGlobe: hasGlobe,
            isPhoneLayout: phoneShellVisible, usesASCIIPunctuation: usesASCIIPunctuation,
            includesBottomEnter: !phoneShellVisible || (!usesFixedEditingRail && !trailingHasReturn),
            usesCategorySymbolPage: showsCategorySymbolPage, numericPageReachesSymbols: numericPageReachesSymbols,
            usesDigitPadRow: usesFixedEditingRail, script: script,
            showsSpaceSideMarks: showsSpaceSideMarks, offersSymbolLibrary: offersSymbolLibrary)
    }

    /// A row too narrow to keep a usable space bar falls back to the single mark; the layout
    /// decides, not a key branch of its own. The keyboard and its previews share this rule.
    static func fittingSpaceSideMarks(_ policy: KeyboardControlPolicy, contentWidth: Double) -> KeyboardControlPolicy {
        guard policy.showsSpaceSideMarks, policy.metrics(width: contentWidth).space >= 44
        else { return policy.withSpaceSideMarks(false) }
        return policy
    }

    /// The known bundled main-shell preset (26 or merged 14/18) whose main rows still provide the
    /// native geometry. Footer/aux sheets are not part of this identity.
    static func knownMainShellPreset(_ facts: DefinitionResolutionMemo.Facts) -> LayoutDefinition? {
        if facts.isBundledQwertyMainShell { return BuiltinLayouts.qwerty26 }
        if facts.isBundledMergedPad {
            switch facts.active?.input.builtinLayout {
            case .some(.merged14): return BuiltinLayouts.merged14
            case .some(.merged18): return BuiltinLayouts.merged18
            default: return nil
            }
        }
        return nil
    }

    /// The preset key at the same declared address (`row-<row>-<key>` or `merged-<row>-<key>`), for
    /// the per-key face/long-press comparison. The address, not the action, identifies a key: an
    /// edited action must still compare against the key it replaced.
    static func mainShellPresetKey(in preset: LayoutDefinition, id: String, key: LayoutKey) -> LayoutKey? {
        // Runs per rendered key: parse in place instead of building arrays.
        let address: Substring
        if id.hasPrefix("row-") {
            address = id.dropFirst(4)
        } else if id.hasPrefix("merged-") {
            address = id.dropFirst(7)
        } else {
            return nil
        }
        guard let dash = address.firstIndex(of: "-"),
            let row = Int(address[..<dash]), let column = Int(address[address.index(after: dash)...]),
            preset.rows.indices.contains(row), preset.rows[row].keys.indices.contains(column)
        else { return nil }
        return preset.rows[row].keys[column]
    }

    /// The bundled merged pad's face policy (lowercase caps, suppressed secondary labels) only
    /// applies while the key face is still the preset. An authored label/secondary/title is shown
    /// verbatim; the letter group and swipe still come from that authored label.
    static func keyFaceUnchanged(_ key: LayoutKey, preset: LayoutKey) -> Bool {
        key.label == preset.label
            && key.secondaryLabel == preset.secondaryLabel
            && key.titleMode == preset.titleMode
            && key.action == preset.action
            && key.width == preset.width
    }

    /// A literal key of a page without authored chrome. Explicit bilingual pairs resolve first: an
    /// English page may pair arbitrary text, so the single-letter code heuristic must not swallow
    /// it. Fixed literals keep their value; a long-press list shows its first entry in the corner.
    static func pageCap(
        _ key: LayoutKey, id: String, kind: KeyboardPageKind, alternate: Bool, usesASCIIPunctuation: Bool,
        shiftActive: @autoclosure () -> Bool
    ) -> KeyCap {
        if let literal = key.resolvedLiteralValue(usesASCIIPunctuation: usesASCIIPunctuation) {
            let paired = key.action.isPairedLiteral
            let letter =
                !paired && kind == .english && literal.count == 1
                && literal.utf8.count == 1 && literal.first?.isLetter == true
            let action: KeyAction =
                letter
                ? (alternate ? .letterVariant(literal) : .code(literal.lowercased()))
                : .literal(literal)
            let title = key.literalFaceTitle(usesASCIIPunctuation: usesASCIIPunctuation)
            return KeyCap(
                id: id,
                title: letter && shiftActive() ? title.uppercased() : title,
                subtitle: key.secondaryLabel ?? key.longPress?.first?.label, action: action)
        }
        let value = key.action.value ?? ""
        let letter = kind == .english && value.count == 1 && value.utf8.count == 1 && value.first?.isLetter == true
        let action: KeyAction =
            letter
            ? (alternate ? .letterVariant(value) : .code(value.lowercased()))
            : key.action.keyAction(usesASCIIPunctuation: usesASCIIPunctuation)
        // English letters follow Shift as before; other pages follow it for the code keys Shift
        // capitalises (see `KeyCapShiftTitle`). A custom title keeps its label.
        let followsShift = letter || (key.titleMode != .custom && KeyCapShiftTitle.followsShift(action))
        return KeyCap(
            id: id, title: followsShift && shiftActive() ? key.label.uppercased() : key.label,
            subtitle: key.secondaryLabel ?? key.longPress?.first?.label, action: action)
    }
}

/// Which key-area shell draws the current page; resolved once by `KeyboardPanelRules.keyAreaRenderer`.
enum KeyAreaRenderer: Equatable {
    /// An authored page whose rows, rails and footer all come from data.
    case authoredChromePage
    /// The digit pad a phone keypad uses for its 123 page.
    case phoneDigitPad
    /// The categorised #+= grid.
    case categorySymbolPage
    /// An authored page without chrome, drawn in the ordinary rows area.
    case authoredRows
    /// The phone-keypad letter shell (bundled T9 and imported definitions of the same structure).
    case phonePad
    /// The layout's own split keys, one arrangement for both halves (see `SplitLetterPage`).
    case splitHalves
    case standardQwerty
    case mergedPad
    case configuredRows
    /// The row-shaped 123 / #+= pages.
    case symbolRows
}

extension LayoutAction {
    /// The engine action a layout action maps to. Page-level UI actions have no engine face; only
    /// authored chrome keys dispatch them, so they map onto the control tone (`.cycleLayout`).
    /// The symbol branch is only read for literals.
    func keyAction(usesASCIIPunctuation: @autoclosure () -> Bool) -> KeyAction {
        switch type {
        case .code: return .code(value ?? "")
        case .literal: return .literal(literalValue(usesASCIIPunctuation: usesASCIIPunctuation()) ?? "")
        case .space: return .space
        case .backspace: return .backspace
        case .enter: return .enter
        case .globe: return .switchKeyboard
        case .modeSwitch: return .cycleLayout
        case .shift, .pageSwitch, .languageSwitch, .symbolLock, .symbolLibrary, .clearInput, .layoutPageSwitch,
            // The kana kinds are dispatched by the kana renderer/handler, never as one engine key:
            // a whole kana row or a caret move has no single Latin codeword, and an edited board's
            // stored kana action must not be flattened into one.
            .kana, .kanaModifier, .cursorLeft:
            return .cycleLayout
        }
    }
}

// MARK: - Candidate band

/// Whether a page keeps the candidate band. A layout's own letters follow the layout; ABC always
/// keeps its word suggestions, 123 and #+= only a live composition. On a wide surface the keyboard's
/// dismiss entry sits in the band, and without it a rail beside the keys takes their width, so every
/// page keeps the band there: flipping to 123 never narrows the key area.
enum KeyboardCandidateBand {
    static func required(
        definitionPage: Bool, definitionRequires: Bool, lettersPage: Bool, keepsForComposition: Bool,
        wideDismiss: Bool
    ) -> Bool {
        if definitionPage { return definitionRequires }
        return lettersPage || keepsForComposition || wideDismiss
    }
}

// MARK: - Authored control-row shortcuts

/// The shortcuts the keyboard bar adds around an authored control row, and which entries that row
/// already declares. A row that declares its own 123 key is drawn as the author stored it, as on
/// Android: the editor starts from the keyboard's whole bottom row, so nothing is missing from it.
/// An older row without one keeps the shortcuts it always had, so no layout loses its way to the
/// 123 page. A declared entry is never duplicated: a 中英 key counts under either action kind an
/// authored row may use for it. The globe is added whenever the system needs one and the layout
/// has none, since it is the only way to the next keyboard.
struct KeyboardFooterShortcutPlan: Equatable {
    let supplementShortcuts: Bool
    let declaresNumericShortcut: Bool
    let declaresSymbolShortcut: Bool
    let declaresLayoutSwitch: Bool

    init(controlRow: LayoutRow?, supplementShortcuts: Bool = true) {
        let keys = controlRow?.keys ?? []
        let declaresNumericShortcut = keys.contains { $0.action.pageSwitchTarget == .numeric }
        self.supplementShortcuts = supplementShortcuts && !declaresNumericShortcut
        self.declaresNumericShortcut = declaresNumericShortcut
        declaresSymbolShortcut = keys.contains { $0.action.pageSwitchTarget == .symbols }
        declaresLayoutSwitch = keys.contains {
            $0.action.type == .modeSwitch || $0.action.type == .languageSwitch
        }
    }

    /// Whether the bar adds its 123 shortcut.
    var addsNumericShortcut: Bool { supplementShortcuts && !declaresNumericShortcut }

    /// Whether the bar adds its symbol-page shortcut.
    var addsSymbolShortcut: Bool { supplementShortcuts && !declaresSymbolShortcut }

    /// Whether the bar adds its 中/英 shortcut; a declared one stays where the author put it.
    var addsLayoutSwitch: Bool { supplementShortcuts && !declaresLayoutSwitch }

    /// Whether the bar adds the globe key.
    func addsGlobe(definitionHasGlobe: Bool, showsGlobe: Bool) -> Bool {
        !definitionHasGlobe && showsGlobe
    }

    /// Whether the bar supplements this physical layout's authored footer. Only the bundled boards
    /// whose footer declares every control key rely on the declaration alone.
    static func supplements(physicalLayoutID: String?) -> Bool {
        guard let physicalLayoutID else { return true }
        return physicalLayoutID != BuiltinLayouts.zhuyin41.id
            && physicalLayoutID != BuiltinLayouts.cangjie26.id
    }
}

// MARK: - Keyboard title

/// Published identities carry the transport kind, so a resolved physical name takes precedence.
enum KeyboardTitleRule {
    static func title(
        published: String?, inputMethodName: String?, isBundled: Bool,
        physicalLayoutID: String?, definitionName: String?, kindName: String,
        builtinName: (String) -> String?
    ) -> String {
        if isBundled, let physicalLayoutID, let board = builtinName(physicalLayoutID) {
            return UserKeyboard.physicalBoardTitle(
                inputMethodName: inputMethodName, physicalLayoutName: board) ?? board
        }
        if let published { return published }
        if isBundled { return kindName }
        return definitionName ?? kindName
    }
}
