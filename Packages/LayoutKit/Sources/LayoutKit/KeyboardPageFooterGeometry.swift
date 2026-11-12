import Foundation

/// Footer widths for an authored page, shared by the runtime and the preview.
///
/// A materialized default footer is the same key set the built-in control row draws. Recognizing
/// that structure (actions/targets and the frozen default widths — never an ID or label) keeps the
/// built-in control-row budget, so copying a page does not immediately squeeze the bottom row that
/// was tuned for it. Any changed width or structure falls back to the real authored relative
/// weights; a custom title, secondary label or long-press list does not change the geometry.
///
/// Pass only the visible keys: the host removes globe keys when the system has no keyboard switch
/// and passes a policy with `hasGlobe == false`, so the filtered default still matches the same
/// budget. The helper never adds, removes or repairs a key.
public struct KeyboardPageFooterGeometry: Equatable, Sendable {
    /// One width per `keys` element.
    public let keyWidths: [Double]
    public let spacing: Double
    /// True when the keys are exactly the live default footer and the shared control-row budget
    /// applies. False means `keyWidths` came from the authored relative weights.
    public let usesControlRowBudget: Bool

    /// The widths of the rails beside the page's rows that the footer runs under. Absent for a page
    /// without rails, or whose trailing rail runs down beside the footer.
    public struct Rails: Equatable, Sendable {
        public let leading: Double
        public let trailing: Double
        public init(leading: Double, trailing: Double) {
            self.leading = leading
            self.trailing = trailing
        }
    }

    public init(width: Double, keys: [LayoutKey], policy: KeyboardControlPolicy, rails: Rails? = nil) {
        // The digit pad's cells follow the rail the page really has, not the shell's default.
        let policy =
            policy.isDigitPad && (rails?.leading ?? 0) > 0
            ? policy.aligned(to: .init(rail: rails?.leading ?? 0, digit: 0)) : policy
        let metrics = policy.metrics(width: width)
        spacing = metrics.spacing
        let resolvedWidth = width.isFinite ? max(0, width) : 0
        guard !keys.isEmpty else {
            keyWidths = []
            usesControlRowBudget = false
            return
        }
        if let slots = Self.defaultFooterSlots(keys: keys, policy: policy) {
            keyWidths = slots.map { metrics[$0] }
            usesControlRowBudget = true
            return
        }
        let available = max(0, resolvedWidth - spacing * Double(keys.count - 1))
        if let railed = Self.widthsUnderRails(keys: keys, available: available, rails: rails) {
            keyWidths = railed
            usesControlRowBudget = false
            return
        }
        // Normalize through the shared projection: legal but huge finite weights must not overflow
        // the sum or the per-key multiplication into NaN frames.
        let projection = LayoutRowWidthProjection(weights: keys.map(\.widthWeight))
        if projection.keyFractions.contains(where: { $0 > 0 }) {
            keyWidths = projection.keyFractions.map { available * $0 }
        } else {
            keyWidths = Array(repeating: available / Double(keys.count), count: keys.count)
        }
        usesControlRowBudget = false
    }

    /// A footer under rails: the first key sits under the leading rail, the last under the trailing
    /// rail and the rest share what is left by their own weights, so the footer keeps the columns
    /// of the rows above. Nil when there is nothing to align or the rails leave no room.
    private static func widthsUnderRails(keys: [LayoutKey], available: Double, rails: Rails?) -> [Double]? {
        guard let rails, keys.count >= 3, rails.leading > 0 || rails.trailing > 0 else { return nil }
        let lead = rails.leading > 0 ? rails.leading : nil
        let trail = rails.trailing > 0 ? rails.trailing : nil
        let middle = Array(keys.dropFirst(lead == nil ? 0 : 1).dropLast(trail == nil ? 0 : 1))
        let rest = available - (lead ?? 0) - (trail ?? 0)
        guard !middle.isEmpty, rest > 0 else { return nil }
        let projection = LayoutRowWidthProjection(weights: middle.map(\.widthWeight))
        let shares =
            projection.keyFractions.contains { $0 > 0 }
            ? projection.keyFractions.map { rest * $0 }
            : Array(repeating: rest / Double(middle.count), count: middle.count)
        return (lead.map { [$0] } ?? []) + shares + (trail.map { [$0] } ?? [])
    }

    /// The slots of a default footer: the control row's slots in order, or the order pages were
    /// saved with while the globe sat first, so a stored copy keeps its native widths.
    static func defaultFooterSlots(keys: [LayoutKey], policy: KeyboardControlPolicy) -> [KeyboardControlPolicy.Slot]? {
        let slots = policy.slots
        if isDefaultFooter(keys: keys, slots: slots, policy: policy) { return slots }
        let globeFirst = slots.filter { $0 == .globe } + slots.filter { $0 != .globe }
        if globeFirst != slots, isDefaultFooter(keys: keys, slots: globeFirst, policy: policy) { return globeFirst }
        return nil
    }

