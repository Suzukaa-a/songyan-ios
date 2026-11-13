import Foundation

/// Builtin presentation policy. DIY rows/actions are deliberately outside this policy.
/// Page changes never own or mutate the engine's remembered Chinese/English mode.
public struct KeyboardControlPolicy: Equatable, Sendable {
    /// The page a control row sits on is the same set a `.pageSwitch` key can open.
    public typealias Page = LayoutAction.PageTarget
    public enum Slot: CaseIterable, Hashable, Sendable {
        case page, language, globe, space, utility, enter
        /// The runtime footer's comma left of the space bar and full stop right of it; they exist
        /// only while `showsSpaceSideMarks` is on and the row is wide enough.
        case markLeft, markRight
        /// Keys, never positions: the direct 「符号」 key of a letter page whose 123 page cannot
        /// reach the symbol page, and the symbol page's 锁定 toggle (in the utility position).
        case symbolPage, symbolLock
        /// A key, never a position: 更多 on the row-shaped symbol page, in the utility position. It
        /// opens the categorized symbol library instead of typing a mark.
        case symbolLibrary
        /// A semantic key, never a physical slot: the 123 the row-shaped #+= page's left
        /// switch is "return to letters" (preserving the input language), not a language toggle.
        case returnToLetters
    }
    public enum LanguageAction: Equatable, Sendable {
        case toggleLanguage
        /// Switch only the panel's symbol language and keep the current page (123 / row-shaped #+=).
        case toggleSymbols
        /// Return to the main letter keyboard without changing the Chinese/English input state.
        case returnToLetters
    }
    public enum Utility: Equatable, Sendable {
        case punctuation(String)
        /// An imported keypad's 123 page: its declared trailing rail has no 0, so the slot types it.
        case digit(String)
    }

    public let page: Page
    public let isEnglishMode: Bool
    public let hasGlobe: Bool
    public let isPhoneLayout: Bool
    public let usesASCIIPunctuation: Bool
    /// Bundled T9 moves Return into its large trailing rail. Other surfaces keep it
    /// in the bottom row. This is presentation only; the action remains `.enter`.
    public let includesBottomEnter: Bool
    /// The #+= page is the categorized grid (with 锁定) rather than rows of keys
    /// shaped like the 123 page's.
    public let usesCategorySymbolPage: Bool
    /// The 123 page this letter page opens carries its own switch to the symbol page (the row
    /// page's third-row switch, or an authored page's symbol switch). Only then does the letter
    /// page's utility position type punctuation instead of opening the symbol page.
    public let numericPageReachesSymbols: Bool
    /// The 123 page is drawn as the digit pad on the nine-key letter shell's grid. An imported
    /// keypad keeps its own declared rails and bottom row, so the shell flag alone is not enough.
    public let usesDigitPadRow: Bool
    /// The scheme's input language for automatic faces; author labels never read it.
    public let script: KeyLabelScript
    /// The row-shaped symbol page already types every mark, so its utility position opens the
    /// symbol library (更多) instead of typing one. The native panel, its preview and an
    /// unchanged materialized copy use the same choice; authored keys keep their own actions.
    public let offersSymbolLibrary: Bool
    /// The native footer puts a comma left of the space bar and a full stop right of it. Off for
    /// authored pages and narrow native rows, which keep their declared or single comma key.
    public private(set) var showsSpaceSideMarks: Bool
    /// Which marks sit beside the space bar: the sentence marks, or the address marks a URL or
    /// email field types most. The keys stay where they are; only their marks change.
    public private(set) var fieldMarks: FieldMarks = .sentence

    public enum FieldMarks: Equatable, Sendable {
        case sentence, url, email
    }
    /// The bundled phone shell's column widths. When set, the first bottom key sits
    /// under the rail and the rest share the grid's width with a wide space bar
    /// (see `Metrics.init(width:columns:includesUtility:)`) instead of the generic
    /// budget.
    public private(set) var phoneColumns: PhoneColumns?

    public struct PhoneColumns: Equatable, Sendable {
        public let rail: Double
        public let digit: Double
        public init(rail: Double, digit: Double) {
            self.rail = rail
            self.digit = digit
        }
    }

