import Foundation
import LayoutKit

/// The height budget derives from the **selected physical definition, size class and candidate bar config**, never
/// from transient language/page/candidate state.
///
/// Production height is **fixed** for one physical definition: `headerHeight` is decided by the config value and the
/// primary candidate font size (system default 44pt); a definition with candidate-area capability keeps that budget
/// in every input state. Candidates appearing/disappearing only swap the bar content and never change the shell
/// height, so UIKit and SwiftUI need not negotiate height in the same frame. A definition without candidate-area
/// capability can use the header-less base height via `candidateAreaReserved: false`.
///
/// `layoutPlan(showsHeader: false)` serves both the mathematical base height and definitions without a candidate
/// area; it is not used to shrink one definition's idle height based on transient candidate content.
///
/// Key invariant: the host's hosting view is bottom-anchored and the panel content top-aligned, so under the fixed
/// budget the first key row top = `verticalPadding + readingRowHeight + headerHeight`, constant and **exactly**
/// equal to the main area top (reading row / header / key area pairwise share no pixel row).
///
/// The **standalone trusted reading row** (`readingRowHeight`) belongs only to the budget the host grants from the
/// selected definition's content (`CandidateReadingRowPolicy.isEligible`); the phone left rail requests no extra top
/// reading row. Once granted it is kept in all phases/pages/candidate states of that physical definition.
public struct KeyboardPanelGeometry: Equatable, Sendable {
    /// Header budget determined by the config and the primary candidate font size (at least 36pt).
    public let headerHeight: Double
    /// Standalone reading row budget: 0 when not granted, `CandidateReadingRowPolicy.height` when granted.
    public let readingRowHeight: Double
    public let keyHeight: Double
    public let visibleMainRows: Int

    /// Extra height a page without a candidate area (DIY definition) gets in the unified shell: kept as top blank space instead of stretching key rows.
    public let topSlack: Double

    /// `fittedHeaderHeight`/`topSlack` come from the host's `KeyboardPanelGeometry.fit`: the extra height of the unified shell
    /// goes to the candidate area (or to top blank space when there is none); key rows never exceed the standard key height.
    public init(
        candidateHeight: Double, keyHeight: Double,
        selectedMainRows: Int, maximumVisibleRows: Int = 3,
        readingRowReserved: Bool = false, candidateSize: Double = 17,
        compactReadingRow: Bool = false,
        fittedHeaderHeight: Double? = nil, topSlack: Double = 0,
        fittedReadingRowHeight: Double? = nil
    ) {
        headerHeight = max(
            CandidateBarDefinition.Collapsed.effectiveHeight(
                candidateHeight, candidateSize: candidateSize), fittedHeaderHeight ?? 0)
        self.topSlack = max(0, topSlack)
        // A fitted height may be below the policy height: a squeezed row (`fit`).
        readingRowHeight =
            readingRowReserved
            ? fittedReadingRowHeight ?? CandidateReadingRowPolicy.height(reserved: true, compact: compactReadingRow)
            : 0
        self.keyHeight = keyHeight
        // Latin/numeric pages need three rows even when a DIY Chinese layout is
        // shorter. Reserve their shared budget rather than resizing the host on ABC.
        visibleMainRows = max(3, min(max(1, selectedMainRows), max(3, maximumVisibleRows)))
    }

    public var mainAreaHeight: Double {
        Double(visibleMainRows) * (keyHeight + Self.rowSpacing) - Self.rowSpacing
    }

    /// Top/bottom padding (`.padding(.vertical, 4)` in `panelBody`).
    public static let verticalPadding: Double = 4
    /// Top padding when the candidate area (and reading row) is at the top: the candidate row's own touch margin
    /// is enough, so no extra 4pt band is added. Definitions without a candidate area still use `verticalPadding`.
    public static let candidateTopPadding: Double = 0
    /// Fixed gap between the main key area and the control row (`VStack(spacing: 4)` in `panelBody`).
    public static let controlSpacing: Double = 4

