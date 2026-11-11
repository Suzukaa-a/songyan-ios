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

    /// The blank margin kept on each side of a `panelWidth` wide surface for a `requested` choice:
    /// cut so the key area keeps `minimumKeyAreaWidth`, and zero on a surface already that narrow.
    public static func sideMargin(panelWidth: Double, requested: Double) -> Double {
        guard panelWidth.isFinite, requested.isFinite else { return 0 }
        return max(0, min(requested, (panelWidth - minimumKeyAreaWidth) / 2))
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

/// The user's two width choices, in points: where an automatic split starts and the blank margin
/// beside the key area. Device settings, not layout content, so a layout file never carries them.
public struct KeyboardWidthSettings: Equatable, Sendable {
    public static let splitWidthRange = 400...1200
    public static let splitWidthStep = 20
    /// The default is the phone-sized surface limit, so an untouched setting splits exactly where
    /// it always did.
    public static let defaultSplitWidth = Int(KeyboardSurfaceWidth.phoneMaximum)
    public static let sideMarginRange = 0...96
    public static let sideMarginStep = 4

    /// A key area wider than this splits (when the layout's split is automatic).
    public let splitWidth: Int
    public let sideMargin: Int

    public static let standard = KeyboardWidthSettings()

    /// Out-of-range or off-step values snap down into the offered choices.
    public init(splitWidth: Int = defaultSplitWidth, sideMargin: Int = 0) {
        self.splitWidth = Self.clampedSplitWidth(splitWidth)
        self.sideMargin = Self.clampedSideMargin(sideMargin)
    }

    public static func clampedSplitWidth(_ value: Int) -> Int {
        let low = splitWidthRange.lowerBound
        let clamped = min(max(value, low), splitWidthRange.upperBound)
        return (clamped - low) / splitWidthStep * splitWidthStep + low
    }

    public static func clampedSideMargin(_ value: Int) -> Int {
        min(max(value, sideMarginRange.lowerBound), sideMarginRange.upperBound) / sideMarginStep * sideMarginStep
    }
}
