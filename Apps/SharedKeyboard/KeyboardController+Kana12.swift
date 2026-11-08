import Foundation
import KeyboardCore
import QuartzCore

// MARK: - Kana12 input binding
//
// The kana12 surface reports one gesture per press and owns no engine state. Each gesture is
// resolved here on the main thread from the last snapshot the engine actually landed, and its
// engine code keys are queued through InputSession's existing asynchronous pending-code batch:
// a press never waits on the engine queue, and its raw romaji/BackSpace codes are never shown
// as the composition (the engine turns them into kana itself).
//
// A gesture that arrives while an earlier gesture's batch is still decoding waits in a FIFO
// queue and is resolved only once that batch has landed, so the model always sees the
// composition its previous effect predicted. Composition ownership is dropped on anything this
// front end did not produce: a foreign key, a commit, a cursor move, a document change, or a
// scheme/mode switch.

/// Controller-owned kana12 binding state. Kept as one value so the class stores one property.
struct Kana12BindingState {
    /// The pure model: key plus flick direction to append/replace/literal effects.
    var model = Kana12InputModel()
    /// Presses waiting for the gesture before them to land, in press order.
    var queued: [Kana12QueuedIntent] = []
    /// Guards `pumpKana12Intents` against re-entering itself through its own callbacks.
    var pumping = false
    /// The model has emitted an effect; its ownership may still be live.
    var engaged = false
    /// The engine snapshot scheme the state was last reconciled with.
    var schemaID = ""
    /// The host document the queued presses belong to.
    var documentGeneration: UInt64 = 0
}

/// One press the kana12 surface reported, kept until every gesture before it has landed.
struct Kana12QueuedIntent {
    let action: Kana12ViewAction
    /// The press time, so a queued press keeps the user's own tap timing (the J2.3 cycle window).
    let timestamp: TimeInterval
    /// The host document the press belongs to; a press for a previous document never types.
    let documentGeneration: UInt64
    /// The engine the press was computed for.
    let engine: ObjectIdentifier
}

extension KeyboardController {
    // MARK: Surface entry point

    /// Handles one press from the kana12 surface. Engine work never runs on this call: the
    /// press's code keys go through the existing asynchronous batch, and a press that arrives
    /// while an earlier batch is decoding is queued and resolved in press order.
    func handleKana12(_ action: Kana12ViewAction) {
        guard !retired else { return }
        synchronizeKana12Document()
        kana12.queued.append(
            Kana12QueuedIntent(
                action: action, timestamp: CACurrentMediaTime(),
                documentGeneration: englishDocumentGeneration,
                engine: ObjectIdentifier(session.engine)))
        pumpKana12Intents()
    }

    /// The 只用 flick setting (default off: repeated taps walk the J2.3 cycle instead).
    var kana12FlickOnly: Bool {
        get { kana12.model.flickOnly }
        set { kana12.model.flickOnly = newValue }
    }

    // MARK: Reconciliation with the landed engine state

    /// Reconciles the model with a snapshot the engine just landed. Ownership only survives
    /// when this front end produced exactly that composition; a commit, a selection, another
    /// keyboard's key, a scheme/mode switch or a document change drops it.
    func observeKana12AfterRefresh() {
        guard !retired else { return }
        if kana12.schemaID != snapshot.schemaID {
            kana12.schemaID = snapshot.schemaID
            resetKana12State()
        }
        guard !isEnglishMode else {
            if kana12.engaged || !kana12.queued.isEmpty { resetKana12State() }
            return
        }
        guard kana12.engaged else { return }
        kana12.model.synchronize(kana12Observation())
    }

    /// Presses queued for a previous host document never type into the current one; a batch
    /// already decoding is taken back before it can commit into the new document.
    private func synchronizeKana12Document() {
        guard kana12.documentGeneration != englishDocumentGeneration else { return }
        session.cancelPendingCodes()
        kana12.queued.removeAll()
        kana12.model.reset()
        kana12.engaged = false
        kana12.documentGeneration = englishDocumentGeneration
    }

    /// A key from another surface (or a control key) ends kana12's claim on the composition
    /// tail; queued presses may still land afterwards.
    func invalidateKana12Ownership() {
        kana12.model.reset()
        kana12.engaged = false
    }

    /// Drops ownership and every queued press: the keyboard is gone, the field changed, or
    /// the input mode/scheme switched under it.
    func resetKana12State() {
        kana12.model.reset()
        kana12.queued.removeAll()
        kana12.engaged = false
        kana12.schemaID = snapshot.schemaID
        kana12.documentGeneration = englishDocumentGeneration
    }

    // MARK: Press pump

