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
        var lines = ["\(collected.snapshots.count) 份词库，共 \(total) 条，会并入「\(sourceName)」："]
        let names = entriesByDictionary.keys.sorted()
        lines += names.prefix(listedDictionaries).map { "· \($0)：\(entriesByDictionary[$0] ?? 0) 条" }
        if names.count > listedDictionaries { lines.append("· 等共 \(names.count) 种词库") }
        lines.append("用不到的词库会跳过。开始合并前会先自动保存当前的学习数据；合并后无法撤回。")
        if !collected.skipped.isEmpty {
            lines.append("")
            lines.append("这些文件不会并入：")
            lines += collected.skipped.prefix(listedSkippedFiles).map { "· \($0.fileName)：\(reasonText($0.reason))" }
            if collected.skipped.count > listedSkippedFiles {
                lines.append("· 另有 \(collected.skipped.count - listedSkippedFiles) 个文件")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Shown when the pick holds nothing to merge.
    public static func nothingToImport(_ collected: CollectedSnapshots) -> String {
        collected.skipped.isEmpty ? "所选的位置里没有 Rime 词库文件。" : "所选文件里没有能并入的词库，没有做任何修改。"
    }

    public static let tooLarge = "所选的文件太多或太大，请分几次导入。没有做任何修改。"

    public static func reasonText(_ reason: SnapshotSkipReason) -> String {
        switch reason {
        case .notASnapshot: return "不是 Rime 词库文件，或者已经损坏"
        case .tooLarge: return "文件太大"
        case .empty: return "里面没有词"
        }
    }
}
