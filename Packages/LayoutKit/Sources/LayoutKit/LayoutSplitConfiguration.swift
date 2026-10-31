import Foundation

/// Widths at or below this are phone-sized surfaces (a folded cover screen is 466 pt): they keep one
/// keyboard under the automatic split, may narrow for one-handed use and never cap their content.
public enum KeyboardSurfaceWidth {
    public static let phoneMaximum = 600.0
}

/// A saved split follows the available keyboard width, including floating windows.
public struct LayoutSplitConfiguration: Codable, Equatable, Sendable {
    /// When a split is shown. Independent from `automaticGap`: this decides whether to split at
    /// all, `automaticGap` only decides how much gutter an active split keeps.
    public enum Activation: String, Codable, Sendable {
        /// Saved row cuts and spacing stay, but rows are never split.
        case off
        /// Split only on wide surfaces: a one-hand phone or folded cover screen keeps one keyboard.
        case automatic
        /// Split at every width; the user explicitly asked for two halves.
        case always
    }

    public var activation: Activation
    public var rowBreaks: [Int]
    public var gapFraction: Double
    /// The gutter follows the width instead of `gapFraction`.
    public var automaticGap: Bool
    public static let defaultGapFraction = 0.32

    public init(activation: Activation = .automatic, rowBreaks: [Int] = [], gapFraction: Double? = nil) {
        self.activation = activation
        self.rowBreaks = rowBreaks
        self.gapFraction = gapFraction ?? Self.defaultGapFraction
        automaticGap = gapFraction == nil
    }

    /// Whether this split really shows at `width`, measured on the whole keyboard.
    public func isActive(width: Double) -> Bool {
        switch activation {
        case .off: return false
        case .always: return true
        case .automatic: return width.isFinite && width > KeyboardSurfaceWidth.phoneMaximum
        }
    }

    /// The split to render at this width, or nil when rows stay whole. Renderers and previews
    /// resolve once against the whole keyboard, so an inner key area narrowed by rails can never
    /// switch the split off a second time.
    public func resolved(forWidth width: Double) -> ActiveLayoutSplit? {
        guard isActive(width: width) else { return nil }
        return ActiveLayoutSplit(rowBreaks: rowBreaks, gapFraction: gapFraction, automaticGap: automaticGap)
    }

    /// The cut shown for each row: the saved one, else `defaults` (the cuts the keyboard draws
    /// before any is saved), else the middle. Editors show this and write cuts only when the user
    /// changes one, so an untouched split keeps following the layout's own defaults.
    public func cutPositions(rowKeyCounts: [Int], defaults: [Int]?) -> [Int] {
        let source = rowBreaks.isEmpty ? (defaults ?? []) : rowBreaks
        return rowKeyCounts.indices.map {
            ActiveLayoutSplit.breakIndex(rowBreaks: source, row: $0, keyCount: rowKeyCounts[$0])
        }
    }

    public static func resolving(page: Self?, main: Self?) -> Self? {
        if let page { return page }
        guard var inherited = main else { return nil }
        // Other pages have different key counts and choose their own row boundaries.
        inherited.rowBreaks = []
        return inherited
    }

    public func validate(rowKeyCounts: [Int]) throws {
        guard gapFraction.isFinite, (0...0.85).contains(gapFraction) else {
            throw LayoutError.invalid("拆分间距应在 0% 到 85% 之间，请调整后保存。")
        }
        guard rowBreaks.count <= rowKeyCounts.count else {
            throw LayoutError.invalid("拆分位置比按键行还多，请重新设置拆分位置。")
        }
        for (row, count) in rowBreaks.enumerated() {
            guard rowKeyCounts[row] <= 1 || (1..<rowKeyCounts[row]).contains(count) else {
                throw LayoutError.invalid("拆分位置应在两个按键之间，请调整后保存。")
            }
        }
    }

    /// Character index of the split in a row, whatever the width; editors show it even when the
    /// current surface keeps the row whole.
    public func breakIndex(row: Int, keyCount: Int) -> Int {
        ActiveLayoutSplit.breakIndex(rowBreaks: rowBreaks, row: row, keyCount: keyCount)
    }
}

/// A split that is showing at the current width. Only `LayoutSplitConfiguration.resolved(forWidth:)`
/// creates one, and it is never stored, so geometry never re-applies the width rule.
public struct ActiveLayoutSplit: Equatable, Sendable {
    public let rowBreaks: [Int]
    public let gapFraction: Double
    public let automaticGap: Bool

    /// Each half stays within one thumb's reach on large surfaces.
    public static let maximumThumbHalfWidth = 300.0
    /// The automatic gutter's share of the width. It is narrower than the saved default so the
    /// keys get wider; a wider surface opens the gutter instead once a half reaches its maximum.
    public static let automaticGapShare = 0.2
    /// The outer margin that keeps the halves off the screen edges: a share of the width within
    /// these bounds.
    public static let edgeMarginShare = 0.025
    public static let minimumEdgeMargin = 8.0
    public static let maximumEdgeMargin = 20.0
    /// Automatic spacing lets a key grow to this width before the rest becomes gutter, so a few
    /// columns on a tablet do not stretch into slabs.
    public static let maximumAutomaticKeyWidth = 84.0
    /// Automatic spacing never shrinks a key below this width.
    public static let minimumAutomaticKeyWidth = 32.0

