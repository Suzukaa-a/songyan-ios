import Foundation

/// A package's own files as the user-config code needs them: the hash of each file the package
/// ships, and a way to read its bytes.
struct PackageFiles: Sendable {
    /// The package's id: what the user's confirmations of its scripts are scoped to.
    var id = ""
    /// Path to the SHA-256 of the package's own bytes.
    let hashes: [String: String]
    let read: @Sendable (String) -> Data?

    static let none = PackageFiles(id: "", hashes: [:], read: { _ in nil })

    /// The files a manifest lists, read from `resources`. Scripts the app replaced with the user's
    /// copy are read from `originals`, where the install kept the package's bytes.
    static func installed(
        _ files: [RecipeManifest.File], resources: URL, originals: URL?, id: String = ""
    ) -> PackageFiles {
        let hashes = Dictionary(
            files.filter { UserConfigFiles.isAllowedPath($0.path) }.map { ($0.path, $0.sha256) },
            uniquingKeysWith: { first, _ in first })
        return PackageFiles(id: id, hashes: hashes) { path in
            guard hashes[path] != nil, UserConfigSafety.safePath(path) else { return nil }
            if let originals, let data = try? Data(contentsOf: originals.appendingPathComponent(path)) { return data }
            guard let data = try? Data(contentsOf: resources.appendingPathComponent(path)) else { return nil }
            // The installed entry is the generated sandbox around the package's own rime.lua.
            return path == LuaSandbox.entryPath ? LuaSandbox.restoreOriginal(data) : data
        }
    }
}

/// Where the app keeps what it knows about the user's files besides the files themselves: which
/// copies replace a package file, and which scripts the user agreed to use. Private to the app, because
/// the folder itself can be written by any app the user lets into it.
struct UserConfigState: Sendable {
    let directory: URL?
    static let lock = NSLock()

    var overridesFile: URL? { directory?.appendingPathComponent("overrides.json") }
    var scriptsFile: URL? { directory?.appendingPathComponent("scripts-confirmed.json") }

    func read<T: Decodable>(_ file: URL?, as type: T.Type) -> T? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func write<T: Encodable>(_ value: T, to file: URL?) throws {
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
    }
}

/// The user's files that replace a file of the package in use, as on desktop Rime: a file in the user
/// folder with the same relative path wins over the package's own, as a whole.
///
/// Editing a package file creates such a copy (the package is never touched), so the copy is the only
/// place the user's version lives and a package update cannot merge into it. Two facts are kept in
/// `UserConfigState`: the package file's hash when the copy was made (to tell that the package has a
/// newer version since) and which copies the user has been told about (once each).
struct UserOverrides: Sendable {
    let folder: URL
    let state: UserConfigState

    struct Entry: Equatable, Sendable {
        let path: String
        /// The package's own file changed since the copy was made.
        let updated: Bool
    }

    private struct Marks: Codable {
        var bases: [String: String] = [:]
        var acknowledged: [String] = []
    }

    /// The files of the user's folder that shadow a file of the package, by relative path.
    func entries(_ package: PackageFiles, excluding: Set<String> = []) -> [Entry] {
        let marks = readMarks()
        return shadowed(package).filter { !excluding.contains($0) }.map { path in
            let base = marks.bases[path]
            let current = package.hashes[path]
            return Entry(path: path, updated: base != nil && current != nil && base != current)
        }
    }

    /// The shadowing files the user has not been told about yet.
    func unacknowledged(_ package: PackageFiles, paths: [String]? = nil) -> [String] {
        let told = Set(readMarks().acknowledged)
        return (paths ?? shadowed(package)).filter { !told.contains($0) }
    }

    func acknowledge(_ paths: [String]) {
        UserConfigState.lock.lock()
        defer { UserConfigState.lock.unlock() }
        var marks = readMarks()
        marks.acknowledged = Array(Set(marks.acknowledged).union(paths))
        writeMarks(marks)
    }

    /// The user's file at `path` (relative to the package), or nil when there is none.
    func overrideFile(_ path: String) -> URL? {
        guard UserConfigFiles.isAllowedPath(path), let url = Self.inside(folder, path) else { return nil }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true ? url : nil
    }

