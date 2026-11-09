import Foundation

/// The idle-toolbar entries the user can turn off and reorder; `rawValue` is the stored name.
public enum IdleToolbarItem: String, CaseIterable, Sendable {
    case emoji
    case settings
    case tools
}

/// The user's choice for the idle toolbar: every item once, in order, each shown or not. Off items
/// keep their place so turning one back on does not lose where it was.
public struct IdleToolbarLayout: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var item: IdleToolbarItem
        public var shown: Bool

        public init(item: IdleToolbarItem, shown: Bool) {
            self.item = item
            self.shown = shown
        }
    }

    public private(set) var entries: [Entry]

    private init(validated entries: [Entry]) { self.entries = entries }

    /// Today's idle toolbar: kaomoji, settings, then the tools.
    public static let `default` = IdleToolbarLayout(
        validated: [IdleToolbarItem.emoji, .settings, .tools].map { Entry(item: $0, shown: true) })

    public var shown: [IdleToolbarItem] { entries.filter(\.shown).map(\.item) }
    public var isDefault: Bool { self == .default }

    public func withShown(_ item: IdleToolbarItem, _ shown: Bool) -> IdleToolbarLayout {
        IdleToolbarLayout(validated: entries.map { $0.item == item ? Entry(item: item, shown: shown) : $0 })
    }

    /// Moves among all entries, so an off item can be reordered too. Offsets follow `onMove`.
    public func moving(fromOffsets source: IndexSet, toOffset destination: Int) -> IdleToolbarLayout {
        var moved = entries
        let picked = source.sorted().map { moved[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted().reversed() { moved.remove(at: index) }
        moved.insert(contentsOf: picked, at: destination - before)
        return IdleToolbarLayout(validated: moved)
    }

    /// `emoji,-settings,...`: names in order, a leading `-` marks an item that is off.
    public func toWire() -> String {
        entries.map { ($0.shown ? "" : "-") + $0.item.rawValue }.joined(separator: ",")
    }

    /// Nothing stored gives the default; unknown or repeated names are skipped and items the value
    /// does not mention are appended on, so an older or damaged value never hides a button for good.
    /// A removed item (the old clipboard button) is an unknown name and simply drops out.
    public static func parse(_ wire: String?) -> IdleToolbarLayout {
        guard let wire, !wire.trimmingCharacters(in: .whitespaces).isEmpty else { return .default }
        var seen: [Entry] = []
        for token in wire.split(separator: ",", omittingEmptySubsequences: false) {
            let name = token.trimmingCharacters(in: .whitespaces)
            let off = name.hasPrefix("-")
            guard let item = IdleToolbarItem(rawValue: off ? String(name.dropFirst()) : name),
                !seen.contains(where: { $0.item == item })
            else { continue }
            seen.append(Entry(item: item, shown: !off))
        }
        guard !seen.isEmpty else { return .default }
        for entry in Self.default.entries where !seen.contains(where: { $0.item == entry.item }) {
            seen.append(entry)
        }
        return IdleToolbarLayout(validated: seen)
    }
}

/// One drawn idle-toolbar slot. A pinned tool is the tools item's own shortcut, drawn before the
/// tools button.
public enum IdleToolbarSlot: Equatable, Sendable {
    case emoji
    case settings
    case pinned(Int)
    case tools
}

/// How many entries fit a width. The keyboard and the settings page both call this, so the count
/// the settings page shows is the one the keyboard enforces.
public enum IdleToolbarCapacity {
    /// The smallest slot an icon keeps: a comfortable touch target, so a full toolbar drops entries
    /// instead of cramming them.
    public static let minIconSlot: Double = 44
    public static let maxPinnedSlot: Double = 96

    /// The most chosen entries a toolbar `width` points wide shows, after `fixedSlots` entries that
    /// are always drawn.
    public static func limit(width: Double, fixedSlots: Int = 0) -> Int {
        max(0, Int((width / minIconSlot).rounded(.down)) - fixedSlots)
    }

    public struct Slot: Equatable, Sendable {
        public var minWidth: Double
        public var droppable: Bool

        public init(minWidth: Double, droppable: Bool) {
            self.minWidth = minWidth
            self.droppable = droppable
        }
    }

    /// Which slots stay: while they need more than `width`, the last droppable one goes, so the
    /// front of the user's order wins. Slots that cannot be dropped always stay.
    public static func keep(width: Double, slots: [Slot]) -> [Bool] {
        var kept = [Bool](repeating: true, count: slots.count)
        guard width > 0 else { return kept }
        var need = slots.reduce(0) { $0 + $1.minWidth }
        var index = slots.count - 1
        while need > width, index >= 0 {
            if slots[index].droppable {
                kept[index] = false
                need -= slots[index].minWidth
            }
            index -= 1
        }
        return kept
    }
}

/// Builds the idle toolbar's slot list from the user's choice and what the field and window offer.
public enum IdleToolbarAssembly {
    /// The shown items in the user's order, minus what is unavailable. A choice can only remove
    /// entries, never add one the field cannot offer. The tools item brings the pinned tools ahead
    /// of its button and goes away with `toolsAvailable` (a protected field, no readable host).
    /// `pinnedWidths` are the pinned tools' own minimum widths.
    public static func slots(
        layout: IdleToolbarLayout, hidden: Bool, toolsAvailable: Bool, pinnedWidths: [Double] = []
    ) -> [IdleToolbarSlot] {
        guard !hidden else { return [] }
        return layout.shown.flatMap { item -> [IdleToolbarSlot] in
            switch item {
            case .emoji: [.emoji]
            case .settings: [.settings]
            case .tools: toolsAvailable ? pinnedWidths.indices.map { .pinned($0) } + [.tools] : []
            }
        }
    }

    /// `slots` after width overflow: dropped from the end of the user's order, with `fixedSlots`
    /// always-drawn entries (such as the wide-screen hide button) taking room that is never given
    /// back.
    public static func fitting(
        _ slots: [IdleToolbarSlot], pinnedWidths: [Double] = [], width: Double, fixedSlots: Int = 0
    ) -> [IdleToolbarSlot] {
        let fixed = [IdleToolbarCapacity.Slot](
            repeating: .init(minWidth: IdleToolbarCapacity.minIconSlot, droppable: false), count: fixedSlots)
        let drawn =
            slots.map { slot -> IdleToolbarCapacity.Slot in
                if case .pinned(let index) = slot, pinnedWidths.indices.contains(index) {
                    return .init(
                        minWidth: min(
                            IdleToolbarCapacity.maxPinnedSlot,
                            max(IdleToolbarCapacity.minIconSlot, pinnedWidths[index])),
                        droppable: true)
                }
                return .init(minWidth: IdleToolbarCapacity.minIconSlot, droppable: true)
            } + fixed
        let kept = IdleToolbarCapacity.keep(width: width, slots: drawn)
        return slots.indices.filter { kept[$0] }.map { slots[$0] }
    }
}

/// What can occupy the candidate band; the idle toolbar shows only when none of it does.
public struct IdleToolbarInput: Equatable, Sendable {
    public var isComposing: Bool
    public var hasPrediction: Bool
    public var hasCandidates: Bool
    public var hasEnglishSuggestions: Bool
    public var hasActiveEnglishInput: Bool
    public var hasStatus: Bool
    public var hasCompositionFallback: Bool
    public var hasReadingContent: Bool
    public var hasPendingQueries: Bool
    public var isExpanded: Bool
    public var isCovered: Bool

    public init(
        isComposing: Bool = false, hasPrediction: Bool = false, hasCandidates: Bool = false,
        hasEnglishSuggestions: Bool = false, hasActiveEnglishInput: Bool = false, hasStatus: Bool = false,
        hasCompositionFallback: Bool = false, hasReadingContent: Bool = false, hasPendingQueries: Bool = false,
        isExpanded: Bool = false, isCovered: Bool = false
    ) {
        self.isComposing = isComposing
        self.hasPrediction = hasPrediction
        self.hasCandidates = hasCandidates
        self.hasEnglishSuggestions = hasEnglishSuggestions
        self.hasActiveEnglishInput = hasActiveEnglishInput
        self.hasStatus = hasStatus
        self.hasCompositionFallback = hasCompositionFallback
        self.hasReadingContent = hasReadingContent
        self.hasPendingQueries = hasPendingQueries
        self.isExpanded = isExpanded
        self.isCovered = isCovered
    }

    public var allowsToolbar: Bool {
        !isComposing && !hasPrediction && !hasCandidates && !hasEnglishSuggestions
            && !hasActiveEnglishInput && !hasStatus && !hasCompositionFallback
            && !hasReadingContent && !hasPendingQueries && !isExpanded && !isCovered
    }
}
