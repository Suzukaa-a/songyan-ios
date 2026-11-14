/// Why a tool could not run here. The UI maps each case to its own wording.
public enum ToolUnavailableReason: Equatable, Sendable {
    case secureEntry
    case noText
    case missingCapabilities(ToolCapabilities)
}

public enum ToolFailure: Equatable, Sendable {
    case unavailable(ToolUnavailableReason)
    case cancelled
    case timedOut
    case noResult
    /// The tool's own error text; the UI shows it after the tool title.
    case toolError(message: String?)
}

public enum ToolPhase: Equatable, Sendable {
    case idle
    case running
    case previewing(ToolPreview)
    case writing(ToolWriteRequest)
    case undoing(ToolUndoRequest)
    case wrote(ToolWroteState)
    case failed(ToolFailure)
}

/// One run of one tool. The keyboard drives it with explicit snapshots and
/// timestamps and performs the effects it returns, so this type owns no I/O, no
/// clock and no UI. Writes and undos are two-phase: the session asks the host to
/// write and only records success after the host confirms it.
public struct ToolSession: Sendable {
    public let limits: ToolLimits
    public private(set) var phase: ToolPhase = .idle

    /// Why the last write or undo was refused, if it was.
    public private(set) var writeBlock: ToolWriteBlock?

    private enum RegionState {
        case unchanged
        case changed
        case unreadable
    }

    private let sessionID: String
    private var nextSequence = 1
    private var activeToken: ToolRunToken?
    private var activeRequest: ToolRunRequest?
    private var activeDocument: ToolDocumentSnapshot?
    private var activeDocumentCapabilities: ToolDocumentCapabilities = []
    private var startedAt: Double?
    private var activeTimeout: Double?
    private var lastPreview: ToolPreview?
    private var pendingSource: ToolSourceChange = .unchanged
    private var wroteState: ToolWroteState?

    /// The host supplies one opaque session ID per keyboard session (a UUID
    /// string, for example); run tokens are that ID plus a session-owned sequence,
    /// so two sessions can never share a token.
    public init(limits: ToolLimits, sessionID: String) {
        self.limits = limits
        self.sessionID = sessionID
    }

    private mutating func nextRunToken() -> ToolRunToken {
        let token = ToolRunToken(rawValue: "\(sessionID)#\(nextSequence)")
        nextSequence += 1
        return token
    }

    /// The preview to show while the run is previewing, or after a refused write.
    public var preview: ToolPreview? {
        switch phase {
        case .previewing(let preview): return preview
        case .writing: return lastPreview
        default: return nil
        }
    }

    // MARK: - Run

    /// Starts a run. A capability the host does not provide, a secure or no-text
    /// field, or missing text fails before any work starts.
    public mutating func start(
        tool: some TextTool, hostCapabilities: ToolCapabilities, document: ToolDocumentSnapshot,
        documentCapabilities: ToolDocumentCapabilities = [], now: Double
    ) -> ToolEffect {
        guard phase == .idle else { return .none }
        return begin(
            tool: tool, hostCapabilities: hostCapabilities, document: document,
            documentCapabilities: documentCapabilities,
            token: nextRunToken(), now: now)
    }

    private mutating func begin(
        tool: some TextTool, hostCapabilities: ToolCapabilities, document: ToolDocumentSnapshot,
        documentCapabilities: ToolDocumentCapabilities, token: ToolRunToken, now: Double
    ) -> ToolEffect {
        let missing = tool.requiredCapabilities.subtracting(hostCapabilities)
        guard missing.isEmpty else {
            fail(.unavailable(.missingCapabilities(missing)))
            return .none
        }
        switch ToolInputSelection.select(from: document, limits: limits) {
        case .failure(.secureEntry):
            fail(.unavailable(.secureEntry))
            return .none
        case .failure(.noText):
            fail(.unavailable(.noText))
            return .none
        case .success(let input):
            let request = ToolRunRequest(identity: tool.identity, runToken: token, input: input)
            activeToken = token
            activeRequest = request
            activeDocument = document
            activeDocumentCapabilities = documentCapabilities
            startedAt = now
            activeTimeout = tool.runTimeout
            lastPreview = nil
            wroteState = nil
            writeBlock = nil
            phase = .running
            return .run(request)
        }
    }

