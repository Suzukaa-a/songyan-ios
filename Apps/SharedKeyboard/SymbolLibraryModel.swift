import Combine
import Foundation
import QuickContentKit

// MARK: - Panel state model (render-independent; search isolation lives here)

/// Symbol panel state: catalog data, query buffer, category selection, recents.
/// Search state is independent of the Chinese composition: this model holds no controller/session reference.
@MainActor
public final class SymbolLibraryModel: ObservableObject {
    /// Query key (the exact interface for a host-injected external search action; the internal keyboard uses it too).
    public enum SearchKey: Equatable, Sendable {
        /// Appends characters (may be several; whitespace and newlines are dropped). Chinese can be injected too; matching is by name.
        case character(String)
        case backspace
        case clear
    }

    /// Recent entry (text + its catalog name; the name is nil if the catalog lacks the text, and it can
    /// still be tapped to insert, since recents record the inserted text and do not depend on an entry id).
    public struct RecentEntry: Identifiable, Equatable, Sendable {
        public let text: String
        public let name: String?
        public var id: String { text }
    }

    @Published public private(set) var catalog: SymbolCatalog
    @Published public private(set) var catalogReadError: String?
    @Published public private(set) var recents: [RecentEntry] = []
    /// Non-blocking note for a persistence problem (a failed save keeps the old data and the panel stays usable).
    @Published public private(set) var persistenceNote: String?
    /// Query buffer (private to the panel; normalized comparison is in SymbolCatalog.search).
    @Published public private(set) var query: String = ""
    @Published public private(set) var selectedCategory: String?
    /// Whether the internal ASCII query keyboard is shown (inside the panel only, not a resident bottom key).
    @Published public private(set) var searchKeyboardVisible = false

    @Published public private(set) var storeDirectory: URL?
    @Published public private(set) var isLoading = true
    private let worker: SymbolLibraryIOWorker
    /// Register the predecessor synchronously on MainActor before any Task can
    /// yield: file operation order must follow gestures, not Task scheduling.
    private var pendingOperation: Task<Void, Never>?
    private var requestToken = 0
    private var appliedToken = 0
    private var latestReloadToken = 0
    private var persistenceNoteFromRead = false
    /// The last recents read from or written to the store.
    private var storedRecents: [String] = []
    /// Uses that could not be stored (no Full Access): shown first for the life of
    /// this keyboard process, never written.
    private var sessionRecents: [String] = []
    private let onInsert: (String) -> Bool
    /// Optional report of whether the insert succeeded: the host uses it for "feedback only on real success" side effects.
    /// Timing: called once after onInsert returns true and before recents are recorded.
    private let onInserted: ((Bool) -> Void)?

    /// - Parameters:
    ///   - storeDirectory: Injected user directory (nil = resolve automatically, see SymbolLibraryStorage).
    ///     Host and extension processes can share the custom catalog and recents by using the same directory.
    ///   - onInsert: Insert exit; the host wires `controller.insertLiteral`, which does the composition
    ///     confirmation, so this panel never restarts the engine. The return value says whether this
    ///     literal was dispatched to a valid host exit (false for a partial composition commit, no host
    ///     exit, or input disabled); true does not guarantee the host document accepted it (the public
    ///     proxy gives no receipt). On false, recents are not recorded.
    ///   - onInserted: Optional report of the insert result (called once, before recents are recorded).
    ///   - loadsImmediately: false defers the first read to an explicit `reload()`, for owners
    ///     created with the keyboard that may never show the library.
    public init(
        storeDirectory: URL? = nil,
        onInsert: @escaping (String) -> Bool,
        onInserted: ((Bool) -> Void)? = nil,
        loadsImmediately: Bool = true
    ) {
        self.storeDirectory = storeDirectory
        self.worker = SymbolLibraryIOWorker(directory: storeDirectory)
        self.onInsert = onInsert
        self.onInserted = onInserted
        // Even bundledDefault() reads JSON. First paint must not touch disk.
        self.catalog = SymbolCatalog(categories: [], items: [])
        if loadsImmediately { reload() } else { isLoading = false }
    }

    /// Re-reads the catalog and recents; returns a task for callers that need a stable result to await.
    /// Serialized with insert/clear records in call order, so an old read cannot pass a newer write.
    @discardableResult
    public func reload() -> Task<Void, Never> {
        isLoading = true
        latestReloadToken = requestToken + 1
        return enqueue { await $0.load() }
    }

    @discardableResult
    private func enqueue(_ operation: @escaping (SymbolLibraryIOWorker) async -> SymbolLibraryIOWorker.Outcome) -> Task<
        Void, Never
    > {
        requestToken += 1
        let token = requestToken
        let previous = pendingOperation
        let worker = self.worker
        let task = Task { [weak self] in
            await previous?.value
            let outcome = await operation(worker)
            self?.apply(outcome, token: token)
        }
        pendingOperation = task
        return task
    }

