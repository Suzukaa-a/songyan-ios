import CryptoKit
import Foundation
import ZIPFoundation

/// Portable, versioned backups. Destinations are chosen by the app, never by paths in an archive.
public enum ConfigurationBackupDomain: String, Codable, CaseIterable, Sendable {
    case schemes, dictionaries, rimeConfig, rimeConfigState, recipes
    case layouts, symbols, quickContent, appearance, hints, options, learning, preferences, dependencies
}

public struct ConfigurationBackupManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let domain: ConfigurationBackupDomain
        public let path: String
        public let bytes: Int64
        public let sha256: String
        public var archivePath: String { "payload/\(domain.rawValue)/\(path)" }
        public var blobPath: String { "blobs/\(sha256)" }
    }
    public let format: String
    public let version: Int
    public let id: UUID
    public let createdAt: Date
    public let appVersion: String
    public let presentDomains: [ConfigurationBackupDomain]
    public let files: [File]
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    /// Ignores creation time so automatic backup can skip unchanged content.
    public var contentDigest: String {
        let lines =
            presentDomains.map(\.rawValue).sorted()
            + files.map {
                "\($0.archivePath):\($0.bytes):\($0.sha256)"
            }.sorted()
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ConfigurationBackupError: LocalizedError {
    case invalidArchive, limitExceeded, changedDuringBackup, unsafeFile
    public var errorDescription: String? {
        switch self {
        case .invalidArchive: PackageText.string("backup.error.invalidArchive")
        case .limitExceeded: PackageText.string("backup.error.limitExceeded")
        case .changedDuringBackup: PackageText.string("backup.error.changedDuringBackup")
        case .unsafeFile: PackageText.string("backup.error.unsafeFile")
        }
    }
}

public enum ConfigurationBackupArchive {
    public static let maximumBytes: Int64 = 12 * 1024 * 1024 * 1024
    public static let maximumFileBytes: Int64 = 3 * 1024 * 1024 * 1024
    public static let maximumFiles = 50_000
    private static let maximumManifestBytes = 24 * 1024 * 1024

    public static func changeStamp(
        sources: [ConfigurationBackupDomain: URL],
        include: (ConfigurationBackupDomain, String) -> Bool = { _, _ in true }
    ) throws -> String {
        let value = try inventory(sources, include: include)
        let lines =
            value.domains.map(\.rawValue)
            + value.files.map {
                "\($0.domain.rawValue)/\($0.path):\($0.bytes):\($0.modified?.timeIntervalSince1970 ?? 0):\($0.identifier)"
            }
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Captures to a private staging directory before compression. A concurrent replacement or
    /// publication invalidates the attempt instead of producing a mixed-generation backup.
    public static func create(
        sources: [ConfigurationBackupDomain: URL], destination: URL, appVersion: String,
        include: (ConfigurationBackupDomain, String) -> Bool = { _, _ in true },
        version: Int = 1
    ) throws -> ConfigurationBackupManifest {
        guard (1...2).contains(version) else { throw ConfigurationBackupError.invalidArchive }
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".capture-\(UUID())")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let before = try inventory(sources, include: include)
        var files: [ConfigurationBackupManifest.File] = []
        var total: Int64 = 0
        for item in before.files {
            try Task.checkCancellation()
            let relative = "payload/\(item.domain.rawValue)/\(item.path)"
            let copy = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: item.url, to: copy)
            let copied = try copy.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard copied.isRegularFile == true, copied.isSymbolicLink != true else {
                throw ConfigurationBackupError.unsafeFile
            }
            let (size, digest) = try hash(copy)
            total += size
            guard total <= maximumBytes else { throw ConfigurationBackupError.limitExceeded }
            guard size == item.bytes else { throw ConfigurationBackupError.changedDuringBackup }
            files.append(.init(domain: item.domain, path: item.path, bytes: size, sha256: digest))
        }
        guard before == (try inventory(sources, include: include)) else {
            throw ConfigurationBackupError.changedDuringBackup
        }
        let manifest = ConfigurationBackupManifest(
            format: "songyan-configuration", version: version, id: UUID(), createdAt: Date(),
            appVersion: appVersion, presentDomains: before.domains, files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= maximumManifestBytes else { throw ConfigurationBackupError.limitExceeded }
        try data.write(to: staging.appendingPathComponent("manifest.json"))
        do {
            let zip = try Archive(url: destination, accessMode: .create)
            try zip.addEntry(with: "manifest.json", relativeTo: staging, compressionMethod: .deflate)
            var written = Set<String>()
            for file in files where written.insert(file.blobPath).inserted {
                try Task.checkCancellation()
                try zip.addEntry(
                    with: file.blobPath, fileURL: staging.appendingPathComponent(file.archivePath),
                    compressionMethod: .deflate)
            }
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        return manifest
    }

    /// Extracts only after validating the entire directory. Every payload is size-, CRC- and
    /// SHA-256-checked. Callers must use a fresh private directory, never a live configuration root.
    public static func extract(_ source: URL, to staging: URL) throws -> ConfigurationBackupManifest {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: staging.path) else { throw ConfigurationBackupError.unsafeFile }
        let sourceSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard sourceSize > 0, Int64(sourceSize) <= maximumBytes else { throw ConfigurationBackupError.limitExceeded }
        let zip = try Archive(url: source, accessMode: .read)
        var entries: [String: Entry] = [:]
        var folded = Set<String>()
        for entry in zip {
            guard entry.type == .file, safePath(entry.path),
                folded.insert(entry.path.lowercased()).inserted,
                entries.count <= maximumFiles,
                entry.uncompressedSize <= UInt64(maximumFileBytes)
            else { throw ConfigurationBackupError.invalidArchive }
            entries[entry.path] = entry
        }
        guard let header = entries.removeValue(forKey: "manifest.json"),
            header.uncompressedSize <= maximumManifestBytes
        else { throw ConfigurationBackupError.invalidArchive }
        var headerData = Data()
        let crc = try zip.extract(header) { bytes in
            guard headerData.count + bytes.count <= maximumManifestBytes else {
                throw ConfigurationBackupError.limitExceeded
            }
            headerData.append(bytes)
        }
        guard crc == header.checksum else { throw ConfigurationBackupError.invalidArchive }
        let manifest = try JSONDecoder().decode(ConfigurationBackupManifest.self, from: headerData)
        guard manifest.format == "songyan-configuration", (1...2).contains(manifest.version),
            manifest.files.count <= maximumFiles,
            Set(manifest.presentDomains).count == manifest.presentDomains.count,
            Set(manifest.files.map { $0.archivePath.precomposedStringWithCanonicalMapping.lowercased() }).count
                == manifest.files.count,
            Set(manifest.files.map(\.blobPath)).count == entries.count
        else { throw ConfigurationBackupError.invalidArchive }
        var total: Int64 = 0
        for file in manifest.files {
            guard safePath(file.path), manifest.presentDomains.contains(file.domain),
                file.bytes >= 0, file.bytes <= maximumFileBytes,
                file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                let entry = entries[file.blobPath], entry.uncompressedSize == UInt64(file.bytes)
            else { throw ConfigurationBackupError.invalidArchive }
            total += file.bytes
            guard total <= maximumBytes else { throw ConfigurationBackupError.limitExceeded }
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for domain in manifest.presentDomains {
                try fm.createDirectory(
                    at: staging.appendingPathComponent(domain.rawValue), withIntermediateDirectories: true)
            }
            var extracted: [String: URL] = [:]
            for file in manifest.files {
                try Task.checkCancellation()
                let output = staging.appendingPathComponent(file.domain.rawValue).appendingPathComponent(file.path)
                try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let existing = extracted[file.blobPath] {
                    try fm.copyItem(at: existing, to: output)
                    continue
                }
                guard fm.createFile(atPath: output.path, contents: nil) else {
                    throw ConfigurationBackupError.unsafeFile
                }
                let handle = try FileHandle(forWritingTo: output)
                defer { try? handle.close() }
                var count: Int64 = 0
                var digest = SHA256()
                let checksum = try zip.extract(entries[file.blobPath]!) { bytes in
                    try Task.checkCancellation()
                    count += Int64(bytes.count)
                    guard count <= file.bytes else { throw ConfigurationBackupError.invalidArchive }
                    digest.update(data: bytes)
                    try handle.write(contentsOf: bytes)
                }
                guard count == file.bytes, checksum == entries[file.blobPath]!.checksum,
                    digest.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256
                else { throw ConfigurationBackupError.invalidArchive }
                extracted[file.blobPath] = output
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return manifest
    }

    public static func safePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 2048 && !path.hasPrefix("/") && !path.contains("\\")
            && !path.unicodeScalars.contains(where: { $0.value < 32 })
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private struct Item: Equatable {
        let domain: ConfigurationBackupDomain
        let path: String
        let url: URL
        let bytes: Int64
        let modified: Date?
        let identifier: String
    }
    private struct Inventory: Equatable {
        let domains: [ConfigurationBackupDomain]
        let files: [Item]
    }

    private static func inventory(
        _ sources: [ConfigurationBackupDomain: URL],
        include: (ConfigurationBackupDomain, String) -> Bool
    ) throws -> Inventory {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
        ]
        var domains: [ConfigurationBackupDomain] = []
        var items: [Item] = []
        for domain in ConfigurationBackupDomain.allCases {
            guard let source = sources[domain], fm.fileExists(atPath: source.path) else { continue }
            let info = try source.resourceValues(forKeys: keys)
            guard info.isDirectory == true, info.isSymbolicLink != true else {
                throw ConfigurationBackupError.unsafeFile
            }
            // Foundation's enumerator canonicalizes /var to /private/var on Apple platforms.
            // Calculate relative paths from the same canonical root, never by mismatched lengths.
            let root = source.resolvingSymlinksInPath().standardizedFileURL
            domains.append(domain)
            var failure: Error?
            guard
                let enumerator = fm.enumerator(
                    at: root, includingPropertiesForKeys: Array(keys),
                    errorHandler: { _, error in
                        failure = error
                        return false
                    })
            else { throw ConfigurationBackupError.unsafeFile }
            for case let file as URL in enumerator {
                let normalized = file.standardizedFileURL
                guard normalized.path.hasPrefix(root.path + "/") else { throw ConfigurationBackupError.unsafeFile }
                let path = String(normalized.path.dropFirst(root.path.count + 1))
                let values = try file.resourceValues(forKeys: keys)
                guard include(domain, path) else {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                guard safePath(path) else { throw ConfigurationBackupError.unsafeFile }
                guard values.isSymbolicLink != true else { throw ConfigurationBackupError.unsafeFile }
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true else { throw ConfigurationBackupError.unsafeFile }
                let attributes = try fm.attributesOfItem(atPath: file.path)
                let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                guard bytes <= maximumFileBytes, items.count < maximumFiles else {
                    throw ConfigurationBackupError.limitExceeded
                }
                items.append(
                    Item(
                        domain: domain, path: path, url: file, bytes: bytes,
                        modified: attributes[.modificationDate] as? Date,
                        identifier: String(describing: attributes[.systemFileNumber])))
            }
            if let failure { throw failure }
        }
        return Inventory(
            domains: domains,
            files: items.sorted { "\($0.domain.rawValue)/\($0.path)" < "\($1.domain.rawValue)/\($1.path)" })
    }

    private static func hash(_ url: URL) throws -> (Int64, String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            size += Int64(chunk.count)
            guard size <= maximumFileBytes else { throw ConfigurationBackupError.limitExceeded }
            digest.update(data: chunk)
        }
        return (size, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
