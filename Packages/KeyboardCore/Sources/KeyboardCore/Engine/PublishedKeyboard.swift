import Foundation

// MARK: - Published keyboard (publication unit = input method + layout)
//
// A user keyboard added in the host app is the publication unit: one
// "input method (schema) x layout" combination (e.g. some input method + 14 keys).
//
//   * the host app generates and validates resources only when that keyboard is added/updated;
//   * deleting it removes the combination from the extension's switcher;
//   * the extension never discovers or prepares combinations that weren't added.
//
// Single source of truth: `KeyboardRecipeStore.Activation.publishedKeyboards` (read via
// `activation.keyboards`). This type is an identity (verbatim schema id + layout); it
// persists no human names, branding or generated artifact paths.
//
// Human names are resolved at projection time from `Activation.schemas` (structured
// `KeyboardSchemaDescriptor`; see `KeyboardResourceSet.publishedCombinations` /
// `InputMethodProjection`). Schema-agnostic: whether a compact layout (14/9 keys) needs
// a generated adapter depends only on the layout's capability (`requiresSpellingDisplay`),
// never on layout identity or source name.
public struct PublishedKeyboard: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Input method: source schema ID from the engine enabled list, kept verbatim.
    public let schemaID: String
    /// Keyboard layout (26 / 26 shuangpin / 14 / 9).
    public let layout: KeyboardLayoutKind

    /// A reserved physical layout ID (`InputLayoutPolicy.boards(of:)`) the keyboard types on. nil
    /// keeps the older meaning: the main layout comes from the pairing. Boards of one input method
    /// share its shape and so its pairing and resources; only the identity differs.
    public let board: String?

    /// Identity: `schema:layout`, plus `#board` when a board is set.
    public var id: String { combinationID + (board.map { "#" + $0 } ?? "") }

    /// The resource-bearing combination (input method x layout) this keyboard runs on. Never parse
    /// `id` back into it.
    public var combinationID: String { schemaID + ":" + layout.rawValue }

    public init(schemaID: String, layout: KeyboardLayoutKind, board: String? = nil) {
        self.schemaID = schemaID
        self.layout = layout
        self.board = board.flatMap { $0.isEmpty ? nil : $0 }
    }

    private enum CodingKeys: String, CodingKey { case schemaID, layout, board }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaID: try container.decode(String.self, forKey: .schemaID),
            layout: try container.decode(KeyboardLayoutKind.self, forKey: .layout),
            board: try container.decodeIfPresent(String.self, forKey: .board))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaID, forKey: .schemaID)
        try container.encode(layout, forKey: .layout)
        try container.encodeIfPresent(board, forKey: .board)
    }
}

/// Optional auxiliary candidate route owned by one exact published keyboard pair.
/// Its candidate schema is only trusted when the enclosing publication also proves
/// that schema is enabled and compiled in the same immutable generation.
public struct EnglishCandidateRoute: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let owner: PublishedKeyboard
    public let candidateSchemaID: String

    public var id: String { owner.id }

    public init(owner: PublishedKeyboard, candidateSchemaID: String) {
        self.owner = owner
        self.candidateSchemaID = candidateSchemaID
    }
}

public extension PublishedKeyboard {
    /// Whether the combination needs a generated adapter companion (14/9-key merged or
    /// digit layouts). 26-key (quanpin / shuangpin hints) uses the source schema directly.
    var needsGeneratedAdapter: Bool { layout.requiresSpellingDisplay }

    /// The added-keyboard list of a publication record, duplicates dropped. No list means no
    /// keyboards added; combinations are never invented from the selection or the enabled list.
    static func resolve(published: [PublishedKeyboard]?) -> [PublishedKeyboard] {
        var seen = Set<PublishedKeyboard>()
        return (published ?? []).filter { seen.insert($0).inserted }
    }

    /// Adds an entry (idempotent, keeps insertion order, no duplicates).
    static func adding(
        _ keyboard: PublishedKeyboard,
        to list: [PublishedKeyboard]
    ) -> [PublishedKeyboard] {
        list.contains(keyboard) ? list : list + [keyboard]
    }