    /// Hands the run's results to the session. A stale token returns false and has
    /// no effect, and a delivery that arrives after the injected deadline becomes
    /// a timeout instead of a preview, even if nobody called tick first.
    @discardableResult
    public mutating func complete(_ results: [String], token: ToolRunToken, now: Double) -> Bool {
        guard case .running = phase, token == activeToken, let request = activeRequest else {
            return false
        }
        if isPastDeadline(now) {
            fail(.timedOut)
            return false
        }
        // An empty string is a legal result (it clears the processed range); only
        // an empty list means the tool produced nothing to preview.
        let cleaned = Array(results.prefix(limits.maximumResults))
        guard !cleaned.isEmpty else {
            fail(.noResult)
            return true
        }
        let preview = ToolPreview(
            identity: request.identity, runToken: token, input: request.input, results: cleaned,
            selectedIndex: 0)
        lastPreview = preview
        startedAt = nil
        phase = .previewing(preview)
        return true
    }

    /// Records the tool's own failure for this run. A late delivery is a timeout,
    /// not the tool's own error.
    @discardableResult
    public mutating func fail(message: String?, token: ToolRunToken, now: Double) -> Bool {
        guard case .running = phase, token == activeToken else { return false }
        if isPastDeadline(now) {
            fail(.timedOut)
            return false
        }
        fail(.toolError(message: message))
        return true
    }

    /// Advances the injected clock; a run that exceeds its budget times out and
    /// asks the host to cancel the engine task.
    public mutating func tick(now: Double) -> ToolEffect {
        guard case .running = phase, let token = activeToken else { return .none }
        guard isPastDeadline(now) else { return .none }
        fail(.timedOut)
        return .cancelRun(token)
    }

    /// The budget of the run in progress: the tool's own when it declares one.
    public var runTimeout: Double { activeTimeout ?? limits.runTimeout }

    /// Whether the injected time is past this run's budget. Delivery and tick use
    /// the same rule, so a result can never slip in just because tick was skipped.
    private func isPastDeadline(_ now: Double) -> Bool {
        guard case .running = phase, let startedAt else { return false }
        return now - startedAt >= runTimeout
    }

    /// Stops a running run and asks the host to cancel its engine task. Closing a
    /// preview is dismiss(), not a cancellation.
    public mutating func cancel() -> ToolEffect {
        guard case .running = phase, let token = activeToken else { return .none }
        fail(.cancelled)
        return .cancelRun(token)
    }

    /// Starts the same tool again with a fresh document read and a new token.
    public mutating func retry(
        tool: some TextTool, hostCapabilities: ToolCapabilities, document: ToolDocumentSnapshot,
        documentCapabilities: ToolDocumentCapabilities = [], now: Double
    ) -> ToolEffect {
        switch phase {
        case .previewing, .failed:
            resetRun()
            let token = nextRunToken()
            return begin(
                tool: tool, hostCapabilities: hostCapabilities, document: document,
                documentCapabilities: documentCapabilities, token: token, now: now)
        case .idle, .running, .writing, .undoing, .wrote:
            return .none
        }
    }

    // MARK: - Preview actions

    /// Picks one of several results; the write actions use the picked one.
    @discardableResult
    public mutating func chooseResult(_ index: Int) -> Bool {
        guard case .previewing(let preview) = phase, preview.results.indices.contains(index) else {
            return false
        }
        let updated = ToolPreview(
            identity: preview.identity, runToken: preview.runToken, input: preview.input,
            results: preview.results, selectedIndex: index)
        lastPreview = updated
        phase = .previewing(updated)
        return true
    }