    /// **Mathematical base height** without header (and without reading row)
    /// (`fixedPanelHeight - headerHeight - readingRowHeight`).
    /// The production shell is always the fixed height including the header; this value is only for difference checks and regression assertions.
    public var basePanelHeight: Double {
        mainAreaHeight + Self.controlSpacing + keyHeight + Self.verticalPadding * 2
    }

    /// Panel height including the header (and the granted reading row).
    public var panelHeight: Double {
        readingRowHeight + headerHeight + basePanelHeight - Self.verticalPadding + Self.candidateTopPadding
    }

    /// Stateful real panel height: with header = base + header; without = base.
    /// Because hosting is bottom-anchored and content top-aligned, the difference shows only at the **top** of the panel.
    /// Production does **not** use the no-header branch (see `fixedPanelHeight`).
    public func panelHeight(showsHeader: Bool) -> Double {
        showsHeader ? panelHeight : basePanelHeight + topSlack
    }

    /// Stateful layout plan: shared by production (`KeyboardPanelView.panelBody`) and tests.
    public func layoutPlan(showsHeader: Bool) -> KeyboardPanelLayoutPlan {
        KeyboardPanelLayoutPlan(geometry: self, showsHeader: showsHeader)
    }
}

public extension KeyboardPanelGeometry {
    /// Use the scene viewport, never the keyboard root whose height UIKit can retain during rotation.
    static func landscapeHeightLimit(
        viewportWidth: Double, viewportHeight: Double,
        topInset: Double, bottomInset: Double, isPhone: Bool, compact: Bool
    ) -> Double? {
        guard isPhone, compact, viewportWidth > viewportHeight else { return nil }
        let available = viewportHeight - topInset - bottomInset
        // The system-owned strip sits outside this root; leave room for it and the host editor.
        return available.isFinite && available > 0 ? (available * 0.5).rounded(.down) : nil
    }

    /// The panel's **standard main key area budget** (three rows): Chinese compact layouts (9/14) match the Latin/numeric
    /// pages in height; it is also the row count used when the host looks only at "candidate budget + key height".
    static let standardMainRowCount: Int = 3

    /// Gap between two key rows, and between the main area and the control row.
    static let rowSpacing: Double = 4

    /// The key area's height ceiling: every letter row plus the control row and the gaps between
    /// them (the candidate band and the outer padding are budgeted separately). A board with more
    /// letter rows shares the same area as the standard three-row board and shortens its rows
    /// instead of growing the keyboard past the height decision.
    static let maximumKeyAreaHeight: Double = 256

    /// Key height that spreads the standard three-row board's key area over `physicalMainRows`
    /// letter rows plus the control row. The area is `(rows + 1) * keyHeight + rows * rowSpacing`
    /// and stays the standard board's own area (capped at `maximumKeyAreaHeight`), so a four-row
    /// board keeps the same shell height as a three-row one and only its rows get shorter: the
    /// three portrait presets stay distinct (37.6 / 42.4 / 47.2) instead of meeting at the ceiling.
    static func physicalKeyHeight(standardKeyHeight: Double, physicalMainRows: Int) -> Double {
        let rows = max(standardMainRowCount, physicalMainRows)
        let standardArea =
            Double(standardMainRowCount + 1) * standardKeyHeight
            + Double(standardMainRowCount) * rowSpacing
        let area = min(standardArea, maximumKeyAreaHeight)
        return max(1, (area - Double(rows) * rowSpacing) / Double(rows + 1))
    }

    /// Letter rows a physical board draws above its control row. Only the bundled, registered
    /// physical boards take their own row count; a user layout or a copy keeps the standard
    /// three-row budget so a longer DIY layout keeps scrolling instead of enlarging the shell.
    static func physicalMainRowBudget(forDefinitionID id: String?) -> Int {
        guard let id, let board = BuiltinLayouts.all.first(where: { $0.id == id }) else {
            return standardMainRowCount
        }
        // Every bundled board ends with its control row, which the key area budgets separately.
        return max(standardMainRowCount, board.rows.count - 1)
    }

