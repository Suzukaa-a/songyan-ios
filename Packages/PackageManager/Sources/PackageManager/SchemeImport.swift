import CryptoKit
import Foundation
import KeyboardCore
import Yams
import ZIPFoundation

/// Explicit input contract supplied with a source package, never inferred from its brand.
/// Codes are the actual logical key events produced by the selected keyboard, not display labels.
public struct SchemeInputBinding: Codable, Equatable, Sendable {
    public let layout: String
    public let schemaID: String
    public let code: String
    public let candidate: String
    public init(layout: String, schemaID: String, code: String, candidate: String) {
        self.layout = layout
        self.schemaID = schemaID
        self.code = code
        self.candidate = candidate
    }
}

/// Optional keyboard-package.json augments, but never replaces, the Rime source files.
/// id defines the learning namespace; changing it deliberately creates an independent installation.
public struct SchemePackageDeclaration: Codable, Sendable {
    public let id: String
    public let name: String
    public let bindings: [SchemeInputBinding]
    public init(id: String, name: String, bindings: [SchemeInputBinding]) {
        self.id = id
        self.name = name
        self.bindings = bindings
    }
}

public struct PreparedSchemeImport: Sendable {
    /// Original selected package bytes, before generated default/product metadata. Recipe planning
    /// must use this snapshot so a generated fallback cannot satisfy a missing install_files source.
    public let sourceFiles: [String: Data]
    public let fileResources: [String: RecipeFileResource]
    public var sourceFileResources: [String: RecipeFileResource] { fileResources }
    public let declaration: SchemePackageDeclaration
    public let manifest: RecipeManifest
    public let schemaIDs: [String]
    /// Names read from the exact source files that will be installed; callers parse off the main thread.
    public var schemaNames: [String: String] {
        Dictionary(
            uniqueKeysWithValues: schemaIDs.compactMap { id in
                guard let data = bytes[id + ".schema.yaml"], let name = FuzzyPinyin.schemaName(compiled: data) else {
                    return nil
                }
                return (id, name)
            })
    }
    public let resourceBytes: Int
    public let diagnostics: [String]
    private let bytes: [String: Data]
    /// Learned words the package shipped as `*.userdb.txt`. They are never source files: they stay
    /// out of the package identity and the installed tree, and wait here for the user's answer.
    public let learningSnapshots: CollectedSnapshots
    /// How many distinct dictionaries the shipped learned words belong to.
    public var learningDictionaryCount: Int { Set(learningSnapshots.snapshots.map(\.dictionary)).count }
    /// Source-declared grammar is required for this unchanged installation. Runtime
    /// validation remains authoritative for includes/patches and actual model loading.
    public var requiredModelPaths: [String] { SchemeGrammarRequirements.paths(in: bytes) }

    /// The exact bytes this prepared import will write for `path`, including generated
    /// products such as the standard telephone-key companion. Read-only.
    public func preparedBytes(for path: String) -> Data? { bytes[path] }

    public func preparingModels(_ supplied: [String: RecipeFileResource]) throws -> PreparedSchemeImport {
        var models = fileResources
        for path in requiredModelPaths {
            guard let model = supplied[path] ?? models[path] else {
                throw RecipeInstallError.missingGrammarModels(requiredModelPaths)
            }
            models[path] = model
        }
        return try replacingModels(models)
    }

    /// An update keeps the grammar models of the installed version that the new files do not bring.
    /// A model is added by the user (they are far too large to ship in a package), and the keyboard
    /// settings that point at it live in the user's own configuration, which an update keeps. Models
    /// the new files carry themselves win; the same files over the same models give the same revision.
    public func carryingModels(from installed: InstalledRecipeSources) throws -> PreparedSchemeImport {
        var models = fileResources
        for (path, model) in installed.fileResources
        where path.hasSuffix(".gram") && !path.hasPrefix("source-repositories/")
            && bytes[path] == nil && models[path] == nil
        {
            models[path] = model
        }
        guard models.count != fileResources.count else { return self }
        return try replacingModels(models)
    }

    private func replacingModels(_ models: [String: RecipeFileResource]) throws -> PreparedSchemeImport {
        try RecipeResourceBudget.validate(bytes.mapValues(\.count).merging(models.mapValues(\.size)) { _, new in new })
        let records = Set(bytes.keys).union(models.keys).sorted().map { path in
            if let model = models[path] {
                return RecipeManifest.File(path: path, sha256: model.sha256, size: model.size)
            }
            return RecipeManifest.File(
                path: path, sha256: SchemeSourceCheck.hash(bytes[path]!), size: bytes[path]!.count)
        }
        let revision = String(
            SchemeSourceCheck.hash(Data(records.map { $0.path + $0.sha256 }.joined().utf8)).prefix(40))
        let updated = RecipeManifest(
            id: manifest.id, repository: manifest.repository, revision: revision,
            recipePath: manifest.recipePath, license: manifest.license, schemaID: manifest.schemaID,
            requiredComponents: manifest.requiredComponents, files: records, origin: manifest.origin)
        return PreparedSchemeImport(
            declaration: declaration, manifest: updated, schemaIDs: schemaIDs,
            bytes: bytes, sourceFiles: sourceFiles, fileResources: models, learningSnapshots: learningSnapshots)
    }
    fileprivate init(
        declaration: SchemePackageDeclaration, manifest: RecipeManifest,
        schemaIDs: [String], bytes: [String: Data], sourceFiles: [String: Data],
        fileResources: [String: RecipeFileResource], learningSnapshots: CollectedSnapshots
    ) {
        self.learningSnapshots = learningSnapshots
        self.declaration = declaration
        self.manifest = manifest
        self.schemaIDs = schemaIDs
        self.bytes = bytes
        resourceBytes = bytes.values.reduce(0) { $0 + $1.count } + fileResources.values.reduce(0) { $0 + $1.size }
        self.fileResources = fileResources
        self.sourceFiles = sourceFiles
        diagnostics = SchemeGrammarRequirements.discover(in: bytes).diagnostics
    }
    fileprivate func read(_ path: String) throws -> Data {
        guard let data = bytes[path] else { throw RecipeInstallError.invalidResource(path) }
        return data
    }

