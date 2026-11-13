import Foundation
import KeyboardCore
import PackageManager

/// Portable intent, not installed generations. Downloadable resources never enter a v2 archive.
struct ConfigurationBackupDependencies: Codable, Sendable {
    struct Model: Codable, Sendable {
        let path: String
        let sha256: String
        let bytes: Int
        let url: URL?
    }

    struct Scheme: Codable, Sendable {
        let id: String
        let name: String
        let entry: String
        let revision: String
        let url: URL?
        let target: String?
        let builtin: Bool
        let models: [Model]
        let recipes: [RecipePlanReceipt]
        /// Effective custom patches include recipe choices and app-managed settings, not schemas or dictionaries.
        let customizations: [String: Data]
    }

    struct DictionarySource: Codable, Sendable {
        let path: String
        let sha256: String
        let url: URL?
    }

    struct Dictionary: Codable, Sendable {
        let name: String
        let revision: String
        /// Original order matters: the first source is the import root.
        let sources: [DictionarySource]
    }

    var schemes: [Scheme]
    var dictionary: Dictionary?
    var selection: KeyboardRecipeStore.Activation?

    static let filename = "dependencies.json"
    static var pendingDirectory: URL { ConfigurationBackupStorage.root.appendingPathComponent("dependency-restore") }
    static var captureDirectory: URL { ConfigurationBackupStorage.root.appendingPathComponent("dependency-capture") }

    struct Progress: Codable, Sendable {
        var completed: Set<String> = []
        var failures: [String: String] = [:]
    }

    static func read(from directory: URL) throws -> Self {
        let value = try decode(Self.self, at: directory.appendingPathComponent(filename), maximum: 24 * 1024 * 1024)
        try value.validate()
        return value
    }

    func validate() throws {
        guard schemes.count <= 128, Set(schemes.map(\.id)).count == schemes.count else {
            throw ConfigurationBackupError.invalidArchive
        }
        var bytes = 0
        for scheme in schemes {
            guard PublishedKeyboardSourceKey.validPackageID(scheme.id), Self.safeComponent(scheme.entry),
                scheme.models.count <= 128,
                Set(scheme.models.map(\.path)).count == scheme.models.count,
                scheme.recipes.count <= 512, scheme.customizations.count <= 512,
                scheme.models.allSatisfy({
                    ConfigurationBackupArchive.safePath($0.path) && RecipeResourceBudget.isModel($0.path)
                        && Self.validHash($0.sha256) && $0.bytes >= 0 && $0.bytes <= RecipeResourceBudget.modelFile
                        && ($0.url == nil || Self.downloadable($0.url!))
                }), scheme.url == nil || Self.downloadable(scheme.url!),
                !scheme.builtin || scheme.id == ProductionInputAvailability.builtinPackageID
            else { throw ConfigurationBackupError.invalidArchive }
            for (path, data) in scheme.customizations {
                guard ConfigurationBackupArchive.safePath(path), path.hasSuffix(".custom.yaml"),
                    !path.hasPrefix("build/"), data.count <= 4 * 1024 * 1024
                else { throw ConfigurationBackupError.invalidArchive }
                bytes += data.count
            }
        }
        guard bytes <= 16 * 1024 * 1024 else { throw ConfigurationBackupError.limitExceeded }
        if let selection {
            guard selection.rosterKey != nil, (selection.keyboardsBySource?.count ?? 0) <= 128,
                selection.keyboardsBySource?.keys.allSatisfy(PublishedKeyboardSourceKey.isValid) ?? true
            else { throw ConfigurationBackupError.invalidArchive }
        }
        if let dictionary {
            guard !dictionary.sources.isEmpty, dictionary.sources.count <= 128,
                Set(dictionary.sources.map(\.path)).count == dictionary.sources.count,
                dictionary.sources.allSatisfy({
                    ConfigurationBackupArchive.safePath($0.path) && $0.path.hasSuffix(".dict.yaml")
                        && Self.validHash($0.sha256) && ($0.url == nil || Self.downloadable($0.url!))
                })
            else { throw ConfigurationBackupError.invalidArchive }
        }
    }

