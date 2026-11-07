import Combine
import Foundation
import QuickContentKit

/// Where the keyboard-tools directory lives.
///
/// The keyboard panel reads the App Group content root, so the host prefers
/// <App Group root>/KeyboardTools. Without a usable container the tools stay in an app-local
/// directory the keyboard cannot see, and the page says so instead of pretending they are live.
enum KeyboardToolsStoreLocation: Equatable, Sendable {
    case shared(URL)
    case local(URL)

    var url: URL {
        switch self {
        case .shared(let url), .local(let url): return url
        }
    }

    var isShared: Bool {
        if case .shared = self { return true }
        return false
    }
}

/// User-visible copy for the keyboard-tools page and its editor.
///
/// The words live in their own string catalog so this page can be translated without touching the
/// app's main catalog; the table name is the catalog's file name.
enum KeyboardToolsCopy {
    static func text(_ key: String) -> String {
        String(
            localized: String.LocalizationValue(key), table: "KeyboardToolsSettings", bundle: .main)
    }
}

/// Directory names the page uses. Kept outside the main-actor class so the resolver can read them
/// without crossing an isolation boundary.
enum KeyboardToolsDirectories {
    /// Appended to the shared content root; the keyboard panel reads the same path.
    static let sharedName = "KeyboardTools"
    /// App-local fallback. The keyboard cannot read tools kept here, so the page says so.
    static let localName = "RimeKeyboardTools"
}

/// Host-side owner of the keyboard tools; the only writer.
///
/// Every file operation runs inside ToolStore, an actor, so the main actor never reads or writes
/// the store. The directory is resolved once, on a background task, because the shared-container
/// check probes writability with a real file. A settings file the store cannot read is reported and
/// left alone, never replaced by defaults.
@MainActor
final class KeyboardToolsCenter: ObservableObject {
    static let shared = KeyboardToolsCenter()

    @Published var isPresented = false

    func loadIfNeeded() {
        if loadTask == nil { reload() }
    }

    @discardableResult
    func open(importing url: URL? = nil) -> Task<Void, Never>? {
        isPresented = true
        guard let url else { return nil }
        reload()
        let loading = loadTask
        return Task {
            await loading?.value
            await importTool(fileAt: url)
        }
    }

    @Published private(set) var snapshot: ToolStoreSnapshot?
    @Published private(set) var location: KeyboardToolsStoreLocation?
    @Published private(set) var isLoading = true
    @Published private(set) var isBusy = false
    @Published private(set) var loadFailed = false
    @Published private(set) var lastError: String?
    @Published private(set) var message: String?

    /// Entries in list order; empty until the first successful read.
    var entries: [ToolStoreEntry] { snapshot?.entries ?? [] }
    /// The deletion one undo restores, when there is one.
    var undoableDeletion: ToolStoreDeletion? { snapshot?.undoableDeletion }
    /// Writes wait for a whole, readable snapshot so a refused file is never overwritten.
    var canEdit: Bool { snapshot != nil }

    private var store: ToolStore?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private let resolveLocation: @Sendable () -> KeyboardToolsStoreLocation

    /// resolveLocation is injectable so probes point the store at a scratch directory; the
    /// initializer itself touches no files.
    init(
        resolveLocation: @escaping @Sendable () -> KeyboardToolsStoreLocation = {
            KeyboardToolsCenter.resolveStoreDirectory()
        }
    ) {
        self.resolveLocation = resolveLocation
    }

    // MARK: - Location

    /// Shared container first, app-local directory otherwise. The probe creates the directory and
    /// writes a small file, so only loadStore calls this and only on a background task.
    nonisolated static func resolveStoreDirectory() -> KeyboardToolsStoreLocation {
        let resolved = RimePaths.probedStoreDirectory(
            sharedName: KeyboardToolsDirectories.sharedName,
            localName: KeyboardToolsDirectories.localName, label: "keyboard tools")
        return resolved.isShared ? .shared(resolved.url) : .local(resolved.url)
    }

    // MARK: - Reading