    /// Keep the installation's learning identity when the user explicitly updates it.
    /// A package with its own different identity must instead be imported separately.
    public func updatingInstallation(id: String, name: String) throws -> PreparedSchemeImport {
        if let data = sourceFiles[InstalledPackageLayout.keyboardPackageFile] {
            let declared = try JSONDecoder().decode(SchemePackageDeclaration.self, from: data)
            guard declared.id == id else {
                throw RecipeInstallError.invalidManifest("所选文件属于另一个输入方案，请从「导入方案」添加。")
            }
        }
        let declaration = SchemePackageDeclaration(id: id, name: name, bindings: declaration.bindings)
        var updated = bytes
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        updated[InstalledPackageLayout.keyboardPackageFile] = try encoder.encode(declaration)
        let records = Set(updated.keys).union(fileResources.keys).sorted().map { path in
            if let file = fileResources[path] {
                return RecipeManifest.File(path: path, sha256: file.sha256, size: file.size)
            }
            let data = updated[path]!
            return RecipeManifest.File(path: path, sha256: SchemeSourceCheck.hash(data), size: data.count)
        }
        let revision = String(
            SchemeSourceCheck.hash(Data(records.map { $0.path + $0.sha256 }.joined().utf8)).prefix(40))
        let updatedManifest = RecipeManifest(
            id: id, repository: manifest.repository, revision: revision,
            recipePath: manifest.recipePath, license: manifest.license, schemaID: manifest.schemaID,
            requiredComponents: manifest.requiredComponents, files: records, origin: .userScheme)
        return PreparedSchemeImport(
            declaration: declaration, manifest: updatedManifest,
            schemaIDs: schemaIDs, bytes: updated, sourceFiles: sourceFiles, fileResources: fileResources,
            learningSnapshots: learningSnapshots)
    }
}

