import Foundation
import OSLog
import ToolKit

/// The single gateway between tools and the keyboard's document. It reads through
/// the proxy the keyboard already owns, writes only with the operations UIKit
/// offers (insertText/deleteBackward), and declares only capabilities that are
/// implemented for that proxy. It owns one ToolSession, so preview, write-back,
/// undo and cancellation all go through one state machine.
final class ToolDocumentGateway {
    /// Only capabilities with real-proxy evidence are declared. Replacing a
    /// caret-preceding tail deletes one composed character per deleteBackward; the
    /// simulator UIKit probe (Tests/Performance/ToolDocumentDeleteGranularityTests)
    /// verified that emoji, combining sequences and ZWJ sequences each disappear in
    /// a single call on a live UITextField. Inserting while a selection is active
    /// would need to keep the selected text, which is not verified, so that
    /// capability stays off and such inserts stay blocked with their preview.
    static let capabilities: ToolDocumentCapabilities = [.replacePrecedingTail]

    private let proxy: ToolTextDocumentProxy
    private let capabilities: ToolDocumentCapabilities
    private let limits: ToolLimits
    private var session: ToolSession
    private var pendingUndo: (request: ToolUndoRequest, writtenText: String)?
    /// The caret-context captured right after a write. Undo compares it so text
    /// typed after the write (or a moved caret) refuses instead of overwriting.
    private var postWrite: (documentID: ToolDocumentID, textBeforeCaret: String)?

    init(
        proxy: ToolTextDocumentProxy, sessionID: String, limits: ToolLimits,
        capabilities: ToolDocumentCapabilities = ToolDocumentGateway.capabilities
    ) {
        self.proxy = proxy
        self.capabilities = capabilities
        self.limits = limits
        self.session = ToolSession(limits: limits, sessionID: sessionID)
    }

    var phase: ToolPhase { session.phase }
    var preview: ToolPreview? { session.preview }
    var writeBlock: ToolWriteBlock? { session.writeBlock }
    var undoWindow: Double? { limits.undoWindow }

    /// The current field as the tool model sees it, or nil when the proxy cannot
    /// name the field (an inactive or handing-off proxy).
    func snapshot() -> ToolDocumentSnapshot? {
        guard let identity = proxy.documentIdentity?.uuidString else { return nil }
        let documentID = ToolDocumentID(rawValue: identity)
        if proxy.isSecureTextEntry == true {
            // Never read a password field's text, even to decide its privacy.
            return ToolDocumentSnapshot(
                documentID: documentID, privacy: .password, selectedText: nil,
                textBeforeCaret: nil)
        }
        let before = proxy.textBeforeCaret
        let after = proxy.textAfterCaret
        let selected = proxy.selectedText
        let privacy: ToolDocumentPrivacy =
            before == nil && after == nil && selected == nil ? .noText : .normal
        let selection = selected?.isEmpty == true ? nil : selected
        return ToolDocumentSnapshot(
            documentID: documentID, privacy: privacy, selectedText: selection,
            textBeforeCaret: before)
    }

    // MARK: - Run

    func start(
        tool: some TextTool, hostCapabilities: ToolCapabilities = .text, now: Double
    ) -> ToolEffect {
        guard let document = snapshot() else { return .none }
        return session.start(
            tool: tool, hostCapabilities: hostCapabilities, document: document,
            documentCapabilities: capabilities, now: now)
    }

    func complete(_ results: [String], token: ToolRunToken, now: Double) -> Bool {
        session.complete(results, token: token, now: now)
    }

    func fail(message: String?, token: ToolRunToken, now: Double) -> Bool {
        session.fail(message: message, token: token, now: now)
    }

    /// Starts the same tool again from the current preview or failure, with a fresh
    /// document read and a new run token.
    func retry(
        tool: some TextTool, hostCapabilities: ToolCapabilities = .text, now: Double
    ) -> ToolEffect {
        guard let document = snapshot() else { return .none }
        return session.retry(
            tool: tool, hostCapabilities: hostCapabilities, document: document,
            documentCapabilities: capabilities, now: now)
    }

    func tick(now: Double) -> ToolEffect { session.tick(now: now) }
    func cancel() -> ToolEffect { session.cancel() }
    func chooseResult(_ index: Int) -> Bool { session.chooseResult(index) }
    func copy() -> String? { session.copy() }
    func dismiss() -> ToolDismissOutcome { session.dismiss() }

    // MARK: - Write-back

    func replace(now: Double) -> ToolWriteStart {
        guard let document = snapshot() else { return .blocked(.documentChanged) }
        return session.replace(current: document, now: now)
    }

    func insert(now: Double) -> ToolWriteStart {
        guard let document = snapshot() else { return .blocked(.documentChanged) }
        return session.insert(current: document, now: now)
    }