    func reload() {
        lastError = nil
        message = nil
        isLoading = true
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.readSnapshot()
            guard !Task.isCancelled, generation == self.loadGeneration else { return }
            self.apply(outcome)
        }
    }

    private struct ReadOutcome: Sendable {
        var store: ToolStore
        var location: KeyboardToolsStoreLocation
        var snapshot: ToolStoreSnapshot?
        var errorMessage: String?
    }

    private func apply(_ outcome: ReadOutcome) {
        store = outcome.store
        location = outcome.location
        if let snapshot = outcome.snapshot {
            self.snapshot = snapshot
            loadFailed = false
        } else {
            // A failed reread keeps the list on screen and reports the problem instead of blanking it.
            loadFailed = true
        }
        isLoading = false
        lastError = outcome.errorMessage
    }

    private func readSnapshot() async -> ReadOutcome {
        let (store, location) = await loadStore()
        do {
            let snapshot = try await store.load()
            return ReadOutcome(store: store, location: location, snapshot: snapshot, errorMessage: nil)
        } catch {
            return ReadOutcome(
                store: store, location: location, snapshot: nil,
                errorMessage: Self.userMessage(for: error))
        }
    }

    /// Resolves the directory once and keeps the store. The container probe is disk I/O, so it runs
    /// on a detached task rather than on the main actor.
    private func loadStore() async -> (store: ToolStore, location: KeyboardToolsStoreLocation) {
        if let store, let location { return (store, location) }
        let resolver = resolveLocation
        let resolved = await Task.detached(priority: .userInitiated) { resolver() }.value
        return (ToolStore(rootURL: resolved.url), resolved)
    }

    // MARK: - Display

    /// The name the interface shows for a tool, in the interface language.
    func displayName(of entry: ToolStoreEntry) -> String {
        displayName(of: entry.definition)
    }

    func displayName(of definition: ToolDefinition) -> String {
        definition.displayName(preferredLanguageTags: [ToolLanguage.current.rawValue])
    }

    // MARK: - Settings

    @discardableResult
    func setEnabled(_ enabled: Bool, toolID: String) async -> Bool {
        guard let entry = entry(for: toolID) else { return false }
        let name = displayName(of: entry)
        let key = enabled ? "keyboardTools.status.enabled" : "keyboardTools.status.disabled"
        return await write(
            { store in try await store.setEnabled(enabled, toolID: toolID) },
            success: { String(format: KeyboardToolsCopy.text(key), name) })
    }

    @discardableResult
    func setPinned(_ pinned: Bool, toolID: String) async -> Bool {
        guard let entry = entry(for: toolID) else { return false }
        let name = displayName(of: entry)
        let key = pinned ? "keyboardTools.status.pinned" : "keyboardTools.status.unpinned"
        return await write(
            { store in try await store.setPinned(pinned, toolID: toolID) },
            success: { String(format: KeyboardToolsCopy.text(key), name) })
    }

    @discardableResult
    func moveTool(id: String, toIndex index: Int) async -> Bool {
        await write(
            { store in try await store.moveTool(id: id, toIndex: index) },
            success: { KeyboardToolsCopy.text("keyboardTools.status.moved") })
    }

    // MARK: - Delete and undo

    @discardableResult
    func deleteTool(id: String) async -> Bool {
        guard let entry = entry(for: id) else { return false }
        guard !entry.isBuiltin else {
            lastError = KeyboardToolsCopy.text("keyboardTools.error.builtinNotDeletable")
            return false
        }
        let name = displayName(of: entry)
        return await write(
            { store in try await store.deleteTool(id: id) },
            success: { String(format: KeyboardToolsCopy.text("keyboardTools.status.deleted"), name) })
    }

    @discardableResult
    func undoDelete() async -> Bool {
        guard undoableDeletion != nil else {
            lastError = KeyboardToolsCopy.text("keyboardTools.error.noUndo")
            return false
        }
        return await write(
            { store in
                if let restored = try await store.undoLastDeletion() { return restored }
                return try await store.load()
            },
            success: { KeyboardToolsCopy.text("keyboardTools.status.undone") })
    }

    // MARK: - Import and export

    /// Imports a tool file the user picked. The security-scoped access is opened here, where the
    /// system requires it; the bytes are read inside the store actor.
    func importTool(fileAt url: URL) async {
        guard let store, snapshot != nil else {
            lastError = KeyboardToolsCopy.text("keyboardTools.error.notReady")
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let outcome = try await store.importTool(contentsOf: url)
            snapshot = try await store.load()
            lastError = nil
            message = importMessage(for: outcome)
        } catch {
            lastError = Self.userMessage(for: error)
        }
    }

    /// The byte-based import; the file picker path and probes share it.
    @discardableResult
    func importTool(data: Data) async -> Bool {
        guard let store, snapshot != nil else {
            lastError = KeyboardToolsCopy.text("keyboardTools.error.notReady")
            return false
        }
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let outcome = try await store.importTool(data: data)
            snapshot = try await store.load()
            lastError = nil
            message = importMessage(for: outcome)
            return true
        } catch {
            lastError = Self.userMessage(for: error)
            return false
        }
    }

    private func importMessage(for outcome: ToolImportOutcome) -> String {
        switch outcome {
        case .inserted(let definition):
            return String(
                format: KeyboardToolsCopy.text("keyboardTools.status.imported"),
                displayName(of: definition))
        case .updated(let definition):
            return String(
                format: KeyboardToolsCopy.text("keyboardTools.status.updated"),
                displayName(of: definition))
        }
    }

    /// The bytes of one tool file. The store's encoder writes them, so an exported file imports back
    /// unchanged.
    func exportData(id: String) async -> Data? {
        guard let store else {
            lastError = KeyboardToolsCopy.text("keyboardTools.error.notReady")
            return nil
        }
        do {
            return try await store.exportTool(id: id)
        } catch {
            lastError = Self.userMessage(for: error)
            return nil
        }
    }

    // MARK: - Create and edit

    /// Copies a built-in example (or a user tool) under a fresh identifier so the editor can open
    /// the copy. ToolStore keeps the authored names and steps; the copy is enabled and appended.
    func duplicateTool(id: String) async -> ToolDefinition? {
        guard let store, snapshot != nil else {
            lastError = KeyboardToolsCopy.text("keyboardTools.error.notReady")
            return nil
        }
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let copy = try await store.duplicateTool(id: id)
            snapshot = try await store.load()
            lastError = nil
            message = String(
                format: KeyboardToolsCopy.text("keyboardTools.status.copied"), displayName(of: copy))
            return copy
        } catch {
            lastError = Self.userMessage(for: error)
            return nil
        }
    }

    /// Saves an edited draft. A refused draft reports its reason and writes nothing.
    @discardableResult
    func saveDraft(_ draft: KeyboardToolDraft) async -> Bool {
        let definition: ToolDefinition
        do {
            definition = try draft.definition()
        } catch let error as KeyboardToolDraftError {
            lastError = error.message
            message = nil
            return false
        } catch let error as ToolDefinitionError {
            lastError = error.message(in: .current)
            message = nil
            return false
        } catch {
            lastError = KeyboardToolsCopy.text("keyboardTools.error.generic")
            message = nil
            return false
        }
        return await saveDefinition(definition)
    }

    @discardableResult
    func saveDefinition(_ definition: ToolDefinition) async -> Bool {
        let name = displayName(of: definition)
        return await write(
            { store in try await store.saveUserTool(definition) },
            success: { String(format: KeyboardToolsCopy.text("keyboardTools.status.saved"), name) })
    }

    // MARK: - Writing

    /// Runs one mutation and applies its snapshot. A failed write keeps the displayed list and
    /// reports why; the store itself never leaves a half-written file.
    private func write(
        _ action: @escaping @Sendable (ToolStore) async throws -> ToolStoreSnapshot,
        success: @escaping @Sendable () -> String?
    ) async -> Bool {
        guard let store, snapshot != nil else {
            lastError = KeyboardToolsCopy.text("keyboardTools.error.notReady")
            return false
        }
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let updated = try await action(store)
            snapshot = updated
            lastError = nil
            message = success()
            return true
        } catch {
            lastError = Self.userMessage(for: error)
            return false
        }
    }

    // MARK: - Errors

    /// One short user-facing sentence for a store failure. Definition problems reuse the format
    /// package's own wording, which already names the step and what to do.
    nonisolated static func userMessage(for error: Error) -> String {
        if let storeError = error as? ToolStoreError {
            switch storeError {
            case .metadataUnavailable:
                return KeyboardToolsCopy.text("keyboardTools.error.metadataUnavailable")
            case .pinLimit(let maximum):
                return String(
                    format: KeyboardToolsCopy.text("keyboardTools.error.pinLimit"), maximum)
            case .importInvalid(let definitionError), .definitionInvalid(let definitionError):
                return definitionError.message(in: .current)
            case .toolUnavailable:
                return KeyboardToolsCopy.text("keyboardTools.error.toolUnavailable")
            case .toolNotFound:
                return KeyboardToolsCopy.text("keyboardTools.error.toolNotFound")
            case .builtinNotDeletable:
                return KeyboardToolsCopy.text("keyboardTools.error.builtinNotDeletable")
            case .identifierReservedForBuiltin:
                return KeyboardToolsCopy.text("keyboardTools.error.identifierReserved")
            }
        }
        return KeyboardToolsCopy.text("keyboardTools.error.generic")
    }

    private func entry(for id: String) -> ToolStoreEntry? {
        snapshot?.entries.first { $0.id == id }
    }
}
