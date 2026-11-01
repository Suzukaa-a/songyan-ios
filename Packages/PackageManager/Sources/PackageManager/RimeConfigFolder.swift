import Foundation

/// The user's own Rime files (`*.custom.yaml`, extra dictionaries) kept in a folder they can edit in
/// the Files app and laid over the librime user directory of every new generation, as desktop Rime does.
public enum RimeConfigFolder {
    public static let name = "Rime 配置"
    /// Names copied into a generation's user directory. User snapshots carry files forward, so the
    /// next install removes exactly these first; a file deleted from the folder then disappears.
    static let listFile = "songyan-user-config.txt"
    static let maximumFileBytes = 4 * 1024 * 1024
    static let maximumTotalBytes = 8 * 1024 * 1024
    static let maximumFiles = 100

    /// A `.yaml` / `.txt` file in the folder that cannot be used (too large, not UTF-8, over the limits).
    public struct RejectedFile: LocalizedError {
        public let name: String
        public var errorDescription: String? { "「\(RimeConfigFolder.name)」里的「\(name)」不能使用。" }
    }

    /// Names the last install copied into `user`; empty when it copied none.
    static func names(in user: URL?) -> Set<String> {
        guard let user, let data = try? Data(contentsOf: user.appendingPathComponent(listFile)) else { return [] }
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    /// Replaces the previously copied files in `user` with the folder's current flat `.yaml` / `.txt`
    /// files. A missing folder copies nothing, so its earlier files are removed too.
    static func apply(_ folder: URL, to user: URL) throws {
        let fm = FileManager.default
        for name in names(in: user) where !name.contains("/") && name != ".." {
            try? fm.removeItem(at: user.appendingPathComponent(name))
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let children =
            (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles))
            ?? []
        var copied: [String] = []
        var total = 0
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            let name = child.lastPathComponent
            let values = try child.resourceValues(forKeys: Set(keys))
            guard name.hasSuffix(".yaml") || name.hasSuffix(".txt"), name != listFile,
                values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            guard copied.count < maximumFiles,
                let data = try? BoundedLocalFile.read(child, maximumBytes: maximumFileBytes),
                total + data.count <= maximumTotalBytes, String(data: data, encoding: .utf8) != nil
            else { throw RejectedFile(name: name) }
            total += data.count
            try data.write(to: user.appendingPathComponent(name), options: .atomic)
            copied.append(name)
        }
        try Data(copied.joined(separator: "\n").utf8).write(
            to: user.appendingPathComponent(listFile), options: .atomic)
    }
}

extension RecipePackageManager {
    /// Reinstalls the active installation from its own installed files into a fresh generation, so
    /// the config folder is laid over it again. Files the host wrote beside the package (recipe
    /// inputs, keyboard lists) are carried into the new generation before `deploy` runs.
    @discardableResult
    public func reinstallActivePackage(deploy: @escaping Deploy) async throws -> InstalledRecipe? {
        guard let active = try activeInstallation() else { return nil }
        let previous = active.resourceURL.deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            RecipeManifest.self, from: Data(contentsOf: previous.appendingPathComponent(InstalledPackageLayout.sourceFile)))
        let resources = active.resourceURL
        var models: [String: RecipeFileResource] = [:]
        for file in manifest.files where RecipeResourceBudget.isModel(file.path) {
            models[file.path] = RecipeFileResource(
                url: resources.appendingPathComponent(file.path), size: file.size, sha256: file.sha256)
        }
        return try await installResources(
            manifest, initialUserDataURL: nil,
            deploy: { deployment in
                try Self.copyMissing(from: previous, to: deployment.resourceURL.deletingLastPathComponent())
                return try await deploy(deployment)
            }, fileResources: models, expectedActiveGeneration: .some(active.installation.generation)
        ) { file in
            let data = try Data(contentsOf: resources.appendingPathComponent(file.path))
            // The installed entry is the generated sandbox around the package's own rime.lua.
            return file.path == LuaSandbox.entryPath ? (LuaSandbox.restoreOriginal(data) ?? data) : data
        }
    }

    /// The user directory is the fresh snapshot, never the old generation's copy.
    private static func copyMissing(from source: URL, to target: URL, topLevel: Bool = true) throws {
        let fm = FileManager.default
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = child.lastPathComponent
            if topLevel && name == InstalledPackageLayout.userDirectory { continue }
            let destination = target.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if !fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
                try fm.copyItem(at: child, to: destination)
            } else if isDirectory.boolValue, (try child.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                try copyMissing(from: child, to: destination, topLevel: false)
            }
        }
    }
}
