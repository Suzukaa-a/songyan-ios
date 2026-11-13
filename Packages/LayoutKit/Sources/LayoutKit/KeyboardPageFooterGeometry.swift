import Foundation

/// Footer widths for main layouts and authored pages, shared by the runtime and the preview.
///
/// Automatic row footers share one budget based on their visible keys: ordinary keys keep the
/// same width, Return stays wider, and space absorbs the remaining room. Replacing a globe with
/// punctuation or switching pages does not move the other keys. Explicit widths use authored
/// relative weights. Keypad and railed pages retain their column alignment.
///
/// Pass only the visible keys: the host removes globe keys when the system has no keyboard switch
/// and passes a policy with `hasGlobe == false`, so the filtered default still matches the same
/// budget. The helper never adds, removes or repairs a key.
public struct KeyboardPageFooterGeometry: Equatable, Sendable {
    /// One width per `keys` element.
    public let keyWidths: [Double]
    public let spacing: Double
    /// True for automatic control sizing or a native keypad budget; false for authored weights.
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
        let resolvedWidth = width.isFinite ? max(0, width) : 0
        // A materialized native symbol footer keeps the running keyboard's seven-slot budget.
        // Once its structure or widths are edited, it follows the ordinary authored rules below.
        if policy.page == .symbols, !policy.isPhoneLayout, rails == nil {
            let native = KeyboardControlPolicy(
                page: .symbols, isEnglishMode: policy.isEnglishMode, hasGlobe: policy.hasGlobe,
                isPhoneLayout: false, usesASCIIPunctuation: policy.usesASCIIPunctuation,
                usesCategorySymbolPage: false, script: policy.script, showsSpaceSideMarks: true,
                offersSymbolLibrary: keys.contains { $0.action.type == .symbolLibrary })
            if let slots = Self.defaultFooterSlots(keys: keys, policy: native) {
                let nativeMetrics = native.metrics(width: resolvedWidth)
                keyWidths = slots.map { nativeMetrics[$0] }
                spacing = nativeMetrics.spacing
                usesControlRowBudget = true
                return
            }
        }
        if !policy.isPhoneLayout, rails == nil,
            let automatic = Self.automaticWidths(width: resolvedWidth, keys: keys, spacing: 4)
        {
            keyWidths = automatic
            spacing = 4
            usesControlRowBudget = true
            return
        }
        spacing = metrics.spacing
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
            keyWidths = Self.fittedAuthoredWidths(available: available, fractions: projection.keyFractions)
        } else {
            keyWidths = Array(repeating: available / Double(keys.count), count: keys.count)
        }
        usesControlRowBudget = false
    }

    /// Both renderers scroll the same widths when the row cannot fit. Automatic rows never
    /// shrink their controls below usable sizes; weighted rows retain their authored proportions
    /// until a key needs the minimum touch width.
    public func scrollWidths(availableWidth: Double, minimumKeyWidth: Double = 44) -> [Double]? {
        guard !keyWidths.isEmpty else { return nil }
        let widths = usesControlRowBudget ? keyWidths : keyWidths.map { max(minimumKeyWidth, $0) }
        let content = widths.reduce(0, +) + spacing * Double(widths.count - 1)
        return content > max(0, availableWidth) + 0.001 ? widths : nil
    }

    /// Keep authored proportions until a small key needs its touch minimum. Take that room
    /// from the larger keys before introducing scrolling; main and page footers use this alike.
    private static func fittedAuthoredWidths(available: Double, fractions: [Double]) -> [Double] {
        let minimum = 44.0
        guard available >= Double(fractions.count) * minimum else {
            return fractions.map { available * $0 }
        }
        var widths = Array(repeating: 0.0, count: fractions.count)
        var remaining = Array(fractions.indices)
        var room = available
        while !remaining.isEmpty {
            let total = remaining.reduce(0.0) { $0 + fractions[$1] }
            let proposed = remaining.map { total > 0 ? room * (fractions[$0] / total) : room / Double(remaining.count) }
            let small = zip(remaining, proposed).filter { $0.1 < minimum }.map(\.0)
            if small.isEmpty {
                for (index, width) in zip(remaining, proposed) { widths[index] = width }
                break
            }
            for index in small { widths[index] = minimum }
            room -= Double(small.count) * minimum
            remaining.removeAll { small.contains($0) }
        }
        return widths
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

    /// The slots of a default footer: the control row's slots in order, or an order pages were
    /// saved with earlier (the globe first, or right after the page key), so a stored copy keeps
    /// its native widths.
    static func defaultFooterSlots(keys: [LayoutKey], policy: KeyboardControlPolicy) -> [KeyboardControlPolicy.Slot]? {
        let slots = policy.slots
        if isDefaultFooter(keys: keys, slots: slots, policy: policy) { return slots }
        let rest = slots.filter { $0 != .globe }
        guard rest.count < slots.count else { return nil }
        for earlier in [[.globe] + rest, Array(rest.prefix(1)) + [.globe] + rest.dropFirst()]
        where earlier != slots && isDefaultFooter(keys: keys, slots: earlier, policy: policy) {
            return earlier
        }
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
            return action.type == .symbolLibrary
        case .utility:
            // The ABC page's comma, or the runtime footer's full stop beside the space bar.
            return action.type == .literal
        case .markLeft:
            return action.literalValue(usesASCIIPunctuation: policy.usesASCIIPunctuation) == policy.markLeftText
        case .markRight:
            return action.literalValue(usesASCIIPunctuation: policy.usesASCIIPunctuation) == policy.fullStopText
        }
    }
}

extension KeyboardPageFooterGeometry {
    static func hasAutomaticWidths(_ keys: [LayoutKey]) -> Bool {
        keys.contains { $0.action.type == .space }
            && keys.allSatisfy {
                $0.width == nil
                    || ($0.action.type == .space && $0.width == KeyboardPageDefaultShape.footerSpaceWidth)
            }
    }

    /// Width selection depends only on the visible row, never on the page, language, system
    /// globe availability or the main layout's optional punctuation slots. The stored default
    /// space weight (4) predates automatic sizing and keeps the same automatic behavior as nil.
    private static func automaticWidths(width: Double, keys: [LayoutKey], spacing: Double) -> [Double]? {
        let spaces = keys.indices.filter { keys[$0].action.type == .space }
        guard hasAutomaticWidths(keys) else { return nil }
        // Keep the familiar six-key Return size, independently of the current page's policy.
        let preferredReturn = max(60, KeyboardControlPolicy.Metrics(width: width, hasGlobe: true).enter)
        let returns = keys.filter { $0.action.type == .enter }.count
        let controls = keys.count - spaces.count - returns
        let content = max(0, width - spacing * Double(keys.count - 1))
        let returnRoom = content - Double(controls + spaces.count) * 44
        let returnWidth = returns > 0 ? max(60, min(preferredReturn, returnRoom / Double(returns))) : 0
        let spaceWidth = max(
            44, (content - Double(controls) * 44 - Double(returns) * returnWidth) / Double(spaces.count))
        return keys.map { key in
            switch key.action.type {
            case .space: return spaceWidth
            case .enter: return returnWidth
            default: return 44
            }
        }
    }
}
