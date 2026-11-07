import Foundation

/// One tool in the store: its authored definition plus the settings the store keeps for it.
///
/// Built-in examples are part of the app; user tools are files in the store directory. Both
/// kinds share the same settings, so a built-in can be disabled, reordered and pinned without
/// ever being copied or edited.
public struct ToolStoreEntry: Equatable, Sendable, Identifiable {
    public let definition: ToolDefinition
    public let isBuiltin: Bool
    public let isEnabled: Bool
    public let isPinned: Bool

    public var id: String { definition.id }

    init(definition: ToolDefinition, isBuiltin: Bool, isEnabled: Bool, isPinned: Bool) {
        self.definition = definition
        self.isBuiltin = isBuiltin
        self.isEnabled = isEnabled
        self.isPinned = isPinned
    }
}

/// The most recently removed user tool, kept so the interface can offer one undo.
///
/// The definition, the enable and pin settings and the position in the list are all kept, so
/// restoring it returns the store to the state it had before the deletion.
public struct ToolStoreDeletion: Codable, Equatable, Sendable {
    public let definition: ToolDefinition
    public let wasEnabled: Bool
    public let wasPinned: Bool
    public let orderIndex: Int

    init(definition: ToolDefinition, wasEnabled: Bool, wasPinned: Bool, orderIndex: Int) {
        self.definition = definition
        self.wasEnabled = wasEnabled
        self.wasPinned = wasPinned
        self.orderIndex = orderIndex
    }
}

/// The whole store as one read: entries in user order and, when a user tool was just deleted,
/// the item one undo would restore.
public struct ToolStoreSnapshot: Equatable, Sendable {
    public let entries: [ToolStoreEntry]
    public let undoableDeletion: ToolStoreDeletion?

    /// Enabled tools in list order; this is what the keyboard panel lists.
    public var enabledEntries: [ToolStoreEntry] { entries.filter(\.isEnabled) }

    /// Enabled pinned tools in list order; the toolbar holds at most two.
    public var pinnedEntries: [ToolStoreEntry] { enabledEntries.filter(\.isPinned) }

    init(entries: [ToolStoreEntry], undoableDeletion: ToolStoreDeletion?) {
        self.entries = entries
        self.undoableDeletion = undoableDeletion
    }
}

/// What an import did: either the file was new to the store or it replaced a definition with the
/// same identifier. Both outcomes keep the existing settings.
public enum ToolImportOutcome: Equatable, Sendable {
    case inserted(ToolDefinition)
    case updated(ToolDefinition)
}

/// Typed store failures. Messages are the interface layer's job, so the store never builds
/// user-visible text.
public enum ToolStoreError: Error, Equatable, Sendable {
    /// The settings file exists but cannot be read as a valid store document. The store does not
    /// guess and does not overwrite it.
    case metadataUnavailable
    /// Pinning another tool would exceed the toolbar limit.
    case pinLimit(maximum: Int)
    /// The imported file was rejected by ToolDefinition.decode before anything was written.
    case importInvalid(ToolDefinitionError)
    /// A definition built in memory does not pass ToolDefinition validation.
    case definitionInvalid(ToolDefinitionError)
    /// A stored user tool file is unreadable or corrupt; the store leaves the rest untouched.
    case toolUnavailable(id: String)
    /// No tool with this identifier exists.
    case toolNotFound(id: String)
    /// Built-in examples can be disabled, reordered and pinned, never removed.
    case builtinNotDeletable(id: String)
    /// A user file cannot take the identifier of a built-in example.
    case identifierReservedForBuiltin(id: String)
}