    /// Resolves queued presses in order while no earlier code-key batch is still pending.
    /// Called after a press, and again by `onPendingCodesChanged` once a batch lands.
    func pumpKana12Intents() {
        guard !retired, !kana12.pumping else { return }
        kana12.pumping = true
        defer { kana12.pumping = false }
        let engine = ObjectIdentifier(session.engine)
        let generation = englishDocumentGeneration
        // A press from another document or engine generation must never type into this one.
        kana12.queued.removeAll { $0.engine != engine || $0.documentGeneration != generation }
        while !kana12.queued.isEmpty, session.pendingCodes.isEmpty {
            performKana12(kana12.queued.removeFirst())
        }
    }

    private func performKana12(_ intent: Kana12QueuedIntent) {
        switch intent.action {
        case .kana(let rowID, let direction):
            guard let key = Kana12Key(rawValue: rowID) else {
                invalidateKana12Ownership()
                return
            }
            applyKana12(
                kana12.model.press(
                    key, direction: direction.kana12FlickDirection, at: intent.timestamp,
                    observed: kana12Observation()))
        case .modify:
            applyKana12(
                kana12.model.press(.modifier, at: intent.timestamp, observed: kana12Observation()))
        case .cursorLeft:
            // During composition the caret belongs to the engine: move its composition caret
            // through the same batch, never confirm the composition. The model's claim on the
            // tail is gone because a replacement may no longer assume the caret is at the end.
            invalidateKana12Ownership()
            if snapshot.isComposing {
                session.enqueueCodeKeys([EngineCodeKeyToken.cursorLeft])
            } else {
                moveCursor(by: -1)
            }
        case .backspace:
            invalidateKana12Ownership()
            handle(.backspace)
        case .space:
            invalidateKana12Ownership()
            handle(.space)
        case .enter:
            invalidateKana12Ownership()
            handle(.enter)
        case .symbols, .numbers, .language:
            invalidateKana12Ownership()
            onKana12Navigation?(intent.action)
        }
    }

    private func applyKana12(_ effect: Kana12Effect) {
        switch effect {
        case .append(_, let romaji):
            enqueueKana12(romaji: romaji, backspaces: 0)
        case .replace(_, _, let romaji):
            // Exactly one BackSpace, then the romaji the engine converts to the new kana: one
            // BackSpace deletes one kana because the engine already holds kana in the input.
            enqueueKana12(romaji: romaji, backspaces: effect.backspaces)
        case .literal(let text):
            // Punctuation and brackets are text, never Rime key tokens.
            invalidateKana12Ownership()
            insertLiteral(text)
        case .none:
            break
        }
    }

    private func enqueueKana12(romaji: String, backspaces: Int) {
        var keys = Array(
            repeating: EngineCodeKeyToken.backspace, count: max(0, backspaces))
        keys.append(contentsOf: romaji.map(String.init))
        guard !keys.isEmpty else { return }
        kana12.engaged = true
        session.enqueueCodeKeys(keys)
    }

    // MARK: Observation

    /// The state the model may reason about. The composition is the engine's raw input, which
    /// the kana speller already rewrote to kana; its preedit may be katakana by user option.
    /// `preeditSelStart`/`preeditSelEnd` are Rime's candidate segment, not an editor
    /// selection, so a kana composition never reports a selection here.
    private func kana12Observation() -> Kana12Observation? {
        let state = snapshot
        guard state.isComposing else { return Kana12Observation() }
        let composition = state.rawInput
        guard !composition.isEmpty else { return nil }
        // Only a 1:1 preedit (kana displayed as hiragana or katakana) gives the caret a
        // trustworthy character offset in the composition. Anything else fails closed to a
        // caret the model can never treat as "at the end".
        let caret =
            state.preedit.count == composition.count
            ? min(
                Self.kana12Characters(preedit: state.preedit, beforeByte: state.preeditCaretByte),
                composition.count)
            : 0
        return Kana12Observation(composition: composition, caret: caret, hasSelection: false)
    }

    /// Characters in `preedit` before a UTF-8 byte offset. A mid-scalar offset (after a failed
    /// edit) rounds down to the last whole character instead of inventing one.
    static func kana12Characters(preedit: String, beforeByte byteOffset: Int) -> Int {
        let bytes = Array(preedit.utf8)
        var offset = min(max(0, byteOffset), bytes.count)
        while offset > 0, String(bytes: bytes[..<offset], encoding: .utf8) == nil { offset -= 1 }
        return String(bytes: bytes[..<offset], encoding: .utf8)?.count ?? 0
    }

    /// Whether this snapshot's composition code is kana. The kana speller rewrites the input
    /// to kana before composing, so a live kana composition is recognized from its raw input;
    /// queued code keys must not be echoed as composition text for it.
    static func kana12IsKanaComposition(_ state: EngineSnapshot) -> Bool {
        state.rawInput.unicodeScalars.contains { scalar in
            (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
        }
    }
}

extension Kana12Direction {
    /// The model's flick direction; the surface's `.center` is the model's `.tap`.
    var kana12FlickDirection: Kana12FlickDirection {
        switch self {
        case .center: return .tap
        case .left: return .left
        case .up: return .up
        case .right: return .right
        case .down: return .down
        }
    }
}