    /// The **single** height derivation entry shared by `KeyboardPanelView` (panel) and `KeyboardPanelHost` (host):
    /// the same `KeyboardPanelGeometry` + the same `layoutPlan`.
    ///
    /// The panel uses it for `.frame(height:)`, the host uses it for the ready phase's expected height
    /// (the host is the single height owner). Neither side may reassemble
    /// `header + main + control + padding` or hardcode a number, or the two sides diverge again.
    static func panelHeight(
        candidateHeight: Double, keyHeight: Double,
        selectedMainRows: Int, showsHeader: Bool,
        maximumVisibleRows: Int = 3,
        readingRowReserved: Bool = false,
        candidateSize: Double = 17
    ) -> Double {
        KeyboardPanelGeometry(
            candidateHeight: candidateHeight, keyHeight: keyHeight,
            selectedMainRows: selectedMainRows,
            maximumVisibleRows: maximumVisibleRows,
            readingRowReserved: readingRowReserved,
            candidateSize: candidateSize
        )
        .layoutPlan(showsHeader: showsHeader)
        .panelHeight
    }

    /// Panel height when only "candidate budget + key height" are needed (host and panel share this entry).
    /// Always equals the version taking a concrete `selectedMainRows`: without a physical row budget
    /// `visibleMainRows` is clamped to the standard three rows.
    static func panelHeight(
        candidateHeight: Double, keyHeight: Double,
        showsHeader: Bool, candidateSize: Double = 17
    ) -> Double {
        panelHeight(
            candidateHeight: candidateHeight, keyHeight: keyHeight,
            selectedMainRows: standardMainRowCount, showsHeader: showsHeader,
            candidateSize: candidateSize)
    }

    /// Production **fixed outer budget**: the candidate bar budget is kept in **every** phase and state, so the keyboard shell height
    /// does not change with candidates appearing/disappearing, expand/collapse or Chinese/English switching; it may change
    /// only when switching to a physical definition with a different reading-row capability.
    ///
    /// `KeyboardPanelView` (content height), `KeyboardPanelHost` (the shell of every phase) and extension cold start
    /// (`KeyboardInitialPresentation`) all share this **one** entry. No state change requires the UIKit shell and the
    /// SwiftUI content to negotiate a new height in the same frame.
    ///
    /// `readingRowReserved` is a **physical structure fact** granted by the host from the selected definition's capability,
    /// not candidate/language/page state; default false, and the phone left rail does not request an extra top reading row.
    static func fixedPanelHeight(
        candidateHeight: Double, keyHeight: Double,
        maximumVisibleRows: Int = 3,
        readingRowReserved: Bool = false,
        candidateAreaReserved: Bool = true,
        candidateSize: Double = 17,
        physicalMainRows: Int = standardMainRowCount
    ) -> Double {
        let rows = max(standardMainRowCount, physicalMainRows)
        return panelHeight(
            candidateHeight: candidateHeight,
            keyHeight: physicalKeyHeight(standardKeyHeight: keyHeight, physicalMainRows: rows),
            selectedMainRows: rows, showsHeader: candidateAreaReserved,
            maximumVisibleRows: max(maximumVisibleRows, rows),
            readingRowReserved: readingRowReserved,
            candidateSize: candidateSize)
    }

    /// The accepted physical definition and appearance determine the nominal shell height.
    /// Explicit configuration changes submit a new native budget while temporary pages
    /// and composition/candidate changes keep fitting the current definition.
    /// A candidate area also receives `candidateAreaBonus`; key rows never exceed the standard height.
    /// `physicalMainRows` is the definition's letter-row count: the standard key area is spread over
    /// those rows plus the control row, so a four-row board keeps the three-row shell height.
    static func presentationShellHeight(
        candidateHeight: Double, keyHeight: Double,
        candidateSize: Double = 17, readingRow: Bool,
        candidateArea: Bool = true,
        compactReadingRow: Bool = false,
        physicalMainRows: Int = standardMainRowCount
    ) -> Double {
        let reading = readingRow && candidateArea
        return fixedPanelHeight(
            candidateHeight: candidateHeight, keyHeight: keyHeight,
            readingRowReserved: reading, candidateAreaReserved: candidateArea,
            candidateSize: candidateSize,
            physicalMainRows: physicalMainRows)
            - CandidateReadingRowPolicy.height(reserved: reading)
            + CandidateReadingRowPolicy.height(reserved: reading, compact: compactReadingRow)
            + (candidateArea ? candidateAreaBonus - (reading ? readingLayoutBonusCut : 0) : 0)
    }