    /// The text the run wrote, as the proxy currently shows it before the caret.
    /// Used so undo can refuse to overwrite something the user typed afterwards.
    func currentWrittenText() -> String? {
        guard case .wrote(let wrote) = session.phase, let before = proxy.textBeforeCaret else {
            return nil
        }
        let expected = wrote.request.text
        guard before.count >= expected.count else { return nil }
        return String(before.suffix(expected.count))
    }

    func undo(now: Double) -> ToolUndoStart {
        guard let document = snapshot() else { return .blocked(.documentChanged) }
        guard document.privacy == .normal, document.selectedText == nil,
            case .wrote(let wrote) = session.phase
        else {
            return .blocked(.editedAfterWrite)
        }
        // Read the written span before the session leaves WROTE: the undo request
        // needs the exact text the proxy currently holds there.
        let written = currentWrittenText()
        guard written == wrote.request.text, undoAnchorStillHolds(wrote: wrote) else {
            return .blocked(.editedAfterWrite)
        }
        let start = session.undo(current: document, writtenText: written, now: now)
        if case .requested(let request) = start {
            pendingUndo = (request, written ?? "")
        }
        return start
    }

    /// Performs a requested write through the proxy and records the host's answer
    /// on the session. A field that changed since the preview fails closed.
    @discardableResult
    func apply(_ start: ToolWriteStart, at now: Double) -> Bool {
        guard case .requested(let request) = start else { return false }
        guard let plan = writePlan(for: request) else {
            session.writeFailed()
            return false
        }
        switch plan {
        case .replaceSelection, .insertAtCaret:
            proxy.insertText(request.text)
        case .replacePrecedingTail(let replaced):
            deleteCharacters(replaced)
            proxy.insertText(request.text)
        }
        guard session.writeSucceeded(at: now) else { return false }
        postWrite = (request.documentID, proxy.textBeforeCaret ?? "")
        return true
    }

    /// Performs a requested undo. The written span is deleted by its current
    /// characters, then the original text is restored when the write replaced it.
    @discardableResult
    func applyUndo(_ start: ToolUndoStart, at now: Double) -> Bool {
        guard case .requested = start, let pending = pendingUndo else { return false }
        pendingUndo = nil
        guard snapshot()?.documentID == pending.request.documentID, snapshotIsWritable(),
            capabilities.contains(.replacePrecedingTail)
        else {
            session.undoFailed()
            return false
        }
        deleteCharacters(pending.writtenText)
        if case .restoreText(let original) = pending.request.kind {
            proxy.insertText(original)
        }
        return session.undoSucceeded()
    }

    // MARK: - Proxy writes

    /// What the proxy has to do for a write that is still valid right now.
    private enum WritePlan {
        case replaceSelection
        case replacePrecedingTail(String)
        case insertAtCaret
    }

    /// Re-reads the field right before writing. A changed privacy, a different
    /// field, a selection that no longer matches what the preview would replace,
    /// or text that moved away fails closed instead of writing into the wrong place.
    private func writePlan(for request: ToolWriteRequest) -> WritePlan? {
        guard let document = snapshot(), document.privacy == .normal,
            document.documentID == request.documentID
        else { return nil }
        let selection = proxy.selectedText
        switch request.target {
        case .insertionPoint:
            // Inserting while a selection is active would replace it.
            return selection == nil ? .insertAtCaret : nil
        case .processedRange:
            guard let replaced = request.replacedText else { return nil }
            if let selection, selection == replaced {
                return .replaceSelection
            }
            guard selection == nil, let before = proxy.textBeforeCaret, before.hasSuffix(replaced),
                capabilities.contains(.replacePrecedingTail)
            else { return nil }
            return .replacePrecedingTail(replaced)
        }
    }

    /// Undo may only run while the proxied field is the same, readable one, and —
    /// for a write whose result is empty — the caret context is exactly what it
    /// was right after the write, because an empty result leaves no text to anchor
    /// the position. Typing after the write breaks that and refuses the undo.
    private func undoAnchorStillHolds(wrote: ToolWroteState) -> Bool {
        guard let postWrite, postWrite.documentID == wrote.documentID,
            let before = proxy.textBeforeCaret
        else { return false }
        // The caret context captured right after the write has to be unchanged.
        // A suffix check alone cannot tell "the same text at another position"
        // from "the same position", so the whole captured context is compared.
        return before == postWrite.textBeforeCaret
    }

    private func snapshotIsWritable() -> Bool {
        guard let document = snapshot() else { return false }
        return document.privacy == .normal && document.selectedText == nil
    }

    private func deleteCharacters(_ text: String) {
        for _ in text {
            proxy.deleteBackward()
        }
    }
}

// MARK: - Tool panel driver

/// Where the keyboard gets its tools from. Built-in tools, user scripts and
/// installed extensions all arrive here as ToolKit's TextTool, so the panel and
/// the write path never branch on what an addon is made of. The keyboard starts
/// with no configuration: no tool entry, no panel, no crash.
protocol ToolToolProviding {
    var tools: [any TextTool] { get }
}

struct EmptyToolProvider: ToolToolProviding {
    var tools: [any TextTool] { [] }
}

