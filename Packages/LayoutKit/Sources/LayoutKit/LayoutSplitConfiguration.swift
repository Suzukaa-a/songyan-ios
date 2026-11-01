import Foundation

/// Widths at or below this are phone-sized surfaces (a folded cover screen is 466 pt): they keep one
/// keyboard under the automatic split, may narrow for one-handed use and never cap their content.
public enum KeyboardSurfaceWidth {
    public static let phoneMaximum = 600.0
}

/// One row of an explicit split arrangement: the keys left and right of the gap. A half may be empty
/// only when the row is a single key, which cannot be cut.
public struct LayoutSplitRow: Codable, Equatable, Sendable {
    public var left: [LayoutKey]
    public var right: [LayoutKey]

    public init(left: [LayoutKey], right: [LayoutKey]) {
        self.left = left
        self.right = right
    }

    public var keys: [LayoutKey] { left + right }

    public var hasKeyInEachHalf: Bool {
        (!left.isEmpty && !right.isEmpty) || left.count + right.count == 1
    }
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
    /// The split arrangement as its own copy of the keys, one entry per row of the layout (the
    /// control row included). Written only once the user edited it; when nil the arrangement is the
    /// layout rows cut at `rowBreaks`. When set it replaces the derived one, and `rowBreaks` are
    /// neither used for drawing nor checked against the rows.
    public var halves: [LayoutSplitRow]?

    public init(
        activation: Activation = .automatic, rowBreaks: [Int] = [], gapFraction: Double? = nil,
        halves: [LayoutSplitRow]? = nil
    ) {
        self.activation = activation
        self.rowBreaks = rowBreaks
        self.gapFraction = gapFraction ?? Self.defaultGapFraction
        automaticGap = gapFraction == nil
        self.halves = halves
    }

    private enum CodingKeys: String, CodingKey {
        case activation, rowBreaks, gapFraction, automaticGap, halves
    }

