import Foundation

/// A key of the split arrangement's letter rows: the row among the letter rows (the control row is
/// not one of them) and the key's position in that row read left to right across both halves.
public struct SplitKeyAddress: Hashable, Sendable {
    public var row: Int
    public var key: Int

    public init(row: Int, key: Int) {
        self.row = row
        self.key = key
    }
}

/// Draft edits of a layout's split arrangement. Pure value functions, so the editor holds no logic
/// of its own: every edit of a letter row makes the arrangement explicit (the derived one becomes
/// data), a new key joins the half of the key it follows, and an edit that would leave a half empty
/// changes nothing. `defaultBreaks` are the cuts the keyboard draws before any is saved.
public extension LayoutDefinition {
    /// The last row is the control row when it holds no letters or text, only function keys.
    var splitControlRowIndex: Int? {
        guard let last = rows.last, last.keys.allSatisfy({ $0.action.type != .code && $0.action.type != .literal })
        else { return nil }
        return rows.count - 1
    }

    /// The rows the split view edits.
    var splitLetterIndices: [Int] {
        rows.indices.filter { $0 != splitControlRowIndex }
    }

    /// Whether the user saved a split arrangement of their own.
    var hasExplicitSplit: Bool { split?.halves != nil }

    /// The arrangement of every row, the control row included: the saved one, else the rows cut.
    func splitArrangement(defaultBreaks: [Int]? = nil) -> [LayoutSplitRow] {
        if let halves = split?.halves, halves.count == rows.count { return halves }
        var cut = split ?? LayoutSplitConfiguration(activation: .off)
        cut.rowBreaks = cut.cutPositions(rowKeyCounts: rows.map { $0.keys.count }, defaults: defaultBreaks)
        return cut.derivedArrangement(of: rows)
    }

    /// The letter rows as they are when split: each half's keys in order.
    func splitLetterRows(defaultBreaks: [Int]? = nil) -> [LayoutRow] {
        let all = splitArrangement(defaultBreaks: defaultBreaks)
        return splitLetterIndices.map { LayoutRow(keys: all[$0].keys) }
    }

    /// Per letter row, how many keys the left half has.
    func splitCuts(defaultBreaks: [Int]? = nil) -> [Int] {
        let all = splitArrangement(defaultBreaks: defaultBreaks)
        return splitLetterIndices.map { all[$0].left.count }
    }

    func splitKey(at address: SplitKeyAddress, defaultBreaks: [Int]? = nil) -> LayoutKey? {
        let rows = splitLetterRows(defaultBreaks: defaultBreaks)
        guard rows.indices.contains(address.row), rows[address.row].keys.indices.contains(address.key) else {
            return nil
        }
        return rows[address.row].keys[address.key]
    }

    func replacingSplitKey(at address: SplitKeyAddress, with key: LayoutKey, defaultBreaks: [Int]? = nil)
        -> LayoutDefinition
    {
        var rows = splitLetterRows(defaultBreaks: defaultBreaks)
        guard rows.indices.contains(address.row), rows[address.row].keys.indices.contains(address.key) else {
            return self
        }
        var keys = rows[address.row].keys
        keys[address.key] = key
        rows[address.row] = LayoutRow(keys: keys)
        return storingSplit(rows: rows, cuts: splitCuts(defaultBreaks: defaultBreaks))
    }

    /// Adds `key` after the key at `address`, in the same half. Nil when the row is full.
    func addingSplitKey(after address: SplitKeyAddress, key: LayoutKey, defaultBreaks: [Int]? = nil)
        -> (layout: LayoutDefinition, selected: SplitKeyAddress)?
    {
        var rows = splitLetterRows(defaultBreaks: defaultBreaks)
        var cuts = splitCuts(defaultBreaks: defaultBreaks)
        guard rows.indices.contains(address.row), rows[address.row].keys.indices.contains(address.key),
            rows[address.row].keys.count < LayoutResourceBudget.keysPerRegion
        else { return nil }
        var keys = rows[address.row].keys
        keys.insert(key, at: address.key + 1)
        rows[address.row] = LayoutRow(keys: keys)
        if address.key < cuts[address.row] { cuts[address.row] += 1 }
        return (
            storingSplit(rows: rows, cuts: cuts), SplitKeyAddress(row: address.row, key: address.key + 1)
        )
    }

    /// Removes the key at `address`. Nil when it is a row's only key, or the only key of its half.
    func removingSplitKey(at address: SplitKeyAddress, defaultBreaks: [Int]? = nil)
        -> (layout: LayoutDefinition, selected: SplitKeyAddress)?
    {
        var rows = splitLetterRows(defaultBreaks: defaultBreaks)
        var cuts = splitCuts(defaultBreaks: defaultBreaks)
        guard rows.indices.contains(address.row), rows[address.row].keys.indices.contains(address.key),
            rows[address.row].keys.count > 1
        else { return nil }
        let inLeft = address.key < cuts[address.row]
        let halfSize = inLeft ? cuts[address.row] : rows[address.row].keys.count - cuts[address.row]
        guard halfSize > 1 else { return nil }
        var keys = rows[address.row].keys
        keys.remove(at: address.key)
        rows[address.row] = LayoutRow(keys: keys)
        if inLeft { cuts[address.row] -= 1 }
        return (
            storingSplit(rows: rows, cuts: cuts),
            SplitKeyAddress(row: address.row, key: min(address.key, keys.count - 1))
        )
    }