public extension RecipePackageManager {
    nonisolated func prepareSchemeArchive(
        _ url: URL, expectedSHA256: String? = nil, advertisedSchemaIDs: [String]? = nil
    ) throws -> PreparedSchemeImport {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("scheme-zip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let snapshot = workspace.appendingPathComponent("source.zip")
        try BoundedLocalFile(url, maximumBytes: RecipeResourceBudget.archiveFile).copy(to: snapshot)
        if let expectedSHA256 { try Self.verifyArchiveChecksum(snapshot, expected: expectedSHA256) }
        let archive = try Archive(url: snapshot, accessMode: .read)
        let staging = workspace.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let entries = try Self.scanArchiveEntries(archive)
        // Detect the single enclosing repository before applying resource budgets.
        // Classification uses the package-relative path; extraction still uses the
        // separately validated physical path and preserves every subdirectory.
        let wrapper = Self.archiveWrapper(entries)
        var sizes: [String: Int] = [:]
        var snapshotBytes = 0
        for (entry, path) in entries {
            let logicalPath = wrapper.map { String(path.dropFirst($0.count + 1)) } ?? path
            // A shipped snapshot is extracted only to be offered for merging, under the snapshot bounds
            // instead of the source budgets; one over them is left out.
            let isSnapshot = entry.type == .file && SchemeSourceCheck.isLearningSnapshot(logicalPath)
            if isSnapshot {
                let size = Int(clamping: entry.uncompressedSize)
                guard size <= RimeSnapshotCollector.maximumFileBytes,
                    snapshotBytes + size <= RimeSnapshotCollector.maximumTotalBytes
                else { continue }
                snapshotBytes += size
            } else {
                guard entry.uncompressedSize <= UInt64(RecipeResourceBudget.maximumFileBytes(logicalPath)) else {
                    throw RecipeInstallError.invalidResource("ZIP 解压后大小超过限制")
                }
                if entry.type != .directory { sizes[logicalPath] = Int(entry.uncompressedSize) }
                try RecipeResourceBudget.validate(sizes)
            }
            let destination = staging.appendingPathComponent(path)
            if entry.type == .directory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw RecipeInstallError.invalidResource(path)
                }
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                var count = 0
                let checksum = try archive.extract(entry) { chunk in
                    try Task.checkCancellation()
                    count += chunk.count
                    guard UInt64(count) <= entry.uncompressedSize else {
                        throw RecipeInstallError.invalidResource("ZIP 实际解压大小超出文件声明：\(path)")
                    }
                    try output.write(contentsOf: chunk)
                }
                guard checksum == entry.checksum, UInt64(count) == entry.uncompressedSize else {
                    throw RecipeInstallError.invalidResource("ZIP 文件校验失败：\(path)")
                }
                try output.synchronize()
            }
        }
        let root = wrapper.map { staging.appendingPathComponent($0) } ?? staging
        return try prepareSchemeImport(directory: root, advertisedSchemaIDs: advertisedSchemaIDs)
    }

    /// Several archives of one catalogue entry, merged into a single package. The first archive is the
    /// entry: its files keep their package-relative paths, and only its default.yaml describes the
    /// installed schema_list. Later archives contribute resources at those same paths (a dependency
    /// dictionary or schema has to stay where librime reads it). Identical bytes are one file;
    /// documentation such as a licence keeps every upstream copy under that archive's namespace; a
    /// runtime path two archives fill differently is refused instead of resolving to the wrong
    /// upstream's bytes. Model files stay file references, never in-memory Data.
    nonisolated func prepareSchemeArchives(
        _ urls: [URL], expectedArchives: [RecommendedSchemeArchive]? = nil, advertisedSchemaIDs: [String]? = nil
    ) throws -> PreparedSchemeImport {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-zips-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        // Freeze and size-check every archive before the first one is unpacked: several files share
        // the single-archive compressed budget, so a larger later archive must be refused up front.
        let inputs = try urls.map { try BoundedLocalFile($0, maximumBytes: RecipeResourceBudget.archiveFile) }
        try RecipeResourceBudget.validateArchives(inputs.map { Int64($0.size) })
        var bytes: [String: Data] = [:]
        var fileResources: [String: RecipeFileResource] = [:]
        var claimedPaths: [String: (path: String, label: String)] = [:]
        var snapshotFiles: [PickedFile] = []
        var snapshotBytes = 0
        var sourceBytes = 0
        var modelBytes = 0
        var stagedEntries = 0
        // Model snapshots must outlive this reader: the installation copies them after it returns.
        let modelStaging = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-models-" + UUID().uuidString)
        for (index, url) in urls.enumerated() {
            let snapshot = workspace.appendingPathComponent("source-\(index).zip")
            try inputs[index].copy(to: snapshot)
            if let expectedArchives {
                try Self.verifyArchiveChecksum(snapshot, expected: expectedArchives[index].sha256)
            }
            let archive = try Archive(url: snapshot, accessMode: .read)
            let entries = try Self.scanArchiveEntries(archive)
            let wrapper = Self.archiveWrapper(entries)
            let label = Self.archiveLabel(url: url, wrapper: wrapper, index: index)
            for (entry, path) in entries where entry.type != .directory {
                let logicalPath = wrapper.map { String(path.dropFirst($0.count + 1)) } ?? path
                if logicalPath == ".git" || logicalPath.hasPrefix(".git/") { continue }
                if logicalPath.hasPrefix("build/") && logicalPath != "build/.gitkeep" { continue }
                // The entry archive owns the package's default configuration; a dependency's
                // default.yaml (or its schema_list patch) must never become the published list.
                if index > 0, ["default.yaml", "default.custom.yaml"].contains(logicalPath.lowercased()) {
                    continue
                }
                let size = Int(clamping: entry.uncompressedSize)
                if SchemeSourceCheck.isLearningSnapshot(logicalPath) {
                    // A shipped snapshot is offered for merging only; it is never installed as source.
                    guard size <= RimeSnapshotCollector.maximumFileBytes,
                        snapshotBytes + size <= RimeSnapshotCollector.maximumTotalBytes
                    else { continue }
                    let data = try Self.readArchiveEntry(entry, from: archive, path: path)
                    snapshotBytes += data.count
                    let name = logicalPath.split(separator: "/").last.map(String.init) ?? path
                    snapshotFiles.append(PickedFile(name: name) { limit in data.count > limit ? nil : data })
                    continue
                }
                // User databases are private learning data, never package source; the single-package
                // import refuses them the same way.
                guard !logicalPath.contains(".userdb") else {
                    throw RecipeInstallError.invalidResource(
                        "路径不安全、重复或包含不支持的用户数据文件：\(logicalPath)")
                }
                guard size <= RecipeResourceBudget.maximumFileBytes(logicalPath) else {
                    throw RecipeInstallError.invalidResource("ZIP 解压后大小超过限制")
                }
                if RecipeResourceBudget.isModel(logicalPath) {
                    // Models travel by file reference exactly as a single package's do: extracted
                    // once, snapshotted on disk, and a root prediction database is validated before
                    // it may be installed.
                    guard modelBytes + size <= RecipeResourceBudget.modelTotal else {
                        throw RecipeInstallError.invalidResource("方案文件或模型文件总大小超过限制")
                    }
                    let staged = workspace.appendingPathComponent("model-\(index)-\(stagedEntries).bin")
                    stagedEntries += 1
                    let digest = try Self.extractArchiveEntry(entry, from: archive, path: path, to: staged)
                    if let owner = claimedPaths[logicalPath.lowercased()] {
                        guard fileResources[owner.path]?.sha256 == digest else {
                            throw Self.archiveConflict(path: logicalPath, owner: owner.label, label: label)
                        }
                        continue
                    }
                    let resource = try RecipeFileResource.snapshot(
                        from: staged, directory: modelStaging,
                        maximumBytes: min(
                            RecipeResourceBudget.modelFile, RecipeResourceBudget.modelTotal - modelBytes))
                    modelBytes += resource.size
                    fileResources[logicalPath] = resource
                    claimedPaths[logicalPath.lowercased()] = (logicalPath, label)
                    try Prediction.validateDatabases(in: [logicalPath: resource])
                    continue
                }
                guard sourceBytes + size <= RecipeResourceBudget.sourceTotal else {
                    throw RecipeInstallError.invalidResource("ZIP 解压后大小超过限制")
                }
                let data = try Self.readArchiveEntry(entry, from: archive, path: path)
                sourceBytes += data.count
                try Self.insertArchiveFile(data, at: logicalPath, from: label, into: &bytes, claimed: &claimedPaths)
            }
        }
        return try prepareSchemeImport(
            bytes: bytes, fileResources: fileResources, declaration: nil,
            learning: Self.collectLearning(files: snapshotFiles), advertisedSchemaIDs: advertisedSchemaIDs)
    }

    // Verify the frozen input once, before ZIP parsing; a caller-controlled original can change meanwhile.
    private static func verifyArchiveChecksum(_ url: URL, expected: String) throws {
        let file = try BoundedLocalFile(url, maximumBytes: RecipeResourceBudget.archiveFile)
        var hash = SHA256()
        try file.consume { hash.update(data: $0) }
        guard hash.finalize().hex == expected else {
            throw RecipeInstallError.invalidResource(
                Bundle.main.localizedString(
                    forKey: "catalog.checksumFailure", value: "下载的文件校验失败，请重新下载。", table: nil))
        }
    }

    /// Every file entry of one archive, with unsafe paths, symlinks, duplicates and Finder metadata
    /// rejected before any bytes are extracted.
    private static func scanArchiveEntries(_ archive: Archive) throws -> [(entry: Entry, path: String)] {
        var paths = Set<String>()
        var entries: [(entry: Entry, path: String)] = []
        for entry in archive {
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            if SchemeSourceCheck.isFinderMetadata(path) { continue }
            guard SchemeSourceCheck.safe(path), paths.insert(path.lowercased()).inserted,
                entry.type != .symlink, paths.count <= 2000
            else { throw RecipeInstallError.invalidResource("ZIP 文件路径无效或包含符号链接：\(entry.path)") }
            entries.append((entry, path))
        }
        return entries
    }

    /// The single enclosing repository directory of a repository ZIP, when it has exactly one.
    private static func archiveWrapper(_ entries: [(entry: Entry, path: String)]) -> String? {
        let roots = Set(entries.compactMap { $0.path.split(separator: "/").first.map(String.init) })
        return roots.count == 1 && entries.allSatisfy({ $0.entry.type == .directory || $0.path.contains("/") })
            ? roots.first : nil
    }

    /// A safe single path segment naming the archive a conflicting file came from.
    private static func archiveLabel(url: URL, wrapper: String?, index: Int) -> String {
        let raw = wrapper ?? url.deletingPathExtension().lastPathComponent
        let cleaned = String(
            raw.unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
                    ? Character(scalar) : "-"
            }
        ).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return cleaned.isEmpty ? "archive-\(index + 1)" : cleaned
    }

    /// One runtime path two archives fill differently cannot be resolved to either upstream.
    private static func archiveConflict(path: String, owner: String, label: String) -> RecipeInstallError {
        RecipeInstallError.invalidResource(
            String(
                format: Bundle.main.localizedString(
                    forKey: "scheme.archive.conflict.format",
                    value: "「%1$@」在「%2$@」与「%3$@」中内容不同，请只保留其中一个压缩包。", table: nil),
                path, owner, label))
    }

    /// Extracts one entry to a staging file and returns its SHA-256, refusing bytes beyond the size
    /// it declared. Model files are referenced from disk and must never be loaded into memory.
    private static func extractArchiveEntry(
        _ entry: Entry, from archive: Archive, path: String, to destination: URL
    ) throws -> String {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw RecipeInstallError.invalidResource(path)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let declared = Int(clamping: entry.uncompressedSize)
        var count = 0
        var hash = SHA256()
        let checksum = try archive.extract(entry) { chunk in
            try Task.checkCancellation()
            count += chunk.count
            guard count <= declared else {
                throw RecipeInstallError.invalidResource("ZIP 实际解压大小超出文件声明：\(path)")
            }
            hash.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        guard checksum == entry.checksum, count == declared else {
            throw RecipeInstallError.invalidResource("ZIP 文件校验失败：\(path)")
        }
        try output.synchronize()
        return hash.finalize().hex
    }

    /// Extracts one entry into memory, refusing bytes beyond the size it declared.
    private static func readArchiveEntry(_ entry: Entry, from archive: Archive, path: String) throws -> Data {
        let declared = Int(clamping: entry.uncompressedSize)
        var data = Data()
        data.reserveCapacity(declared)
        let checksum = try archive.extract(entry) { chunk in
            try Task.checkCancellation()
            guard data.count + chunk.count <= declared else {
                throw RecipeInstallError.invalidResource("ZIP 实际解压大小超出文件声明：\(path)")
            }
            data.append(chunk)
        }
        guard checksum == entry.checksum, data.count == declared else {
            throw RecipeInstallError.invalidResource("ZIP 文件校验失败：\(path)")
        }
        return data
    }

    /// Adds one archive's file. Identical bytes reuse the existing file; documentation another archive
    /// also ships (licences, readmes) is kept under that archive's namespace; any other runtime path two
    /// archives spell differently is refused, because a later schema would otherwise silently read the
    /// earlier archive's bytes instead of its own.
    private static func insertArchiveFile(
        _ data: Data, at path: String, from label: String,
        into bytes: inout [String: Data], claimed: inout [String: (path: String, label: String)]
    ) throws {
        guard let owner = claimed[path.lowercased()] else {
            bytes[path] = data
            claimed[path.lowercased()] = (path, label)
            return
        }
        guard bytes[owner.path] != data else { return }
        // Attribution (a different upstream's LICENSE.txt, say) is documentation even when its
        // extension is also a runtime one, so both copies are kept instead of refusing the merge.
        guard !SchemeSourceCheck.isRuntimeSourceFile(path) || SchemeSourceCheck.isDocumentation(path) else {
            throw Self.archiveConflict(path: path, owner: owner.label, label: label)
        }
        var candidate = "source-repositories/" + label + "/" + path
        var attempt = 2
        while claimed[candidate.lowercased()] != nil {
            candidate = "source-repositories/" + label + "-" + String(attempt) + "/" + path
            attempt += 1
        }
        bytes[candidate] = data
        claimed[candidate.lowercased()] = (candidate, label)
    }

    /// A complete directory selected by the user. Symlinks and user databases are never imported.
    /// ZIPs must first be extracted by the user; no shell/plum script is executed.
    nonisolated func prepareSchemeImport(
        directory: URL, declaration: SchemePackageDeclaration? = nil, advertisedSchemaIDs: [String]? = nil
    ) throws -> PreparedSchemeImport {
        let fm = FileManager.default
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else {
            throw RecipeInstallError.invalidResource("请选择解压后的完整输入方案目录；ZIP 文件请先在「文件」App 中解压")
        }
        var files: [DictionaryImportFile] = []
        var visited = 0
        var sawSnapshot = false
        func visit(_ url: URL, prefix: String) throws {
            for child in try fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            {
                let name = child.lastPathComponent
                if name == ".git" || SchemeSourceCheck.isFinderMetadata(prefix + name) { continue }
                if name == "build" {
                    let info = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                    guard info.isSymbolicLink != true, info.isDirectory == true else {
                        throw RecipeInstallError.invalidResource(child.path)
                    }
                    let placeholder = child.appendingPathComponent(".gitkeep")
                    if fm.fileExists(atPath: placeholder.path) {
                        let value = try placeholder.resourceValues(forKeys: [
                            .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
                        ])
                        guard value.isSymbolicLink != true, value.isRegularFile == true, value.fileSize == 0 else {
                            throw RecipeInstallError.invalidResource("build/.gitkeep 必须为空文件")
                        }
                        files.append(DictionaryImportFile(path: prefix + "build/.gitkeep", location: placeholder))
                    }
                    continue
                }
                visited += 1
                guard visited <= 2000, prefix.split(separator: "/").count < 32 else {
                    throw RecipeInstallError.invalidResource("输入方案目录超过 2000 个文件或目录层级超过 32 层")
                }
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw RecipeInstallError.invalidResource("不支持符号链接：\(child.path)")
                }
                let path = prefix + name
                if values.isDirectory != true, SchemeSourceCheck.isLearningSnapshot(path) {
                    sawSnapshot = true
                    continue
                }
                guard files.count < 2000 else { throw RecipeInstallError.invalidResource("输入方案文件超过 2000 个") }
                if values.isDirectory == true {
                    try visit(child, prefix: path + "/")
                } else {
                    files.append(DictionaryImportFile(path: path, location: child))
                }
            }
        }
        try visit(directory, prefix: "")
        return try prepareSchemeImport(
            files: files, declaration: declaration,
            learning: sawSnapshot ? Self.collectLearning(in: directory) : .empty,
            advertisedSchemaIDs: advertisedSchemaIDs)
    }

    /// Multiple files retain explicit package-relative paths (including lua/, opencc/, dictionaries/).
    nonisolated func prepareSchemeImport(
        files: [DictionaryImportFile], declaration supplied: SchemePackageDeclaration? = nil,
        learning folderLearning: CollectedSnapshots? = nil, advertisedSchemaIDs: [String]? = nil
    ) throws -> PreparedSchemeImport {
        var bytes: [String: Data] = [:]
        var fileResources: [String: RecipeFileResource] = [:]
        let modelStaging = FileManager.default.temporaryDirectory
        var names = Set<String>()
        var total = 0, modelTotal = 0
        guard !files.isEmpty, files.count <= 2000 else {
            throw RecipeInstallError.invalidResource("导入的输入方案为空或文件数量超过 2000 个")
        }
        var snapshotFiles: [PickedFile] = []
        for file in files {
            // Learned-word snapshots are not source files; they wait for the user's answer instead.
            if SchemeSourceCheck.isLearningSnapshot(file.path), SchemeSourceCheck.safe(file.path),
                names.insert(file.path.lowercased()).inserted, file.location.isFileURL
            {
                if let node = DiskPickedNode(url: file.location), !node.isDirectory {
                    snapshotFiles.append(PickedFile(name: file.location.lastPathComponent, read: node.file().read))
                }
                continue
            }
            guard SchemeSourceCheck.safe(file.path), names.insert(file.path.lowercased()).inserted,
                file.location.isFileURL, !file.path.contains(".userdb")
            else {
                throw RecipeInstallError.invalidResource("路径不安全、重复或包含不支持的用户数据文件：\(file.path)")
            }
            if RecipeResourceBudget.isModel(file.path) {
                fileResources[file.path] = try RecipeFileResource.snapshot(
                    from: file.location, directory: modelStaging,
                    maximumBytes: min(RecipeResourceBudget.modelFile, RecipeResourceBudget.modelTotal - modelTotal))
                modelTotal += fileResources[file.path]!.size
                try RecipeResourceBudget.validate(fileResources.mapValues(\.size))
                try Prediction.validateDatabases(in: [file.path: fileResources[file.path]!])
                continue
            }
            let data = try BoundedLocalFile.read(
                file.location,
                maximumBytes: min(RecipeResourceBudget.sourceFile, RecipeResourceBudget.sourceTotal - total))
            total += data.count
            bytes[file.path] = data
        }
        return try prepareSchemeImport(
            bytes: bytes, fileResources: fileResources, declaration: supplied,
            learning: folderLearning ?? Self.collectLearning(files: snapshotFiles),
            advertisedSchemaIDs: advertisedSchemaIDs)
    }

    /// Reads the shipped snapshots a package carries. Nothing here fails an import: a pick over the
    /// snapshot bounds, or one that cannot be read, simply brings no learned words.
    nonisolated static func collectLearning(files: [PickedFile]) -> CollectedSnapshots {
        guard !files.isEmpty else { return .empty }
        return (try? RimeSnapshotCollector.collect(files: files, byContent: false)) ?? .empty
    }

    nonisolated static func collectLearning(in directory: URL) -> CollectedSnapshots {
        guard let root = DiskPickedNode(url: directory), let files = try? RimeSnapshotCollector.files(in: root) else {
            return .empty
        }
        return collectLearning(files: files)
    }

    /// The scheme files the app ships in its bundle, installed like an imported scheme so they
    /// share every keyboard and publication path. Only the manifest's entry schemes are taken: the
    /// bundled compact companions belong to the keyboard's offline fallback, and an installed scheme
    /// generates its own when a compact keyboard is added.
    nonisolated func prepareBundledPackage(directory: URL) throws -> PreparedSchemeImport {
        let manifest = try BoundedLocalFile.read(
            directory.appendingPathComponent("manifest.yaml"),
            maximumBytes: RecipeResourceBudget.sourceFile)
        guard let root = try BoundedYAML.load(yaml: String(decoding: manifest, as: UTF8.self)) as? [String: Any],
            let id = root["id"] as? String, let name = root["name"] as? String,
            let entries = (root["entrypoints"] as? [String: Any])?["schemas"] as? [String], !entries.isEmpty
        else {
            throw RecipeInstallError.invalidManifest("内置输入方案的说明文件无效")
        }
        var bytes: [String: Data] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let path = file.lastPathComponent
            guard path != "manifest.yaml", path.hasSuffix(".yaml") else { continue }
            if path.hasSuffix(".schema.yaml"), !entries.contains(String(path.dropLast(12))) { continue }
            bytes[path] = try BoundedLocalFile.read(file, maximumBytes: RecipeResourceBudget.sourceFile)
        }
        guard let defaults = bytes["default.yaml"] else {
            throw RecipeInstallError.invalidManifest("内置输入方案缺少 default.yaml")
        }
        let kept = String(decoding: defaults, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let item = line.trimmingCharacters(in: .whitespaces)
                guard item.hasPrefix("- schema:") else { return true }
                return entries.contains(item.dropFirst(9).trimmingCharacters(in: .whitespaces))
            }
        bytes["default.yaml"] = Data(kept.joined(separator: "\n").utf8)
        return try prepareSchemeImport(
            bytes: bytes, fileResources: [:],
            declaration: SchemePackageDeclaration(id: id, name: name, bindings: []))
    }

    nonisolated private func prepareSchemeImport(
        bytes source: [String: Data], fileResources: [String: RecipeFileResource],
        declaration supplied: SchemePackageDeclaration?,
        learning: CollectedSnapshots = .empty, advertisedSchemaIDs: [String]? = nil
    ) throws -> PreparedSchemeImport {
        var bytes = source
        let sourceFiles = bytes
        let availableSchemas = InstalledPackageLayout.topLevelSchemaFiles(in: bytes.keys).map {
            String($0.dropLast(12))
        }.sorted()
        if let advertisedSchemaIDs,
            advertisedSchemaIDs.isEmpty || !Set(advertisedSchemaIDs).isSubset(of: Set(availableSchemas))
        {
            throw RecipeInstallError.invalidManifest(
                Bundle.main.localizedString(
                    forKey: "catalog.missingInputMethod", value: "下载的方案缺少输入方式，请重新下载。", table: nil))
        }
        let declaration: SchemePackageDeclaration
        if let supplied {
            declaration = supplied
        } else if let data = bytes[InstalledPackageLayout.keyboardPackageFile] {
            declaration = try JSONDecoder().decode(SchemePackageDeclaration.self, from: data)
        } else {
            let ids = availableSchemas
            guard let first = ids.first else {
                throw RecipeInstallError.invalidManifest("导入内容缺少根目录下的 .schema.yaml 方案文件")
            }
            let identities = bytes.mapValues(SchemeSourceCheck.hash).merging(fileResources.mapValues(\.sha256)) {
                _, new in new
            }
            let identity = identities.keys.sorted().map { $0 + identities[$0]! }.joined(separator: "\n")
            // Display name is the first schema in the source's default.yaml enabled list (same rule
            // as entry selection, e.g. rime_ice for Rime-ice), not the first file by name sorting
            // (which would name a whole source after double_pinyin's schema).
            let listed = SchemeSourceCheck.matches(
                "^\\s*-\\s*schema:\\s*[\"']?([A-Za-z0-9_.-]+)",
                String(data: bytes["default.yaml"] ?? Data(), encoding: .utf8) ?? "")
            let primary = advertisedSchemaIDs?.first ?? listed.first(where: ids.contains) ?? first
            let schemaText = String(data: bytes[InstalledPackageLayout.schemaFile(primary)]!, encoding: .utf8) ?? ""
            let name =
                SchemeSourceCheck.matches("^\\s+name:\\s*[\"']?([^\"'\\r\\n#]+)", schemaText).first?
                .trimmingCharacters(in: .whitespaces) ?? primary
            // Without an explicit stable package ID, different source bytes receive separate
            // learning namespaces. Matching filenames alone cannot prove encoding compatibility.
            declaration = SchemePackageDeclaration(
                id: "scheme-" + String(SchemeSourceCheck.hash(Data(identity.utf8)).prefix(16)), name: name, bindings: []
            )
        }
        guard SchemeSourceCheck.safe(declaration.id), !declaration.id.contains("/"), !declaration.name.isEmpty,
            !declaration.id.contains("..")
        else { throw RecipeInstallError.invalidManifest("输入方案声明为空或标识无效") }
        var layouts = Set<String>()
        for binding in declaration.bindings {
            guard let layout = KeyboardLayoutKind(rawValue: binding.layout),
                layouts.insert(binding.layout).inserted, SchemeSourceCheck.safe(binding.schemaID),
                !binding.schemaID.contains("/"), !binding.code.isEmpty, !binding.candidate.isEmpty,
                binding.code.utf8.allSatisfy({
                    layout.keyFold == .phoneDigits ? (50...57).contains($0) : ((97...122).contains($0) || $0 == 39)
                }),
                bytes["\(binding.schemaID).schema.yaml"] != nil
            else {
                throw RecipeInstallError.invalidManifest("每个键盘布局的输入方式映射必须有效且唯一：\(binding.schemaID)/\(binding.layout)")
            }
            if layout.keyFold == .letterGroups, let fold = layout.compactFold,
                !Set(binding.code).isSubset(of: fold.keysSent.union(["'"]))
            {
                throw RecipeInstallError.invalidManifest("\(layout.userTitle)的验证码只能用这个布局按键实际发送的字母：\(binding.code)")
            }
        }
        let schemas = advertisedSchemaIDs ?? availableSchemas
        guard !schemas.isEmpty else { throw RecipeInstallError.invalidManifest("没有可安装的输入方案") }
        try SharedRimePresets.supplement(
            &bytes, openCCDirectory: sharedOpenCCDirectory, enabledSchemaIDs: advertisedSchemaIDs)
        if let advertisedSchemaIDs {
            try Self.enforceAdvertisedSchemaList(&bytes, advertised: advertisedSchemaIDs)
        }
        try SchemeSourceCheck.dependencies(bytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if bytes[InstalledPackageLayout.keyboardPackageFile] == nil || supplied != nil {
            bytes[InstalledPackageLayout.keyboardPackageFile] = try encoder.encode(declaration)
        }
        try RecipeResourceBudget.validate(
            bytes.mapValues(\.count).merging(fileResources.mapValues(\.size)) { _, new in new })
        let records = Set(bytes.keys).union(fileResources.keys).sorted().map { path in
            if let file = fileResources[path] {
                return RecipeManifest.File(path: path, sha256: file.sha256, size: file.size)
            }
            return RecipeManifest.File(
                path: path, sha256: SchemeSourceCheck.hash(bytes[path]!), size: bytes[path]!.count)
        }
        let defaults = String(data: bytes["default.yaml"] ?? Data(), encoding: .utf8) ?? ""
        let listedSchemas = SchemeSourceCheck.matches("^\\s*-\\s*schema:\\s*[\"']?([A-Za-z0-9_.-]+)", defaults)
        let entrySchema =
            advertisedSchemaIDs?.first ?? declaration.bindings.first?.schemaID
            ?? listedSchemas.first(where: { schemas.contains($0) }) ?? schemas[0]
        let revision = String(
            SchemeSourceCheck.hash(Data(records.map { $0.path + $0.sha256 }.joined().utf8)).prefix(40))
        let manifest = RecipeManifest(
            id: declaration.id, repository: "user/import", revision: revision,
            recipePath: InstalledPackageLayout.keyboardPackageFile, license: "用户提供的方案文件",
            schemaID: entrySchema, requiredComponents: [], files: records, origin: .userScheme)
        return PreparedSchemeImport(
            declaration: declaration, manifest: manifest, schemaIDs: schemas, bytes: bytes, sourceFiles: sourceFiles,
            fileResources: fileResources, learningSnapshots: learning)
    }

    /// A catalogue entry decides which input methods an installation offers. A shipped default.yaml
    /// keeps all of its author configuration but publishes exactly the advertised schema_list. A
    /// shipped schema_list patch would silently override that choice, so it is refused rather than
    /// stripped, and the author's patch is preserved in the source snapshot.
    private static func enforceAdvertisedSchemaList(
        _ bytes: inout [String: Data], advertised: [String]
    ) throws {
        if let custom = bytes["default.custom.yaml"] {
            let text = String(decoding: custom, as: UTF8.self)
            guard let root = try? BoundedYAML.load(yaml: text) as? [String: Any] else {
                throw RecipeInstallError.invalidManifest(
                    Bundle.main.localizedString(
                        forKey: "catalog.schemaListUnreadable",
                        value: "无法核对这个输入方案的输入方式列表，请重新下载。", table: nil))
            }
            switch SchemeSourceCheck.schemaListPatch(in: root) {
            case .untouched:
                break
            case .replaced(let list) where list == advertised:
                break
            case .replaced, .unreadable:
                throw RecipeInstallError.invalidManifest(
                    Bundle.main.localizedString(
                        forKey: "catalog.schemaListConflict",
                        value: "这个输入方案会改动输入方式列表，和推荐目录不一致，请重新下载。", table: nil))
            }
        }
        guard let data = bytes["default.yaml"] else { return }
        guard var root = try BoundedYAML.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any]
        else {
            throw RecipeInstallError.invalidManifest(
                Bundle.main.localizedString(
                    forKey: "catalog.schemaListUnreadable",
                    value: "无法核对这个输入方案的输入方式列表，请重新下载。", table: nil))
        }
        root["schema_list"] = advertised.map { ["schema": $0] }
        bytes["default.yaml"] = Data(try Yams.dump(object: root).utf8)
    }

    /// An update passes the generation it started from; the store compares it under its lock so
    /// an installation that changed meanwhile is reported instead of overwritten. `nil` skips the check.
    @discardableResult
    func installSchemeImport(
        _ prepared: PreparedSchemeImport, expectedGeneration: String? = nil,
        deploy: @escaping Deploy
    ) async throws -> InstalledRecipe {
        // `.some(nil)` would demand an empty store, so nil maps to the unchecked outer nil.
        let expected: String?? = expectedGeneration.map { Optional($0) }
        return try await installResources(
            prepared.manifest, initialUserDataURL: nil,
            deploy: { deployment in
                try InstalledRecipeSources(
                    files: prepared.sourceFiles, fileResources: prepared.sourceFileResources, receipts: []
                )
                .write(to: deployment.resourceURL.deletingLastPathComponent())
                return try await deploy(deployment)
            }, fileResources: prepared.fileResources,
            expectedActiveGeneration: expected
        ) { file in
            try prepared.read(file.path)
        }
    }
}