    /// Makes the user's copy of the package file `path` when there is none, from the package's bytes, and
    /// returns it. An existing copy is left as it is. Throws when the file cannot be an override (name,
    /// size, count): the import rules for a path, and only a file the package has.
    @discardableResult
    func copyOf(_ path: String, package: PackageFiles) throws -> URL {
        guard UserConfigFiles.isAllowedPath(path), UserConfigSafety.safePath(path), package.hashes[path] != nil,
            !collides(path)
        else { throw UserConfigError(path, .name) }
        let existing = overrideFile(path)
        if existing == nil {
            guard let data = package.read(path) else { throw UserConfigError(path, .name) }
            guard data.count <= UserConfigFiles.maximumFileBytes else { throw UserConfigError(path, .tooLarge) }
            guard UserConfigFiles.files(in: folder).count < UserConfigFiles.maximumFiles else {
                throw UserConfigError(nil, .tooMany)
            }
        }
        guard let target = Self.inside(folder, path) else { throw UserConfigError(path, .name) }
        if existing == nil, let data = package.read(path) {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        recordBase(path, package: package)
        return target
    }

    /// Notes the package file's hash for `path` unless one is already known; call after the user's copy exists.
    func recordBase(_ path: String, package: PackageFiles) {
        UserConfigState.lock.lock()
        defer { UserConfigState.lock.unlock() }
        var marks = readMarks()
        guard marks.bases[path] == nil, let hash = package.hashes[path] else { return }
        marks.bases[path] = hash
        writeMarks(marks)
    }

    /// Deletes the user's copy at `path`, so the package's own file is used again.
    @discardableResult
    func restore(_ path: String) throws -> Bool {
        guard let file = overrideFile(path) else { return false }
        try FileManager.default.removeItem(at: file)
        pruneEmptyFolders(from: file.deletingLastPathComponent())
        forget(path)
        return true
    }

    /// Drops what is known about `path`; the user's copy there is gone or no longer a copy of anything.
    func forget(_ path: String) {
        UserConfigState.lock.lock()
        defer { UserConfigState.lock.unlock() }
        var marks = readMarks()
        guard marks.bases[path] != nil || marks.acknowledged.contains(path) else { return }
        marks.bases[path] = nil
        marks.acknowledged.removeAll { $0 == path }
        writeMarks(marks)
    }

    /// Whether the folder has a file whose path differs from `path` only in letter case.
    private func collides(_ path: String) -> Bool {
        UserConfigFiles.files(in: folder).contains {
            $0.path != path && $0.path.lowercased() == path.lowercased()
        }
    }

    private func shadowed(_ package: PackageFiles) -> [String] {
        UserConfigFiles.files(in: folder).map(\.path).filter { package.hashes[$0] != nil }
    }

    private func pruneEmptyFolders(from start: URL) {
        let root = folder.standardizedFileURL.path
        var directory = start.standardizedFileURL
        while directory.path != root, directory.path.hasPrefix(root + "/"),
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true
        {
            do { try FileManager.default.removeItem(at: directory) } catch { return }
            directory = directory.deletingLastPathComponent()
        }
    }

    private func readMarks() -> Marks { state.read(state.overridesFile, as: Marks.self) ?? Marks() }

    /// Only what the folder still holds is worth remembering; the rest would resurface for a file made later.
    private func writeMarks(_ marks: Marks) {
        let present = Set(UserConfigFiles.files(in: folder).map(\.path))
        var kept = Marks()
        kept.bases = marks.bases.filter { present.contains($0.key) }
        kept.acknowledged = marks.acknowledged.filter { present.contains($0) }.sorted()
        if kept.bases.isEmpty, kept.acknowledged.isEmpty {
            if let file = state.overridesFile { try? FileManager.default.removeItem(at: file) }
            return
        }
        try? state.write(kept, to: state.overridesFile)
    }

    /// `path` below `base`, or nil when it is not a plain relative path, a link is on the way, or
    /// the result would leave `base`. A link is never followed, whatever it points at.
    static func inside(_ base: URL, _ path: String) -> URL? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty,
            segments.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") && !$0.contains("\\")
                    && !$0.contains("\u{0}")
            })
        else { return nil }
        var step = base
        for segment in segments {
            step = step.appendingPathComponent(segment)
            if let values = try? step.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                return nil
            }
        }
        let root = base.standardizedFileURL.path
        return step.standardizedFileURL.path.hasPrefix(root + "/") ? step : nil
    }
}
