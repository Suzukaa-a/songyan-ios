import Foundation
import Yams

/// Why a file of the user's Rime configuration cannot be used.
public enum UserConfigProblem: String, Sendable {
    /// Not a `.yaml` / `.txt` / `.lua` path the folder holds.
    case name
    /// Larger than one file may be, or the folder as a whole is.
    case tooLarge
    /// More files than the folder may hold.
    case tooMany
    /// Not UTF-8 text.
    case notText
    /// A `.yaml` file the YAML reader rejects.
    case invalidYAML
    /// A `.yaml` file that names a file outside the data folders (an include, a dictionary, a database).
    case unsafeReference
    /// A script the user has not agreed to use (see `UserScripts`); `file` names it.
    case unconfirmedScript
    /// A line the app marks its own settings blocks with (`# Rx: …` or `# }`), which the user's file may not hold.
    case managedMarker
}

/// `file` is the relative path of the file at fault, when one is; `line` the 1-based line the YAML
/// reader stopped at, when it says; `detail` the key or reference at fault.
public struct UserConfigError: Error, LocalizedError, Equatable, Sendable {
    public let file: String?
    public let problem: UserConfigProblem
    public let detail: String?
    public let line: Int?

    public init(_ file: String?, _ problem: UserConfigProblem, detail: String? = nil, line: Int? = nil) {
        self.file = file
        self.problem = problem
        self.detail = detail
        self.line = line
    }

    public var errorDescription: String? {
        let name = file.map { "「\($0)」" } ?? "文件"
        switch problem {
        case .invalidYAML:
            let place = line.map { "第 \($0) 行" } ?? ""
            return "\(name)\(place)格式有误，改动没有应用，键盘仍用原来的设置。改好或删掉这个文件后再试。"
        case .notText:
            return "\(name)不是 UTF-8 文本，改动没有应用，键盘仍用原来的设置。"
        case .tooLarge:
            return "\(name)太大，改动没有应用。每个文件不超过 4 MB，全部加起来不超过 8 MB。"
        case .tooMany:
            return "文件太多，改动没有应用。最多放 100 个文件。"
        case .unsafeReference:
            return "\(name)里有指向别处文件的写法，改动没有应用，键盘仍用原来的设置。"
        case .unconfirmedScript:
            if detail != nil { return "\(name)使用了尚未允许的扩展脚本，请检查配置文件。" }
            return "扩展脚本在你确认之后又有改动，改动没有应用。再点一次「应用更改」。"
        case .managedMarker:
            return "\(name)里有以「# Rx: 」开头的行或单独的「# }」行，这是松烟自己用的标记，改动没有应用。删掉这些行后再试。"
        case .name:
            return "\(name)的名字不能用，改动没有应用，键盘仍用原来的设置。"
        }
    }
}

/// The Chinese text for an error that comes from the 「Rime 配置」 folder; nil for any other error.
public func rimeConfigUserMessage(_ error: Error) -> String? {
    switch error {
    case let error as UserConfigError: return error.errorDescription
    case let error as RimeScriptNameTaken: return error.errorDescription
    default: return nil
    }
}

/// The user's own Rime configuration: the files a desktop Rime user keeps in the user data folder
/// (`*.custom.yaml` patches, `custom_phrase.txt`, their own `.dict.yaml`), kept in the 「Rime 配置」
/// folder. The folder mirrors a package's own layout (`lua/foo.lua` overrides the package's
/// `lua/foo.lua`) and holds plain UTF-8 text only. Names, sizes and content are checked before a
/// file is laid over a generation; nothing in a file is ever followed.
enum UserConfigFiles {
    /// Above any hand-written patch or phrase list; large dictionaries belong in a dictionary import.
    static let maximumFileBytes = 4 * 1024 * 1024
    static let maximumTotalBytes = 8 * 1024 * 1024
    static let maximumFiles = 100
    /// Folders below the root; a package's own layout is one or two deep.
    static let maximumDepth = 4
    private static let maximumDetail = 80
    private static let maximumVisited = 5000

    static let extensions = [".yaml", ".txt", ".lua"]
    /// librime's compiled output folder in the user directory: files there would be taken for build products.
    private static let buildDirectory = "build"
    static let rimeLua = "rime.lua"
    static let luaDirectory = "lua"
    private static let dictionarySuffix = ".dict.yaml"

    private static func isPlainName(_ name: String) -> Bool {
        guard (1...120).contains(name.utf8.count), !name.contains("..") else { return false }
        let scalars = Array(name.unicodeScalars)
        func ascii(_ scalar: Unicode.Scalar, extra: String) -> Bool {
            (scalar.value < 128 && (CharacterSet.alphanumerics.contains(scalar)))
                || extra.unicodeScalars.contains(scalar)
        }
        return ascii(scalars[0], extra: "_") && scalars.dropFirst().allSatisfy { ascii($0, extra: "_.+-") }
    }

    static func isAllowedName(_ name: String) -> Bool {
        isPlainName(name) && extensions.contains { name.hasSuffix($0) && name.count > $0.count }
    }