    public func aligned(to columns: PhoneColumns?) -> KeyboardControlPolicy {
        var copy = self
        copy.phoneColumns = columns
        return copy
    }

    public init(
        page: Page, isEnglishMode: Bool, hasGlobe: Bool,
        isPhoneLayout: Bool, usesASCIIPunctuation: Bool,
        includesBottomEnter: Bool = true, usesCategorySymbolPage: Bool = true,
        numericPageReachesSymbols: Bool = true, usesDigitPadRow: Bool = false,
        script: KeyLabelScript = .simplifiedChinese, showsSpaceSideMarks: Bool = false,
        offersSymbolLibrary: Bool = false
    ) {
        self.page = page
        self.isEnglishMode = isEnglishMode
        self.hasGlobe = hasGlobe
        self.isPhoneLayout = isPhoneLayout
        self.usesASCIIPunctuation = usesASCIIPunctuation
        self.includesBottomEnter = includesBottomEnter
        self.usesCategorySymbolPage = usesCategorySymbolPage
        self.numericPageReachesSymbols = numericPageReachesSymbols
        self.usesDigitPadRow = usesDigitPadRow
        self.script = script
        self.showsSpaceSideMarks = showsSpaceSideMarks
        self.offersSymbolLibrary = offersSymbolLibrary
    }

    /// The same policy with the space bar's marks chosen for the host field.
    public func withFieldMarks(_ marks: FieldMarks) -> KeyboardControlPolicy {
        var copy = self
        copy.fieldMarks = marks
        return copy
    }

    /// The same policy with the runtime footer marks switched on or off.
    public func withSpaceSideMarks(_ enabled: Bool) -> KeyboardControlPolicy {
        var copy = self
        copy.showsSpaceSideMarks = enabled
        return copy
    }

    /// Slot identities and count stay unchanged across all pages and languages
    /// **for one surface**. Only an actual system-keyboard availability change may
    /// add/remove globe, and only the bundled T9 (which moves Return into its own
    /// trailing column) may drop `enter`. The utility position types the comma on letter
    /// and row-shaped 123 / #+= pages (or opens symbols where 123 cannot), has no utility slot on the
    /// phone digit pad (the comma sits in its right column) and locks the categorized symbol page.
    ///
    /// The globe sits immediately left of the space bar, in the comma's slot of the split footer;
    /// in the corner it took the thumb's aim for the page key. A surface without a system-keyboard
    /// switch has no globe slot, and the freed width goes to space/Return.
    public var slots: [Slot] {
        if isDigitPad {
            return [.page, .globe, .language, .space, .symbolPage, .enter].filter { $0 != .globe || hasGlobe }
        }
        // With the marks beside the space bar, the system's globe takes the comma's slot and the
        // key right of the space bar becomes the comma: no other key moves when the globe comes or goes.
        let row: [Slot] =
            showsSpaceSideMarks
            ? [.page, .language, hasGlobe ? .globe : .markLeft, .space, .utility, .enter]
            : [.page, .language, .globe, .space, .utility, .enter]
        return row.filter {
            ($0 != .globe || hasGlobe) && ($0 != .enter || includesBottomEnter)
        }
    }

    /// The phone digit pad's row is a grid row, not a control row: 返回 under the rail, then 中/英,
    /// the space bar and 符号 under the three digit columns and Return under the trailing column,
    /// which holds Delete, 0 and the comma above it. The globe, when shown, shares the first digit
    /// column with 中/英, so 返回 keeps its whole cell.
    public var isDigitPad: Bool { usesDigitPadRow && isBundledPhonePad && page == .numeric }

    /// The row-shaped 123 / #+= page: its third row opens with the 123/symbol switch.
    public var isRowPage: Bool {
        page != .letters && !isPhoneLayout && !(page == .symbols && usesCategorySymbolPage)
    }

