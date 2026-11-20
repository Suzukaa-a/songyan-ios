import CandidateKit
import Combine
import Foundation
import KeyboardCore
import LayoutKit
import OSLog
import UIKit

extension KeyboardController {
    public func selectSchema(_ id: String) { session.selectSchema(id) }
    public func revalidateCurrentSchema() { session.revalidateCurrentSchema() }
    /// Layout switch via the controller's direct entry. Re-selecting the current layout/schema is a no-op.
    /// A real switch clears the ambiguity picker; a failed one keeps it and the previous qualification.
    ///
    /// `board` is the physical board of the keyboard being selected (`PublishedKeyboard.board`). A
    /// layout or schema change that names none lands on no board. The same layout and schema with another
    /// board is a real switch too (romaji and kana are both the 26-key shape): the composition is settled
    /// like any switch, and the caller resets to the letters page.
    public func selectLayout(
        _ layout: KeyboardLayoutKind, boundSchemaID: String? = nil, board: String? = nil
    ) {
        guard !retired else { return }
        let needsTransition =
            boundSchemaID.map { layout != session.layout || $0 != session.selectedSchemaID }
            ?? (layout != session.layout)
        let changesBoard = board != selectedBoard
        guard needsTransition || changesBoard else { return }
        incomingBoard = board
        defer { incomingBoard = nil }
        performLayoutSwitch {
            guard needsTransition else {
                // Nothing in the session changes: settle the composition, then adopt the board.
                guard session.prepareForConfigurationChange() else { return false }
                selectedBoard = board
                // Another board of the same shape may group its codes another way.
                session.useFolds(drawnFolds(layout: layout, board: board))
                reportSuccessfulSelectionChange()
                return true
            }
            // The engine runs the companion of the grouping the new keyboard draws, chosen before the switch.
            session.useFolds(drawnFolds(layout: layout, board: board), revalidate: false)
            if let boundSchemaID {
                session.select(layout: layout, boundSchemaID: boundSchemaID)
            } else {
                session.select(layout: layout)
            }
            return session.layout == layout
                && (boundSchemaID == nil || session.selectedSchemaID == boundSchemaID)
        }
    }

    /// The fold of the layout drawn on `layout` from `board`, when that layout is not the bundled
    /// one: the engine must run that grouping's companion (see `KeyboardResourceSet.folds`). A board
    /// whose codes do not fold maps to nil, which runs on no companion. Other shapes draw their
    /// bundled layout.
    func drawnFolds(layout: KeyboardLayoutKind, board: String?) -> [KeyboardLayoutKind: CompactFold?] {
        Self.drawnFolds(in: drawnLayouts, layout: layout, board: board)
    }

    /// `drawnFolds` with the layouts read from `registry`; the host asks the same when it builds companions.
    nonisolated static func drawnFolds(
        in registry: LayoutRegistry?, layout: KeyboardLayoutKind, board: String?
    ) -> [KeyboardLayoutKind: CompactFold?] {
        guard let board, layout.compactFold != nil, let kind = LayoutInput.Builtin(rawValue: layout.rawValue),
            let definition = registry?.resolvedLayout(id: board)
        else { return [:] }
        let fold = LayoutFold.map(definition, kind: kind).flatMap { CompactFold.of(kind: layout, map: $0) }
        return [layout: fold]
    }

    /// Keeps the running session on the fold of the layout now drawn: a layout edit can change the
    /// grouping under the same keyboard, and the engine must follow it.
    func followDrawnFold() {
        guard !retired else { return }
        session.useFolds(drawnFolds(layout: layout, board: selectedBoard))
    }

    func reportSuccessfulSelectionChange() {
        let change = KeyboardSelectionChange(schemaID: selectedSchemaID, layout: layout, board: selectedBoard)
        successfulChange = change
        onSelectionChanged?(change)
    }

    @discardableResult
    public func discardComposition() -> Bool {
        inputError = nil
        let completed = session.discardComposition()
        // Do not drop the only restore token before cancellation is proven.
        // A failed cancellation leaves the internal canonical/alias input live.
        if completed, !session.snapshot.isComposing { ambiguityPicker.clear() }
        return completed
    }

    @discardableResult
    public func commitComposition(allowingPartial: Bool = false) -> Bool {
        inputError = nil
        if session.compactSpellingLayout && readingFilter.isFiltering { return confirmReadingTarget() }
        let completed = session.commitComposition(allowingPartial: allowingPartial)
        // `refresh()` normally clears the picker when composition ends. Keep
        // the lock on failure so a later code key must still restore first.
        if completed, !session.snapshot.isComposing { ambiguityPicker.clear() }
        return completed
    }

    /// Shared by keycaps, full SymbolLibrary, public confirmation and mode entry.
    /// Partial selection preserves the remaining composition and cancels this
    /// compound action. No fallback to the now-hidden engine highlight.
    func confirmReadingTarget() -> Bool {
        guard session.compactSpellingLayout, readingFilter.isFiltering else { return true }
        guard readingFilter.revision == session.compositionRevision,
            let first = readingFilter.matches.first
        else { return false }
        return session.confirmCandidateAbsolute(first.index) == .completed
    }

    @discardableResult
    public func prepareForConfigurationChange() -> Bool {
        guard !retired else { return false }
        inputError = nil
        var completed = false
        performLayoutSwitch {
            completed = session.prepareForConfigurationChange()
            return completed
        }
        return completed
    }

    public func reloadOptions() {
        guard !retired else { return }
        session.reloadOptions()
        if let message = (session.engine as? RimeBackend)?.lastErrorText {
            Self.diagnosticLogger.error("option reload failed: \(message, privacy: .private)")
            optionError = String(localized: "无法读取当前方案的选项，请重试。")
        }
    }

    public func setOption(_ name: String, value: Bool) {
        guard !retired else { return }
        do {
            try session.setOption(name, value: value)
            optionError =
                (session.engine as? RimeBackend)?.optionPersistenceError == nil
                ? nil : String(localized: "选项已在本次会话生效，但未能保存，请重试。")
        } catch {
            Self.diagnosticLogger.error("option save failed: \(String(describing: error), privacy: .private)")
            optionError = String(localized: "未能保存选项，请重试。")
        }
    }
}