    /// Moves the key one place along its row. The cuts stay where they were, so a key at the cut
    /// that moves across it changes half.
    func movingSplitKey(at address: SplitKeyAddress, by offset: Int, defaultBreaks: [Int]? = nil)
        -> (layout: LayoutDefinition, selected: SplitKeyAddress)?
    {
        var rows = splitLetterRows(defaultBreaks: defaultBreaks)
        let cuts = splitCuts(defaultBreaks: defaultBreaks)
        guard rows.indices.contains(address.row),
            rows[address.row].keys.indices.contains(address.key),
            rows[address.row].keys.indices.contains(address.key + offset)
        else { return nil }
        var keys = rows[address.row].keys
        keys.swapAt(address.key, address.key + offset)
        rows[address.row] = LayoutRow(keys: keys)
        return (
            storingSplit(rows: rows, cuts: cuts), SplitKeyAddress(row: address.row, key: address.key + offset)
        )
    }

    /// Moves the cut of a letter row by `delta` keys. Without a saved arrangement that is the row's
    /// break; with one it moves the key at the cut to the other half. Nil when the cut cannot go there.
    func movingSplitCut(row: Int, by delta: Int, defaultBreaks: [Int]? = nil) -> LayoutDefinition? {
        let letters = splitLetterRows(defaultBreaks: defaultBreaks)
        var cuts = splitCuts(defaultBreaks: defaultBreaks)
        guard letters.indices.contains(row) else { return nil }
        let size = letters[row].keys.count
        let cut = cuts[row] + delta
        guard size >= 2, cut >= 1, cut < size else { return nil }
        if hasExplicitSplit {
            cuts[row] = cut
            return storingSplit(rows: letters, cuts: cuts)
        }
        var cutting = split ?? LayoutSplitConfiguration(activation: .off)
        var breaks = cutting.cutPositions(rowKeyCounts: rows.map { $0.keys.count }, defaults: defaultBreaks)
        breaks[splitLetterIndices[row]] = cut
        cutting.rowBreaks = breaks
        return settingSplit(cutting)
    }

    /// Drops the saved arrangement; the split follows the rows and their cuts again.
    func restoringAutomaticSplit() -> LayoutDefinition {
        guard var cutting = split else { return self }
        cutting.halves = nil
        return settingSplit(cutting.adjusted(to: rows))
    }

    /// Stores the whole rows. A saved arrangement is its own copy of the keys: key edits do not
    /// reach it, but rows that were added, removed or reordered follow into it so it keeps one
    /// entry per row.
    func replacingRowsFollowingSplit(_ newRows: [LayoutRow]) -> LayoutDefinition {
        var copy = self
        copy.rows = newRows
        guard var cutting = split else { return copy }
        let saved = cutting.halves
        cutting = cutting.adjusted(to: newRows)
        if let saved, saved.count == rows.count {
            var used = Set<Int>()
            var follow = [LayoutSplitRow?](repeating: nil, count: newRows.count)
            // A row that did not change stays with its own entry, wherever the rows moved.
            for index in newRows.indices where rows.indices.contains(index) && rows[index] == newRows[index] {
                follow[index] = saved[index]
                used.insert(index)
            }
            for index in newRows.indices where follow[index] == nil {
                if let match = rows.indices.first(where: { !used.contains($0) && rows[$0] == newRows[index] }) {
                    follow[index] = saved[match]
                    used.insert(match)
                }
            }
            // A row edited in place (same count of rows) keeps its entry; a new row is cut as it is.
            let sameCount = newRows.count == rows.count
            for index in newRows.indices where follow[index] == nil {
                follow[index] =
                    sameCount && !used.contains(index)
                    ? saved[index] : cutting.cut(row: index, keys: newRows[index].keys)
                if sameCount { used.insert(index) }
            }
            cutting.halves = follow.map { $0! }
        } else {
            cutting.halves = nil
        }
        copy.split = cutting
        return copy
    }

    /// Writes `rows` cut at `cuts` as the saved arrangement (the derived one becomes data). The
    /// control row keeps its own entry.
    private func storingSplit(rows letters: [LayoutRow], cuts: [Int]) -> LayoutDefinition {
        var all = splitArrangement()
        for (n, index) in splitLetterIndices.enumerated() {
            let keys = letters[n].keys
            all[index] = LayoutSplitRow(left: Array(keys.prefix(cuts[n])), right: Array(keys.dropFirst(cuts[n])))
        }
        var cutting = split ?? LayoutSplitConfiguration(activation: .off)
        cutting.halves = all
        return settingSplit(cutting)
    }
}