    /// The two gaps every layout shares, as space beyond half the configured candidate row
    /// (the candidate text is centred in that row):
    /// - `candidateBottomSpace`: between the candidate text and the keys;
    /// - `candidateTopSpace`: above the first text row (candidates on 9/26-key, readings on 14/18-key),
    ///   before `hostGapWorkaroundCut` comes off the top.
    /// 9/26-key and 14/18-key derive their band heights and text offsets from these, so a change to
    /// either gap moves every layout together.
    static let candidateBottomSpace: Double = 3
    static let candidateTopSpace: Double = 9
    /// How far above the keys every layout centres its candidate text: half the candidate row plus
    /// `candidateBottomSpace`. The ABC suggestion row uses it too, so a taller band (the selected
    /// layout's reading row, which ABC does not show) does not lift its words.
    static func candidateTextCentreAboveKeys(candidateHeight: Double, candidateSize: Double) -> Double {
        CandidateBarDefinition.Collapsed.effectiveHeight(candidateHeight, candidateSize: candidateSize) / 2
            + candidateBottomSpace
    }
    /// Extra height the candidate area gets beyond the configured budget: both shared gaps,
    /// minus the temporary `hostGapWorkaroundCut`.
    static let candidateAreaBonus: Double = candidateTopSpace + candidateBottomSpace - hostGapWorkaroundCut
    /// TEMPORARY: iOS often adds a 17pt blank band above a third-party keyboard (after switching from a system
    /// keyboard or returning to the app; FB24460699 / FB25094825), which the extension cannot detect. Until Apple
    /// fixes it, every layout's shell is 10pt shorter and `fit` takes those 10pt off the top of the topmost band
    /// only, so the keyboard does not look too tall with the band while the candidates keep their place above
    /// the keys. Set back to 0 once the band is gone.
    static let hostGapWorkaroundCut: Double = 10
    /// 14/18-key: the reading row's share of the spare height. It puts the (smaller, lower-set) reading text
    /// where the 9/26-key candidate text starts, i.e. the same `candidateTopSpace` look.
    static let readingRowSpareShare: Double = 10
    /// 14/18-key: space above the candidate text (beyond half its row) under the reading row.
    static let readingCandidateSpace: Double = 2
    /// How much less candidate-area bonus a definition with a reading row gets (negative: more): its spare
    /// height is the reading row's share, the space under it and the shared `candidateBottomSpace`.
    static let readingLayoutBonusCut: Double =
        candidateTopSpace - readingRowSpareShare - readingCandidateSpace