    /// Runs on the backup I/O queue. Only reads small manifests and custom patches; no model hashing/copying.
    static func capture(locations: [ConfigurationBackupDomain: URL]) throws {
        let fm = FileManager.default
        let directory = captureDirectory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var schemes: [Scheme] = []
        let root = locations[.schemes]!
        let slots =
            fm.fileExists(atPath: root.path)
            ? try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) : []
        for slot in slots.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !slot.lastPathComponent.hasPrefix("."),
                let installed = try installed(at: slot)
            else { continue }
            let generation = slot.appendingPathComponent("versions/\(installed.generation)")
            let resources = generation.appendingPathComponent("resources")
            let manifest = try decode(RecipeManifest.self, at: generation.appendingPathComponent("source.json"))
            struct URLRecord: Decodable { let url: URL? }
            struct Origin: Decodable { let target: String }
            struct Catalog: Decodable {
                let files: [String]
                let receipts: [RecipePlanReceipt]
            }
            let urlRecord = try optional(URLRecord.self, at: slot.appendingPathComponent("source-url.json"))
            let origin = try optional(Origin.self, at: slot.appendingPathComponent("source-origin.json"))
            let catalog = try optional(Catalog.self, at: generation.appendingPathComponent("recipe-catalog.json"))
            let downloaded =
                try optional(
                    [String: SchemeImportCenter.DownloadedModelSource].self,
                    at: slot.appendingPathComponent("model-sources.json")) ?? [:]
            let declaration = try optional(
                SchemePackageDeclaration.self, at: resources.appendingPathComponent("keyboard-package.json"))
            var urls: [String: URL] = [:]
            // A recorded invocation is authoritative; old installations can recover a declared URL
            // from the recipe inputs without ever copying their dictionaries or models.
            for receipt in catalog?.receipts ?? [] {
                for resource in receipt.externalResources where downloadable(resource.url) {
                    urls[resource.path] = resource.url
                }
            }
            for path in catalog?.files ?? [] where path.hasSuffix(".recipe.yaml") || path == "recipe.yaml" {
                guard ConfigurationBackupArchive.safePath(path) else { throw ConfigurationBackupError.invalidArchive }
                let file = generation.appendingPathComponent("recipe-inputs").appendingPathComponent(path)
                if let data = try? boundedData(file, maximum: 1024 * 1024),
                    let recipe = try? DeclarativeRecipe(path: path, source: data)
                {
                    for resource in recipe.downloads where urls[resource.path] == nil && downloadable(resource.url) {
                        urls[resource.path] = resource.url
                    }
                }
            }
            let models = manifest.files.filter { RecipeResourceBudget.isModel($0.path) }.map { model in
                Model(
                    path: model.path, sha256: model.sha256, bytes: model.size,
                    url: downloaded[model.path].flatMap { $0.sha256 == model.sha256 ? $0.url : nil } ?? urls[model.path]
                )
            }
            var custom = try customizations(in: resources)
            custom.merge(try customizations(in: generation.appendingPathComponent("user"))) { _, user in user }
            schemes.append(
                Scheme(
                    id: installed.id, name: declaration?.name ?? installed.id, entry: installed.schemaID,
                    revision: installed.revision,
                    url: urlRecord?.url.flatMap { downloadable($0) ? $0 : nil }, target: origin?.target,
                    builtin: installed.id == ProductionInputAvailability.builtinPackageID,
                    models: models, recipes: catalog?.receipts ?? [], customizations: custom))
            // Never combine an old installation's intent with a newly installed source.
            guard try self.installed(at: slot)?.generation == installed.generation else {
                throw ConfigurationBackupError.changedDuringBackup
            }
        }
        var copied = Set<String>()
        var dictionary: Dictionary?
        if let installed = try installed(at: locations[.dictionaries]!) {
            let resources = locations[.dictionaries]!.appendingPathComponent(
                "versions/\(installed.generation)/resources")
            struct Origin: Decodable {
                let path: String
                let location: String
                let sha256: String
            }
            struct Summary: Decodable { let name: String }
            let origins = try decode([Origin].self, at: resources.appendingPathComponent("import.json"))
            var sources: [DictionarySource] = []
            for origin in origins {
                guard ConfigurationBackupArchive.safePath(origin.path), origin.path.hasSuffix(".dict.yaml") else {
                    throw ConfigurationBackupError.invalidArchive
                }
                let url = URL(string: origin.location).flatMap { downloadable($0) ? $0 : nil }
                sources.append(.init(path: origin.path, sha256: origin.sha256, url: url))
                if url == nil {
                    let relative = "dictionary/" + origin.path
                    try copyIfChanged(
                        resources.appendingPathComponent("import-sources/" + origin.path),
                        to: directory.appendingPathComponent(relative))
                    copied.insert(relative)
                }
            }
            let summary = try optional(Summary.self, at: resources.appendingPathComponent("host-import-summary.json"))
            dictionary = Dictionary(
                name: summary?.name ?? String(localized: "自定义拼音"), revision: installed.revision, sources: sources)
        }
        var selection = try KeyboardRecipeStore.activation(rootURL: locations[.recipes])
        if let selection {
            var rosters = selection.keyboardsBySource ?? [:]
            if let key = selection.rosterKey { rosters[key] = selection.keyboards }
            for (key, keyboards) in rosters where key.hasPrefix("userScheme:") && !keyboards.isEmpty {
                let id = String(key.dropFirst("userScheme:".count))
                guard !schemes.contains(where: { $0.id == id }) else { continue }
                // Keep a missing host installation visible as unresolved intent, rather than
                // silently dropping a still-published keyboard from the backup.
                schemes.append(
                    Scheme(
                        id: id, name: id, entry: keyboards[0].schemaID,
                        revision: selection.packageID == id ? selection.revision : "unknown",
                        url: nil, target: nil, builtin: id == ProductionInputAvailability.builtinPackageID,
                        models: [], recipes: [], customizations: [:]))
            }
        }
        // Preserve unresolved restore intent in subsequent backups, including local dictionary
        // sources. A network failure must not turn the next automatic backup into data loss.
        if fm.fileExists(atPath: pendingDirectory.appendingPathComponent(filename).path) {
            let pending = try read(from: pendingDirectory)
            let progress = try readProgress()
            for scheme in pending.schemes where !progress.completed.contains("scheme:" + scheme.id) {
                schemes.removeAll { $0.id == scheme.id }
                schemes.append(scheme)
            }
            if !progress.completed.contains("dictionary"), let pendingDictionary = pending.dictionary {
                dictionary = pendingDictionary
                for source in pendingDictionary.sources where source.url == nil {
                    let relative = "dictionary/" + source.path
                    try copyIfChanged(
                        pendingDirectory.appendingPathComponent(relative),
                        to: directory.appendingPathComponent(relative))
                    copied.insert(relative)
                }
            }
            selection = pending.selection
        }
        let value = Self(schemes: schemes.sorted { $0.id < $1.id }, dictionary: dictionary, selection: selection)
        try value.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeIfChanged(encoder.encode(value), to: directory.appendingPathComponent(filename))
        let dictionaryRoot = directory.appendingPathComponent("dictionary").resolvingSymlinksInPath()
        if let walker = fm.enumerator(at: dictionaryRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker
            where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                let relative = "dictionary/" + url.path.dropFirst(dictionaryRoot.path.count + 1)
                if !copied.contains(relative) { try fm.removeItem(at: url) }
            }
        }
    }

    static func readProgress() throws -> Progress {
        try optional(Progress.self, at: pendingDirectory.appendingPathComponent("progress.json")) ?? Progress()
    }

    static func saveProgress(_ progress: Progress) throws {
        try JSONEncoder().encode(progress).write(
            to: pendingDirectory.appendingPathComponent("progress.json"), options: .atomic)
    }

    private static func installed(at slot: URL) throws -> InstalledRecipe? {
        guard let result = try optional(InstalledRecipe.self, at: slot.appendingPathComponent("active.json")) else {
            return nil
        }
        guard safeComponent(result.id), safeComponent(result.generation) else {
            throw ConfigurationBackupError.invalidArchive
        }
        return result
    }

    private static func customizations(in root: URL) throws -> [String: Data] {
        let root = root.resolvingSymlinksInPath()
        var result: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return result }
        for case let url as URL in walker {
            if url.lastPathComponent == "build" || url.lastPathComponent.contains(".userdb")
                || url.lastPathComponent.hasPrefix(".")
            {
                if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { walker.skipDescendants() }
                continue
            }
            guard url.lastPathComponent.hasSuffix(".custom.yaml") else { continue }
            let path = String(url.path.dropFirst(root.path.count + 1))
            result[path] = try boundedData(url, maximum: 4 * 1024 * 1024)
        }
        return result
    }

    static func downloadable(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }
    private static func safeComponent(_ value: String) -> Bool {
        ConfigurationBackupArchive.safePath(value) && !value.contains("/") && !value.hasPrefix(".")
    }
    private static func validHash(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
    static func boundedData(_ url: URL, maximum: Int = 8 * 1024 * 1024) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= maximum else {
            throw ConfigurationBackupError.invalidArchive
        }
        return try Data(contentsOf: url)
    }
    private static func decode<T: Decodable>(_ type: T.Type, at url: URL, maximum: Int = 8 * 1024 * 1024) throws -> T {
        try JSONDecoder().decode(type, from: boundedData(url, maximum: maximum))
    }
    private static func optional<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        FileManager.default.fileExists(atPath: url.path) ? try decode(type, at: url) : nil
    }
    static func writeIfChanged(_ data: Data, to url: URL) throws {
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
    }
    private static func copyIfChanged(_ source: URL, to target: URL) throws {
        let fm = FileManager.default
        if fm.contentsEqual(atPath: source.path, andPath: target.path) { return }
        _ = try source.resourceValues(forKeys: [.isRegularFileKey])
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try boundedData(source, maximum: 64 * 1024 * 1024)
        try data.write(to: target, options: .atomic)
    }
}
