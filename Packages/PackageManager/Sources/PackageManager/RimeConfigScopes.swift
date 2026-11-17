import Foundation

/// Each installed input scheme package keeps its own Rime configuration: a folder below the 「Rime 配置」
/// root, named after the package so the Files app shows whose files they are. Editing one package's
/// files never changes what another package gets, as `default.custom.yaml`, a schema id two packages
/// share, or a script under `lua/` would if all of them read one folder.
///
/// Which folder belongs to which package is recorded in the app's private state (`folders.json`): the
/// folder keeps its name when the package is renamed or deleted, so reinstalling it brings the user's
/// files back. Folders in the root are the user's; a file directly in the root belongs to no package.
public struct RimeConfigScopes: Sendable {
    public let root: URL
    public let state: URL

    public init(root: URL, state: URL) {
        self.root = root
        self.state = state
    }

    /// A package that receives the user's configuration, and the name its folder gets.
    public struct Recipient: Equatable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    struct Record: Codable, Equatable {
        /// Package id to the folder's name in `root`.
        var folders: [String: String] = [:]
        /// Set while the files of the one shared folder are being copied into each package's folder;
        /// `legacy` lists the root's entries to copy, so a run cut short starts again from the same list.
        var migrating = false
        var legacy: [String] = []
    }

    static let recordName = "folders.json"
    /// Files of the one shared state the migration copies into each package's state.
    static let legacyStateFiles = ["overrides.json", "scripts-confirmed.json"]
    private static let lock = NSLock()

    var recordFile: URL { state.appendingPathComponent(Self.recordName) }

    /// The private state of package `id`: what the app knows about the files of its folder.
    public func stateDirectory(_ id: String) -> URL {
        state.appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(String(sha256Hex(Data(id.utf8)).prefix(32)), isDirectory: true)
    }