    /// A split without a gap setting (a hand-written file) takes the automatic gap, and one without
    /// cuts takes the middle; the encoder still writes all four so older readers keep decoding.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activation = try container.decode(Activation.self, forKey: .activation)
        rowBreaks = try container.decodeIfPresent([Int].self, forKey: .rowBreaks) ?? []
        gapFraction = try container.decodeIfPresent(Double.self, forKey: .gapFraction) ?? Self.defaultGapFraction
        automaticGap = try container.decodeIfPresent(Bool.self, forKey: .automaticGap) ?? true
        halves = try container.decodeIfPresent([LayoutSplitRow].self, forKey: .halves)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activation, forKey: .activation)
        try container.encode(rowBreaks, forKey: .rowBreaks)
        try container.encode(gapFraction, forKey: .gapFraction)
        try container.encode(automaticGap, forKey: .automaticGap)
        try container.encodeIfPresent(halves, forKey: .halves)
    }

    /// The arrangement for `rows`: the explicit halves when there are any, else the rows cut at
    /// `rowBreaks`.
    public func arrangement(of rows: [LayoutRow]) -> [LayoutSplitRow] {
        halves ?? derivedArrangement(of: rows)
    }

    /// `rows` cut at `rowBreaks`; the space bar of a row becomes one half under each thumb.
    public func derivedArrangement(of rows: [LayoutRow]) -> [LayoutSplitRow] {
        rows.indices.map { cut(row: $0, keys: rows[$0].keys) }
    }

    /// One row cut where this split says. The space bar of a row is divided between the halves: the
    /// left gets the keys before it and half its width, the right the other half and the keys after.
    public func cut(row: Int, keys: [LayoutKey]) -> LayoutSplitRow {
        guard let spaceAt = keys.firstIndex(where: { $0.action.type == .space }) else {
            let at = breakIndex(row: row, keyCount: keys.count)
            return LayoutSplitRow(left: Array(keys.prefix(at)), right: Array(keys.dropFirst(at)))
        }
        let half = keys[spaceAt].settingWidth(keys[spaceAt].widthWeight / 2)
        return LayoutSplitRow(
            left: Array(keys.prefix(spaceAt)) + [half], right: [half] + Array(keys.dropFirst(spaceAt + 1)))
    }

    /// What is wrong with the explicit halves for a layout of `rowCount` rows, or nil.
    public func halvesProblem(rowCount: Int) -> HalvesProblem? {
        guard let halves else { return nil }
        if halves.count != rowCount { return .rowCountMismatch }
        return halves.allSatisfy(\.hasKeyInEachHalf) ? nil : .halfEmpty
    }

    public enum HalvesProblem: Equatable, Sendable {
        /// The arrangement does not have one entry for every row of the layout.
        case rowCountMismatch
        /// A row has no key in one of its halves.
        case halfEmpty
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
        // Explicit halves carry their own cuts, so stale row breaks never reach a renderer.
        return ActiveLayoutSplit(
            rowBreaks: halves == nil ? rowBreaks : [], gapFraction: gapFraction, automaticGap: automaticGap,
            halves: halves)
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
        // Other pages have different key counts and choose their own row boundaries; the layout's
        // own split keys belong to its letters only.
        inherited.rowBreaks = []
        inherited.halves = nil
        return inherited
    }

    /// `rowKeyCounts` are the keys of every whole row. Explicit halves must match the row count and
    /// keep a key in each half; `allowsHalves` is false for pages, which only follow the layout's split.
    public func validate(rowKeyCounts: [Int], allowsHalves: Bool = false) throws {
        guard gapFraction.isFinite, (0...0.85).contains(gapFraction) else {
            throw LayoutError.invalid("拆分间距应在 0% 到 85% 之间，请调整后保存。")
        }
        if halves != nil {
            guard allowsHalves else { throw LayoutError.invalid(LayoutSplitMessage.halvesOnlyOnLayout) }
            guard halvesProblem(rowCount: rowKeyCounts.count) == nil else {
                throw LayoutError.invalid(LayoutSplitMessage.halvesShape)
            }
            return
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

/// Messages of the split arrangement checks.
public enum LayoutSplitMessage {
    public static let halvesShape = "拆分时的键盘要和键盘有同样的行数，每一边至少要有一个键。"
    public static let halvesOnlyOnLayout = "只有键盘布局可以单独设置拆分时的按键。"
}

/// A split that is showing at the current width. Only `LayoutSplitConfiguration.resolved(forWidth:)`
/// creates one, and it is never stored, so geometry never re-applies the width rule.
public struct ActiveLayoutSplit: Equatable, Sendable {
    public let rowBreaks: [Int]
    public let gapFraction: Double
    public let automaticGap: Bool
    /// The layout's own split keys, only on the split of the main letters: every other page, the
    /// English letters and nested areas draw their own rows and never see them.
    public let halves: [LayoutSplitRow]?

    init(rowBreaks: [Int], gapFraction: Double, automaticGap: Bool, halves: [LayoutSplitRow]? = nil) {
        self.rowBreaks = rowBreaks
        self.gapFraction = gapFraction
        self.automaticGap = automaticGap
        self.halves = halves
    }

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

    /// The same split with one row cut moved; earlier rows without a cut keep the middle.
    public func settingBreak(row: Int, to value: Int) -> ActiveLayoutSplit {
        var breaks = rowBreaks
        while breaks.count <= row { breaks.append(0) }
        breaks[row] = value
        return ActiveLayoutSplit(
            rowBreaks: breaks, gapFraction: gapFraction, automaticGap: automaticGap, halves: halves)
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
        max(0, edgeMargin(width: width, keyCount: widestKeyCount) - 4)
    }

    /// The keys of the widest letter row: ten for whole rows; with explicit halves the widest cut
    /// row, counting the Shift and Delete the last letter row gains.
    public var widestKeyCount: Int {
        guard let halves else { return 10 }
        let letters = halves.filter { $0.keys.allSatisfy { $0.action.type != .space } }.map(\.keys.count)
        return max(10, (letters.max() ?? 10) + 2)
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
