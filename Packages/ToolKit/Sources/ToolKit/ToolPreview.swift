/// Identity of one run, opaque and supplied by the host's generator (a UUID, for
/// example). Results and errors are accepted only for the current token, so a late
/// answer from a cancelled, retried or previous-session run can never reach the
/// preview: a fresh session gets fresh tokens from its own generator.
public struct ToolRunToken: Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One run's request, fixed when the run starts: which tool, which text, which run.
public struct ToolRunRequest: Equatable, Sendable {
    public let identity: ToolIdentity
    public let runToken: ToolRunToken
    public let input: ToolInput

    public init(identity: ToolIdentity, runToken: ToolRunToken, input: ToolInput) {
        self.identity = identity
        self.runToken = runToken
        self.input = input
    }
}

/// The preview every write goes through. Several results are chosen between
/// before any write action is offered.
public struct ToolPreview: Equatable, Sendable {
    public let identity: ToolIdentity
    public let runToken: ToolRunToken
    public let input: ToolInput
    public let results: [String]
    public let selectedIndex: Int

    public init(
        identity: ToolIdentity, runToken: ToolRunToken, input: ToolInput, results: [String],
        selectedIndex: Int
    ) {
        self.identity = identity
        self.runToken = runToken
        self.input = input
        self.results = results
        self.selectedIndex = selectedIndex
    }

    public var selectedText: String { results[selectedIndex] }
}

/// Where a confirmed result goes.
public enum ToolWriteTarget: Equatable, Sendable {
    /// Replace the end of the source range (the selection end, or the text before
    /// the caret) by replacedUnitCount UTF-16 code units plus the result text.
    case processedRange
    /// Insert at the caret without replacing anything.
    case insertionPoint
}

/// What the document gateway has to write.
public struct ToolWriteRequest: Equatable, Sendable {
    public let documentID: ToolDocumentID
    public let target: ToolWriteTarget
    public let text: String
    /// The text being replaced; nil for an insertion.
    public let replacedText: String?
    /// UTF-16 code units of the source range the result replaces.
    public let replacedUnitCount: Int

    /// True when the replaced range is only part of the selection or of the text
    /// before the caret, which the gateway can only do if it declares
    /// replacement of arbitrary ranges.
    public let requiresSubrange: Bool

    public init(
        documentID: ToolDocumentID, target: ToolWriteTarget, text: String,
        replacedText: String?, replacedUnitCount: Int, requiresSubrange: Bool
    ) {
        self.documentID = documentID
        self.target = target
        self.text = text
        self.replacedText = replacedText
        self.replacedUnitCount = replacedUnitCount
        self.requiresSubrange = requiresSubrange
    }

    /// UTF-16 code units this write inserts.
    public var insertedUnitCount: Int { ToolTextUnits.count(text) }
}

/// What the document gateway has to do to undo the write it performed.
public struct ToolUndoRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Put the replaced text back over the written result.
        case restoreText(String)
        /// Delete the inserted result.
        case removeInserted
    }

    public let documentID: ToolDocumentID
    public let kind: Kind
    /// UTF-16 code units the undo replaces or removes.
    public let unitCount: Int

    public init(documentID: ToolDocumentID, kind: Kind, unitCount: Int) {
        self.documentID = documentID
        self.kind = kind
        self.unitCount = unitCount
    }
}

/// Why a write or undo was refused. The preview (or the undo state) is kept, so
/// the user can act again instead of losing the run.
public enum ToolWriteBlock: Equatable, Sendable {
    case documentChanged
    case secureEntry
    /// The focused field withholds its text (a no-text field), which is not the
    /// same user-facing reason as a password field.
    case noText
    /// The write needs the gateway's replacePrecedingTail capability: it covers
    /// only part of the caret-preceding text.
    case unsupportedPartialReplacement
    /// The write would insert while a selection is active, and the gateway has not
    /// declared that it can keep the selected text.
    case unsupportedInsertion
    /// The text the run wrote is no longer where it was, so undoing would overwrite
    /// what the user typed after the write.
    case editedAfterWrite
}

/// Result of asking to write. The host performs the write and then reports back
/// through writeSucceeded/writeFailed; only success advances the state.
public enum ToolWriteStart: Equatable, Sendable {
    case requested(ToolWriteRequest)
    case blocked(ToolWriteBlock)
    case notReady
}

/// Result of asking to undo. Success comes back through undoSucceeded.
public enum ToolUndoStart: Equatable, Sendable {
    case requested(ToolUndoRequest)
    case blocked(ToolWriteBlock)
    case expired
    case notReady
}

/// What closing the tool's UI did. The host must stop the engine task only for
/// a cancelled run; an in-flight write or undo is left to report back.
public enum ToolDismissOutcome: Equatable, Sendable {
    case dismissed
    case cancelled(ToolRunToken)
    case unavailable
}

/// Work the keyboard performs for the model; the model performs no I/O itself.
public enum ToolEffect: Equatable, Sendable {
    case none
    case run(ToolRunRequest)
    /// Cancel the engine task of this run; a cancelled or timed-out run always
    /// emits it so the host stops the work it started.
    case cancelRun(ToolRunToken)
    case copy(String)
}

/// What happened to the source range the run read. A read that failed is its own
/// case, so the UI never reports an unknown source as an unchanged one.
public enum ToolSourceChange: Equatable, Sendable {
    case unchanged
    case changed
    case unreadable
}

/// The state after the host confirmed a write: what was written, whether the
/// source had changed, and how the write can be taken back.
public struct ToolWroteState: Equatable, Sendable {
    public let request: ToolWriteRequest
    public let source: ToolSourceChange
    public let undoRequest: ToolUndoRequest
    public let writtenAt: Double
    public let documentID: ToolDocumentID

    public init(
        request: ToolWriteRequest, source: ToolSourceChange, undoRequest: ToolUndoRequest,
        writtenAt: Double, documentID: ToolDocumentID
    ) {
        self.request = request
        self.source = source
        self.undoRequest = undoRequest
        self.writtenAt = writtenAt
        self.documentID = documentID
    }

    /// True only when the source was read and differs; an unreadable source is not
    /// reported as unchanged.
    public var sourceChanged: Bool { source == .changed }
}