enum SchemeSourceCheck {
    static func expandingLocalDependencies(_ seeds: [String], inventory: [String: Data]) throws -> [String] {
        var paths = Set(seeds)
        while true {
            let selected = inventory.filter { paths.contains($0.key) }
            let local = try missingDependencies(selected, inventory: inventory).filter {
                inventory[$0] != nil && !paths.contains($0)
            }
            if local.isEmpty { return paths.sorted() }
            paths.formUnion(local)
        }
    }
    /// Read on bytes, the way librime reads a path: a combining mark after `/`, `:` or `\` must not hide it.
    static func safe(_ path: String) -> Bool {
        let bytes = path.utf8
        return !bytes.isEmpty && bytes.first != 0x2F
            && bytes.split(separator: 0x2F, omittingEmptySubsequences: false).allSatisfy { part in
                !part.isEmpty && !part.elementsEqual(".".utf8) && !part.elementsEqual("..".utf8)
                    && !part.contains(0x5C) && !part.contains(0x3A)
            } && path.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
    /// macOS Finder/Archive Utility artifacts: `__MACOSX/` resource-fork trees,
    /// `._*` AppleDouble files and `.DS_Store`.
    static func isFinderMetadata(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard let first = components.first, let last = components.last else { return false }
        return first == "__MACOSX" || last.hasPrefix("._") || last == ".DS_Store"
    }
    /// A librime `*.userdb.txt` text snapshot: the file itself, with no `.userdb` folder above it.
    /// Anything else with `userdb` in its path stays refused.
    static func isLearningSnapshot(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard let last = parts.last, last.lowercased().hasSuffix(".userdb.txt") else { return false }
        return !parts.dropLast().contains { $0.contains(".userdb") }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// Files a package provides for librime: configuration, dictionaries, Lua, OpenCC data and models.
    /// Everything else (licences, readmes, workflows) is attribution and documentation.
    static func isRuntimeSourceFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [".yaml", ".lua", ".txt", ".json", ".gram", ".ocd", ".ocd2"].contains(where: lower.hasSuffix)
            || Prediction.isDatabasePath(path)
    }
    /// What a default.custom.yaml patch does to the schema_list. Untouched keeps the author's
    /// other customisations; replaced is accepted only when it equals the advertised list;
    /// unreadable cannot be proven to keep that choice and is refused.
    enum SchemaListPatch: Equatable {
        case untouched
        case replaced([String])
        case unreadable
    }
    static func schemaListPatch(in root: [String: Any]) -> SchemaListPatch {
        var result = SchemaListPatch.untouched
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    if key == "schema_list" || key.hasPrefix("schema_list/") || key.hasPrefix("schema_list@") {
                        guard result == .untouched else { continue }
                        guard let rows = child as? [[String: Any]],
                            rows.allSatisfy({ $0["schema"] is String })
                        else {
                            result = .unreadable
                            continue
                        }
                        result = .replaced(rows.compactMap { $0["schema"] as? String })
                        continue
                    }
                    walk(child)
                }
            } else if let array = value as? [Any] {
                for item in array { walk(item) }
            }
        }
        walk(root)
        return result
    }

    /// Upstream attribution (licences, notices, readmes). Such a file can carry a runtime extension
    /// (a shipped LICENSE.txt), so the merge classifies it before the generic runtime rule.
    static func isDocumentation(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let stem = (name.split(separator: ".").first.map(String.init) ?? name).uppercased()
        let documentNames = [
            "LICENSE", "LICENCE", "NOTICE", "COPYING", "AUTHORS", "PROVENANCE", "README", "CHANGELOG",
            "HISTORY", "THIRD-PARTY-NOTICES",
        ]
        return documentNames.contains { stem == $0 || stem.hasPrefix($0 + "-") || stem.hasPrefix($0 + "_") }
    }
    static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
    static func dependencies(_ files: [String: Data]) throws {
        let missing = try dependencyClosure(files).required
        guard missing.isEmpty else {
            if missing.allSatisfy({ $0.hasSuffix(".schema.yaml") }) {
                throw RecipeInstallError.missingSchemaFiles(missing)
            }
            throw RecipeInstallError.invalidResource("缺少输入方案依赖项：" + missing.joined(separator: "、"))
        }
    }
    /// Every referenced path the tree lacks, the optional ones included, so a source download can fetch them all.
    static func missingDependencies(_ files: [String: Data], inventory: [String: Data]? = nil) throws -> [String] {
        let closure = try dependencyClosure(files, inventory: inventory)
        return (closure.required + closure.optional).sorted()
    }

    /// What the tree lacks. `required` stops an installation; `optional` does not: files reached only
    /// through a schema's `dependencies` (a reverse-lookup scheme librime builds when present) or a
    /// dictionary's `use_preset_vocabulary`. librime deploys the input method without them and only that
    /// lookup, or the preset vocabulary, is absent; packages such as 薄荷 and 白霜 rely on the shared
    /// `luna_pinyin` and `essay` that a desktop Rime installs.
    static func dependencyClosure(_ files: [String: Data], inventory: [String: Data]? = nil) throws -> (
        required: [String], optional: [String]
    ) {
        var missing = Set<String>()
        var optional = Set<String>()
        var softPending: [String] = []
        var soft = false
        // Source inventory can include variants which are not deployment roots.
        // Follow the actual plain schema_list when available; includes/patches
        // and absent defaults conservatively retain the full inventory scan.
        var selected: Set<String>?
        if let data = files["default.yaml"],
            let root = try? BoundedYAML.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any]
        {
            var list = root["schema_list"] as? [[String: Any]]
            if let customData = files["default.custom.yaml"] {
                // Recognize only literal replacement patches (including the
                // frontend's archived keyboard-enable recipe). Unknown native
                // patch/include expressions retain conservative inventory checks.
                if let custom = try? BoundedYAML.load(yaml: String(decoding: customData, as: UTF8.self))
                    as? [String: Any],
                    let patch = custom["patch"] as? [String: Any], custom["__patch"] == nil,
                    let replacement = patch["schema_list"] as? [[String: Any]]
                {
                    list = replacement
                } else if let custom = try? BoundedYAML.load(yaml: String(decoding: customData, as: UTF8.self))
                    as? [String: Any],
                    custom["patch"] == nil, let patches = custom["__patch"] as? [[String: Any]],
                    patches.allSatisfy({ $0.count == 1 && $0["patch/+"] is [String: Any] })
                {
                    for item in patches {
                        if let replacement = (item["patch/+"] as? [String: Any])?["schema_list"] as? [[String: Any]] {
                            list = replacement
                        }
                    }
                } else {
                    list = nil
                }
            }
            if let list, list.allSatisfy({ $0["schema"] is String }) {
                let ids = Set(list.compactMap { $0["schema"] as? String })
                let present = ids.filter { files[$0 + InstalledPackageLayout.schemaFileSuffix] != nil }
                missing.formUnion(ids.subtracting(present).map { $0 + InstalledPackageLayout.schemaFileSuffix })
                if !present.isEmpty { selected = present }
            }
        }
        var pending = files.keys.filter {
            if let selected {
                if $0.hasSuffix(".schema.yaml") { return selected.contains(String($0.dropLast(12))) }
                if $0.hasSuffix(".dict.yaml") { return false }
                if $0.hasPrefix("lua/") { return false }
            }
            return ($0.hasSuffix(".yaml") && !$0.contains("/")) || $0 == "rime.lua"
                || ($0.hasPrefix("lua/") && $0.hasSuffix(".lua")) || ($0.hasPrefix("opencc/") && $0.hasSuffix(".json"))
        }
        var visited = Set<String>()
        func require(_ name: String) throws {
            guard safe(name) else { throw RecipeInstallError.invalidResource("依赖项路径非法：\(name)") }
            if files[name] == nil {
                if soft { optional.insert(name) } else { missing.insert(name) }
            } else if !visited.contains(name) {
                pending.append(name)
            }
        }
        func requireOptional(_ name: String) throws {
            if soft { return try require(name) }
            guard safe(name) else { throw RecipeInstallError.invalidResource("依赖项路径非法：\(name)") }
            softPending.append(name)
        }
        func requireModule(_ module: String) throws {
            let base = "lua/" + module.replacingOccurrences(of: ".", with: "/")
            let available = inventory ?? files
            // Match package.path order: ?.lua before ?/init.lua. The actual
            // chosen file must be required AND enqueued, including init modules.
            let path =
                available[base + ".lua"] != nil
                ? base + ".lua"
                : available[base + "/init.lua"] != nil ? base + "/init.lua" : base + ".lua"
            try require(path)
        }
        while true {
            guard let path = pending.popLast() else {
                // The required closure is complete; what only the optional edges reach comes after it.
                if soft || softPending.isEmpty { break }
                soft = true
                for name in softPending { try require(name) }
                continue
            }
            guard visited.insert(path).inserted, let data = files[path] else { continue }
            // Repository documentation, workflows and examples are not deployed Rime configs.
            let yaml = path.hasSuffix(".yaml")
            let lua = path == "rime.lua" || (path.hasPrefix("lua/") && path.hasSuffix(".lua"))
            let opencc = path.hasPrefix("opencc/") && path.hasSuffix(".json")
            guard yaml || lua || opencc else { continue }
            guard let text = String(data: data, encoding: .utf8) else {
                throw RecipeInstallError.invalidResource("文件不是 UTF-8 编码：\(path)")
            }
            if yaml {
                // Dictionary rows following the YAML document terminator are tabular text.
                let end =
                    path.hasSuffix(".dict.yaml")
                    ? text.range(of: "(?m)^\\.\\.\\.[ \\t]*(?:#[^\\r\\n]*)?\\r?$", options: .regularExpression)?
                        .lowerBound : nil
                let source = end.map { String(text[..<$0]) } ?? text
                let root: Node?
                do { root = try BoundedYAML.compose(yaml: source) } catch let error as BoundedYAML.LimitExceeded {
                    throw RecipeInstallError.invalidResource("\(path)：\(error.localizedDescription)")
                } catch is CancellationError { throw CancellationError() } catch {
                    throw RecipeInstallError.invalidResource("YAML 格式无效：\(path)：\(error)")
                }
                // BoundedYAML already caps expansion; keep an independent budget for the walkers below.
                var budget = 2 * BoundedYAML.maximumExpandedNodes  // two walks below
                func spend() throws {
                    budget -= 1
                    guard budget >= 0 else { throw RecipeInstallError.invalidResource("\(path)：YAML 节点数量过多") }
                    if budget & 0xFFF == 0 { try Task.checkCancellation() }
                }
                func scalar(_ node: Node) -> String? { node.tag == Tag(.null) ? nil : node.string }
                func reference(_ node: Node) throws {
                    guard let value = scalar(node), let colon = value.firstIndex(of: ":"), colon != value.startIndex
                    else { return }
                    // librime ConfigCompiler::CreateReference: unqualified and :/ paths
                    // refer to the current resource; '?' marks an optional reference.
                    let name = String(value[..<colon])
                    let file = name.hasSuffix(".yaml") ? name : name + ".yaml"
                    guard safe(file) else { throw RecipeInstallError.invalidResource("依赖项路径非法：\(file)") }
                    if !value.contains("?") || files[file] != nil { try require(file) }
                }
                func visit(_ node: Node) throws {
                    try spend()
                    if let mapping = node.mapping {
                        for (key, value) in mapping {
                            switch key.string {
                            case "__include": try reference(value)
                            case "__patch":
                                if let list = value.sequence {
                                    for item in list { try reference(item) }
                                } else {
                                    try reference(value)
                                }
                            case "dictionary":
                                if let name = scalar(value), !name.isEmpty { try require(name + ".dict.yaml") }
                            case "use_preset_vocabulary":
                                if value.bool == true { try requireOptional("essay.txt") }
                            case "import_preset":
                                if let name = scalar(value), !name.isEmpty { try require(name + ".yaml") }
                            case "opencc_config":
                                if let name = scalar(value), !name.isEmpty { try require("opencc/" + name) }
                            case "import_tables", "dependencies":
                                if let list = value.sequence {
                                    for item in list {
                                        guard let name = scalar(item), !name.isEmpty else { continue }
                                        if key.string == "dependencies" {
                                            try requireOptional(name + InstalledPackageLayout.schemaFileSuffix)
                                        } else {
                                            try require(name + ".dict.yaml")
                                        }
                                    }
                                }
                            default: break
                            }
                            try visit(value)
                        }
                    } else if let list = node.sequence {
                        for item in list { try visit(item) }
                    }
                }
                if let root { try visit(root) }
                // Inspect parsed scalar values: comments often document the legacy
                // @global syntax even when the actual component uses @*module.
                func luaReferences(_ node: Node) throws {
                    try spend()
                    if let mapping = node.mapping {
                        for (_, value) in mapping { try luaReferences(value) }
                    } else if let list = node.sequence {
                        for value in list { try luaReferences(value) }
                    } else if let value = scalar(node) {
                        for module in matches(
                            "^lua_(?:processor|translator|filter|segmentor)@\\*([A-Za-z0-9_.]+)", value)
                        {
                            try requireModule(module)
                        }
                        if !matches("^lua_(?:processor|translator|filter|segmentor)@(?!\\*)([A-Za-z0-9_]+)", value)
                            .isEmpty
                        {
                            try require("rime.lua")
                        }
                    }
                }
                if let root { try luaReferences(root) }
            } else if path.hasSuffix(".lua") {
                for module in matches("require\\s*\\(?\\s*[\"']([A-Za-z0-9_./-]+)[\"']", text)
                where !["math", "string", "table", "utf8", "rime"].contains(module) {
                    try requireModule(module)
                }
            } else if path.hasPrefix("opencc/") {
                let object = try JSONSerialization.jsonObject(with: data)
                func visit(_ value: Any) throws {
                    if let dict = value as? [String: Any] {
                        if let file = dict["file"] as? String { try require("opencc/" + file) }
                        for child in dict.values { try visit(child) }
                    } else if let array = value as? [Any] {
                        for child in array { try visit(child) }
                    }
                }
                try visit(object)
            }
        }
        return (missing.sorted(), optional.subtracting(missing).sorted())
    }
}

