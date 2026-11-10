import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public struct CommonPhrase: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var shortcut: String
    public init(id: UUID = UUID(), text: String, shortcut: String = "") {
        self.id = id
        self.text = text
        self.shortcut = shortcut
    }
    public func matches(_ query: String) -> Bool {
        let value = SymbolSearch.normalize(query)
        return value.isEmpty || SymbolSearch.normalize(text).contains(value)
            || SymbolSearch.normalize(shortcut).contains(value)
    }
}

public struct LocalQuickContent: Codable, Equatable, Sendable {
    public var version = 1
    public var phrases: [CommonPhrase] = []
    public init() {}
}

/// Local-only storage with no backup copy. Files written by older versions may still carry a
/// clipboard history; it is ignored on decode and dropped on the next save.
/// A file lock serializes host/extension read-modify-write transactions across processes.
public struct LocalQuickContentStore: Sendable {
    public static let directoryName = "LocalQuickContent"
    public static let maximumPhrases = 100
    public static let maximumTextBytes = 4096
    public static let maximumFileBytes = 1024 * 1024
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var file: URL { directory.appendingPathComponent("content.json") }

    public func read() throws -> LocalQuickContent {
        // Missing storage is a disabled, empty state, with no write as a side effect.
        guard FileManager.default.fileExists(atPath: directory.path) else { return LocalQuickContent() }
        return try load()
    }

    @discardableResult
    public func savePhrase(_ phrase: CommonPhrase) throws -> LocalQuickContent {
        try mutate { state in
            if let index = state.phrases.firstIndex(where: { $0.id == phrase.id }) {
                state.phrases[index] = phrase
            } else {
                state.phrases.append(phrase)
            }
        }
    }

    @discardableResult
    public func deletePhrase(_ id: UUID) throws -> LocalQuickContent {
        try mutate { $0.phrases.removeAll { $0.id == id } }
    }

    public func exportPhrases() throws -> Data {
        try Self.encode(PhraseArchive(phrases: read().phrases))
    }

    @discardableResult
    public func importPhrases(_ data: Data) throws -> LocalQuickContent {
        guard data.count <= Self.maximumFileBytes else {
            throw SymbolCatalogError(QuickContentText.string("quickContent.error.fileTooLarge"))
        }
        let archive: PhraseArchive
        do { archive = try JSONDecoder().decode(PhraseArchive.self, from: data) } catch {
            throw SymbolCatalogError(QuickContentText.string("quickContent.error.unreadable"))
        }
        guard archive.version == 1 else {
            throw SymbolCatalogError(QuickContentText.string("quickContent.error.unsupportedFormat"))
        }
        try Self.validatePhrases(archive.phrases)
        return try mutate { $0.phrases = archive.phrases }
    }

    /// The caller owns security-scoped access while this bounded descriptor read runs.
    @discardableResult
    public func importPhrases(from url: URL) throws -> LocalQuickContent {
        let data = try QuickContentFileReader.read(
            url, maximumBytes: Self.maximumFileBytes,
            sizeError: QuickContentText.string("quickContent.error.fileTooLarge"))
        return try importPhrases(data)
    }

    private struct PhraseArchive: Codable {
        var version = 1
        var phrases: [CommonPhrase]
    }

    private func mutate(_ body: (inout LocalQuickContent) throws -> Void) throws -> LocalQuickContent {
        try locked {
            var state = try load()
            try body(&state)
            try save(state)
            return state
        }
    }

    private func load() throws -> LocalQuickContent {
        guard FileManager.default.fileExists(atPath: file.path) else { return LocalQuickContent() }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        guard size <= Self.maximumFileBytes else {
            throw SymbolCatalogError(QuickContentText.string("quickContent.error.storedTooLarge"))
        }
        let data = try Data(contentsOf: file)
        let state = try JSONDecoder().decode(LocalQuickContent.self, from: data)
        try Self.validate(state)
        return state
    }

    private func save(_ state: LocalQuickContent) throws {
        try Self.validate(state)
        let data = try Self.encode(state)
        guard data.count <= Self.maximumFileBytes else {
            throw SymbolCatalogError(QuickContentText.string("quickContent.error.contentTooLarge"))
        }
        #if os(iOS)
            // Readable after first unlock: the keyboard is used over a locked screen too, and
            // complete protection would make phrases unreadable there.
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: file, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(excluded)
        let descriptor = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw SymbolCatalogError(QuickContentText.string("quickContent.error.storageUnavailable"))
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw SymbolCatalogError(QuickContentText.string("quickContent.error.busy"))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func validateText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            text.utf8.count <= maximumTextBytes, !text.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw SymbolCatalogError(QuickContentText.string("quickContent.error.textInvalid"))
        }
    }

    private static func validatePhrases(_ phrases: [CommonPhrase]) throws {
        guard phrases.count <= maximumPhrases, Set(phrases.map(\.id)).count == phrases.count else {
            throw SymbolCatalogError(QuickContentText.string("quickContent.error.tooManyPhrases"))
        }
        for phrase in phrases {
            try validateText(phrase.text)
            guard phrase.shortcut.utf8.count <= 64 else {
                throw SymbolCatalogError(QuickContentText.string("quickContent.error.shortcutTooLong"))
            }
        }
    }

    private static func validate(_ state: LocalQuickContent) throws {
        guard state.version == 1 else {
            throw SymbolCatalogError(QuickContentText.string("quickContent.error.storedUnreadable"))
        }
        try validatePhrases(state.phrases)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}