    /// Slots are *positions* (width and view identity stay put); on 123 / #+= the
    /// return-to-letters key takes the page position, while the globe keeps the
    /// leading position it has on every page.
    ///
    /// The comma sits in the utility slot on the letter page and on the row-shaped
    /// 123 / #+= pages alike (long press for the other sentence marks), so it never moves
    /// when the page flips, as Gboard keeps its punctuation slots. A phone keypad's letter
    /// page, or one paired with a 123 page that has no symbol switch, opens the symbol page
    /// from there instead so it stays reachable. The phone digit pad keeps 0 there.
    ///
    /// The categorized symbol page carries 锁定 in the utility position: its grid
    /// already types every mark, and the lock decides whether the page stays open
    /// after a symbol (Sogou and iFlytek return to letters unless locked).
    public func key(at slot: Slot) -> Slot {
        switch page {
        case .letters:
            guard slot == .utility else { return slot }
            return lettersTypePunctuation ? .utility : .symbolPage
        case .numeric:
            // 123: the left switch returns to letters (keeping the language) and the language key
            // switches the symbol branch in place. The row page types the comma there, a digit
            // pad has no such slot (bundled 9-key) or the #+= switch (imported keypad, no rows).
            switch slot {
            case .page: return .returnToLetters
            case .utility: return isRowPage || isBundledPhonePad ? .utility : .page
            default: return slot
            }
        case .symbols:
            if usesCategorySymbolPage {
                // Categorized grid: the page position returns (keeping the language), the
                // language position opens 123, and the utility position is the lock.
                switch slot {
                case .page: return .language
                case .language: return .page
                case .utility: return .symbolLock
                default: return slot
                }
            }
            if slot == .utility && offersSymbolLibrary && !isPhoneLayout { return .symbolLibrary }
            return slot == .page ? .returnToLetters : slot
        }
    }

    private var lettersTypePunctuation: Bool { !isPhoneLayout && numericPageReachesSymbols }

    /// The phone-pad row: the bundled 9-key, and every layout's categorized symbol
    /// page, move Return into their own trailing column.
    public var isBundledPhonePad: Bool { isPhoneLayout && !includesBottomEnter }

    public var pageTarget: Page { page == .numeric ? .symbols : .numeric }
    public var pageTitle: String {
        guard pageTarget == .symbols else { return KeyLabelPolicy.numericPageTitle }
        return symbolPageTitle
    }
    /// The automatic face of a key that opens the symbol page (the D27 符 key included).
    public var symbolPageTitle: String { KeyLabelPolicy.symbolPageTitle(script: script) }

    /// The automatic space caption; an author label is drawn by its owner instead.
    public func spaceTitle(isComposing: Bool) -> String {
        KeyLabelPolicy.spaceTitle(script: script, isComposing: isComposing)
    }

    public func spaceAccessibilityLabel(isComposing: Bool) -> String {
        KeyLabelPolicy.spaceAccessibilityLabel(script: script, isComposing: isComposing)
    }

    /// Spoken name of a page switch, read by the panel and both previews.
    public func pageSwitchAccessibilityLabel(for target: Page, isBundledPhonePad: Bool) -> String {
        KeyLabelPolicy.pageSwitchAccessibilityLabel(target: target, isBundledPhonePad: isBundledPhonePad)
    }

    /// The page-following default: letters toggle the input language; 123 (the 9-key digit pad
    /// included) and the row-shaped #+= page switch the symbol language in place; the categorized
    /// symbol grid returns to the main letter keyboard.
    public var languageAction: LanguageAction { languageAction(for: nil) }

    /// What the language key does. Nil follows the page; an authored behavior overrides the page
    /// rule, including the categorized page's return default.
    public func languageAction(for behavior: LayoutAction.LanguageSwitchBehavior?) -> LanguageAction {
        switch behavior {
        case .symbols: return .toggleSymbols
        case .letters: return .returnToLetters
        case nil:
            switch page {
            case .letters: return .toggleLanguage
            case .numeric: return .toggleSymbols
            case .symbols: return usesCategorySymbolPage ? .returnToLetters : .toggleSymbols
            }
        }
    }

    public var languageTitle: String { languageTitle(for: nil) }
    public func languageTitle(for behavior: LayoutAction.LanguageSwitchBehavior?) -> String {
        KeyLabelPolicy.languageTitle(
            script: script, action: languageAction(for: behavior),
            isEnglishMode: isEnglishMode, usesASCIIPunctuation: usesASCIIPunctuation)
    }