/// Persists the keyboard tools for one container directory.
///
/// Layout of the directory the caller passes:
///
///     state.json                         small settings: format version, id, enabled, pinned
///     tools/<id>.songyantool.json        one authored definition per user tool
///     trash/last-deletion.json           the single undo entry, replaced by the next deletion
///
/// The host passes the directory; the package never looks up an App Group, a bundle or a
/// profile, and the directory is expected to sit beside the layouts directory in the shared
/// container. List order is the order of the entries array in state.json; a built-in or user
/// tool that is not listed yet is appended (built-ins first, then user files sorted by id), so
/// a fresh install, a new built-in or a file dropped into tools/ still appears.
///
/// All reads and writes run inside the actor, so callers never do disk IO on the main thread,
/// and the initializer touches no files. The host is the single writer (the settings screen);
/// readers only ever see a whole file because every write is atomic. A missing settings file is
/// the first-use state; an unreadable one is reported as metadataUnavailable instead of being
/// replaced, and an import or definition edit validates before the first write, so a rejected
/// change leaves every file as it was.
public actor ToolStore {
    public static let maximumPinnedTools = 2

    /// Directory injected by the host. The store appends its own file names to it.
    public nonisolated let rootURL: URL

    private let builtins: [ToolDefinition]

    private static let stateFormatVersion = 1
    private static let stateFileName = "state.json"
    private static let toolsDirectoryName = "tools"
    private static let trashDirectoryName = "trash"
    private static let deletionFileName = "last-deletion.json"
    private static let toolFileSuffix = ".songyantool.json"
    /// The settings file holds only ids and flags; the bound guards against a corrupt file that
    /// claims to be enormous before it is read into memory.
    private static let maximumStateBytes = 256 * 1024
    private static let maximumDeletionBytes = 128 * 1024

    public init(
        rootURL: URL,
        builtins: [ToolDefinition] = BuiltinToolDefinitions.all()
    ) {
        self.rootURL = rootURL
        self.builtins = builtins
    }

    // MARK: - Reading

    /// Reads the store without writing anything.
    ///
    /// A missing settings file is the first-use state: the built-ins in list order followed by
    /// any user tool files already in the directory. A settings file that cannot be read throws
    /// metadataUnavailable so the interface can report it rather than lose the user's settings.
    public func load() async throws -> ToolStoreSnapshot {
        let surface = try readSurface()
        return ToolStoreSnapshot(entries: surface.entries, undoableDeletion: surface.deletion)
    }

    // MARK: - Import and export

    /// Validates and stores one .songyantool.json file. ToolDefinition.decode is the only parser,
    /// so import accepts exactly what export writes.
    ///
    /// A file whose identifier already exists as a user tool replaces that definition and keeps
    /// its enable, pin and order settings; re-importing the same file is therefore harmless.
    /// A file that claims a built-in identifier is rejected with identifierReservedForBuiltin.
    public func importTool(data: Data) async throws -> ToolImportOutcome {
        let definition: ToolDefinition
        do {
            definition = try ToolDefinition.decode(data)
        } catch let error as ToolDefinitionError {
            throw ToolStoreError.importInvalid(error)
        }
        return try storeImported(definition)
    }

    /// File-URL import for the system file picker. The caller owns any security-scoped access.
    public func importTool(contentsOf url: URL) async throws -> ToolImportOutcome {
        let definition: ToolDefinition
        do {
            definition = try ToolDefinition.decode(contentsOf: url)
        } catch let error as ToolDefinitionError {
            throw ToolStoreError.importInvalid(error)
        }
        return try storeImported(definition)
    }

    /// Writes an edited user definition. The identifier keeps its settings and list position;
    /// a new identifier is appended and enabled. Built-in identifiers are rejected.
    public func saveUserTool(_ definition: ToolDefinition) async throws -> ToolStoreSnapshot {
        let surface = try readSurface()
        if builtins.contains(where: { $0.id == definition.id }) {
            throw ToolStoreError.identifierReservedForBuiltin(id: definition.id)
        }
        let entries = try persistUserDefinition(definition, in: surface)
        return ToolStoreSnapshot(entries: entries, undoableDeletion: surface.deletion)
    }

    /// Deterministic export using ToolDefinition's own encoder. The names stay exactly as the
    /// author wrote them.
    public func exportTool(id: String) async throws -> Data {
        let surface = try readSurface()
        guard let entry = surface.entries.first(where: { $0.id == id }) else {
            throw ToolStoreError.toolNotFound(id: id)
        }
        return try entry.definition.encoded()
    }

    /// Copies a built-in or user tool under a fresh identifier, keeping the authored names and
    /// steps; the copy is a user tool appended at the end of the list.
    public func duplicateTool(id: String) async throws -> ToolDefinition {
        let surface = try readSurface()
        guard let entry = surface.entries.first(where: { $0.id == id }) else {
            throw ToolStoreError.toolNotFound(id: id)
        }
        let identifier = freshIdentifier(existing: Set(surface.entries.map(\.id)))
        let copy = ToolDefinition(
            formatVersion: entry.definition.formatVersion,
            id: identifier,
            name: entry.definition.name,
            steps: entry.definition.steps)
        do {
            try writeTool(copy)
        } catch let error as ToolDefinitionError {
            throw ToolStoreError.definitionInvalid(error)
        }
        var entries = surface.entries
        entries.append(
            ToolStoreEntry(definition: copy, isBuiltin: false, isEnabled: true, isPinned: false))
        try writeState(entries: entries)
        return copy
    }

    // MARK: - Settings

    public func setEnabled(_ enabled: Bool, toolID: String) async throws -> ToolStoreSnapshot {
        let surface = try readSurface()
        var entries = surface.entries
        let index = try index(of: toolID, in: entries)
        let entry = entries[index]
        entries[index] = ToolStoreEntry(
            definition: entry.definition, isBuiltin: entry.isBuiltin, isEnabled: enabled,
            isPinned: entry.isPinned)
        try writeState(entries: entries)
        return ToolStoreSnapshot(entries: entries, undoableDeletion: surface.deletion)
    }

    /// Pins a tool to the toolbar. A third pinned tool is rejected with pinLimit; unpinning
    /// always works. Pinning a disabled tool is allowed but it stays out of pinnedEntries until
    /// it is enabled again.
    public func setPinned(_ pinned: Bool, toolID: String) async throws -> ToolStoreSnapshot {
        let surface = try readSurface()
        var entries = surface.entries
        let index = try index(of: toolID, in: entries)
        let entry = entries[index]
        if pinned, !entry.isPinned,
            entries.filter(\.isPinned).count >= Self.maximumPinnedTools
        {
            throw ToolStoreError.pinLimit(maximum: Self.maximumPinnedTools)
        }
        entries[index] = ToolStoreEntry(
            definition: entry.definition, isBuiltin: entry.isBuiltin, isEnabled: entry.isEnabled,
            isPinned: pinned)
        try writeState(entries: entries)
        return ToolStoreSnapshot(entries: entries, undoableDeletion: surface.deletion)
    }

    /// Moves a tool to a list position. An index outside the list is clamped to the nearest end.
    public func moveTool(id: String, toIndex index: Int) async throws -> ToolStoreSnapshot {
        let surface = try readSurface()
        var entries = surface.entries
        let current = try self.index(of: id, in: entries)
        let entry = entries.remove(at: current)
        entries.insert(entry, at: max(0, min(index, entries.count)))
        if current != (try self.index(of: id, in: entries)) {
            try writeState(entries: entries)
        }
        return ToolStoreSnapshot(entries: entries, undoableDeletion: surface.deletion)
    }

    // MARK: - Delete and undo

    /// Removes a user tool from the list and the tools directory. Only the latest deletion can
    /// be undone; its definition and settings are kept in trash/last-deletion.json.
    public func deleteTool(id: String) async throws -> ToolStoreSnapshot {
        let surface = try readSurface()
        var entries = surface.entries
        let index = try self.index(of: id, in: entries)
        let entry = entries[index]
        guard !entry.isBuiltin else {
            throw ToolStoreError.builtinNotDeletable(id: id)
        }
        let deletion = ToolStoreDeletion(
            definition: entry.definition, wasEnabled: entry.isEnabled, wasPinned: entry.isPinned,
            orderIndex: index)
        try writeDeletion(deletion)
        entries.remove(at: index)
        do {
            try removeToolFile(id: id)
            try writeState(entries: entries)
        } catch {
            if let previous = surface.deletion {
                try writeDeletion(previous)
            } else {
                try removeDeletion()
            }
            try writeTool(entry.definition)
            throw error
        }
        return ToolStoreSnapshot(entries: entries, undoableDeletion: deletion)
    }

    /// Restores the most recently deleted tool exactly where it was, with its settings.
    ///
    /// Returns nil when nothing is waiting for undo. If another tool was pinned while this one
    /// was deleted, the restored tool comes back enabled but unpinned so the toolbar limit still
    /// holds.
    public func undoLastDeletion() async throws -> ToolStoreSnapshot? {
        let surface = try readSurface()
        guard let deletion = surface.deletion else { return nil }
        var entries = surface.entries
        if entries.contains(where: { $0.id == deletion.definition.id }) {
            // The tool came back some other way (for example a re-import); drop the stale record.
            try removeDeletion()
            return ToolStoreSnapshot(entries: entries, undoableDeletion: nil)
        }
        do {
            try writeTool(deletion.definition)
        } catch let error as ToolDefinitionError {
            throw ToolStoreError.definitionInvalid(error)
        }
        let pinnedCount = entries.filter(\.isPinned).count
        let restoredPinned = deletion.wasPinned && pinnedCount < Self.maximumPinnedTools
        entries.insert(
            ToolStoreEntry(
                definition: deletion.definition, isBuiltin: false,
                isEnabled: deletion.wasEnabled, isPinned: restoredPinned),
            at: max(0, min(deletion.orderIndex, entries.count)))
        do {
            try writeState(entries: entries)
        } catch {
            try removeToolFile(id: deletion.definition.id)
            throw error
        }
        // The restored definition makes any retained undo record stale; cleaning it is not a save.
        try? removeDeletion()
        return ToolStoreSnapshot(entries: entries, undoableDeletion: nil)
    }

    // MARK: - Surface

    private struct Surface {
        var entries: [ToolStoreEntry]
        var deletion: ToolStoreDeletion?
    }

    private struct StoredState: Codable, Equatable, Sendable {
        var formatVersion: Int
        var entries: [StoredEntry]
    }

    private struct StoredEntry: Codable, Equatable, Sendable {
        var id: String
        var enabled: Bool
        var pinned: Bool
    }

    private struct StoredDeletion: Codable, Equatable, Sendable {
        var formatVersion: Int
        var deletion: ToolStoreDeletion
    }

    private func readSurface() throws -> Surface {
        let builtinByID = Dictionary(
            builtins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stateFile = rootURL.appendingPathComponent(Self.stateFileName)
        let stateExists = FileManager.default.fileExists(atPath: stateFile.path)
        let storedEntries: [StoredEntry]
        if stateExists {
            storedEntries = try readState(at: stateFile).entries
        } else {
            storedEntries = builtins.map { StoredEntry(id: $0.id, enabled: true, pinned: false) }
        }

        let requiredUserIDs = Set(storedEntries.map(\.id).filter { builtinByID[$0] == nil })
        let storedTools = try readStoredUserTools(
            requiredIDs: requiredUserIDs, builtinIDs: Set(builtinByID.keys))

        var entries: [ToolStoreEntry] = []
        for stored in storedEntries {
            if let builtin = builtinByID[stored.id] {
                entries.append(
                    ToolStoreEntry(
                        definition: builtin, isBuiltin: true, isEnabled: stored.enabled,
                        isPinned: stored.pinned))
            } else if let definition = storedTools[stored.id] {
                entries.append(
                    ToolStoreEntry(
                        definition: definition, isBuiltin: false, isEnabled: stored.enabled,
                        isPinned: stored.pinned))
            }
            // A user tool whose file is gone was removed between the two writes; drop the
            // settings entry instead of failing the whole store.
        }

        let listed = Set(entries.map(\.id))
        for builtin in builtins where !listed.contains(builtin.id) {
            entries.append(
                ToolStoreEntry(
                    definition: builtin, isBuiltin: true, isEnabled: true, isPinned: false))
        }
        for identifier in storedTools.keys.sorted()
        where !listed.contains(identifier) && builtinByID[identifier] == nil {
            if let definition = storedTools[identifier] {
                entries.append(
                    ToolStoreEntry(
                        definition: definition, isBuiltin: false, isEnabled: true,
                        isPinned: false))
            }
        }
        return Surface(entries: entries, deletion: readDeletion())
    }

    private func readState(at url: URL) throws -> StoredState {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard
                values.isRegularFile == true,
                let size = values.fileSize,
                size <= Self.maximumStateBytes
            else {
                throw ToolStoreError.metadataUnavailable
            }
            let data = try Data(contentsOf: url)
            let state = try JSONDecoder().decode(StoredState.self, from: data)
            guard
                state.formatVersion == Self.stateFormatVersion,
                Set(state.entries.map(\.id)).count == state.entries.count,
                state.entries.filter(\.pinned).count <= Self.maximumPinnedTools
            else {
                throw ToolStoreError.metadataUnavailable
            }
            return state
        } catch let error as ToolStoreError {
            throw error
        } catch {
            throw ToolStoreError.metadataUnavailable
        }
    }

    private func readStoredUserTools(
        requiredIDs: Set<String>, builtinIDs: Set<String>
    ) throws -> [String: ToolDefinition] {
        let directory = rootURL.appendingPathComponent(
            Self.toolsDirectoryName, isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [:] }
        let files = try fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        var definitions: [String: ToolDefinition] = [:]
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            guard name.hasSuffix(Self.toolFileSuffix) else { continue }
            let identifier = String(name.dropLast(Self.toolFileSuffix.count))
            guard !identifier.isEmpty, !builtinIDs.contains(identifier) else { continue }
            do {
                let definition = try ToolDefinition.decode(contentsOf: file)
                guard definition.id == identifier else { continue }
                definitions[identifier] = definition
            } catch {
                // The settings entry needs this file: a damaged file must not be reported as a
                // working tool, and dropping it would silently lose the user's tool.
                if requiredIDs.contains(identifier) {
                    throw ToolStoreError.toolUnavailable(id: identifier)
                }
            }
        }
        return definitions
    }

    private func readDeletion() -> ToolStoreDeletion? {
        let url =
            rootURL
            .appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.deletionFileName)
        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            let size = values.fileSize,
            size <= Self.maximumDeletionBytes,
            let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode(StoredDeletion.self, from: data),
            stored.formatVersion == Self.stateFormatVersion
        else { return nil }
        return stored.deletion
    }

    // MARK: - Writing

    private func writeState(entries: [ToolStoreEntry]) throws {
        let state = StoredState(
            formatVersion: Self.stateFormatVersion,
            entries: entries.map {
                StoredEntry(id: $0.id, enabled: $0.isEnabled, pinned: $0.isPinned)
            })
        let data = try encode(state)
        try FileManager.default.createDirectory(
            at: rootURL, withIntermediateDirectories: true)
        try data.write(to: rootURL.appendingPathComponent(Self.stateFileName), options: Self.atomicWriteOptions)
    }

    private func writeTool(_ definition: ToolDefinition) throws {
        let data = try definition.encoded()
        let directory = rootURL.appendingPathComponent(
            Self.toolsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: toolFileURL(for: definition.id), options: Self.atomicWriteOptions)
    }

    private func writeDeletion(_ deletion: ToolStoreDeletion) throws {
        let stored = StoredDeletion(
            formatVersion: Self.stateFormatVersion, deletion: deletion)
        let data = try encode(stored)
        let directory = rootURL.appendingPathComponent(
            Self.trashDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(
            to: directory.appendingPathComponent(Self.deletionFileName),
            options: Self.atomicWriteOptions)
    }

    private func removeToolFile(id: String) throws {
        let url = toolFileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func removeDeletion() throws {
        let url =
            rootURL
            .appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.deletionFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func toolFileURL(for id: String) -> URL {
        rootURL
            .appendingPathComponent(Self.toolsDirectoryName, isDirectory: true)
            .appendingPathComponent(id + Self.toolFileSuffix)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static var atomicWriteOptions: Data.WritingOptions {
        #if os(iOS)
            // The keyboard extension reads tools while the device is locked, so complete
            // protection would make the list unreadable there.
            [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
            .atomic
        #endif
    }

    // MARK: - Helpers

    private func index(of identifier: String, in entries: [ToolStoreEntry]) throws -> Int {
        guard let index = entries.firstIndex(where: { $0.id == identifier }) else {
            throw ToolStoreError.toolNotFound(id: identifier)
        }
        return index
    }

    private func storeImported(_ definition: ToolDefinition) throws -> ToolImportOutcome {
        let surface = try readSurface()
        if builtins.contains(where: { $0.id == definition.id }) {
            throw ToolStoreError.identifierReservedForBuiltin(id: definition.id)
        }
        let existed = surface.entries.contains { $0.id == definition.id }
        _ = try persistUserDefinition(definition, in: surface)
        return existed ? .updated(definition) : .inserted(definition)
    }

    private func persistUserDefinition(_ definition: ToolDefinition, in surface: Surface) throws -> [ToolStoreEntry] {
        let previous = surface.entries.first { $0.id == definition.id }?.definition
        var entries = surface.entries
        apply(definition, to: &entries)
        do {
            try writeTool(definition)
        } catch let error as ToolDefinitionError {
            throw ToolStoreError.definitionInvalid(error)
        }
        do {
            try writeState(entries: entries)
        } catch {
            // A metadata failure must not expose a definition that the caller was told did not save.
            if let previous {
                try writeTool(previous)
            } else {
                try removeToolFile(id: definition.id)
            }
            throw error
        }
        return entries
    }

    private func apply(_ definition: ToolDefinition, to entries: inout [ToolStoreEntry]) {
        if let index = entries.firstIndex(where: { $0.id == definition.id }) {
            let previous = entries[index]
            entries[index] = ToolStoreEntry(
                definition: definition, isBuiltin: false, isEnabled: previous.isEnabled,
                isPinned: previous.isPinned)
        } else {
            entries.append(
                ToolStoreEntry(
                    definition: definition, isBuiltin: false, isEnabled: true, isPinned: false))
        }
    }

    /// A copy never reuses an identifier; the author's names are kept so the copy looks exactly
    /// like the example until the user renames it.
    private func freshIdentifier(existing: Set<String>) -> String {
        while true {
            let candidate =
                "copy-"
                + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            if !existing.contains(candidate),
                !builtins.contains(where: { $0.id == candidate })
            {
                return candidate
            }
        }
    }
}