    /// Confirms "replace". The current document must be the one the run read and
    /// not a password field. A changed or unreadable source turns the write into
    /// an insertion, which keeps the original text and therefore needs only the
    /// gateway's insert capability. A truncated input that is still unchanged
    /// replaces part of its range, so only that path needs the range capability.
    public mutating func replace(current: ToolDocumentSnapshot, now: Double) -> ToolWriteStart {
        guard case .previewing(let preview) = phase else { return .notReady }
        if let block = writeBlock(current: current, expected: activeDocument?.documentID) {
            writeBlock = block
            return .blocked(block)
        }
        guard let documentID = activeDocument?.documentID else { return .notReady }
        // Temporary fail-closed rule: no gateway has been verified to replace only
        // the processed tail of a selection (UIKit's insertText replaces the whole
        // selection). This is separate from replacePrecedingTail: keep refusing
        // instead of claiming the truncated-selection case is implemented; reopen
        // once a gateway can do it and is verified.
        if preview.input.isTruncated, preview.input.scope == .selection {
            writeBlock = .unsupportedPartialReplacement
            return .blocked(.unsupportedPartialReplacement)
        }
        let state = regionState(current: current, input: preview.input)
        if state == .unchanged {
            if preview.input.isTruncated,
                !activeDocumentCapabilities.contains(.replacePrecedingTail)
            {
                writeBlock = .unsupportedPartialReplacement
                return .blocked(.unsupportedPartialReplacement)
            }
            writeBlock = nil
            let request = ToolWriteRequest(
                documentID: documentID, target: .processedRange, text: preview.selectedText,
                replacedText: preview.input.text, replacedUnitCount: preview.input.unitCount,
                requiresSubrange: preview.input.isTruncated)
            pendingSource = .unchanged
            phase = .writing(request)
            return .requested(request)
        }
        if preview.input.scope == .selection,
            !activeDocumentCapabilities.contains(.insertPreservingSelection)
        {
            writeBlock = .unsupportedInsertion
            return .blocked(.unsupportedInsertion)
        }
        writeBlock = nil
        let request = ToolWriteRequest(
            documentID: documentID, target: .insertionPoint, text: preview.selectedText,
            replacedText: nil, replacedUnitCount: 0, requiresSubrange: false)
        pendingSource = state == .changed ? .changed : .unreadable
        phase = .writing(request)
        return .requested(request)
    }

    /// Confirms "insert": the result goes to the caret and leaves the text alone.
    /// Inserting while a selection is active would replace it, so that case needs
    /// the gateway's replaceRange capability; a caret-preceding source never does,
    /// even when it was truncated.
    public mutating func insert(current: ToolDocumentSnapshot, now: Double) -> ToolWriteStart {
        guard case .previewing(let preview) = phase else { return .notReady }
        if let block = writeBlock(current: current, expected: activeDocument?.documentID) {
            writeBlock = block
            return .blocked(block)
        }
        if preview.input.scope == .selection,
            !activeDocumentCapabilities.contains(.insertPreservingSelection)
        {
            writeBlock = .unsupportedInsertion
            return .blocked(.unsupportedInsertion)
        }
        guard let documentID = activeDocument?.documentID else { return .notReady }
        writeBlock = nil
        let request = ToolWriteRequest(
            documentID: documentID, target: .insertionPoint, text: preview.selectedText,
            replacedText: nil, replacedUnitCount: 0, requiresSubrange: false)
        pendingSource = .unchanged
        phase = .writing(request)
        return .requested(request)
    }

    /// Confirms "copy": nothing is written and there is nothing to undo.
    @discardableResult
    public mutating func copy() -> String? {
        guard case .previewing(let preview) = phase else { return nil }
        let text = preview.selectedText
        resetRun()
        return text
    }

    // MARK: - Host confirmation

    /// The host wrote the result; only now does the session offer undo.
    @discardableResult
    public mutating func writeSucceeded(at now: Double) -> Bool {
        guard case .writing(let write) = phase, let documentID = activeDocument?.documentID else {
            return false
        }
        let undo: ToolUndoRequest
        if write.target == .processedRange {
            undo = ToolUndoRequest(
                documentID: documentID, kind: .restoreText(write.replacedText ?? ""),
                unitCount: write.insertedUnitCount)
        } else {
            undo = ToolUndoRequest(
                documentID: documentID, kind: .removeInserted, unitCount: write.insertedUnitCount)
        }
        let wrote = ToolWroteState(
            request: write, source: pendingSource, undoRequest: undo, writtenAt: now,
            documentID: documentID)
        wroteState = wrote
        lastPreview = nil
        phase = .wrote(wrote)
        return true
    }

