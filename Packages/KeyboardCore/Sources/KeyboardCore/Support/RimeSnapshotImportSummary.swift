import Foundation

// MARK: - Import request and confirmation text for snapshots from other Rime front-ends
//
// Pure functions of a `CollectedSnapshots`: the host builds the request archive and the text the
// user confirms from the same value. The keyboard extension decides which dictionaries the input
// scheme in use learns into when it merges, so the confirmation can only promise that the rest is skipped.

public enum RimeSnapshotImportSummary {
    /// Dictionaries listed in the confirmation before the rest is folded into a count.
    static let listedDictionaries = 8
    static let listedSkippedFiles = 8

    /// The request archive for the keyboard extension. `sourceID` and `resourceRevision` are the identity
    /// of the input scheme in use, which the extension checks again before it merges.
    public static func archive(
        from collected: CollectedSnapshots, sourceID: String, resourceRevision: String, sourceName: String,
        now: Date = Date()
    ) throws -> LearningBackupArchive {
        try LearningBackupArchive(
            producer: LearningBackupArchive.importProducer,
            sourceID: sourceID, resourceRevision: resourceRevision, sourceName: sourceName,
            engineVersion: "unknown", createdAt: now,
            dictionaries: try collected.snapshots.map {
                try LearningBackupArchive.DictionarySnapshot(name: $0.dictionary, data: $0.data)
            })
    }

    /// What the user confirms: the dictionaries that will be offered to the input scheme in use, and the files left out.
    public static func confirmation(for collected: CollectedSnapshots, sourceName: String) -> String {
        var entriesByDictionary: [String: Int] = [:]
        for snapshot in collected.snapshots {
            entriesByDictionary[snapshot.dictionary, default: 0] += snapshot.entryCount
        }
        let total = collected.snapshots.reduce(0) { $0 + $1.entryCount }
        var lines = [
            String(
                format: String(localized: "core.import.confirmationTitle", bundle: .module),
                String(collected.snapshots.count), String(total), sourceName)
        ]
        let names = entriesByDictionary.keys.sorted()
        lines += names.prefix(listedDictionaries).map {
            String(
                format: String(localized: "core.import.entry", bundle: .module),
                $0, String(entriesByDictionary[$0] ?? 0))
        }
        if names.count > listedDictionaries {
            lines.append(
                String(
                    format: String(localized: "core.import.moreDictionaries", bundle: .module),
                    String(names.count)))
        }
        lines.append(String(localized: "core.import.footer", bundle: .module))
        if !collected.skipped.isEmpty {
            lines.append("")
            lines.append(String(localized: "core.import.skippedTitle", bundle: .module))
            lines += collected.skipped.prefix(listedSkippedFiles).map {
                String(
                    format: String(localized: "core.import.skippedEntry", bundle: .module),
                    $0.fileName, reasonText($0.reason))
            }
            if collected.skipped.count > listedSkippedFiles {
                lines.append(
                    String(
                        format: String(localized: "core.import.moreSkipped", bundle: .module),
                        String(collected.skipped.count - listedSkippedFiles)))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Shown when the pick holds nothing to merge.
    public static func nothingToImport(_ collected: CollectedSnapshots) -> String {
        collected.skipped.isEmpty
            ? String(localized: "core.import.nothingAtLocation", bundle: .module)
            : String(localized: "core.import.nothingInFiles", bundle: .module)
    }

    public static var tooLarge: String { String(localized: "core.import.tooLarge", bundle: .module) }

    public static func reasonText(_ reason: SnapshotSkipReason) -> String {
        switch reason {
        case .notASnapshot: return String(localized: "core.import.reasonNotASnapshot", bundle: .module)
        case .tooLarge: return String(localized: "core.import.reasonTooLarge", bundle: .module)
        case .empty: return String(localized: "core.import.reasonEmpty", bundle: .module)
        }
    }
}