    /// Removes an entry (idempotent; unchanged if absent).
    static func removing(
        _ keyboard: PublishedKeyboard,
        from list: [PublishedKeyboard]
    ) -> [PublishedKeyboard] {
        list.filter { $0 != keyboard }
    }

    /// The selection falls back only if the current combination was removed (or there is no
    /// valid current one); an unaffected current combination is kept.
    /// Uses only publication identity and list order.
    static func selectionAfterRemoval(
        from remaining: [PublishedKeyboard],
        current: PublishedKeyboard?
    ) -> PublishedKeyboard? {
        if let current, remaining.contains(current) { return current }
        return remaining.first
    }

    /// What switching the keyboard to an input scheme publishes: the keyboards remembered for that
    /// scheme, with the first one in use; when none were ever chosen, one starting keyboard from its
    /// addable list (the 26-key one when it has it). nil when the scheme offers no keyboard at all.
    static func switchTarget(
        remembered: [PublishedKeyboard], addable: [PublishedKeyboard]
    ) -> (roster: [PublishedKeyboard], selection: PublishedKeyboard)? {
        let kept = resolve(published: remembered)
        if let first = kept.first { return (kept, first) }
        guard let start = addable.first(where: { $0.layout == .qwerty26 }) ?? addable.first else { return nil }
        return ([start], start)
    }

    /// Adapter generation tasks (deduplicated, ordered): compact-layout combinations only.
    /// 26-key combinations need no generation and are excluded.
    static func generationTasks(for requested: [PublishedKeyboard]) -> [PublishedKeyboard] {
        var seen = Set<String>()
        return requested.filter { $0.needsGeneratedAdapter && seen.insert($0.combinationID).inserted }
    }
}

// MARK: - Human-facing projection (names from current scheme descriptors, not persisted)

/// Display projection of a published keyboard: publication identity plus the input
/// method name resolved from the current record. The name comes from
/// `KeyboardSchemaDescriptor.name`, not a persisted field, so renames follow
/// automatically; an empty name falls back to the layout name, never an internal id.
public struct PublishedKeyboardDisplay: Equatable, Sendable, Identifiable {
    public let keyboard: PublishedKeyboard
    /// Input method display name (from `Activation.schemas` / resource snapshot; may be empty).
    public let inputMethodName: String

    public var id: String { keyboard.id }
    public var layout: KeyboardLayoutKind { keyboard.layout }

    public init(keyboard: PublishedKeyboard, inputMethodName: String) {
        self.keyboard = keyboard
        self.inputMethodName = inputMethodName
    }

    /// Title: `<input method> · <layout>`; layout name only when there is no input method name.
    public var title: String {
        let trimmed = inputMethodName.trimmingCharacters(in: .whitespaces)
        let layoutName =
            keyboard.board.flatMap { UserTerminology.builtinLayoutName(physicalLayoutID: $0) }
            ?? UserTerminology.layoutName(layout)
        return trimmed.isEmpty ? layoutName : "\(trimmed) · \(layoutName)"
    }
}

public extension PublishedKeyboard {
    /// Resolves the display name from scheme descriptors (`Activation.schemas` or the
    /// snapshot `schemas`). Empty when not found, so the layout name is shown.
    static func display(
        _ keyboard: PublishedKeyboard,
        in descriptors: [KeyboardSchemaDescriptor]
    ) -> PublishedKeyboardDisplay {
        // Only a declared human-readable name counts. Empty or `name == id` falls back to the
        // layout name so raw schema/source IDs never reach the manager or switcher.
        let name = descriptors.first { $0.id == keyboard.schemaID }?.humanReadableName ?? ""
        return PublishedKeyboardDisplay(keyboard: keyboard, inputMethodName: name)
    }

    /// Batch projection (keeps input order).
    static func displays(
        _ keyboards: [PublishedKeyboard],
        in descriptors: [KeyboardSchemaDescriptor]
    ) -> [PublishedKeyboardDisplay] {
        keyboards.map { display($0, in: descriptors) }
    }
}