/// The tool runtime the host injects: the tool list and the one set of limits.
/// nil until a script runtime (or a test) supplies them; no limit is guessed here.
struct ToolConfiguration {
    let provider: any ToolToolProviding
    let limits: ToolLimits
}

/// One adapter from panel intents to ToolKit's ToolSession and the document
/// gateway. It keeps no phase of its own; it only runs the async tool and
/// republishes the session's state to the model. Kept UIKit-free so a probe can
/// run it against the production gateway.
@MainActor
final class ToolPanelDriver: ToolPanelDriving {
    private let configuration: ToolConfiguration
    private let gateway: @MainActor () -> ToolDocumentGateway?
    private let clock: () -> Double
    private var task: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var runningTool: (any TextTool)?
    private(set) var lastToolTitle: String?

    /// Called after a run, write or undo moves the one session forward so the
    /// model can republish the panel.
    var onChange: (() -> Void)?

    init(
        configuration: ToolConfiguration,
        gateway: @escaping @MainActor () -> ToolDocumentGateway?,
        clock: @escaping () -> Double = { Date.timeIntervalSinceReferenceDate }
    ) {
        self.configuration = configuration
        self.gateway = gateway
        self.clock = clock
    }

    var entries: [ToolPanelEntry] {
        configuration.provider.tools.map { tool in
            let missing = tool.requiredCapabilities.subtracting(.text)
            return ToolPanelEntry(
                identity: tool.identity,
                availability: missing.isEmpty ? .ready : .missingCapabilities(missing))
        }
    }

    var phase: ToolPhase { gateway()?.phase ?? .idle }
    var preview: ToolPreview? { gateway()?.preview }
    var writeBlock: ToolWriteBlock? { gateway()?.writeBlock }
    var undoWindow: Double? { configuration.limits.undoWindow }

    func run(_ identity: ToolIdentity) {
        guard let tool = configuration.provider.tools.first(where: { $0.identity == identity }),
            let gateway = gateway()
        else { return }
        lastToolTitle = identity.title
        begin(gateway.start(tool: tool, hostCapabilities: .text, now: clock()), tool: tool)
        notify()
    }

    func retry() {
        guard let tool = runningTool ?? configuration.provider.tools.first,
            let gateway = gateway()
        else { return }
        begin(gateway.retry(tool: tool, hostCapabilities: .text, now: clock()), tool: tool)
        notify()
    }

    func chooseResult(_ index: Int) {
        _ = gateway()?.chooseResult(index)
        notify()
    }

    func cancel() {
        task?.cancel()
        timeoutTask?.cancel()
        _ = gateway()?.cancel()
        notify()
    }

    func copy() -> String? {
        let text = gateway()?.copy()
        notify()
        return text
    }

    func replace() {
        guard let gateway = gateway() else { return }
        let start = gateway.replace(now: clock())
        _ = gateway.apply(start, at: clock())
        notify()
    }

    func insert() {
        guard let gateway = gateway() else { return }
        let start = gateway.insert(now: clock())
        _ = gateway.apply(start, at: clock())
        notify()
    }

    func undo() {
        guard let gateway = gateway() else { return }
        let start = gateway.undo(now: clock())
        _ = gateway.applyUndo(start, at: clock())
        notify()
    }

    func dismiss() -> ToolDismissOutcome {
        task?.cancel()
        timeoutTask?.cancel()
        runningTool = nil
        lastToolTitle = nil
        let outcome = gateway()?.dismiss() ?? .unavailable
        notify()
        return outcome
    }

    // MARK: - Run plumbing

    private func begin(_ effect: ToolEffect, tool: any TextTool) {
        guard case .run(let request) = effect else { return }
        runningTool = tool
        lastToolTitle = request.identity.title
        task?.cancel()
        timeoutTask?.cancel()
        task = Task { [weak self] in
            do {
                let results = try await tool.run(input: request.input)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // A result arriving after the deadline is rejected by the
                    // session's own clock check; the driver just reports it.
                    _ = self.gateway()?.complete(
                        results, token: request.runToken, now: self.clock())
                    self.notify()
                }
            } catch is CancellationError {
                // A cancel or timeout already moved the session.
            } catch {
                // Only the script runtime's own mapped copy may reach the panel; any other error
                // is logged and the panel falls back to its generic sentence.
                Logger.scriptAddon.error("script run failed: \(String(describing: error), privacy: .private)")
                let message = (error as? ScriptToolError)?.errorDescription
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    _ = self.gateway()?.fail(
                        message: message, token: request.runToken,
                        now: self.clock())
                    self.notify()
                }
            }
        }
        let timeout = tool.runTimeout ?? configuration.limits.runTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // The timeout effect asks the host to cancel the run; cancelling the
                // driver's task is what actually stops the tool.
                if case .cancelRun = self.gateway()?.tick(now: self.clock()) {
                    self.task?.cancel()
                }
                self.notify()
            }
        }
    }

    private func notify() {
        onChange?()
    }
}
