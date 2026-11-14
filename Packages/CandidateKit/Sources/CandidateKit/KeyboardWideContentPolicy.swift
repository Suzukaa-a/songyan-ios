import Foundation
import LayoutKit

/// Where a width-capped keyboard content sits on a surface wider than its cap.
public enum KeyboardContentDock: String, CaseIterable, Sendable {
    case left, center, right

    /// Unknown or missing stored values fall back to center, the neutral default.
    public static func resolve(_ storedValue: String?) -> Self {
        storedValue.flatMap(Self.init(rawValue:)) ?? .center
    }
}

/// The laid-out width and side insets for a wide surface. No scale factor: callers assign
/// `contentWidth` as a real frame width and let the insets fill the rest.
public struct KeyboardWideContentPlan: Equatable, Sendable {
    /// false means the content keeps the full panel width and both insets are zero.
    public let active: Bool
    /// Real width to lay out with; finite and never above the panel width.
    public let contentWidth: Double
    /// Blank width before the content; finite and non-negative.
    public let leadingInset: Double
    /// Blank width after the content; finite and non-negative.
    public let trailingInset: Double

    public static func inactive(panelWidth: Double) -> Self {
        let width = KeyboardWideContentPolicy.normalized(panelWidth)
        return Self(active: false, contentWidth: width, leadingInset: 0, trailingInset: 0)
    }
}

/// Keeps wide layouts from stretching: above a phone-sized surface the content is capped and
/// docked left, center or right. The policy only does geometry — layout identity, split, height,
/// preferences and system gestures stay with their owners.
public enum KeyboardWideContentPolicy {
    /// The 9-key outer frame keeps the inner 436pt phone shell intact with a 4pt gutter per side
    /// (`436 + 2 * 4 = 444`); the reconcile is left to the layout that draws the shell.
    public static let phoneNineMaximumContentWidth: Double = 444
    /// The merged 14/18-key letter pads read as one unit on a wide surface without stretching.
    public static let mergedMaximumContentWidth: Double = 520

    /// Returns the real content width and insets for this surface. A nil or oversized cap, a
    /// phone-sized surface (`KeyboardSurfaceWidth.phoneMaximum`), and malformed widths all stay
    /// inactive at full width.
    public static func plan(
        panelWidth: Double,
        maximumContentWidth: Double?,
        dock: KeyboardContentDock
    ) -> KeyboardWideContentPlan {
        let width = normalized(panelWidth)
        guard width > KeyboardSurfaceWidth.phoneMaximum,
            let maximumContentWidth,
            maximumContentWidth.isFinite,
            maximumContentWidth > 0,
            maximumContentWidth < width
        else { return .inactive(panelWidth: width) }
        let remaining = width - maximumContentWidth
        let leading: Double
        let trailing: Double
        switch dock {
        case .left:
            leading = 0
            trailing = remaining
        case .center:
            leading = remaining / 2
            trailing = remaining - leading
        case .right:
            leading = remaining
            trailing = 0
        }
        return KeyboardWideContentPlan(
            active: true, contentWidth: maximumContentWidth,
            leadingInset: leading, trailingInset: trailing)
    }

    /// The key area never gets narrower than this, whatever side margin is chosen.
    public static let minimumKeyAreaWidth: Double = 280

    /// The blank margin kept on each side of a `panelWidth` wide surface: `percent` of the full
    /// width on a large screen (wider than `largeAbove`), cut so the key area keeps
    /// `minimumKeyAreaWidth`, and zero on any other screen.
    public static func sideMargin(panelWidth: Double, percent: Double, largeAbove: Double) -> Double {
        guard panelWidth.isFinite, percent.isFinite, largeAbove.isFinite, panelWidth > largeAbove else { return 0 }
        return max(0, min(panelWidth * percent / 100, (panelWidth - minimumKeyAreaWidth) / 2))
    }

    /// The plan for a surface with a blank `sideMargin` on each side. The cap and dock work on the
    /// width left after the margins, so a margin can bring a surface under a threshold; the insets
    /// then include the margin and the content width never exceeds what the margins leave.
    public static func plan(
        panelWidth: Double,
        maximumContentWidth: Double?,
        dock: KeyboardContentDock,
        sideMargin: Double
    ) -> KeyboardWideContentPlan {
        let width = normalized(panelWidth)
        let margin = min(max(0, sideMargin.isFinite ? sideMargin : 0), width / 2)
        let inner = plan(panelWidth: width - 2 * margin, maximumContentWidth: maximumContentWidth, dock: dock)
        guard margin > 0 else { return inner }
        return KeyboardWideContentPlan(
            active: true, contentWidth: inner.contentWidth,
            leadingInset: inner.leadingInset + margin, trailingInset: inner.trailingInset + margin)
    }

    /// Real UI widths may be negative or non-finite right after a resize; normalize exactly once.
    static func normalized(_ width: Double) -> Double {
        width.isFinite ? max(0, width) : 0
    }
}

/// The user's two width choices: the width above which a screen counts as large (where an
/// automatic split starts and the side margin applies), and that margin as a share of the width.
/// Device settings, not layout content, so a layout file never carries them.
public struct KeyboardWidthSettings: Equatable, Sendable {
    public static let splitWidthRange = 400...1200
    public static let splitWidthStep = 20
    /// The default is the phone-sized surface limit, so an untouched setting splits exactly where
    /// it always did.
    public static let defaultSplitWidth = Int(KeyboardSurfaceWidth.phoneMaximum)
    public static let sideMarginPercentRange = 0.0...10.0
    public static let sideMarginPercentStep = 0.5
    public static let defaultSideMarginPercent = 5.0