    /// The name of package `id`'s folder, or nil when it has none yet.
    public func folderName(_ id: String) -> String? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return read()?.folders[id]
    }

    /// Package `id`'s folder; with no folder yet one is named after `name()` (nil: none is made and
    /// nil is returned, for a package that is not installed).
    public func folder(_ id: String, name: () -> String?) throws -> URL? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // Until the shared folder is handed out (`migrate`), no package reads anything: one that took a
        // folder of its own now would never get its copy of the shared files.
        guard var record = read() ?? (rootNames().isEmpty && !hasLegacyState() ? Record() : nil) else {
            return nil
        }
        if let existing = record.folders[id] { return root.appendingPathComponent(existing, isDirectory: true) }
        guard let name = name() else { return nil }
        let taken = Set(record.folders.values.map { $0.lowercased() }).union(rootNames().map { $0.lowercased() })
        let folder = Self.folderName(for: name, id: id, taken: taken)
        record.folders[id] = folder
        try write(record)
        return root.appendingPathComponent(folder, isDirectory: true)
    }

    /// Whether the files still sit in the one folder every package shared.
    public func needsMigration() -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let record = read() else { return true }
        return record.migrating
    }

    /// Gives every package in `recipients` its own copy of what the one shared folder holds, so each gets
    /// exactly what it got before and edits diverge from here on. A file already in a package's folder is
    /// kept: it is newer than the shared copy. The shared files are removed only after every copy is
    /// complete, and a run cut short starts again from the same list. With no recipient nothing is
    /// removed: no package would get the files.
    public func migrate(recipients: [Recipient]) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var record: Record
        if let existing = read() {
            guard existing.migrating else { return }
            record = existing
        } else {
            record = Record(folders: [:], migrating: true, legacy: rootNames().sorted())
            if record.legacy.isEmpty, !hasLegacyState() {
                record.migrating = false
                try write(record)
                return
            }
        }
        let fm = FileManager.default
        for recipient in recipients.sorted(by: { $0.id < $1.id }) where record.folders[recipient.id] == nil {
            let taken = Set(record.folders.values.map { $0.lowercased() }).union(rootNames().map { $0.lowercased() })
            record.folders[recipient.id] = Self.folderName(for: recipient.name, id: recipient.id, taken: taken)
        }
        try write(record)
        for recipient in recipients {
            guard let name = record.folders[recipient.id] else { continue }
            let target = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for entry in record.legacy where entry != name {
                let source = root.appendingPathComponent(entry)
                guard fm.fileExists(atPath: source.path) else { continue }
                try Self.copyMissing(source, to: target.appendingPathComponent(entry))
            }
            let packageState = stateDirectory(recipient.id)
            try fm.createDirectory(at: packageState, withIntermediateDirectories: true)
            for file in Self.legacyStateFiles {
                let source = state.appendingPathComponent(file)
                guard fm.fileExists(atPath: source.path) else { continue }
                try Self.copyMissing(source, to: packageState.appendingPathComponent(file))
            }
        }
        if !recipients.isEmpty {
            let folders = Set(record.folders.values)
            for entry in record.legacy where !folders.contains(entry) {
                let url = root.appendingPathComponent(entry)
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            }
            for file in Self.legacyStateFiles {
                let url = state.appendingPathComponent(file)
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            }
        }
        record.migrating = false
        record.legacy = []
        try write(record)
    }

    /// A folder name the Files app shows as the package's name. Names that a backup would leave out
    /// (hidden, or a word the backup reserves for engine files) or that another folder already uses
    /// get a suffix, so every package's files travel with a backup under a name of their own.
    static func folderName(for name: String, id: String, taken: Set<String>) -> String {
        func clean(_ text: String) -> String {
            var scalars = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                if CharacterSet.controlCharacters.contains(scalar) { continue }
                scalars.append(["/", ":", "\\"].contains(scalar) ? "-" : scalar)
            }
            var result = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
            while result.hasPrefix(".") { result.removeFirst() }
            return String(result.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        var base = clean(name)
        if base.isEmpty { base = clean(id) }
        if base.isEmpty { base = "Rime" }
        let lower = base.lowercased()
        if ["build", "sync", "staging"].contains(lower) || lower.contains(".userdb") || lower.hasSuffix(".lock")
            || lower.hasSuffix(".log")
        {
            base += " Rime"
        }
        var candidate = base
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    private func hasLegacyState() -> Bool {
        Self.legacyStateFiles.contains { FileManager.default.fileExists(atPath: state.appendingPathComponent($0).path) }
    }

    /// The root's visible entries.
    private func rootNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    private func read() -> Record? {
        guard let data = try? Data(contentsOf: recordFile) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func write(_ record: Record) throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: recordFile, options: .atomic)
    }

    /// Copies `source` to `target`, file by file, leaving every file `target` already has. Links are not
    /// followed. A file is written through a temporary name, so a cut-short run never leaves half of one.
    private static func copyMissing(_ source: URL, to target: URL) throws {
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        if values.isSymbolicLink == true { return }
        if values.isDirectory == true {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for child in try fm.contentsOfDirectory(atPath: source.path) {
                try copyMissing(source.appendingPathComponent(child), to: target.appendingPathComponent(child))
            }
        } else if values.isRegularFile == true, !fm.fileExists(atPath: target.path) {
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".copy-\(UUID().uuidString)")
            try fm.copyItem(at: source, to: temporary)
            do {
                try fm.moveItem(at: temporary, to: target)
            } catch {
                try? fm.removeItem(at: temporary)
                throw error
            }
        }
    }

    /// What is installed in the store at `store`: its active generation and the name the package
    /// declares (nil when it declares none). Nil when nothing is installed there.
    public static func installedRecipient(store: URL) -> (generation: String?, declaredName: String?)? {
        guard let data = try? Data(contentsOf: store.appendingPathComponent(InstalledPackageLayout.activeMarker)),
            let active = try? JSONDecoder().decode(InstalledRecipe.self, from: data),
            !active.generation.isEmpty, !active.generation.contains("/"), !active.generation.hasPrefix(".")
        else { return nil }
        let generation = store.appendingPathComponent(InstalledPackageLayout.versionsDirectory, isDirectory: true)
            .appendingPathComponent(active.generation, isDirectory: true)
        let declaration =
            (try? Data(
                contentsOf: generation.appendingPathComponent(InstalledPackageLayout.resourcesDirectory)
                    .appendingPathComponent(InstalledPackageLayout.keyboardPackageFile)
            )).flatMap { try? JSONDecoder().decode(SchemePackageDeclaration.self, from: $0) }
        return (active.generation, declaration?.name)
    }
}
