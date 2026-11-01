import Foundation

// MARK: - Finding `.userdb.txt` snapshots in what the user picked
//
// A single picked file is recognised by its content, whatever its name; inside a ZIP or a folder
// only files named `*.userdb.txt` count, because sync folders also hold installation and
// configuration files. The user's files are only read.
//
// Bounds follow the learning backup archive the snapshots are sent in (the keyboard extension reads
// it in memory): at most `maximumFiles` snapshots, `maximumFileBytes` each and `maximumTotalBytes`
// together. One snapshot over the per-file bound is skipped; a pick over the other bounds is refused whole.

/// A file the user picked, or a file found in a picked folder.
public struct PickedFile: Sendable {
    /// Shown to the user as it is.
    public let name: String
    /// Reads at most `limit` bytes; returns nil when the file is larger.
    public let read: @Sendable (_ limit: Int) throws -> Data?

    public init(name: String, read: @escaping @Sendable (_ limit: Int) throws -> Data?) {
        self.name = name
        self.read = read
    }
}

/// A picked folder or one of its entries.
public protocol PickedNode: Sendable {
    var name: String { get }
    var isDirectory: Bool { get }
    func children() throws -> [PickedNode]
    func file() -> PickedFile
}

/// A folder or file on disk. Symbolic links and anything that is not a plain file or folder are ignored.
public struct DiskPickedNode: PickedNode {
    public let url: URL
    public let isDirectory: Bool

    public init?(url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { return nil }
        if values?.isDirectory == true {
            isDirectory = true
        } else if values?.isRegularFile == true {
            isDirectory = false
        } else {
            return nil
        }
        self.url = url
    }

    public var name: String { url.lastPathComponent }

    public func children() throws -> [PickedNode] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .compactMap { DiskPickedNode(url: $0) }
    }

    public func file() -> PickedFile {
        let url = url
        return PickedFile(name: url.lastPathComponent) { limit in
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit { return nil }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // One byte more than the limit tells a file that grew after the size check.
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            return data.count > limit ? nil : data
        }
    }
}

/// Why a picked file is not merged. A dictionary the input scheme in use does not learn into is
/// only known to the keyboard extension, which skips it when it merges.
public enum SnapshotSkipReason: Equatable, Sendable {
    /// Not a Rime user dictionary snapshot, or damaged.
    case notASnapshot
    /// Larger than `RimeSnapshotCollector.maximumFileBytes`.
    case tooLarge
    /// A snapshot without a single entry.
    case empty
}

public struct CollectedSnapshot: Equatable, Sendable {
    /// The picked file (or the ZIP entry's base name) it came from.
    public let fileName: String
    public let dictionary: String
    public let entryCount: Int
    /// The snapshot without a BOM.
    public let data: Data
}

public struct SkippedSnapshot: Equatable, Sendable {
    public let fileName: String
    public let reason: SnapshotSkipReason
}

public struct CollectedSnapshots: Equatable, Sendable {
    public let snapshots: [CollectedSnapshot]
    public let skipped: [SkippedSnapshot]

    public init(snapshots: [CollectedSnapshot], skipped: [SkippedSnapshot]) {
        self.snapshots = snapshots
        self.skipped = skipped
    }

    public static let empty = CollectedSnapshots(snapshots: [], skipped: [])
}

public enum RimeSnapshotCollector {
    public static let maximumFiles = LearningBackupArchive.maximumDictionaryCount
    public static let maximumFileBytes = LearningBackupArchive.maximumDictionaryBytes
    public static let maximumTotalBytes = LearningBackupArchive.maximumTotalDictionaryBytes
    /// A picked ZIP is read whole before its entries are inflated one by one.
    public static let maximumZipBytes = 32 * 1_024 * 1_024
    /// Entries a ZIP or folder walk looks at; a sync folder holds a few dozen.
    public static let maximumEntries = 4_096
    /// A sync folder is `sync/<installation>/<name>.userdb.txt`; one level more for the folder above it.
    public static let maximumDepth = 3

    /// The pick holds more snapshots or bytes than one import takes; nothing is collected.
    public struct TooLarge: Error, Equatable {}

    static let snapshotSuffix = ".userdb.txt"

    static func isSnapshotName(_ path: String) -> Bool {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        return !base.hasPrefix(".") && base.lowercased().hasSuffix(snapshotSuffix)
    }

