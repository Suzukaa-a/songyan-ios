import Foundation

// Where the system draws its own keyboard switch key, a row reads without the globe. Every view and
// editor goes through these, so the keyboard, its previews and the editors agree on one shape.

extension Array where Element == LayoutKey {
    /// A row as a machine shows it; `shown` is false where the system draws its own switch key.
    /// A globe immediately left of the space bar holds the comma's slot (`123 中/英 🌐 空格 ， 换行`), so
    /// without it the footer reads `， 空格 。`: the slot types the comma and the comma right of the
    /// space bar becomes the full stop; no key moves. Any other globe is left out; in an explicitly
    /// weighted footer its width goes to Return, so the space bar keeps its width.
    public func forSystemSwitch(shown: Bool) -> [LayoutKey] {
        guard !shown, let space = firstIndex(where: { $0.action.type == .space }) else {
            return shown ? self : filter { $0.action.type != .globe }
        }
        if space > 0, self[space - 1].action.type == .globe {
            // A split footer has a space bar in each half; the comma follows the last of them.
            var afterSpace = space + 1
            while afterSpace < count, self[afterSpace].action.type == .space { afterSpace += 1 }
            return enumerated().map { index, key in
                if index == space - 1 {
                    return KeyboardPageDefinition.symbolFooterMark(fullStop: false, marks: .chinese)
                        .settingWidth(key.width)
                }
                if index == afterSpace, key.isFooterComma {
                    return KeyboardPageDefinition.symbolFooterMark(fullStop: true, marks: .chinese)
                        .settingWidth(key.width)
                }
                return key
            }.filter { $0.action.type != .globe }
        }
        let freed = filter { $0.action.type == .globe }.reduce(0) { $0 + $1.widthWeight }
        guard freed > 0 else { return self }
        // Automatic footers re-budget themselves; only an explicitly weighted one hands the
        // weight to Return.
        if KeyboardPageFooterGeometry.hasAutomaticWidths(self) { return filter { $0.action.type != .globe } }
        return filter { $0.action.type != .globe }.map {
            $0.action.type == .enter ? $0.settingWidth($0.widthWeight + freed) : $0
        }
    }

    /// The stored index of each key `forSystemSwitch(shown:)` returns.
    public func systemSwitchSources(shown: Bool) -> [Int] {
        if shown { return [Int](indices) }
        if let space = firstIndex(where: { $0.action.type == .space }), space > 0,
            self[space - 1].action.type == .globe
        {
            return indices.filter { $0 == space - 1 || self[$0].action.type != .globe }
        }
        return indices.filter { self[$0].action.type != .globe }
    }

    /// `forSystemSwitch(shown:)` laid back over the stored indices, for views that address keys by
    /// their stored index: each source holds the key drawn there; a left-out globe keeps its key.
    public func systemSwitchKeysBySource(shown: Bool) -> [LayoutKey] {
        var keys = self
        for (index, key) in zip(systemSwitchSources(shown: shown), forSystemSwitch(shown: shown)) { keys[index] = key }
        return keys
    }
}

extension LayoutKey {
    /// The default footer's comma: it types the comma in both symbol languages.
    var isFooterComma: Bool {
        action.type == .literal && action.value == "，" && action.asciiValue == ","
    }
}

public extension Array where Element == LayoutKey {
    /// Whether `key` is the only globe key among these keys: on a machine that needs one, the main
    /// layout keeps it.
    func isLastGlobe(_ key: LayoutKey) -> Bool {
        key.action.type == .globe && filter { $0.action.type == .globe }.count == 1
    }
}

/// A machine either needs a globe key or never will (the system draws its own), so an editor opens
/// a layout or page in that machine's shape: where the system has its own switch key, no globe is
/// left to hide and the comma and full stop beside the space bar are ordinary keys.
public extension LayoutDefinition {
    func forSystemSwitch(shown: Bool) -> LayoutDefinition {
        guard !shown else { return self }
        var copy = replacingRowsFollowingSplit(rows.map { LayoutRow(keys: $0.keys.forSystemSwitch(shown: false)) })
        // A saved split arrangement is its own copy of the keys; each row reads across both halves.
        copy.split?.halves = split?.halves?.map { row in
            let whole = row.left + row.right
            let halves = zip(whole.systemSwitchSources(shown: false), whole.forSystemSwitch(shown: false))
            return LayoutSplitRow(
                left: halves.filter { $0.0 < row.left.count }.map(\.1),
                right: halves.filter { $0.0 >= row.left.count }.map(\.1))
        }
        return copy
    }
}

public extension KeyboardPageDefinition {
    func forSystemSwitch(shown: Bool) -> KeyboardPageDefinition {
        guard !shown else { return self }
        var copy = self
        copy.rows = rows.map { LayoutRow(keys: $0.keys.forSystemSwitch(shown: false)) }
        copy.chrome?.bottom = (chrome?.bottom ?? []).forSystemSwitch(shown: false)
        copy.chrome?.leading = (chrome?.leading ?? []).forSystemSwitch(shown: false)
        copy.chrome?.trailing = (chrome?.trailing ?? []).forSystemSwitch(shown: false)
        return copy
    }
}