    /// The host could not write; the preview comes back so the user can try again.
    @discardableResult
    public mutating func writeFailed() -> Bool {
        guard case .writing = phase, let preview = lastPreview else { return false }
        phase = .previewing(preview)
        return true
    }

    // MARK: - Undo

    /// Whether the written result can still be undone at the injected time.
    public func canUndo(at now: Double) -> Bool {
        guard case .wrote(let wrote) = phase else { return false }
        guard let window = limits.undoWindow else { return true }
        return now - wrote.writtenAt <= window
    }

    /// Asks the host to take the write back. The same document and a non-password
    /// field are required, and a sub-range write needs the range capability. The
    /// host reads the written span and passes its current text here, so an edit made
    /// after the write is refused instead of being overwritten.
    public mutating func undo(
        current: ToolDocumentSnapshot, writtenText: String?, now: Double
    ) -> ToolUndoStart {
        guard case .wrote(let wrote) = phase else { return .notReady }
        if let block = writeBlock(current: current, expected: wrote.documentID) {
            writeBlock = block
            return .blocked(block)
        }
        if wrote.request.requiresSubrange,
            !activeDocumentCapabilities.contains(.replacePrecedingTail)
        {
            writeBlock = .unsupportedPartialReplacement
            return .blocked(.unsupportedPartialReplacement)
        }
        guard canUndo(at: now) else { return .expired }
        guard writtenText == wrote.request.text else {
            writeBlock = .editedAfterWrite
            return .blocked(.editedAfterWrite)
        }
        writeBlock = nil
        phase = .undoing(wrote.undoRequest)
        return .requested(wrote.undoRequest)
    }

    /// The host undid the write.
    @discardableResult
    public mutating func undoSucceeded() -> Bool {
        guard case .undoing = phase else { return false }
        resetRun()
        return true
    }

    /// The host could not undo; the write stays undoable so the user can act again.
    @discardableResult
    public mutating func undoFailed() -> Bool {
        guard case .undoing = phase, let wrote = wroteState else { return false }
        phase = .wrote(wrote)
        return true
    }

    /// Leaves the current state. Closing while a run is still going cancels it and
    /// reports the cancel request, so the host stops the engine task; a write or
    /// undo already handed to the host is left to finish and report back.
    @discardableResult
    public mutating func dismiss() -> ToolDismissOutcome {
        switch phase {
        case .running:
            guard let token = activeToken else { return .dismissed }
            resetRun()
            return .cancelled(token)
        case .previewing, .wrote, .failed:
            resetRun()
            return .dismissed
        case .idle, .writing, .undoing:
            return .unavailable
        }
    }

    // MARK: - Internal

    private func writeBlock(
        current: ToolDocumentSnapshot, expected: ToolDocumentID?
    ) -> ToolWriteBlock? {
        if current.privacy == .password { return .secureEntry }
        if current.privacy == .noText { return .noText }
        guard let expected, current.documentID == expected else { return .documentChanged }
        return nil
    }

    /// A selection is compared as a whole: the same tail under a different prefix
    /// is a different selection and must not count as unchanged. The
    /// caret-preceding case compares the processed tail, because a replace writes
    /// exactly that tail.
    private func regionState(current: ToolDocumentSnapshot, input: ToolInput) -> RegionState {
        switch input.scope {
        case .selection:
            guard let currentSelection = current.selectedText,
                let original = activeDocument?.selectedText
            else { return .unreadable }
            return currentSelection == original ? .unchanged : .changed
        case .precedingSegment:
            guard let before = current.textBeforeCaret,
                let original = activeDocument?.textBeforeCaret
            else { return .unreadable }
            return before == original ? .unchanged : .changed
        }
    }

    private mutating func fail(_ failure: ToolFailure) {
        phase = .failed(failure)
        startedAt = nil
    }

    private mutating func resetRun() {
        phase = .idle
        activeToken = nil
        activeRequest = nil
        activeDocument = nil
        activeDocumentCapabilities = []
        startedAt = nil
        lastPreview = nil
        pendingSource = .unchanged
        wroteState = nil
        writeBlock = nil
    }
}
