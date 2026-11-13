import Foundation
import KeyboardCore
import LayoutKit
import QuickContentKit

/// Copies the same categories the keyboard displays, before the editor opens.
enum KeyboardPageDraftFactory {
    static func recentKeys() async throws -> [LayoutKey] {
        try await HostConfigIOQueue.async {
            let directory = SymbolLibraryStorage.defaultStoreDirectory()
            var readError: Error?
            let texts = RecentSymbolStore(directory: directory).read { readError = $0 }
            if let readError { throw readError }
            return texts.map { .init(label: $0, action: .init(.literal, value: $0)) }
        }
    }

    /// Opens an existing page for editing with the same id and name. Function keys become authored
    /// chrome and a categorized page gets the categories the keyboard currently shows, because the
    /// editor mutates data and can never read that library on the main thread.
    static func editableDraft(
        _ page: KeyboardPageDefinition, numericForm: KeyboardNumericForm = .rows,
        numericMarks: KeyboardNumericMarks = .chinese
    ) async throws -> KeyboardPageDefinition {
        var resolved = page
        if resolved.symbolPresentation == .automatic,
            KeyboardPageResolver.symbolPresentation(
                page: resolved, mainLayoutIsPhoneKeypad: numericForm == .phoneDigitPad) == .categorized
        {
            // The running phone layout opens categories, not the automatic page's backup rows.
            resolved.symbolPresentation = .categorized
        }
        if resolved.symbolPresentation == .categorized && resolved.categories == nil {
            // Legacy browser rows stay in the draft: resolving the category snapshot must not
            // delete content the stored page still carries.
            resolved.categories = try await authoredCategories()
        }
        let marks = resolved.defaultSymbolMarks ?? numericMarks
        var draft = resolved.materialized(numericForm: numericForm, numericMarks: marks)
        // Only a page that truly followed the keyboard stays nil. An automatic page whose wire data
        // pins an initial branch keeps that author choice when opened for editing.
        if resolved.defaultSymbolMarks == nil && resolved.resolvesAtRuntime {
            draft.defaultSymbolMarks = nil
        }
        return draft
    }

    /// A copy always carries the current function keys as real data. An automatic 123 page is
    /// materialized in the shape the caller selects (the running main layout's digit pad or the
    /// ten-column row page), and an automatic symbol page in the presentation requested.
    static func copy(
        _ page: KeyboardPageDefinition, presentation: KeyboardSymbolPresentation? = nil,
        numericMarks: KeyboardNumericMarks? = nil, numericForm: KeyboardNumericForm? = nil
    ) async throws -> KeyboardPageDefinition {
        var base = page
        if base.numericPresentation == .automatic {
            let marks = numericMarks ?? .chinese
            let form = numericForm ?? .rows
            var copy = base.copy(numericMarks: numericMarks, numericForm: form)
            copy.name = numericCopyName(marks: marks, form: form)
            try copy.validate()
            return copy
        }
        if base.symbolPresentation == .automatic, let presentation, presentation != .automatic {
            switch presentation {
            case .rows:
                // Keep the automatic presentation until the model materializes it: only that branch
                // knows whether the stored rows are still the canonical preset (then it may take the
                // initial-language snapshot) or author-modified (then it keeps them, along with the
                // author's split). Hand-picking a preset here would discard both.
                let copy = base.copy(
                    name: String(localized: "\(page.listName) 副本"), numericMarks: numericMarks,
                    numericForm: numericForm ?? .rows)
                try copy.validate()
                return copy
            case .categorized:
                // Categorized copies take the live library snapshot below; their initial branch
                // follows the keyboard unless the caller pinned one.
                base.chrome = nil
                base.symbolPresentation = .categorized
                base.rows = []
                base.categories = try await authoredCategories()
            case .automatic:
                break
            }
        }
        if base.symbolPresentation == .categorized && base.categories == nil {
            base.categories = try await authoredCategories()
        }
        // Runtime-resolved pages never pick a branch on their own; only a caller's explicit choice
        // pins the copy. Authored pages keep the initial branch they were saved with.
        let copy = base.copy(numericMarks: numericMarks, numericForm: numericForm ?? .rows)
        try copy.validate()
        return copy
    }

    private static func numericCopyName(marks: KeyboardNumericMarks, form: KeyboardNumericForm) -> String {
        switch form {
        // The digit pad's keys are the same digits in both languages.
        case .phoneDigitPad: return String(localized: "\(UserTerminology.phoneDigitPad) 副本")
        case .rows:
            let language = marks == .ascii ? String(localized: "英文 123") : String(localized: "中文 123")
            return String(localized: "\(language) 副本")
        }
    }

    /// The category snapshot the keyboard draws: common symbols, recents and the user's library
    /// in display order. Reads on the serial configuration queue, never the main thread.
    private static func authoredCategories() async throws -> [KeyboardPageCategory] {
        try await HostConfigIOQueue.async {
            let directory = SymbolLibraryStorage.defaultStoreDirectory()
            var readError: Error?
            let catalog = SymbolCatalogStore(directory: directory).loadActive { readError = $0 }
            if let readError { throw readError }
            let recents = RecentSymbolStore(directory: directory).read { readError = $0 }
            if let readError { throw readError }
            let displayed = SymbolPageTable.phoneSymbolCategories(
                ascii: false, recents: recents,
                library: catalog.orderedCategories.map {
                    .init(id: $0.id, title: $0.name, symbols: catalog.items(in: $0.id).map(\.text))
                })
            var result = displayed.map { category in
                KeyboardPageCategory(
                    id: category.id, name: category.title, columns: category.columns,
                    keys: category.caps.map { .init(label: $0.title, action: .init(.literal, value: $0.title)) },
                    source: category.id == SymbolPageTable.recentCategoryID ? .recent : .fixed)
            }
            if !result.contains(where: { $0.source == .recent }) {
                let recent = KeyboardPageCategory(
                    id: SymbolPageTable.recentCategoryID, name: String(localized: "最近"), keys: [], source: .recent)
                result.insert(recent, at: 1)
            }
            return result
        }
    }
}