    public func languageCurrentSideIsFirst(for behavior: LayoutAction.LanguageSwitchBehavior?) -> Bool? {
        KeyLabelPolicy.languageCurrentSideIsFirst(
            action: languageAction(for: behavior),
            isEnglishMode: isEnglishMode, usesASCIIPunctuation: usesASCIIPunctuation)
    }

    public var languageAccessibilityLabel: String { languageAccessibilityLabel(for: nil) }
    public func languageAccessibilityLabel(for behavior: LayoutAction.LanguageSwitchBehavior?) -> String {
        KeyLabelPolicy.languageAccessibilityLabel(
            script: script, action: languageAction(for: behavior),
            isEnglishMode: isEnglishMode, usesASCIIPunctuation: usesASCIIPunctuation)
    }
    public var utility: Utility {
        isBundledPhonePad && page == .numeric && !isDigitPad
            ? .digit("0") : .punctuation(showsSpaceSideMarks && !hasGlobe ? fullStopText : singleMarkText)
    }

    /// The one mark of a footer without the comma beside the space bar: the comma in sentences,
    /// the field's own mark in a URL or email field.
    public var singleMarkText: String { fieldMarks == .sentence ? utilityText : fullStopText }

    /// The runtime footer's full stop right of the space bar; the same mark in every script.
    public static let fullStop = "。"

    /// The full stop the split footer draws: ASCII marks keep the footer's shape and change the mark,
    /// so 中/英 never moves a key.
    public var fullStopText: String {
        switch fieldMarks {
        case .url: return "/"
        case .email: return "."
        case .sentence: return usesASCIIPunctuation ? "." : Self.fullStop
        }
    }

    /// The mark left of the space bar: the comma, or `:` in a URL and `@` in an email field.
    public var markLeftText: String {
        switch fieldMarks {
        case .url: return ":"
        case .email: return "@"
        case .sentence: return utilityText
        }
    }

    public var markLeftAlternates: [String] {
        switch fieldMarks {
        case .url: return [".", "-", "_", "@"]
        case .email: return ["_", "-", "+"]
        case .sentence: return utilityAlternates
        }
    }

    /// Only the effective symbol branch decides the width; the input script names the mark:
    /// Japanese types 、 where Chinese types ，.
    public var utilityText: String {
        guard !usesASCIIPunctuation else { return "," }
        return script == .japanese ? "、" : "，"
    }

    /// The punctuation slot's long-press list, its first entry being the corner hint. Japanese
    /// adds ・ here; ASCII fields keep only typeable marks.
    ///
    /// With the split footer the full stop sits on its own key, so this comma holds only the pauses;
    /// the single-mark footer keeps the full sentence-mark list.
    /// The face of 更多 follows the input language, like the other automatic control titles.
    public var symbolLibraryTitle: String { KeyLabelPolicy.symbolLibraryTitle(script: script) }

    public var utilityAlternates: [String] {
        if showsSpaceSideMarks, hasGlobe, fieldMarks != .sentence { return fullStopAlternates }
        if showsSpaceSideMarks, !hasGlobe {
            return usesASCIIPunctuation ? ["'", ";", ":"] : [script == .japanese ? "・" : "、", "：", "；"]
        }
        if usesASCIIPunctuation { return [".", "?", "!", "'", "\""] }
        return script == .japanese ? ["。", "？", "！", "・", "…"] : ["。", "？", "！", "、", "…"]
    }

    /// The split footer's full stop key holds the sentence-ending marks.
    public var fullStopAlternates: [String] {
        switch fieldMarks {
        case .url: return [".", "?", "=", "&", "#"]
        case .email: return ["-", "_"]
        case .sentence: return usesASCIIPunctuation ? ["?", "!", "…"] : ["？", "！", "…"]
        }
    }