    /// Lays out a page with the given top bands inside `shellHeight`: the four key rows (three main rows +
    /// control row) share the remaining height equally but never exceed `standardKeyHeight`; extra height goes to
    /// the candidate area, or stays at the top when there is none. When height is short (iOS reused the shorter
    /// height of the previous presentation, e.g. switching from nine-key to 14-key mid-presentation) the reading
    /// row yields height first (down to `CandidateReadingRowPolicy.minimumHeight`), and key height is squeezed only if that is still not enough.
    ///
    /// With a candidate area, the page is laid out `hostGapWorkaroundCut` taller and the cut comes off the top of
    /// the topmost band (`topTrim`), as long as that band keeps room for its text; otherwise (a short shell
    /// already squeezing the reading row) the page is fitted to the shell as is.
    static func fit(
        shellHeight: Double, candidateHeight: Double, standardKeyHeight: Double,
        readingRowReserved: Bool, candidateAreaReserved: Bool,
        candidateSize: Double = 17, compactReadingRow: Bool = false,
        drawnMainRows: Int = standardMainRowCount
    ) -> KeyboardPanelFit {
        func layout(_ height: Double) -> KeyboardPanelFit {
            untrimmedFit(
                shellHeight: height, candidateHeight: candidateHeight, standardKeyHeight: standardKeyHeight,
                readingRowReserved: readingRowReserved, candidateAreaReserved: candidateAreaReserved,
                candidateSize: candidateSize, compactReadingRow: compactReadingRow,
                drawnMainRows: drawnMainRows)
        }
        let cut = hostGapWorkaroundCut
        guard candidateAreaReserved, cut > 0 else { return layout(shellHeight) }
        let tall = layout(shellHeight + cut)
        if tall.readingRowHeight > 0 {
            // The reading text sits low in its row; 4pt under the policy height still clears it.
            let floor = CandidateReadingRowPolicy.height(reserved: true, compact: compactReadingRow) - 4
            guard tall.readingRowHeight - cut >= floor else { return layout(shellHeight) }
            return KeyboardPanelFit(
                keyHeight: tall.keyHeight, headerHeight: tall.headerHeight, topSlack: tall.topSlack,
                readingRowHeight: tall.readingRowHeight - cut, topTrim: cut)
        }
        let floor = CandidateBarDefinition.Collapsed.effectiveHeight(candidateHeight, candidateSize: candidateSize)
        guard tall.headerHeight - cut >= floor else { return layout(shellHeight) }
        return KeyboardPanelFit(
            keyHeight: tall.keyHeight, headerHeight: tall.headerHeight - cut, topSlack: tall.topSlack,
            readingRowHeight: 0, topTrim: cut)
    }

    private static func untrimmedFit(
        shellHeight: Double, candidateHeight: Double, standardKeyHeight: Double,
        readingRowReserved: Bool, candidateAreaReserved: Bool,
        candidateSize: Double, compactReadingRow: Bool,
        drawnMainRows: Int
    ) -> KeyboardPanelFit {
        let header =
            candidateAreaReserved
            ? CandidateBarDefinition.Collapsed.effectiveHeight(candidateHeight, candidateSize: candidateSize) : 0
        let fullReading =
            candidateAreaReserved
            ? CandidateReadingRowPolicy.height(reserved: readingRowReserved, compact: compactReadingRow) : 0
        let top = candidateAreaReserved ? candidateTopPadding : verticalPadding
        let rows = Double(drawnMainRows + 1)
        let fixedWithoutReading =
            top + header + Double(drawnMainRows - 1) * rowSpacing + controlSpacing + verticalPadding
        let fullKeyHeight = physicalKeyHeight(
            standardKeyHeight: standardKeyHeight, physicalMainRows: drawnMainRows)
        let shortfall = max(0, fullKeyHeight * rows - (shellHeight - fixedWithoutReading - fullReading))
        let reading = fullReading - min(shortfall, max(0, fullReading - CandidateReadingRowPolicy.minimumHeight))
        let available = shellHeight - fixedWithoutReading - reading
        let key = max(1, min(fullKeyHeight, available / rows))
        let slack = max(0, available - key * rows)
        // A reading row takes its share of the spare height as touch budget; the
        // candidate row takes the rest.
        let readingExtra = reading > 0 ? min(slack, readingRowSpareShare) : 0
        return KeyboardPanelFit(
            keyHeight: key,
            headerHeight: candidateAreaReserved ? header + slack - readingExtra : 0,
            topSlack: candidateAreaReserved ? 0 : slack,
            readingRowHeight: reading + readingExtra)
    }

    /// **Base height without header** (`panelHeight(showsHeader: false)`).
    ///
    /// Only a mathematical base for difference checks (`full height == base + headerHeight`); **not** the production idle budget:
    /// production keeps the candidate bar budget in every phase (see `fixedPanelHeight`).
    static func idlePanelHeight(
        candidateHeight: Double, keyHeight: Double,
        selectedMainRows: Int = standardMainRowCount,
        maximumVisibleRows: Int = 3,
        candidateSize: Double = 17,
        physicalMainRows: Int? = nil
    ) -> Double {
        let rows = max(standardMainRowCount, physicalMainRows ?? selectedMainRows)
        return panelHeight(
            candidateHeight: candidateHeight,
            keyHeight: physicalKeyHeight(standardKeyHeight: keyHeight, physicalMainRows: rows),
            selectedMainRows: rows, showsHeader: false,
            maximumVisibleRows: max(maximumVisibleRows, rows), candidateSize: candidateSize)
    }
}

