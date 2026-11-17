import Foundation
import KeyboardCore

/// The language a dictionary's text is written in, read at deployment so candidates are drawn with
/// that language's glyphs instead of always Simplified Chinese. Kana entries (5 % or more) make it
/// Japanese, Hangul entries (20 % or more) Korean; Chinese is told by the characters only one script
/// uses (20 or more of one side and at least twice the other); an even mix follows the system's
/// Chinese script; a dictionary with none of these forces no language.
public enum DictionaryLanguage {
    private static let maximumBytes = 4 * 1024 * 1024
    private static let maximumEntries = 50_000
    private static let kanaShare = 0.05
    private static let hangulShare = 0.20
    private static let scriptMinimum = 20
    private static let scriptRatio = 2

    private static let scripts: (simplified: Set<Unicode.Scalar>, traditional: Set<Unicode.Scalar>) = {
        guard let url = Bundle.module.url(forResource: "ScriptCharacters", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return ([], []) }
        let lines = text.components(separatedBy: "\n")
        return (Set(lines[0].unicodeScalars), Set(lines.count > 1 ? lines[1].unicodeScalars : "".unicodeScalars))
    }()

    /// The wire value for the entries' `texts`: `zh-Hans`, `zh-Hant`, `ja`, `ko`, `zh` (system) or `none`.
    public static func detect<S: Sequence<String>>(_ texts: S) -> String {
        var entries = 0
        var kana = 0
        var hangul = 0
        var simplified = 0
        var traditional = 0
        var han = false
        for text in texts {
            entries += 1
            var hasKana = false
            var hasHangul = false
            for scalar in text.unicodeScalars {
                if isKana(scalar.value) {
                    hasKana = true
                } else if isHangul(scalar.value) {
                    hasHangul = true
                } else if scripts.simplified.contains(scalar) {
                    simplified += 1
                    han = true
                } else if scripts.traditional.contains(scalar) {
                    traditional += 1
                    han = true
                } else if isHan(scalar.value) {
                    han = true
                }
            }
            if hasKana { kana += 1 }
            if hasHangul { hangul += 1 }
        }
        if entries == 0 { return InputLanguageResolver.detectedNone }
        if Double(kana) / Double(entries) >= kanaShare { return "ja" }
        if Double(hangul) / Double(entries) >= hangulShare { return "ko" }
        if simplified >= scriptMinimum, simplified >= scriptRatio * traditional { return "zh-Hans" }
        if traditional >= scriptMinimum, traditional >= scriptRatio * simplified { return "zh-Hant" }
        return han ? InputLanguageResolver.detectedSystemChinese : InputLanguageResolver.detectedNone
    }

    /// The language of the dictionary `name` in `sourceDirectory` (`<name>.dict.yaml`, with the tables it
    /// imports one level down); nil when the file cannot be read. Reads at most 4 MiB and 50,000 entries.
    public static func read(sourceDirectory: URL, name: String) -> String? {
        guard let main = dictionaryFile(sourceDirectory, name) else { return nil }
        var budget = Budget()
        var texts: [String] = []
        guard let imports = readTable(main, into: &texts, budget: &budget) else { return nil }
        for table in imports {
            guard let file = dictionaryFile(sourceDirectory, table) else { continue }
            _ = readTable(file, into: &texts, budget: &budget)
        }
        return detect(texts)
    }

    private struct Budget {
        var bytes = 0
        var entries = 0
        var spent: Bool { bytes >= DictionaryLanguage.maximumBytes || entries >= DictionaryLanguage.maximumEntries }
    }

    private static func dictionaryFile(_ directory: URL, _ name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { return nil }
        let file = directory.appendingPathComponent("\(name).dict.yaml")
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            ? file : nil
    }

    /// The entries' text appended to `texts`; returns the tables the header imports, or nil when unreadable.
    private static func readTable(_ file: URL, into texts: inout [String], budget: inout Budget) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maximumBytes)
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        var imports: [String] = []
        var columns = ["text", "code", "weight"]
        var header: [String] = []
        var inHeader = true
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if budget.spent { break }
            budget.bytes += line.utf8.count + 1
            if inHeader {
                if line == "..." {
                    inHeader = false
                    let declared = headerList(header, "columns")
                    if !declared.isEmpty { columns = declared }
                    imports += headerList(header, "import_tables")
                } else {
                    header.append(String(line))
                }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            let at = max(columns.firstIndex(of: "text") ?? 0, 0)
            if at < fields.count, !fields[at].isEmpty {
                texts.append(String(fields[at]))
                budget.entries += 1
            }
        }
        // A file without a header end is not a dictionary table.
        return inHeader ? nil : imports
    }

    private static func headerList(_ header: [String], _ key: String) -> [String] {
        guard let start = header.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "\(key):" }) else {
            return []
        }
        return header.dropFirst(start + 1)
            .prefix { $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("- ") }
            .map {
                $0.trimmingCharacters(in: .whitespaces).dropFirst(2)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            }
    }

    private static func isKana(_ cp: UInt32) -> Bool {
        (0x3040...0x30FF).contains(cp) || (0x31F0...0x31FF).contains(cp) || (0xFF66...0xFF9F).contains(cp)
    }

    private static func isHangul(_ cp: UInt32) -> Bool {
        (0xAC00...0xD7A3).contains(cp) || (0x1100...0x11FF).contains(cp) || (0x3130...0x318F).contains(cp)
    }

    private static func isHan(_ cp: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(cp) || (0x3400...0x4DBF).contains(cp) || (0x20000...0x2A6DF).contains(cp)
            || (0xF900...0xFAFF).contains(cp)
    }
}