    /// One budget for every builtin page. Fractions apply to *content* width after gaps.
    /// At 382pt content (390pt phone minus panel insets) with globe:
    /// 44/44/44/114.8/44/71.2pt, plus five 4pt gaps. The two switches keep the
    /// 44pt target and the width they no longer take goes to space, the most-hit key.
    /// Without the globe, Return makes the right side as wide as the left, so the space bar
    /// is centred on every page. Return never falls below 60pt on a supported >=320pt
    /// keyboard; extremely small previews scale as a whole.
    public func metrics(width: Double) -> Metrics {
        if isDigitPad { return Metrics(digitPadWidth: width, rail: phoneColumns?.rail, hasGlobe: hasGlobe) }
        if let phoneColumns, !hasGlobe, !includesBottomEnter {
            return Metrics(width: width, columns: phoneColumns, includesUtility: true)
        }
        if showsSpaceSideMarks {
            return Metrics(
                width: width, hasGlobe: hasGlobe, includesEnter: includesBottomEnter,
                withSpaceSideMarks: true)
        }
        return Metrics(
            width: width, hasGlobe: hasGlobe, includesEnter: includesBottomEnter,
            includesUtility: true)
    }

    public struct Metrics: Equatable, Sendable {
        public let spacing: Double
        public let page: Double
        public let language: Double
        public let globe: Double
        public let space: Double
        public let utility: Double
        public let enter: Double
        /// The symbol page key; as wide as the page switches except on the digit pad.
        public let symbolPage: Double
        /// The runtime footer's comma left of the space bar; zero when it is not shown.
        public let markLeft: Double
        /// The runtime footer's full stop right of the space bar; zero when it is not shown.
        public let markRight: Double

        /// The digit pad row: one cell under the rail (`rail` wide, or a fifth of the row without
        /// the shell's columns), three equal cells under the digit columns and one under the
        /// trailing column, as wide as the rail. With the globe, 返回 keeps the first cell and the
        /// globe and 中/英 split the second.
        public init(digitPadWidth width: Double, rail: Double?, hasGlobe: Bool) {
            let width = width.isFinite ? max(0, width) : 0
            let side = min(width / 2, max(0, rail ?? (width - 16) / 5))
            let cell = max(0, (width - 2 * side - 16) / 3)
            let shared = max(0, (cell - 4) / 2)
            self.init(
                spacing: 4, page: side, language: hasGlobe ? shared : cell,
                globe: hasGlobe ? shared : 0, space: cell, utility: 0, enter: side, symbolPage: cell)
        }

        /// The rows that also carry the runtime comma/full stop around the space bar.
        public init(width: Double, hasGlobe: Bool, includesEnter: Bool, withSpaceSideMarks: Bool) {
            self = Self.sideMarksBudget(
                width: width, hasGlobe: hasGlobe, includesEnter: includesEnter)
        }

        public init(
            width: Double, hasGlobe: Bool, includesEnter: Bool = true,
            includesUtility: Bool = true
        ) {
            let width = width.isFinite ? max(0, width) : 0
            let count = (hasGlobe ? 4 : 3) + (includesUtility ? 1 : 0) + (includesEnter ? 1 : 0)
            // Without the globe, Return takes whatever makes the keys right of the space bar as wide
            // as those left of it, so the space bar sits on the centre line on every page. With the
            // globe the width goes to the space bar instead: it is the most-hit key.
            let centredContent = 252.0
            let centred =
                !hasGlobe && includesUtility && includesEnter
                && width >= centredContent + Double(count - 1) * 4
            let minimumContent =
                centred
                ? centredContent
                : (hasGlobe ? 188.0 : 144.0) + (includesUtility ? 44.0 : 0) + (includesEnter ? 60.0 : 0)
            let minimumTotal = minimumContent + Double(count - 1) * 4
            let scale = min(1, width / minimumTotal)
            spacing = 4 * scale
            let unit = scale * Self.columnGrowth(width: width)
            let content = max(0, width - Double(count - 1) * spacing)
            let extra = max(0, content - minimumContent * unit)
            if hasGlobe {
                // The globe already takes a slot; keeping both switches at the 44pt target
                // hands their old base + growth to space instead of widening the switches.
                page = 44 * unit
                language = page
            } else {
                // The centred base budget is 52 + 52 + 44 + 44 + 60; the switches grow a little
                // and Return follows them, the rest goes to space.
                page = (centred ? 52 : 50) * unit + min(12, extra * 0.10)
                language = page
            }
            globe = hasGlobe ? 44 * unit : 0
            utility = includesUtility ? 44 * unit : 0
            if centred {
                enter = page + language - utility
            } else {
                enter = includesEnter ? 60 * unit + min(20, extra * 0.16) : 0
            }
            space = max(0, content - page - language - globe - utility - enter)
            symbolPage = page
            markLeft = 0
            markRight = 0
        }