    /// A nested area (a category grid) inside an already-resolved page: its own setting wins and is
    /// resolved at `width`; otherwise it inherits the page's active spacing with its own row cuts.
    public static func resolving(
        nested: LayoutSplitConfiguration?, parent: ActiveLayoutSplit?, width: Double
    ) -> ActiveLayoutSplit? {
        if let nested { return nested.resolved(forWidth: width) }
        return parent?.withoutRowBreaks
    }

    /// The same spacing for an area with different key counts, which picks its own row cuts.
    public var withoutRowBreaks: ActiveLayoutSplit {
        ActiveLayoutSplit(rowBreaks: [], gapFraction: gapFraction, automaticGap: automaticGap)
    }

    /// The split a page is drawn with. The main letters take the main split as is. The English
    /// letter page (standard 26-key rows) of a layout with hand cuts takes the standard cuts, unless
    /// an authored page with its own rows is showing: that keeps its inherited middle cuts. Other pages inherit the
    /// spacing without the main layout's row cuts unless they carry their own split.
    public static func drawn(
        main: LayoutSplitConfiguration?, mainWidth: Double, showsMainLetters: Bool,
        showsEnglishLetters: Bool, authoredPage: KeyboardPageDefinition?,
        pageSplit: @autoclosure () -> LayoutSplitConfiguration?, contentWidth: Double
    ) -> ActiveLayoutSplit? {
        let resolved = main?.resolved(forWidth: mainWidth)
        if showsMainLetters { return resolved }
        if showsEnglishLetters, !Self.drawsItsOwnRows(authoredPage), let resolved, pageSplit() == nil {
            return resolved.forStandardLetterRows
        }
        return resolving(nested: pageSplit(), parent: resolved, width: contentWidth)
    }

    /// Whether a page's own rows replace the standard English letters. The preset English page and
    /// any page of standard alphabet rows draw exactly like them; other rows keep the inherited
    /// cuts, and a chrome page has Shift and Delete as keys of its third row.
    static func drawsItsOwnRows(_ page: KeyboardPageDefinition?) -> Bool {
        guard let page else { return false }
        return !KeyboardPageDefaultShape.isNativeAlphabet(page) || page.chrome != nil
    }

    /// Room added at both edges of the key area on top of the panel's own 4pt side padding.
    public func edgeInset(width: Double) -> Double {
        max(0, edgeMargin(width: width) - 4)
    }

    /// The same spacing on the standard 26-key letter rows, cut where the hands divide whatever
    /// layout the split came from.
    public var forStandardLetterRows: ActiveLayoutSplit {
        ActiveLayoutSplit(
            rowBreaks: BuiltinLayouts.standardLetterRowBreaks, gapFraction: gapFraction, automaticGap: automaticGap)
    }

    /// The split index in a row.
    public func breakIndex(row: Int, keyCount: Int) -> Int {
        Self.breakIndex(rowBreaks: rowBreaks, row: row, keyCount: keyCount)
    }

    static func breakIndex(rowBreaks: [Int], row: Int, keyCount: Int) -> Int {
        guard keyCount > 1 else { return keyCount }
        let requested = rowBreaks.indices.contains(row) ? rowBreaks[row] : (keyCount + 1) / 2
        return min(keyCount - 1, max(1, requested))
    }

    public func gap(
        width: Double, keyCount: Int, spacing: Double = 4, minimumKeyWidth: Double = 28
    ) -> Double {
        guard keyCount > 1 else { return 0 }
        let keyFloor = automaticGap ? max(Self.minimumAutomaticKeyWidth, minimumKeyWidth) : minimumKeyWidth
        let room = max(0, width - Double(keyCount) * keyFloor - Double(keyCount - 1) * spacing)
        // Keep large surfaces within thumb reach, while narrow windows keep usable keys.
        let maximumContentWidth = min(
            Self.maximumThumbHalfWidth * 2,
            Double(keyCount) * Self.maximumAutomaticKeyWidth + Double(keyCount - 1) * spacing)
        let requested =
            automaticGap
            ? max(width * Self.automaticGapShare, width - maximumContentWidth)
            : width * gapFraction
        let result = min(requested, room)
        return result > spacing ? result : 0
    }

    /// The margin left at both screen edges of a split key area, for a row of `keyCount` keys (the
    /// widest letter row). It gives way before the keys shrink: it only takes what the width has
    /// left after the key floor and the gutter, and is zero when the surface does not split.
    public func edgeMargin(width: Double, keyCount: Int = 10, spacing: Double = 4) -> Double {
        guard width.isFinite, gap(width: width, keyCount: keyCount, spacing: spacing) > 0 else { return 0 }
        let keyFloor = automaticGap ? Self.minimumAutomaticKeyWidth : 28
        let slack = max(0, width - Double(keyCount) * keyFloor - Double(keyCount - 1) * spacing)
        let margin = min(Self.maximumEdgeMargin, max(Self.minimumEdgeMargin, width * Self.edgeMarginShare))
        let gutter = min(gap(width: width, keyCount: keyCount, spacing: spacing), slack)
        return max(0, min(margin, (slack - gutter) / 2))
    }
}