    /// The files in a picked folder that may be snapshots, by name, at most `maximumDepth` levels down.
    public static func files(in root: PickedNode) throws -> [PickedFile] {
        var found: [PickedFile] = []
        var visited = 0

        func walk(_ node: PickedNode, depth: Int) throws {
            for child in try node.children().sorted(by: { $0.name < $1.name }) {
                visited += 1
                if visited > maximumEntries { throw TooLarge() }
                if child.name.hasPrefix(".") || child.name == "__MACOSX" { continue }
                if child.isDirectory {
                    if depth < maximumDepth { try walk(child, depth: depth + 1) }
                } else if isSnapshotName(child.name) {
                    found.append(child.file())
                    if found.count > maximumFiles { throw TooLarge() }
                }
            }
        }
        try walk(root, depth: 1)
        return found
    }

    /// Reads every snapshot in `files`. `byContent` says the files were picked one by one (a ZIP or a
    /// snapshot of any name); folder entries come from `files(in:)` and are read only as snapshots.
    public static func collect(files: [PickedFile], byContent: Bool) throws -> CollectedSnapshots {
        var run = Run()
        for file in files {
            guard let data = try file.read(byContent ? maximumZipBytes : maximumFileBytes) else {
                run.skipped.append(SkippedSnapshot(fileName: file.name, reason: .tooLarge))
                continue
            }
            if byContent && data.starts(with: BoundedZipReader.magic) {
                try run.addZip(named: file.name, data: data)
            } else {
                try run.add(name: file.name, data: data)
            }
        }
        return CollectedSnapshots(snapshots: run.snapshots, skipped: run.skipped)
    }

    private struct Run {
        var snapshots: [CollectedSnapshot] = []
        var skipped: [SkippedSnapshot] = []
        private var total = 0

        mutating func addZip(named zipName: String, data: Data) throws {
            let reader: BoundedZipReader
            do { reader = try BoundedZipReader(data: data) } catch BoundedZipReader.Failure.tooManyEntries {
                throw TooLarge()
            } catch {
                skipped.append(SkippedSnapshot(fileName: zipName, reason: .notASnapshot))
                return
            }
            let (snapshotsBefore, skippedBefore, totalBefore) = (snapshots.count, skipped.count, total)
            for entry in reader.entries where !entry.isDirectory {
                let parts = entry.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                guard let base = parts.last, parts.count - 1 < maximumDepth,
                    !parts.contains("__MACOSX"), !parts.contains(where: { $0.hasPrefix(".") }),
                    isSnapshotName(base)
                else { continue }
                do {
                    try add(name: base, data: reader.contents(of: entry, limit: maximumFileBytes))
                } catch BoundedZipReader.Failure.entryTooLarge {
                    skipped.append(SkippedSnapshot(fileName: base, reason: .tooLarge))
                } catch let error as TooLarge {
                    throw error
                } catch {
                    // A damaged archive is not worth merging half of.
                    snapshots.removeSubrange(snapshotsBefore...)
                    skipped.removeSubrange(skippedBefore...)
                    total = totalBefore
                    skipped.append(SkippedSnapshot(fileName: zipName, reason: .notASnapshot))
                    return
                }
            }
            if snapshots.count == snapshotsBefore && skipped.count == skippedBefore {
                skipped.append(SkippedSnapshot(fileName: zipName, reason: .notASnapshot))
            }
        }

        mutating func add(name: String, data: Data) throws {
            guard RimeUserDbText.looksLikeSnapshot(data.prefix(64)) else {
                skipped.append(SkippedSnapshot(fileName: name, reason: .notASnapshot))
                return
            }
            if data.count > maximumFileBytes {
                skipped.append(SkippedSnapshot(fileName: name, reason: .tooLarge))
                return
            }
            let body = RimeUserDbText.strippingBOM(data)
            let info: RimeUserDbSnapshotInfo
            do { info = try RimeUserDbText.inspect(body) } catch {
                skipped.append(SkippedSnapshot(fileName: name, reason: .notASnapshot))
                return
            }
            guard info.entryCount > 0 else {
                skipped.append(SkippedSnapshot(fileName: name, reason: .empty))
                return
            }
            // Only snapshots that will be merged count toward the limits.
            total += data.count
            if total > maximumTotalBytes || snapshots.count >= maximumFiles { throw TooLarge() }
            snapshots.append(
                CollectedSnapshot(
                    fileName: name, dictionary: info.dictionary, entryCount: info.entryCount, data: Data(body)))
        }
    }
}