        /// Phone row: the first key sits under the rail; the keys under the 3×3 grid
        /// do not follow its columns. Like iFlytek's and Sogou's 9-key, the space bar
        /// takes most of that span (side keys : space ≈ 1 : 2.4 : 1), since it is the
        /// most-hit key of the row, and the two side switches stay wide enough to hit.
        /// Falls back to the generic budget when the span cannot fit.
        public init(width: Double, columns: PhoneColumns, includesUtility: Bool) {
            let width = width.isFinite ? max(0, width) : 0
            let gaps = Double(includesUtility ? 3 : 2) * 4
            let span = width - columns.rail - gaps
            let sideShare = includesUtility ? 1 / 4.4 : 1 / 3.4
            let side = span * sideShare
            guard columns.rail >= 0, side >= 44, span - side * (includesUtility ? 2 : 1) >= 44 else {
                self.init(
                    width: width, hasGlobe: false, includesEnter: false,
                    includesUtility: includesUtility)
                return
            }
            self.init(
                spacing: 4, page: columns.rail, language: side, globe: 0,
                space: span - side * (includesUtility ? 2 : 1),
                utility: includesUtility ? side : 0, enter: 0)
        }

        /// The rows that also carry the runtime comma/full stop around the space bar. The marks
        /// take a constant share and the space bar keeps the rest, so the row still fills the width.
        /// The two marks are the same size and Return takes the rest of the right side, so Return
        /// is never narrower than a mark.
        private static func sideMarksBudget(
            width: Double, hasGlobe: Bool, includesEnter: Bool
        ) -> Metrics {
            let width = width.isFinite ? max(0, width) : 0
            // The globe and the comma share one slot, so both machines draw the same six keys.
            let count = includesEnter ? 6 : 5
            let minimumContent = 40.0 + 40 + 40 + 44 + 40 + (includesEnter ? 80.0 : 0)
            let minimumTotal = minimumContent + Double(count - 1) * 4
            let scale = min(1, width / minimumTotal)
            let spacing = 4 * scale
            let unit = scale * columnGrowth(width: width)
            let content = max(0, width - Double(count - 1) * spacing)
            let page = 40 * unit
            let language = page
            let mark = 40 * unit
            let markLeft = hasGlobe ? 0 : mark
            let utility = mark
            let globe = hasGlobe ? mark : 0
            let enter = includesEnter ? 80 * unit : 0
            let space = max(0, content - page - language - mark - utility - enter)
            return Metrics(
                spacing: spacing, page: page, language: language, globe: globe, space: space,
                utility: utility, enter: enter, markLeft: markLeft, markRight: utility)
        }

        /// How much wider the letter columns above a `width` wide row are than a phone's: the keys
        /// beside the space bar grow with them, so a wide board's space bar does not take all the
        /// extra room and squeeze its neighbours. 1 on every phone.
        public static func columnGrowth(width: Double) -> Double {
            StandardKeyRowGeometry(width: width).keyGapScale()
        }

        private init(
            spacing: Double, page: Double, language: Double, globe: Double,
            space: Double, utility: Double, enter: Double, symbolPage: Double? = nil,
            markLeft: Double = 0, markRight: Double = 0
        ) {
            self.spacing = spacing
            self.page = page
            self.language = language
            self.globe = globe
            self.space = space
            self.utility = utility
            self.enter = enter
            self.symbolPage = symbolPage ?? page
            self.markLeft = markLeft
            self.markRight = markRight
        }

        public subscript(slot: Slot) -> Double {
            switch slot {
            case .page: return page
            case .language: return language
            case .globe: return globe
            case .space: return space
            case .utility: return utility
            case .enter: return enter
            case .symbolPage: return symbolPage
            case .markLeft: return markLeft
            case .markRight: return markRight
            case .symbolLock: return utility
            case .symbolLibrary: return utility
            // Semantic slot only; it occupies the physical page position.
            case .returnToLetters: return page
            }
        }
    }
}
