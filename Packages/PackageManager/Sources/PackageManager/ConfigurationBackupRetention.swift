import Foundation

/// Automatic backups run whenever the configuration or learning data changes, so only the newest
/// copies are kept. Pre-restore backups are counted separately: they are never uploaded and stay
/// the way back from a restore the user regrets.
public enum ConfigurationBackupRetention {
    public static let keptBackups = 10
    public static let keptSafetyBackups = 3
    public static let safetySuffix = ".restore.songyanbackup"

    /// The suffix marks a pre-restore backup whatever language named the file.
    public static func isSafety(_ file: URL) -> Bool { file.lastPathComponent.hasSuffix(safetySuffix) }

    /// The backups beyond the kept counts; `dated` gives each file's creation date.
    public static func surplus(_ files: [URL], dated: (URL) -> Date) -> [URL] {
        let newestFirst = files.filter { $0.pathExtension == "songyanbackup" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { dated($0) > dated($1) }
        return Array(newestFirst.filter { !isSafety($0) }.dropFirst(keptBackups))
            + Array(newestFirst.filter(isSafety).dropFirst(keptSafetyBackups))
    }
}