/// A bounded physical row height, independent of candidate fonts and engine state.
public enum KeyboardHeightPreset: String, CaseIterable, Hashable, Sendable {
    case compact
    case standard
    case comfortable

    public static func resolve(_ storedValue: String?) -> Self {
        storedValue.flatMap(Self.init(rawValue:)) ?? .standard
    }

    /// `compact` is a compact-height surface (an iPhone in landscape): the screen is short there,
    /// so rows are well below the portrait ones while each preset keeps its relative step.
    public func keyHeight(compact: Bool) -> Double {
        switch (self, compact) {
        case (.compact, false): return 48
        case (.standard, false): return 54
        case (.comfortable, false): return 60
        case (.compact, true): return 34
        case (.standard, true): return 38
        case (.comfortable, true): return 42
        }
    }
}

/// Immutable external height inputs; live content is fitted inside this shell.
public struct KeyboardPanelPresentationBudget: Equatable, Sendable {
    public let candidateHeight: Double
    public let candidateSize: Double
    public let readingRow: Bool
    public let candidateArea: Bool
    public let compact: Bool
    public let heightPreset: KeyboardHeightPreset
    /// Letter rows the selected physical board draws above its control row; every other page
    /// re-fits inside the shell this budgets. The standard boards and user layouts keep three.
    public let physicalMainRows: Int

    public init(
        candidateHeight: Double, candidateSize: Double, readingRow: Bool,
        candidateArea: Bool, compact: Bool, heightPreset: KeyboardHeightPreset = .standard,
        physicalMainRows: Int = KeyboardPanelGeometry.standardMainRowCount
    ) {
        self.candidateHeight = candidateHeight
        self.candidateSize = candidateSize
        self.readingRow = readingRow
        self.candidateArea = candidateArea
        self.compact = compact
        self.heightPreset = heightPreset
        self.physicalMainRows = physicalMainRows
    }

    public var keyHeight: Double { heightPreset.keyHeight(compact: compact) }
    public var shellHeight: Double {
        KeyboardPanelGeometry.presentationShellHeight(
            candidateHeight: candidateHeight,
            keyHeight: keyHeight,
            candidateSize: candidateSize,
            readingRow: readingRow,
            candidateArea: candidateArea,
            compactReadingRow: compact,
            physicalMainRows: physicalMainRows)
    }

    public func withCompact(_ compact: Bool) -> Self {
        Self(
            candidateHeight: candidateHeight, candidateSize: candidateSize,
            readingRow: readingRow, candidateArea: candidateArea, compact: compact,
            heightPreset: heightPreset, physicalMainRows: physicalMainRows)
    }
}

/// Result of `KeyboardPanelGeometry.fit`: the key height, candidate area height and top slack shared by host and panel.
public struct KeyboardPanelFit: Equatable, Sendable {
    public let keyHeight: Double
    /// Actual candidate area (header) height; 0 when there is no candidate area.
    public let headerHeight: Double
    /// Blank space left at the top when there is no candidate area.
    public let topSlack: Double
    /// Actual reading row height (including its share of spare height); 0 when not granted.
    public var readingRowHeight: Double = 0
    /// How much was cut off the top of the topmost band (reading row, else candidate row) for
    /// `hostGapWorkaroundCut`: that band lays its content out `topTrim` taller, bottom-aligned,
    /// so only blank space above the text goes.
    public var topTrim: Double = 0
}