    /// A keyboard wider than this splits automatically.
    public let splitWidth: Int
    /// A keyboard wider than this gets the side margin; the same range and step as `splitWidth`.
    public let marginWidth: Int
    /// Each side's blank margin on a large screen, in percent of the keyboard's full width.
    public let sideMarginPercent: Double
    /// Whether the user picked the margin; an untouched setting gives way to a system inset.
    public let sideMarginIsChosen: Bool

    public static let standard = KeyboardWidthSettings()

    /// Out-of-range or off-step values snap into the offered choices. A nil margin is the default.
    public init(splitWidth: Int = defaultSplitWidth, marginWidth: Int? = nil, sideMarginPercent: Double? = nil) {
        self.splitWidth = Self.clampedSplitWidth(splitWidth)
        self.marginWidth = Self.clampedSplitWidth(marginWidth ?? Self.defaultSplitWidth)
        self.sideMarginPercent = Self.clampedSideMarginPercent(sideMarginPercent ?? Self.defaultSideMarginPercent)
        self.sideMarginIsChosen = sideMarginPercent != nil
    }

    /// The margin to draw. When the system already keeps blank room beside the keyboard (an iPhone
    /// in landscape, where the globe and dictation sit on either side), the default margin would
    /// only push the keys further in than the system keyboard's; a margin the user chose still applies.
    public func effectiveSideMarginPercent(systemInsetsSides: Bool) -> Double {
        systemInsetsSides && !sideMarginIsChosen ? 0 : sideMarginPercent
    }

    public static func clampedSplitWidth(_ value: Int) -> Int {
        let low = splitWidthRange.lowerBound
        let clamped = min(max(value, low), splitWidthRange.upperBound)
        return (clamped - low) / splitWidthStep * splitWidthStep + low
    }

    public static func clampedSideMarginPercent(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSideMarginPercent }
        let clamped = min(max(value, sideMarginPercentRange.lowerBound), sideMarginPercentRange.upperBound)
        return (clamped / sideMarginPercentStep).rounded() * sideMarginPercentStep
    }
}

/// Where the 9-key keyboard shows its expanded candidates on a screen with room beside it.
public enum NineKeyCandidateSide: String, CaseIterable, Sendable {
    case left, right, off

    /// Unknown or missing stored values fall back to the left, the default.
    public static func resolve(_ storedValue: String?) -> Self {
        storedValue.flatMap(Self.init(rawValue:)) ?? .left
    }

    /// The other side; off stays off.
    public var mirrored: Self {
        switch self {
        case .left: return .right
        case .right: return .left
        case .off: return .off
        }
    }
}

/// The candidate column beside a docked 9-key keyboard.
public struct NineKeySideCandidatePlan: Equatable, Sendable {
    /// `.left` or `.right`, never `.off`.
    public let side: NineKeyCandidateSide
    /// Width of the candidate column, the gap not included.
    public let candidateWidth: Double
    /// Width of the gap between the candidates and the keys; it holds the swap button.
    public let stripWidth: Double
    /// Width of the 9-key keyboard.
    public let keypadWidth: Double

    /// The keys sit on the side away from the candidates.
    public var keypadDock: KeyboardContentDock { side == .left ? .right : .left }
}

/// Splits a wide screen into the candidates, a gap and the 9-key keyboard. The gap is a share of
/// the whole width, so the keys come away from the middle and sit under one thumb at the screen's
/// edge; the rest is shared evenly, the keys never wider than the phone shell. Geometry only.
public enum NineKeySideCandidatePolicy {
    /// Narrower than this the column would show a word or two per row; the side stays blank.
    public static let minimumCandidateWidth: Double = 160
    /// The keys never get narrower than this, the same floor as any key area.
    public static let minimumKeypadWidth: Double = KeyboardWideContentPolicy.minimumKeyAreaWidth
    /// The gap holds the swap button and is never narrower than it.
    public static let minimumStripWidth: Double = 40
    /// The gap in percent of the width left after the side margins.
    public static let gapPercentRange = 0...30
    public static let gapPercentStep = 5
    public static let defaultGapPercent = 15

    public static func clampedGapPercent(_ value: Int) -> Int {
        let low = gapPercentRange.lowerBound
        let clamped = min(max(value, low), gapPercentRange.upperBound)
        return (clamped - low) / gapPercentStep * gapPercentStep + low
    }

    /// `keyAreaWidth` is the width left after the side margins; `maximumKeypadWidth` the widest
    /// the 9-key shell draws.
    public static func plan(
        keyAreaWidth: Double, maximumKeypadWidth: Double, side: NineKeyCandidateSide,
        gapPercent: Int = defaultGapPercent
    ) -> NineKeySideCandidatePlan? {
        guard side != .off, keyAreaWidth.isFinite, maximumKeypadWidth.isFinite, maximumKeypadWidth > 0
        else { return nil }
        let strip = max(minimumStripWidth, keyAreaWidth * Double(clampedGapPercent(gapPercent)) / 100)
        let rest = keyAreaWidth - strip
        let keypad = min(maximumKeypadWidth, rest / 2)
        let candidates = rest - keypad
        guard keypad >= minimumKeypadWidth, candidates >= minimumCandidateWidth else { return nil }
        return NineKeySideCandidatePlan(
            side: side, candidateWidth: candidates, stripWidth: strip, keypadWidth: keypad)
    }
}
