import CryptoKit
import Darwin
import Foundation

/// Durable per-source learning exports, independent of the manual transfer's single output slot.
/// Only exported text archives live here; live Rime databases are never copied between processes.
public struct LearningSnapshotStore: Sendable {
    public static let directoryName = "LearningSnapshots"
    public static let automaticICloudBackupKey = "backup.automaticICloud.v1"
    /// Uploading backups to iCloud on its own is opt-in: handing the user's data to Apple is their
    /// choice. Local backups and snapshots never leave the device and do not depend on it.
    public static func automaticICloudBackupEnabled(_ defaults: UserDefaults?) -> Bool {
        defaults?.object(forKey: automaticICloudBackupKey) as? Bool == true
    }
    public let root: URL
    public init(root: URL) { self.root = root }

    public struct PendingRestore: Codable, Sendable {
        public let file: String
        public var requestID: UUID?
        public var targetSourceID: String? = nil
        public var targetRevision: String? = nil
        public var waitingForDependency: Bool? = nil
    }

    public func save(_ archive: LearningBackupArchive) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        defer { flock(fd, LOCK_UN) }
        if let existing = try snapshot(sourceID: archive.sourceID, revision: archive.resourceRevision) {
            if existing.createdAt > archive.createdAt || existing.dictionaries == archive.dictionaries { return }
        }
        let directory = root.appendingPathComponent("archives")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try archive.encoded().write(
            to: directory.appendingPathComponent(Self.filename(archive.sourceID, archive.resourceRevision)),
            options: .atomic)
    }

    // MARK: Raw copies

    /// Where the keyboard leaves its copies of the learning databases. The app turns each into an
    /// archive with its own engine, so the keyboard never sets its engine aside for a snapshot.
    public static let rawDirectoryName = "raw"

    /// One copy of a source's learning databases, as the keyboard took it.
    public struct RawCopy: Codable, Equatable, Sendable {
        public let sourceID: String
        public let revision: String
        public let sourceName: String
        public let copiedAt: Date
        /// The user directory to point a temporary engine at; holds only the copied databases.
        public var directory: URL = URL(fileURLWithPath: "/")

        enum CodingKeys: String, CodingKey { case sourceID, revision, sourceName, copiedAt }
    }

    /// Copies the learning databases in `userDirectory` (its `*.userdb` folders) for the app to
    /// convert. The engine keeps running: a learning database only appends and adds files, and a
    /// copy whose tail was mid-write opens without that last record. A copy taken while the
    /// database rewrote its files (the listing changed under it) is taken again.
    public func saveRawCopy(sourceID: String, revision: String, sourceName: String, userDirectory: URL, now: Date)
        throws
    {
        let fm = FileManager.default
        let raw = root.appendingPathComponent(Self.rawDirectoryName)
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        let name = (Self.filename(sourceID, revision) as NSString).deletingPathExtension
        for _ in 0..<3 {
            let before = try Self.databaseListing(userDirectory)
            guard !before.isEmpty else { return }
            let staging = raw.appendingPathComponent(".copy-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                for database in Set(before.keys.map { $0.components(separatedBy: "/")[0] }) {
                    try fm.copyItem(
                        at: userDirectory.appendingPathComponent(database), to: staging.appendingPathComponent(database)
                    )
                }
                guard
                    try Self.databaseListing(userDirectory).filter({ !$0.key.hasSuffix(".log") })
                        == before.filter({ !$0.key.hasSuffix(".log") })
                else {
                    try? fm.removeItem(at: staging)
                    continue
                }
                let copy = RawCopy(sourceID: sourceID, revision: revision, sourceName: sourceName, copiedAt: now)
                try JSONEncoder().encode(copy).write(to: staging.appendingPathComponent("copy.json"), options: .atomic)
                let target = raw.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: staging, to: target)
                return
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }
    }

    /// The copies waiting to be turned into archives.
    public func rawCopies() throws -> [RawCopy] {
        let raw = root.appendingPathComponent(Self.rawDirectoryName)
        guard FileManager.default.fileExists(atPath: raw.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: raw, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { directory in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("copy.json")),
                    var copy = try? JSONDecoder().decode(RawCopy.self, from: data)
                else { return nil }
                copy.directory = directory
                return copy
            }
    }

    public func discardRawCopy(_ copy: RawCopy) throws {
        guard
            copy.directory.deletingLastPathComponent().standardizedFileURL
                == root.appendingPathComponent(Self.rawDirectoryName).standardizedFileURL
        else { return }
        try FileManager.default.removeItem(at: copy.directory)
    }

    /// Every file of the `*.userdb` folders with its size, keyed by `folder/file`.
    private static func databaseListing(_ userDirectory: URL) throws -> [String: Int] {
        let fm = FileManager.default
        var listing: [String: Int] = [:]
        let folders = (try? fm.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.pathExtension == "userdb" {
            for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                listing[folder.lastPathComponent + "/" + file.lastPathComponent] = size
            }
        }
        return listing
    }

    public func saveSafety(_ archive: LearningBackupArchive) throws {
        let directory = root.appendingPathComponent("safety")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(Self.filename(archive.sourceID, archive.resourceRevision))
        let data = try archive.encoded()
        if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
    }

    public func snapshots() throws -> [LearningBackupArchive] {
        let directory = root.appendingPathComponent("archives")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])
        guard files.count <= 1000 else { throw LearningBackupArchiveError.encodedTooLarge(bytes: files.count) }
        return try files.filter { $0.pathExtension == "json" }.map { try read($0) }
    }

    public func snapshot(sourceID: String, revision: String) throws -> LearningBackupArchive? {
        let file = root.appendingPathComponent("archives").appendingPathComponent(Self.filename(sourceID, revision))
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try read(file)
    }

    /// Called only after the user confirms restoring a complete configuration backup.
    public func prepareRestore(waitingForDependencies: Bool = false) throws {
        let pending = try snapshots().map {
            PendingRestore(
                file: Self.filename($0.sourceID, $0.resourceRevision), requestID: nil,
                waitingForDependency: waitingForDependencies ? true : nil)
        }
        try writePending(pending)
    }

    /// A configuration restore may rebuild the same source under a new resource revision.
    /// The host calls this only after verifying its identity and installing/publishing it.
    /// Move the newest unsubmitted snapshot; never retry an already attempted merge.
    public func retargetPendingRestore(sourceID: String, revision: String) throws {
        try withPendingLock { try retargetWhileLocked(sourceID: sourceID, revision: revision) }
    }

    private func retargetWhileLocked(sourceID: String, revision: String) throws {
        var pending = try pendingRestores()
        var matching: [(PendingRestore, LearningBackupArchive)] = []
        for item in pending {
            guard item.file.range(of: "^[0-9a-f]{64}\\.json$", options: .regularExpression) != nil else {
                throw LearningBackupArchiveError.malformedArchive
            }
            let archive = try read(root.appendingPathComponent("archives").appendingPathComponent(item.file))
            if archive.sourceID == sourceID { matching.append((item, archive)) }
        }
        guard !matching.contains(where: { $0.0.requestID != nil }),
            let newest = matching.max(by: { $0.1.createdAt < $1.1.createdAt })
        else { return }
        let oldNames = Set(matching.map { $0.0.file })
        pending.removeAll { oldNames.contains($0.file) }
        // Keep the original bytes separate from new exports of the rebuilt installation.
        pending.append(
            PendingRestore(
                file: newest.0.file, requestID: nil,
                targetSourceID: sourceID, targetRevision: revision))
        try writePending(pending)
    }

    public func pendingRestores() throws -> [PendingRestore] {
        let file = root.appendingPathComponent("pending.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 256 * 1024 else {
            throw LearningBackupArchiveError.encodedTooLarge(bytes: 256 * 1024)
        }
        return try JSONDecoder().decode([PendingRestore].self, from: Data(contentsOf: file))
    }

    /// The extension submits at most once. Failed/interrupted merges remain visible in the
    /// manual transfer UI and are not automatically repeated (a merge may have partially run).
    public func advanceRestore(sourceID: String, revision: String, transfer: LearningTransferStore) throws -> Bool {
        try withPendingLock { try advanceWhileLocked(sourceID: sourceID, revision: revision, transfer: transfer) }
    }

    private func advanceWhileLocked(sourceID: String, revision: String, transfer: LearningTransferStore) throws -> Bool
    {
        var pending = try pendingRestores()
        let name = Self.filename(sourceID, revision)
        guard
            let index = pending.firstIndex(where: {
                $0.targetRevision == nil
                    ? $0.file == name : ($0.targetSourceID == sourceID && $0.targetRevision == revision)
            })
        else { return false }
        guard pending[index].waitingForDependency != true else { return true }
        let current = try transfer.read()
        if let requestID = pending[index].requestID {
            if current?.id == requestID, current?.status == .succeeded {
                pending.remove(at: index)
                try writePending(pending)
                return false
            }
            return true
        }
        guard current?.status != .pending, current?.status != .running else { return true }
        let file = pending[index].file
        guard file.range(of: "^[0-9a-f]{64}\\.json$", options: .regularExpression) != nil else {
            throw LearningBackupArchiveError.malformedArchive
        }
        let original = try read(root.appendingPathComponent("archives").appendingPathComponent(file))
        guard original.sourceID == sourceID else { throw LearningBackupArchiveError.identityMismatch(field: .sourceID) }
        let archive = try LearningBackupArchive(
            producer: original.producer,
            sourceID: sourceID, resourceRevision: revision, sourceName: original.sourceName,
            engineVersion: original.engineVersion, createdAt: original.createdAt, dictionaries: original.dictionaries)
        // Persist intent before submitting. If interrupted in between, the item stays held for
        // explicit retry instead of silently applying the same learning data twice.
        pending[index].requestID = UUID()
        try writePending(pending)
        let request = try transfer.submitRestore(archive)
        pending[index].requestID = request.id
        try writePending(pending)
        return true
    }

    public func markAutomaticAttempt(sourceID: String, revision: String, date: Date) throws {
        let directory = root.appendingPathComponent("attempts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(date).write(
            to: directory.appendingPathComponent(Self.filename(sourceID, revision)), options: .atomic)
    }

    /// Taking a snapshot sets the keyboard's engine aside, so it is rare: by default at most one a
    /// day, and only when the learning data changed after the last attempt (the Android keyboard's
    /// rule). The user picks the interval in days; 0 turns automatic snapshots off.
    public static let automaticIntervalKey = "learning.automaticSnapshotDays.v1"
    public static let automaticIntervalChoices = [1, 3, 7, 0]
    public static let defaultAutomaticDays = 1

    public static func automaticDays(_ defaults: UserDefaults?) -> Int {
        let stored = defaults?.object(forKey: automaticIntervalKey) as? Int
        return stored.flatMap { automaticIntervalChoices.contains($0) ? $0 : nil } ?? defaultAutomaticDays
    }

    public func shouldAutomaticallyExport(
        sourceID: String, revision: String, now: Date, learningModifiedAt: Date?, days: Int = defaultAutomaticDays
    ) throws -> Bool {
        guard days > 0, let learningModifiedAt else { return false }
        let interval = TimeInterval(days) * 24 * 60 * 60
        let file = root.appendingPathComponent("attempts").appendingPathComponent(Self.filename(sourceID, revision))
        guard FileManager.default.fileExists(atPath: file.path) else { return true }
        let date = try JSONDecoder().decode(Date.self, from: Data(contentsOf: file))
        return now.timeIntervalSince(date) >= interval && learningModifiedAt > date
    }

    /// When the learning databases in `userDirectory` were last written; nil when there are none.
    public static func learningModifiedAt(userDirectory: URL) -> Date? {
        let fm = FileManager.default
        let databases = (try? fm.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: nil)) ?? []
        return databases.filter { $0.pathExtension == "userdb" }.flatMap { database in
            (try? fm.contentsOfDirectory(at: database, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    private func read(_ file: URL) throws -> LearningBackupArchive {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            (values.fileSize ?? 0) <= LearningBackupArchive.maximumEncodedBytes
        else { throw LearningBackupArchiveError.encodedTooLarge(bytes: values.fileSize ?? 0) }
        return try LearningBackupArchive.decode(Data(contentsOf: file))
    }

    private func writePending(_ pending: [PendingRestore]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(pending).write(to: root.appendingPathComponent("pending.json"), options: .atomic)
    }

    private func withPendingLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(
            root.appendingPathComponent(".pending.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }

    private static func filename(_ source: String, _ revision: String) -> String {
        SHA256.hash(data: Data("\(source)\n\(revision)".utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }
}