/// Frontend-selected enablement for schemas the live engine can actually run. The
/// source YAML remains in resources/sourceFiles; only this transaction's private
/// user configuration receives the schema_list override.
public enum SupportedSchemaSelection {
    /// Identity of our managed block, in the same `# Rx:` form plum's recipe.sh uses.
    static let rx = "songyan:supported_schemas:"

    /// The user's or package's `default.custom.yaml` (often written by plum, with `__patch`,
    /// `__include` and comments) is kept byte for byte; our selection is one more `__patch`
    /// entry, applied last, so it overrides `schema_list` the way a later Rime patch does.
    public static func stage(_ schemaIDs: [String], deployment: RecipeDeployment) throws {
        guard !schemaIDs.isEmpty, Set(schemaIDs).count == schemaIDs.count,
            schemaIDs.allSatisfy({ !$0.contains("/") && SchemeSourceCheck.safe($0) })
        else {
            throw RecipeInstallError.invalidResource("没有可启用的输入方案")
        }
        let name = "default.custom.yaml"
        let user = deployment.userDataURL.appendingPathComponent(name)
        let resource = deployment.resourceURL.appendingPathComponent(name)
        let existing = FileManager.default.fileExists(atPath: user.path) ? user : resource
        var original = ""
        if FileManager.default.fileExists(atPath: existing.path) {
            guard let text = String(data: try Data(contentsOf: existing), encoding: .utf8) else {
                throw RecipeInstallError.invalidResource("default.custom.yaml 不是 UTF-8 文本，请改成 UTF-8 编码后重试。")
            }
            original = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        }
        // JSON string literals are valid YAML double-quoted scalars, so any safe ID stays a string.
        let items = try schemaIDs.map { id in
            "        - schema: " + String(decoding: try JSONEncoder().encode(id), as: UTF8.self) + "\n"
        }
        let body = "  - patch/+:\n      schema_list:\n" + items.joined()
        let merged: String
        do { merged = try RecipePlanSupport.patch(original, body: body, rx: rx) } catch {
            throw RecipeInstallError.invalidResource("default.custom.yaml 的写法无法自动加入输入方案选择，请检查这个文件后重试。")
        }
        try Data(merged.utf8).write(to: user, options: .atomic)
    }
}