    /// A name a new file may be made with: never a script, which comes from the new-script entry.
    static func isCreatableName(_ name: String) -> Bool { isAllowedName(name) && !name.hasSuffix(".lua") }

    private static func isAllowedFolder(_ name: String) -> Bool { isPlainName(name) && name != buildDirectory }

    /// Whether `path` (`/`-separated, relative to the folder) is a file the folder holds. A script
    /// (`.lua`) belongs where Rime looks for one: `rime.lua`, or below `lua/`.
    static func isAllowedPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, parts.count <= maximumDepth + 1, isAllowedName(last) else { return false }
        if last.hasSuffix(".lua"), path != rimeLua, !(parts.count > 1 && parts[0] == luaDirectory) { return false }
        return parts.dropLast().allSatisfy(isAllowedFolder)
    }

    /// Whether `path` is a script of the user's own: `rime.lua` or a `.lua` file below `lua/`.
    static func isScriptPath(_ path: String) -> Bool { path.hasSuffix(".lua") && isAllowedPath(path) }

    struct Entry: Equatable {
        let path: String
        let url: URL
    }

    /// The usable files of `folder` and its folders, sorted by path; links are never followed and
    /// anything with another name is ignored.
    static func files(in folder: URL) -> [Entry] {
        walk(folder).filter(\.allowed).map { Entry(path: $0.path, url: $0.url) }
    }

    /// Every `.yaml` / `.txt` / `.lua` file of the folder, usable or not, sorted by path.
    static func listed(in folder: URL) -> [String] { walk(folder).map(\.path) }

    private struct Found {
        let path: String
        let url: URL
        let allowed: Bool
    }

    private static func walk(_ folder: URL) -> [Found] {
        var found: [Found] = []
        var visited = 0
        func collect(_ directory: URL, _ prefix: String, _ depth: Int) {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
            let children =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
            for child in children {
                visited += 1
                guard visited <= maximumVisited, let values = try? child.resourceValues(forKeys: Set(keys)),
                    values.isSymbolicLink != true
                else { continue }
                let name = child.lastPathComponent
                if values.isRegularFile == true {
                    guard extensions.contains(where: { name.hasSuffix($0) }) else { continue }
                    let path = prefix + name
                    found.append(Found(path: path, url: child, allowed: isAllowedPath(path)))
                } else if values.isDirectory == true, depth < maximumDepth, isAllowedFolder(name) {
                    collect(child, prefix + name + "/", depth + 1)
                }
            }
        }
        collect(folder, "", 0)
        return found.sorted { $0.path < $1.path }
    }

    /// The problem with the file at `name` (a relative path) holding `data`, or nil when it can be used.
    /// A user's file may not hold the markers of the app's own blocks: the app finds its blocks again by
    /// those lines, and a scalar spanning lines can hide a forged one from the YAML check. `allowingBlocks`
    /// is for text the app itself merged its blocks into.
    static func check(_ name: String, _ data: Data, allowingBlocks: Bool = false) -> UserConfigError? {
        guard isAllowedPath(name) else { return UserConfigError(name, .name) }
        guard data.count <= maximumFileBytes else { return UserConfigError(name, .tooLarge) }
        guard let text = decode(data) else { return UserConfigError(name, .notText) }
        guard name.hasSuffix(".yaml") else { return nil }
        if !allowingBlocks, hasManagedMarker(text) { return UserConfigError(name, .managedMarker) }
        let result = read(name, text)
        if let error = result.error { return error }
        if let bad = UserConfigSafety.unsafeReference(result.root) {
            return UserConfigError(name, .unsafeReference, detail: String(bad.prefix(maximumDetail)))
        }
        return nil
    }

    /// Whether any line starts with `# Rx: ` or is `# }`, on bytes, with every kind of line end
    /// (`\r\n` is rewritten to `\n` before the app's blocks are looked for).
    static func hasManagedMarker(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { $0.utf8HasPrefix("# Rx: ") || $0.utf8Equals("# }") }
    }

    /// Reads one file's YAML the way every check does; nil error means `root` is the document.
    static func read(_ name: String, _ text: String) -> (root: BoundedYAML.TextNode?, error: UserConfigError?) {
        let yaml = yamlPart(name, text)
        if UserConfigSafety.tooDeep(yaml) {
            return (nil, UserConfigError(name, .invalidYAML, detail: "nested too deeply"))
        }
        do {
            return (try BoundedYAML.loadAsText(yaml: yaml), nil)
        } catch {
            return (
                nil,
                UserConfigError(
                    name, .invalidYAML, detail: String(error.localizedDescription.prefix(maximumDetail)),
                    line: BoundedYAML.errorLine(error))
            )
        }
    }

    /// A dictionary source is a YAML header, ended by `...`, then tab-separated rows; only the header is YAML.
    static func yamlPart(_ name: String, _ text: String) -> String {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard name.hasSuffix(dictionarySuffix) else { return text }
        let lines = text.components(separatedBy: "\n")
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "..." }) else {
            return text
        }
        return lines[..<end].joined(separator: "\n")
    }

    /// Strict UTF-8 without NUL characters, or nil.
    static func decode(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") else { return nil }
        return text
    }
}
