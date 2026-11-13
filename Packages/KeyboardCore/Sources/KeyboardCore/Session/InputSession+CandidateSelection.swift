import Foundation

/// The engine state whose candidates were drawn when a selection action was created.
/// Revisions may change while a finger is down; the generation changes when that
/// touch no longer belongs to the same composition.
struct CandidateSelectionContext: Equatable, Sendable {
    let generation: Int
    let revision: Int
    let schemaID: String
    let layout: KeyboardLayoutKind
    let mode: InputMode
    let pageIndex: Int
    let pageSize: Int
}

/// A candidate bound to a physical press, after all preceding code keys have landed.
/// Preparing it does not select anything; a drag may discard it without an engine action.
public struct PreparedCandidateSelection: Sendable {
    let index: Int
    let page: Int
    let text: String
    let context: CandidateSelectionContext
}

extension InputSession {
    var candidateSelectionContext: CandidateSelectionContext {
        CandidateSelectionContext(
            generation: candidateSelectionGeneration, revision: compositionRevision,
            schemaID: selectedSchemaID, layout: layout, mode: mode,
            pageIndex: snapshot.pageIndex, pageSize: snapshot.pageSize)
    }

    /// Establish the target at touch-down, not when SwiftUI last built a button.
    /// A final code key may have replaced the whole menu since that render. It
    /// precedes this press, so finish it before reading the touched slot's word.
    /// Later changes still go through the normal context/word checks on release.
    public func prepareCandidateSelection(_ index: Int, onPage page: Int? = nil) -> PreparedCandidateSelection? {
        guard !retired, index >= 0 else { return nil }
        drainPendingCodes()
        guard inputAvailable(), snapshot.isComposing || snapshot.isPrediction else {
            return nil
        }
        let page = page ?? snapshot.pageIndex
        guard let absolute = candidateAbsoluteIndex(index, page: page, size: snapshot.pageSize) else {
            return nil
        }
        do {
            let text: String?
            if page == snapshot.pageIndex {
                text = snapshot.candidates.first { $0.index == index }?.text
            } else if engine.supportsReadOnlyBrowsing {
                text = try engine.readCandidates(fromIndex: absolute, count: 1).first?.text
            } else {
                text = nil
            }
            guard let text else { return nil }
            return PreparedCandidateSelection(
                index: index, page: page, text: text, context: candidateSelectionContext)
        } catch {
            onError?(error)
            return nil
        }
    }

    @discardableResult
    public func selectCandidate(_ selection: PreparedCandidateSelection) -> Bool {
        selectCandidate(
            selection.index, onPage: selection.page, seenText: selection.text, from: selection.context)
    }

    /// Select the word the user touched, even if a decode or refresh landed before
    /// touch-up. Never reuse an old index for a different word or a new composition.
    @discardableResult
    func selectCandidate(
        _ index: Int, onPage page: Int? = nil, seenText: String,
        from context: CandidateSelectionContext
    ) -> Bool {
        guard acceptsCandidateSelection(from: context), index >= 0,
            let absolute = candidateAbsoluteIndex(index, page: page ?? context.pageIndex, size: context.pageSize)
        else {
            return false
        }
        drainPendingCodes()
        guard acceptsCandidateSelection(from: context), inputAvailable(),
            snapshot.isComposing || snapshot.isPrediction
        else {
            return false
        }
        do {
            let resolved: Int?
            if context.revision == compositionRevision {
                resolved = absolute
            } else {
                resolved = try resolveCandidateSelection(absolute: absolute, text: seenText)
            }
            guard let resolved else { return false }
            let before = (snapshot.preedit, snapshot.rawInput, snapshot.preeditSelStart)
            let result = try engine.selectCandidateAbsolute(resolved)
            let delivered = apply(result)
            // An engine call returning normally is not proof of a selection.
            // Respect the host's acknowledgement, or real partial conversion
            // progress when Rime leaves the remaining segments composing.
            if !result.committed.isEmpty {
                return delivered
            }
            return result.isComposing
                && (result.preedit, result.rawInput, result.preeditSelStart) != before
        } catch {
            onError?(error)
            return false
        }
    }

    private func acceptsCandidateSelection(from context: CandidateSelectionContext) -> Bool {
        !retired && context.generation == candidateSelectionGeneration
            && context.schemaID == selectedSchemaID && context.layout == layout && context.mode == mode
    }

    private func candidateAbsoluteIndex(_ index: Int, page: Int, size: Int) -> Int? {
        guard page >= 0 else { return nil }
        guard size > 0 else { return index }
        guard index < size else { return nil }
        let (start, pageOverflow) = page.multipliedReportingOverflow(by: size)
        let (absolute, indexOverflow) = start.addingReportingOverflow(index)
        return pageOverflow || indexOverflow ? nil : absolute
    }

    private func resolveCandidateSelection(absolute: Int, text: String) throws -> Int? {
        let pageStart = snapshot.pageSize > 0 ? snapshot.pageIndex * snapshot.pageSize : 0
        if let unchanged = snapshot.candidates.first(where: { pageStart + $0.index == absolute }),
            unchanged.text == text
        {
            return absolute
        }
        // Check a previously browsed distant slot without paging the engine or
        // loading its entire candidate list on the touch-up path.
        if engine.supportsReadOnlyBrowsing,
            try engine.readCandidates(fromIndex: absolute, count: 1).first?.text == text
        {
            return absolute
        }
        if let moved = snapshot.candidates.first(where: { $0.text == text }) {
            return pageStart + moved.index
        }
        guard engine.supportsReadOnlyBrowsing else { return nil }
        // Re-ranking commonly moves a visible word across the first few pages.
        // Keep recovery bounded; a disappeared word must never select its replacement.
        let limit = max(64, min(256, snapshot.pageSize))
        let candidates = try engine.readCandidates(fromIndex: 0, count: limit)
        return candidates.firstIndex(where: { $0.text == text })
    }
}