/// The exact vertical layout of the panel in a given state (content coordinates, origin = panel top edge).
///
/// There is no `bottomReserve`: the panel consists only of the `readingRow (may be 0) / header / main / control`
/// segments plus top/bottom padding; production derives `showsHeader` from the selected definition's candidate-area
/// capability and keeps it unchanged across that definition's input states. The reading row sits **above** the header, each laid out and hit separately.
public struct KeyboardPanelLayoutPlan: Equatable, Sendable {
    /// Header budget determined by the config and the primary candidate font size (at least 36pt).
    public let configuredHeaderHeight: Double
    /// Actual height of the standalone reading row: non-zero when the host granted it and the definition has a candidate area.
    public let readingRowHeight: Double
    /// Actual height of the top candidate surface: the effective budget when the definition has a candidate area, otherwise 0.
    public let headerHeight: Double
    public let mainAreaHeight: Double
    public let keyHeight: Double
    /// Total panel height: the fixed candidate and reading-row budgets chosen by the definition's capabilities.
    public let panelHeight: Double

    public init(geometry: KeyboardPanelGeometry, showsHeader: Bool) {
        configuredHeaderHeight = geometry.headerHeight
        contentTop =
            showsHeader
            ? KeyboardPanelGeometry.candidateTopPadding
            : KeyboardPanelGeometry.verticalPadding + geometry.topSlack
        readingRowHeight = showsHeader ? geometry.readingRowHeight : 0
        headerHeight = showsHeader ? geometry.headerHeight : 0
        mainAreaHeight = geometry.mainAreaHeight
        keyHeight = geometry.keyHeight
        panelHeight = geometry.panelHeight(showsHeader: showsHeader)
    }

    /// Panel top to the first vertical band's top edge (the top padding of `panelBody`).
    public let contentTop: Double
    /// Standalone reading row frame (zero height when not granted; the header then starts right at `contentTop`).
    public var readingRowFrame: PanelVerticalFrame {
        PanelVerticalFrame(top: contentTop, height: readingRowHeight)
    }
    public var headerFrame: PanelVerticalFrame {
        PanelVerticalFrame(top: readingRowFrame.maxY, height: headerHeight)
    }
    /// Main area viewport frame (first key row top = this frame's minY).
    public var mainAreaFrame: PanelVerticalFrame {
        PanelVerticalFrame(top: headerFrame.maxY, height: mainAreaHeight)
    }
    /// Top y of the first key row (= main area top).
    public var firstKeyRowTop: Double { mainAreaFrame.minY }
    /// Control row frame.
    public var controlRowFrame: PanelVerticalFrame {
        PanelVerticalFrame(
            top: mainAreaFrame.maxY + KeyboardPanelGeometry.controlSpacing,
            height: keyHeight)
    }
    /// Panel bottom y (always equal to `panelHeight`).
    public var contentBottom: Double {
        controlRowFrame.maxY + KeyboardPanelGeometry.verticalPadding
    }

    /// Adjacent vertical bands **meet exactly without overlapping**: reading row bottom == header top, header
    /// bottom == main area top, main area bottom + spacing == control row top, content bottom == panel height.
    /// All segments shift by the same `readingRowHeight + headerHeight`, so under the fixed production budget this does not depend on candidate state.
    public var bandsAreContiguous: Bool {
        readingRowFrame.minY == contentTop
            && readingRowFrame.maxY == headerFrame.minY
            && headerFrame.maxY == mainAreaFrame.minY
            && controlRowFrame.minY == mainAreaFrame.maxY + KeyboardPanelGeometry.controlSpacing
            && contentBottom == panelHeight
    }

    // MARK: Distance from the screen bottom (screen coordinates when the host anchors to the bottom; must not depend on state)

    /// Distance from a band's top edge to the panel bottom.
    public func distanceFromPanelBottom(toTopOf band: PanelVerticalFrame) -> Double {
        panelHeight - band.minY
    }
    /// Distance from a band's bottom edge to the panel bottom.
    public func distanceFromPanelBottom(toBottomOf band: PanelVerticalFrame) -> Double {
        panelHeight - band.maxY
    }
}

/// One-dimensional (vertical) frame: top edge + height.
public struct PanelVerticalFrame: Equatable, Sendable {
    public let top: Double
    public let height: Double
    public init(top: Double, height: Double) {
        self.top = top
        self.height = height
    }
    public var maxY: Double { top + height }
    public var minY: Double { top }
    public func intersects(_ other: PanelVerticalFrame) -> Bool {
        minY < other.maxY && other.minY < maxY
    }
}
