import Foundation

/// Engine state the front end has actually observed. The model never invents it: a nil
/// observation means "unknown" and every replacement falls back to no-op, so a stale or
/// unavailable snapshot can never send a BackSpace the engine did not consume.
public struct Kana12Observation: Equatable, Sendable {
    /// Engine preedit text while composing; nil when idle (committed, cleared, or no composition).
    public var composition: String?
    /// Caret offset inside the composition, counted in Characters from its start. Never UTF-16
    /// or UTF-8 units: the front end converts the engine's byte caret before passing it in.
    public var caret: Int
    /// A selection inside the composition or document; replacements stay off while one exists.
    public var hasSelection: Bool

    public init(composition: String? = nil, caret: Int = 0, hasSelection: Bool = false) {
        self.composition = composition
        self.caret = caret
        self.hasSelection = hasSelection
    }
}

/// What the front end must do for one key press. The model is pure: it never calls an engine.
public enum Kana12Effect: Equatable, Sendable {
    /// Send every Character of romaji to the engine in order; the composition then shows kana.
    case append(kana: String, romaji: String)
    /// Send exactly one BackSpace, then every Character of romaji. One BackSpace deletes one
    /// kana because kagiroi already converted the composition to kana; never use romaji.length,
    /// which lets extra BackSpaces leak to the editor and over-deletes.
    case replace(previousKana: String, kana: String, romaji: String)
    /// Insert the text literally (punctuation, brackets, ellipsis); never a Rime key token.
    case literal(String)
    /// Nothing to do: unsupported direction, no variant, or no proof of this model's tail.
    case none

    /// The kana this effect leaves in the composition, if any.
    public var kana: String? {
        switch self {
        case .append(let kana, _): return kana
        case .replace(_, let kana, _): return kana
        case .literal, .none: return nil
        }
    }

    /// The validated engine code this effect types, if any.
    public var romaji: String? {
        switch self {
        case .append(_, let romaji): return romaji
        case .replace(_, _, let romaji): return romaji
        case .literal, .none: return nil
        }
    }

    /// BackSpaces the front end must send before the romaji: exactly one for a replacement.
    public var backspaces: Int {
        switch self {
        case .replace: return 1
        case .append, .literal, .none: return 0
        }
    }
}

/// J2 kana12 input model: maps a key plus flick direction to append/replace/literal effects,
/// owns the J2.3 tap cycle and the J2.4 小゛゜ replacement, and tracks whether the kana it last
/// emitted is still the tail of the composition the front end observes.
///
/// Composition ownership: a replacement is only emitted while the front end observes exactly
/// the composition this model predicted after its previous effect, with the caret at the end.
/// Foreign input, a cursor move, a selection, a commit or a clear changes one of those facts, so
/// the next replacement degrades to append or no-op. There is no fallback to guessing.
public struct Kana12InputModel: Sendable {
    /// J2.3 repeated-tap window. The window is measured with the caller's monotonic timestamps;
    /// a timestamp that goes backwards starts a fresh cycle instead of extending one.
    public static let toggleInterval: TimeInterval = 0.8

    private struct Ownership: Sendable {
        var key: Kana12Key
        var cycleIndex: Int
        var lastKana: String
        var expectedComposition: String
        var isTapChain: Bool
        var timestamp: TimeInterval
    }

    private var ownership: Ownership?

    /// The 只用 flick setting (default off): when on, repeated taps append instead of cycling.
    public var flickOnly: Bool

    public init(flickOnly: Bool = false) {
        self.flickOnly = flickOnly
    }