    private func apply(_ outcome: SymbolLibraryIOWorker.Outcome, token: Int) {
        guard token > appliedToken else { return }
        appliedToken = token
        storeDirectory = outcome.directory
        if let catalog = outcome.catalog {
            self.catalog = catalog
            if let selectedCategory, !catalog.categories.contains(where: { $0.id == selectedCategory }) {
                self.selectedCategory = nil
            }
            catalogReadError = outcome.catalogReadError
        }
        for use in outcome.unstoredUses {
            sessionRecents = Array(([use] + sessionRecents.filter { $0 != use }).prefix(Self.recentLimit))
        }
        if let texts = outcome.texts { storedRecents = texts }
        if !outcome.unstoredUses.isEmpty || outcome.texts != nil || outcome.catalog != nil {
            let merged = sessionRecents + storedRecents.filter { !sessionRecents.contains($0) }
            recents = Self.recentEntries(texts: Array(merged.prefix(Self.recentLimit)), catalog: catalog)
        }
        if outcome.updatesPersistenceNote {
            persistenceNote = outcome.persistenceNote
            persistenceNoteFromRead = outcome.isRead
        } else if outcome.isRead && persistenceNoteFromRead {
            persistenceNote = nil
            persistenceNoteFromRead = false
        }
        if token == latestReloadToken { isLoading = false }
    }

    // MARK: Search (own buffer; never writes to the host or Rime)

    /// Single entry for query keys (the internal keyboard and host external actions share one buffer and its rules).
    public func searchKey(_ key: SearchKey) {
        switch key {
        case .character(let characters):
            let allowed = characters.filter { !$0.isWhitespace && !$0.isNewline }
            guard !allowed.isEmpty else { return }
            query += allowed
        case .backspace:
            if !query.isEmpty { query.removeLast() }
        case .clear:
            query = ""
        }
    }

    /// Entered from a panel search action: opens the internal query keyboard.
    public func beginSearch() { searchKeyboardVisible = true }

    /// Leaves search: clears the query buffer and hides the query keyboard (back to category browsing; the composition is untouched).
    public func endSearch() {
        query = ""
        searchKeyboardVisible = false
    }

    public var isSearching: Bool { !query.isEmpty }
    public var searchResults: [SymbolItem] { catalog.search(query) }

    // MARK: Browse

    public func selectCategory(_ id: String?) { selectedCategory = id }

    /// Categories that have items (empty ones are skipped to avoid empty header areas).
    public var visibleCategories: [SymbolCategory] {
        catalog.orderedCategories.filter { !catalog.items(in: $0.id).isEmpty }
    }

    public func categoryName(_ id: String) -> String? {
        catalog.categories.first(where: { $0.id == id })?.name
    }

    // MARK: Insert and recents

    /// Inserts a symbol: the only output closure + the recents record (dedupe and move to front, persist, keep old on failure).
    /// Recents are recorded only after the insert really took effect (onInsert returned true); the panel
    /// stays open, so several symbols can be inserted in a row.
    public func insert(_ item: SymbolItem) {
        insertText(item.text, name: item.name)
    }

    /// Inserts a recent entry (the catalog may no longer contain it; inserted by text only).
    public func insert(entry: RecentEntry) {
        insertText(entry.text, name: entry.name)
    }

    /// Private phrases and clipboard text never enter the symbol-recents file.
    public func insertQuickText(_ text: String) -> Bool {
        let inserted = onInsert(text)
        onInserted?(inserted)
        return inserted
    }

    private func insertText(_ text: String, name: String?) {
        let inserted = onInsert(text)
        onInserted?(inserted)
        guard inserted else { return }
        recordUse(text)
    }

    /// Records a symbol another surface (the 9-key symbol page) already inserted,
    /// so both share one recents list.
    public func recordUse(_ text: String) {
        recordUses([text])
    }

    /// A categorized page defers its recents until closing so the grid stays still while typing.
    public func recordUses(_ texts: [String]) {
        guard !texts.isEmpty else { return }
        enqueue { await $0.record(texts) }
    }

    private static let recentLimit = 20

    /// Clears recents (keeps the old data and notes on failure); ordered after earlier insert records/refreshes.
    @discardableResult
    public func clearRecents() -> Task<Void, Never> {
        sessionRecents = []
        recents = Self.recentEntries(texts: storedRecents, catalog: catalog)
        return enqueue { await $0.clear() }
    }

    private static func recentEntries(texts: [String], catalog: SymbolCatalog) -> [RecentEntry] {
        texts.map { text in
            RecentEntry(text: text, name: catalog.items.first(where: { $0.text == text })?.name)
        }
    }
}