    /// The frozen default footer shape: the given slots in order, with the default space weight
    /// and every other default key at nil (= native budget width).
    private static func isDefaultFooter(
        keys: [LayoutKey], slots: [KeyboardControlPolicy.Slot], policy: KeyboardControlPolicy
    ) -> Bool {
        guard keys.count == slots.count else { return false }
        for (key, slot) in zip(keys, slots) {
            // The digit pad's space bar is one digit column, not the control row's wide one.
            let expectedWidth = slot == .space && !policy.isDigitPad ? KeyboardPageDefaultShape.footerSpaceWidth : nil
            guard key.width == expectedWidth else { return false }
            guard matches(key.action, expected: policy.key(at: slot), policy: policy) else { return false }
        }
        return true
    }

    private static func matches(
        _ action: LayoutAction, expected: KeyboardControlPolicy.Slot, policy: KeyboardControlPolicy
    ) -> Bool {
        switch expected {
        case .page:
            return action.pageSwitchTarget == policy.pageTarget
        case .returnToLetters:
            // The row pages' left switch is a return, not a language toggle.
            return action.pageSwitchTarget == .letters
        case .language:
            // The categorized default return keeps the native language/tools menu, so it may be an
            // explicit `.letters` language key as well as the page-following nil form.
            guard action.type == .languageSwitch else { return false }
            if policy.page == .symbols && policy.usesCategorySymbolPage {
                return action.languageSwitchBehavior == nil || action.languageSwitchBehavior == .letters
            }
            return action.languageSwitchBehavior == nil
        case .globe:
            return action.type == .globe
        case .space:
            return action.type == .space
        case .enter:
            return action.type == .enter
        case .symbolPage:
            return action.pageSwitchTarget == .symbols
        case .symbolLock:
            return action.type == .symbolLock
        case .symbolLibrary:
            // Authored footers have no symbol-library action, so none is the live default.
            return false
        case .utility:
            // The ABC page's comma, or the runtime footer's full stop beside the space bar.
            return action.type == .literal
        case .markLeft:
            return action.type == .literal && action.value == policy.utilityText
        case .markRight:
            return action.type == .literal && action.value == policy.fullStopText
        }
    }
}

public extension KeyboardPageFooterGeometry {
    /// A layout's own bottom row with keys added or removed, sized like the built-in row: keys
    /// without a chosen width start at the built-in size for their kind. An added key first takes
    /// up to a fifth of the space bar, then the other keys narrow toward the 44 pt touch size
    /// (Return toward 60 pt), and only then does the space bar give up more. Nil when the author
    /// chose a width or there is no space bar; the row then sizes by its weights.
    static func builtInSizedWidths(
        width: Double, keys: [LayoutKey], policy: KeyboardControlPolicy
    ) -> (widths: [Double], spacing: Double)? {
        let metrics = policy.metrics(width: width)
        let spaces = keys.indices.filter { keys[$0].action.type == .space }
        guard !spaces.isEmpty,
            spaces.allSatisfy({ keys[$0].width == nil || keys[$0].width == KeyboardPageDefaultShape.footerSpaceWidth }),
            keys.allSatisfy({ $0.action.type == .space || $0.width == nil })
        else { return nil }
        let natural = keys.map { key -> Double in
            switch key.action.type {
            case .space: return 0
            case .pageSwitch: return key.action.pageSwitchTarget == .symbols ? metrics.symbolPage : metrics.page
            case .languageSwitch, .modeSwitch: return metrics.language
            case .globe: return metrics.globe > 0 ? metrics.globe : metrics.page
            case .enter: return metrics.enter > 0 ? metrics.enter : metrics.page
            default: return metrics.utility > 0 ? metrics.utility : metrics.page
            }
        }
        let floors = zip(keys, natural).map { key, natural in
            key.action.type == .space ? 0 : min(natural, key.action.type == .enter ? 60 : 44)
        }
        let content = max(0, width - metrics.spacing * Double(keys.count - 1))
        let spaceTarget = metrics.space * 0.8 * Double(spaces.count)
        let free = content - spaceTarget
        let naturalTotal = natural.reduce(0, +)
        let floorTotal = floors.reduce(0, +)
        var widths: [Double]
        if naturalTotal <= free {
            widths = natural
        } else if floorTotal < free {
            let share = (free - floorTotal) / (naturalTotal - floorTotal)
            widths = zip(floors, natural).map { floor, natural in floor + share * (natural - floor) }
        } else {
            widths = floors
        }
        let space = (content - widths.reduce(0, +)) / Double(spaces.count)
        guard space >= 44 else { return nil }
        for index in spaces { widths[index] = space }
        return (widths, metrics.spacing)
    }
}