    /// Handles one press. Pass the state the front end has just observed before this press.
    @discardableResult
    public mutating func press(
        _ key: Kana12Key, direction: Kana12FlickDirection = .tap, at now: TimeInterval,
        observed: Kana12Observation?
    ) -> Kana12Effect {
        synchronize(observed)
        if key == .modifier {
            guard direction == .tap else { return .none }
            return modifierEffect(observed: observed, at: now)
        }
        guard let output = Kana12Layout.output(for: key, direction: direction) else {
            return .none
        }
        switch output {
        case .literal(let literal):
            // A literal is committed to the document, which ends the engine composition.
            ownership = nil
            return .literal(literal)
        case .kana(let kana):
            guard let romaji = Kana12RomajiTable.romaji(for: kana) else {
                ownership = nil
                return .none
            }
            let cycle = Kana12Layout.toggleCycle(for: key)
            if !flickOnly, direction == .tap, !cycle.isEmpty, let current = ownership,
                current.key == key, current.isTapChain,
                current.cycleIndex < cycle.count,
                now >= current.timestamp, now - current.timestamp < Self.toggleInterval
            {
                let nextIndex = (current.cycleIndex + 1) % cycle.count
                let nextKana = cycle[nextIndex]
                guard let nextRomaji = Kana12RomajiTable.romaji(for: nextKana) else { return .none }
                let expected = replacingLastCharacter(in: current.expectedComposition, with: nextKana)
                ownership = Ownership(
                    key: key, cycleIndex: nextIndex, lastKana: nextKana,
                    expectedComposition: expected, isTapChain: true, timestamp: now)
                return .replace(previousKana: current.lastKana, kana: nextKana, romaji: nextRomaji)
            }
            let expected = predictedComposition(appending: kana, observed: observed)
            ownership = expected.map {
                Ownership(
                    key: key, cycleIndex: cycle.firstIndex(of: kana) ?? 0, lastKana: kana,
                    expectedComposition: $0, isTapChain: direction == .tap, timestamp: now)
            }
            return .append(kana: kana, romaji: romaji)
        }
    }

    /// Reconciles with newly observed state without pressing a key: a cursor move, a selection,
    /// a commit, a clear, or input from another keyboard. Ownership only survives when the
    /// observation still matches the composition this model predicted.
    public mutating func synchronize(_ observed: Kana12Observation?) {
        guard let current = ownership else { return }
        if !matches(observed, expectedComposition: current.expectedComposition) {
            ownership = nil
        }
    }

    /// Drops all state (keyboard hidden, input mode or scheme switched, model restarted).
    public mutating func reset() {
        ownership = nil
    }

    private mutating func modifierEffect(observed: Kana12Observation?, at now: TimeInterval) -> Kana12Effect {
        guard let current = ownership,
            matches(observed, expectedComposition: current.expectedComposition)
        else {
            ownership = nil
            return .none
        }
        guard let nextKana = Kana12Layout.nextVariant(of: current.lastKana),
            let nextRomaji = Kana12RomajiTable.romaji(for: nextKana)
        else {
            // No variant: nothing changes, but pressing another key ends a tap cycle.
            ownership = Ownership(
                key: .modifier, cycleIndex: 0, lastKana: current.lastKana,
                expectedComposition: current.expectedComposition, isTapChain: false, timestamp: now)
            return .none
        }
        let expected = replacingLastCharacter(in: current.expectedComposition, with: nextKana)
        ownership = Ownership(
            key: .modifier, cycleIndex: 0, lastKana: nextKana,
            expectedComposition: expected, isTapChain: false, timestamp: now)
        return .replace(previousKana: current.lastKana, kana: nextKana, romaji: nextRomaji)
    }

    /// The composition the engine must show after appending kana, or nil when the front end has
    /// not given enough state to predict it (unknown observation, selection, caret mid-text).
    private func predictedComposition(appending kana: String, observed: Kana12Observation?) -> String? {
        guard let observed, !observed.hasSelection else { return nil }
        let composition = observed.composition ?? ""
        guard observed.caret == composition.count else { return nil }
        return composition + kana
    }

    private func replacingLastCharacter(in composition: String, with kana: String) -> String {
        String(composition.dropLast()) + kana
    }

    /// Ownership requires the exact predicted text and the caret at its end; a shorter bounded
    /// comparison could mistake a foreign composition for this model's tail.
    private func matches(_ observed: Kana12Observation?, expectedComposition: String) -> Bool {
        guard let observed, !observed.hasSelection else { return false }
        let composition = observed.composition ?? ""
        return composition == expectedComposition && observed.caret == composition.count
    }
}
