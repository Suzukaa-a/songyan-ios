import Foundation

// MARK: - Header reader for `.userdb.txt` snapshots written by any Rime front-end
//
// Pure data, no file I/O. The host uses it to recognise snapshots from Squirrel, Weasel, Trime,
// fcitx5-rime, Hamster and Songyan before anything is sent to the keyboard extension. The extension
// repeats the check on its own side (`RimeLearningFormat.parseImported`) and is the authority.
//
// Unlike Songyan's own backups, a snapshot from another front-end may lack `/rime_version`,
// `/user_id`, `/tick` and even `/db_type`. `/db_name` is required: without it librime's restore
// would merge the file into its own temporary database. A `/db_type` other than `userdb` is refused
// because librime refuses it too.

public struct RimeUserDbSnapshotInfo: Equatable, Sendable {
    /// The user dictionary the snapshot merges into (`/db_name` without a `.userdb…` suffix).
    public let dictionary: String
    /// Rows librime will read as entries; zero means there is nothing to merge.
    public let entryCount: Int
}

public enum RimeUserDbTextError: Error, Equatable, Sendable {
    case invalid
}

public enum RimeUserDbText {
    public static let header = "# Rime user dictionary"
    public static let maximumMetadataBytes = 256
    public static let maximumDictionaryNameBytes = 256

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let headerBytes = Array(header.utf8)
    private static let noComment = "# no comment"

    /// Whether `head`, the first bytes of a file, starts like a snapshot (a UTF-8 BOM is allowed).
    public static func looksLikeSnapshot(_ head: Data) -> Bool {
        let bytes = Array(head.prefix(bom.count + headerBytes.count))
        let start = bytes.starts(with: bom) ? bom.count : 0
        guard bytes.count - start >= headerBytes.count else { return false }
        return Array(bytes[start..<(start + headerBytes.count)]) == headerBytes
    }

    /// Removes a leading UTF-8 BOM, which librime's reader would take as part of the first line.
    public static func strippingBOM(_ data: Data) -> Data {
        data.starts(with: bom) ? data.dropFirst(bom.count) : data
    }

    /// Reads a snapshot (BOM already removed or not). Throws for anything librime's restore would
    /// not take as a user dictionary, and for text that is not UTF-8.
    public static func inspect(_ data: Data) throws -> RimeUserDbSnapshotInfo {
        let body = strippingBOM(data)
        guard !body.isEmpty, String(data: body, encoding: .utf8) != nil else { throw RimeUserDbTextError.invalid }
        var metadata: [String: String] = [:]
        var entries = 0
        var first = true
        var inComments = true
        for line in lines(of: body) {
            if first {
                first = false
                guard line == header else { throw RimeUserDbTextError.invalid }
                continue
            }
            if line.isEmpty { continue }
            if inComments && line.hasPrefix("#") {
                if line.hasPrefix("#@") {
                    let pair = line.dropFirst(2).split(separator: "\t", omittingEmptySubsequences: false)
                    guard pair.count == 2, pair[1].utf8.count <= maximumMetadataBytes,
                        metadata.updateValue(String(pair[1]), forKey: String(pair[0])) == nil
                    else { throw RimeUserDbTextError.invalid }
                } else if line == noComment {
                    inComments = false
                }
                continue
            }
            let row = line.split(separator: "\t", omittingEmptySubsequences: false)
            if row.count >= 2, !row[0].isEmpty, !row[1].isEmpty { entries += 1 }
        }
        if let type = metadata["/db_type"], type != "userdb" { throw RimeUserDbTextError.invalid }
        guard let dbName = metadata["/db_name"] else { throw RimeUserDbTextError.invalid }
        let name = dictionaryName(dbName)
        guard validName(name) else { throw RimeUserDbTextError.invalid }
        return RimeUserDbSnapshotInfo(dictionary: name, entryCount: entries)
    }

    /// librime's `UserDbHelper::GetDbName`: old versions wrote `name.userdb.kct`, so the name ends
    /// before the last `.userdb`.
    public static func dictionaryName(_ dbName: String) -> String {
        guard let range = dbName.range(of: ".userdb", options: .backwards) else { return dbName }
        return String(dbName[..<range.lowerBound])
    }

    static func validName(_ name: String) -> Bool {
        let control = name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        return !name.isEmpty && name.utf8.count <= maximumDictionaryNameBytes && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && !name.contains(".userdb") && !control
            && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits on LF only and trims trailing whitespace like librime does, which also drops a
    /// Windows line's CR. Swift's `Character` view would fuse CR LF, so this works on bytes.
    private static func lines(of data: Data) -> [String] {
        data.split(separator: 0x0A, omittingEmptySubsequences: false).map { slice in
            var end = slice.endIndex
            while end > slice.startIndex, [0x20, 0x09, 0x0D].contains(slice[end - 1]) { end -= 1 }
            return String(decoding: slice[slice.startIndex..<end], as: UTF8.self)
        }
    }
}
