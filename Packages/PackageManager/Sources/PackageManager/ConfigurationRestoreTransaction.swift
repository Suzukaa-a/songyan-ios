import Foundation

/// Replacements are copied beside each destination first. A durable journal allows startup to
/// roll back an interrupted restore before loading any managers. Destination URLs are supplied
/// by the app on both paths; an archive or journal cannot choose arbitrary filesystem paths.
public enum ConfigurationRestoreTransaction {
    public struct Replacement: Sendable {
        public let key: String
        public let source: URL?
        public let destination: URL
        public init(key: String, source: URL?, destination: URL) {
            self.key = key
            self.source = source
            self.destination = destination
        }
    }
    private struct Entry: Codable {
        let key: String
        let hadOriginal: Bool
    }
    private struct Journal: Codable {
        let id: UUID
        let entries: [Entry]
        var committed: Bool
    }

    public static func install(_ replacements: [Replacement], journalURL: URL) throws {
        let fm = FileManager.default
        let targets = Dictionary(uniqueKeysWithValues: replacements.map { ($0.key, $0.destination) })
        try recover(journalURL: journalURL, destinations: targets)
        let id = UUID()
        let entries = replacements.map { Entry(key: $0.key, hadOriginal: fm.fileExists(atPath: $0.destination.path)) }
        var journal = Journal(id: id, entries: entries, committed: false)
        do {
            for item in replacements {
                try Task.checkCancellation()
                try fm.createDirectory(
                    at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let source = item.source {
                    try fm.copyItem(at: source, to: sibling(item.destination, id: id, suffix: "new"))
                }
            }
            try fm.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            for item in replacements {
                try Task.checkCancellation()
                if fm.fileExists(atPath: item.destination.path) {
                    try fm.moveItem(at: item.destination, to: sibling(item.destination, id: id, suffix: "old"))
                }
                if item.source != nil {
                    try fm.moveItem(at: sibling(item.destination, id: id, suffix: "new"), to: item.destination)
                }
            }
            journal.committed = true
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        } catch {
            // A failed rollback keeps the journal for next startup. Never report success or
            // erase the only old copy after an incomplete file operation.
            if fm.fileExists(atPath: journalURL.path) {
                try recover(journalURL: journalURL, destinations: targets)
            } else {
                for item in replacements { try? fm.removeItem(at: sibling(item.destination, id: id, suffix: "new")) }
            }
            throw error
        }
        try recover(journalURL: journalURL, destinations: targets)
    }

    public static func recover(journalURL: URL, destinations: [String: URL]) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: journalURL.path) else { return }
        let size = try journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 else { throw ConfigurationBackupError.invalidArchive }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        guard journal.entries.count <= destinations.count,
            Set(journal.entries.map(\.key)).count == journal.entries.count,
            journal.entries.allSatisfy({ destinations[$0.key] != nil })
        else { throw ConfigurationBackupError.invalidArchive }
        for entry in journal.entries.reversed() {
            let target = destinations[entry.key]!
            let old = sibling(target, id: journal.id, suffix: "old")
            let new = sibling(target, id: journal.id, suffix: "new")
            if !journal.committed {
                if fm.fileExists(atPath: old.path) {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.moveItem(at: old, to: target)
                } else if !entry.hadOriginal, fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
            } else if fm.fileExists(atPath: old.path) {
                try fm.removeItem(at: old)
            }
            if fm.fileExists(atPath: new.path) { try fm.removeItem(at: new) }
        }
        try fm.removeItem(at: journalURL)
    }

    private static func sibling(_ target: URL, id: UUID, suffix: String) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(
            ".songyan-restore-\(id)-\(target.lastPathComponent).\(suffix)")
    }
}
