import Foundation

/// The user's own Rime files (`*.custom.yaml`, extra dictionaries, scripts) kept in a folder they can
/// edit in the Files app and laid over every new generation, as desktop Rime does.
///
/// A file in the folder with the path of one of the package's own files replaces it as a whole. Plain
/// text files go into the generation's user directory, where librime reads them before the package's;
/// scripts go into the generation's resources, the only place librime-lua loads them from, with the
/// package's own bytes kept beside so the next install can start from them again. Every file is
/// checked first (`UserConfigFiles.check`), and a script the user has not agreed to is left out.
public enum RimeConfigFolder {
    public static let name = "Rime 配置"
    /// Names copied into a generation. User snapshots carry files forward, so the next install removes
    /// exactly these first; a file deleted from the folder then disappears.
    static let listFile = "songyan-user-config.txt"
    static let maximumFileBytes = UserConfigFiles.maximumFileBytes
    static let maximumTotalBytes = UserConfigFiles.maximumTotalBytes
    static let maximumFiles = UserConfigFiles.maximumFiles
    /// Beside `resources`: the package's bytes of every script the user's copy replaced.
    static let originalsDirectory = "package-originals"

    /// Files librime itself writes into the user directory; the folder never replaces them.
    static let reservedNames: Set<String> = ["installation.yaml", "user.yaml", listFile]

    /// Names the last install copied into `user`; empty when it copied none.
    static func names(in user: URL?) -> Set<String> {
        guard let user, let data = try? Data(contentsOf: user.appendingPathComponent(listFile)) else { return [] }
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    /// Hands `written` back to the app: they leave the list, so the next `apply` neither deletes them
    /// nor lays the folder's copy over them.
    static func release(_ written: some Sequence<String>, in user: URL) throws {
        let listed = names(in: user)
        let kept = listed.subtracting(written)
        guard kept.count != listed.count else { return }
        try Data(kept.sorted().joined(separator: "\n").utf8).write(
            to: user.appendingPathComponent(listFile), options: .atomic)
    }

    /// What one install takes from the folder: the files that passed every check, in path order.
    struct Plan {
        var files: [(path: String, data: Data)] = []
        /// Scripts left out because the user has not agreed to them.
        var unconfirmed: [UserScripts.Entry] = []

        var scripts: [(path: String, data: Data)] { files.filter { UserConfigFiles.isScriptPath($0.path) } }
        var text: [(path: String, data: Data)] { files.filter { !UserConfigFiles.isScriptPath($0.path) } }
    }

    /// Reads and checks the folder. With `strict` (the user asked to apply) the first file that cannot be
    /// used, or script that is not agreed to, throws `UserConfigError` and nothing is taken; otherwise
    /// such a file is left out, so one bad file never blocks an import or an update. Files that are too
    /// large, not UTF-8, unreadable YAML, naming a file outside the data folders, or named like a file the
    /// app or librime keeps in `user` are left out either way; `unusedNames` reports them.
    static func plan(_ folder: URL, package: PackageFiles, state: UserConfigState, strict: Bool) throws -> Plan {
        var accepted: [(path: String, data: Data)] = []
        var total = 0
        var lowered = Set<String>()
        for entry in UserConfigFiles.files(in: folder) {
            try Task.checkCancellation()
            guard !reservedNames.contains(entry.path) else { continue }
            guard accepted.count < maximumFiles else {
                if strict { throw UserConfigError(nil, .tooMany) }
                break
            }
            guard
                let data = try? BoundedLocalFile.read(
                    entry.url, maximumBytes: maximumFileBytes, followingSymlinks: false),
                total + data.count <= maximumTotalBytes
            else {
                if strict { throw UserConfigError(entry.path, .tooLarge) }
                continue
            }
            if let error = UserConfigFiles.check(entry.path, data) {
                if strict { throw error }
                continue
            }
            guard lowered.insert(entry.path.lowercased()).inserted else {
                if strict { throw UserConfigError(entry.path, .name) }
                continue
            }
            total += data.count
            accepted.append((entry.path, data))
        }
        let unconfirmed = UserScripts(state: state).unconfirmed(
            Dictionary(accepted.map { ($0.path, $0.data) }, uniquingKeysWith: { first, _ in first }), package: package)
        if strict, let first = unconfirmed.first { throw UserConfigError(first.path, .unconfirmedScript) }
        let blocked = Set(unconfirmed.map(\.path))
        return Plan(files: accepted.filter { !blocked.contains($0.path) }, unconfirmed: unconfirmed)
    }

    /// Puts the plan's scripts into `resources`, keeping the package's own bytes of a script it replaces
    /// under `originals`. Call before the sandbox entry is generated. Returns the script paths written.
    static func overlayScripts(_ plan: Plan, resources: URL, originals: URL) throws -> [String] {
        let fm = FileManager.default
        var written: [String] = []
        for script in plan.scripts {
            let target = resources.appendingPathComponent(script.path)
            if fm.fileExists(atPath: target.path) {
                let kept = originals.appendingPathComponent(script.path)
                try fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: kept)
                try fm.copyItem(at: target, to: kept)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.data.write(to: target, options: .atomic)
            written.append(script.path)
        }
        return written
    }

    /// Replaces the previously copied files in `user` with the plan's text files and records them, with
    /// `overlaid` (the scripts already put into resources), in the list. A name the app already keeps in
    /// `user` is left to the app, so `unusedNames` reports the folder's copy.
    static func write(_ plan: Plan, to user: URL, overlaid: [String] = []) throws {
        let fm = FileManager.default
        // The app's blocks inside a copy it is about to remove go back into the new copy of that file.
        var kept: [String: [ManagedBlock]] = [:]
        for name in names(in: user) where UserConfigFiles.isAllowedPath(name) {
            let file = user.appendingPathComponent(name)
            if name.hasSuffix(".custom.yaml"), let text = try? String(contentsOf: file, encoding: .utf8) {
                kept[name] = managedBlocks(in: text)
            }
            try? fm.removeItem(at: file)
            var parent = file.deletingLastPathComponent()
            while parent.standardizedFileURL.path != user.standardizedFileURL.path,
                (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true
            {
                try? fm.removeItem(at: parent)
                parent = parent.deletingLastPathComponent()
            }
        }
        var copied: [String] = []
        for file in plan.text {
            try Task.checkCancellation()
            let target = user.appendingPathComponent(file.path)
            var content = file.data
            if file.path.hasSuffix(".custom.yaml") {
                // A custom file the app keeps blocks in: the user's lines and the app's blocks share one file.
                var blocks = kept[file.path] ?? []
                if fm.fileExists(atPath: target.path) {
                    blocks = managedBlocks(in: (try? String(contentsOf: target, encoding: .utf8)) ?? "")
                    guard !blocks.isEmpty else { continue }
                }
                if !blocks.isEmpty {
                    guard let text = String(data: file.data, encoding: .utf8),
                        let joined = checkedMerge(file.path, text, blocks: blocks)
                    else { continue }
                    content = Data(joined.utf8)
                    try? fm.removeItem(at: target)
                }
            }
            guard !fm.fileExists(atPath: target.path) else { continue }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: target, options: .atomic)
            } catch {
                continue
            }
            copied.append(file.path)
        }
        // A file that left the folder keeps the blocks the app put into it, as the app's own file.
        for (name, blocks) in kept where !blocks.isEmpty && !copied.contains(name) {
            let target = user.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path), let text = checkedMerge(name, "", blocks: blocks) else {
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: target, options: .atomic)
        }
        try Data((copied + overlaid).joined(separator: "\n").utf8).write(
            to: user.appendingPathComponent(listFile), options: .atomic)
    }

    /// Replaces the previously copied files in `user` with the folder's current text files, as an
    /// install that is not an explicit apply does, without scripts.
    static func apply(_ folder: URL, to user: URL) throws {
        let plan = try plan(folder, package: .none, state: UserConfigState(directory: nil), strict: false)
        try write(plan, to: user)
    }

    /// One block the app wrote into a custom file between `# Rx: <rx> {` and `# }`.
    struct ManagedBlock: Equatable {
        let rx: String
        /// The lines inside, each ending with a newline.
        let body: String
    }

    /// The blocks the app wrote into `text`. The text of a copy in `user` is the user's file plus the app's
    /// blocks, so each block is read back only if its lines are a valid patch on their own: anything else
    /// is not something the app wrote.
    static func managedBlocks(in text: String) -> [ManagedBlock] {
        scannedBlocks(in: text).filter { block in
            UserConfigFiles.check(
                "blocks.custom.yaml", Data(("__patch:\n" + block.body).utf8), allowingBlocks: true) == nil
        }
    }

    private static func scannedBlocks(in text: String) -> [ManagedBlock] {
        var blocks: [ManagedBlock] = []
        var current: (rx: String, body: String)?
        for line in text.components(separatedBy: "\n") {
            if let open = current {
                if line == "# }" {
                    blocks.append(ManagedBlock(rx: open.rx, body: open.body))
                    current = nil
                } else {
                    current = (open.rx, open.body + line + "\n")
                }
            } else if line.hasPrefix("# Rx: "), line.hasSuffix(" {") {
                current = (String(line.dropFirst(6).dropLast(2)), "")
            }
        }
        return blocks
    }

    /// The user's own lines of a custom file: everything but the app's blocks, and the `__patch:` line
    /// they leave empty.
    static func withoutManagedBlocks(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        var inside = false
        for line in lines {
            if inside {
                if line == "# }" { inside = false }
            } else if line.hasPrefix("# Rx: "), line.hasSuffix(" {") {
                inside = true
            } else {
                kept.append(line)
            }
        }
        lines = kept
        if let begin = lines.firstIndex(of: "__patch:") {
            let end =
                lines.indices.dropFirst(begin + 1).first {
                    !lines[$0].isEmpty && !lines[$0].hasPrefix(" ") && !lines[$0].hasPrefix("#")
                } ?? lines.count
            let remaining = lines[(begin + 1)..<end].contains {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
            if !remaining { lines.remove(at: begin) }
        }
        return lines.joined(separator: "\n")
    }

    /// The user's custom file with the app's `blocks` put back in, or nil when the two cannot be
    /// combined (the file has its own `__patch` in a shape the blocks cannot join); the caller then
    /// leaves the file to the app.
    static func merged(_ userText: String, blocks: [ManagedBlock]) -> String? {
        guard !blocks.isEmpty else { return userText }
        var text = withoutManagedBlocks(userText.replacingOccurrences(of: "\r\n", with: "\n"))
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        for block in blocks {
            guard let next = try? RecipePlanSupport.patch(text, body: block.body, rx: block.rx) else { return nil }
            text = next
        }
        return text
    }

    /// `merged`, accepted only when the result passes the same checks as a file of the user's (the blocks
    /// are the app's, but the text they land in is not), so nothing is written that no check has read.
    static func checkedMerge(_ name: String, _ userText: String, blocks: [ManagedBlock]) -> String? {
        guard let text = merged(userText, blocks: blocks),
            UserConfigFiles.check(name, Data(text.utf8), allowingBlocks: true) == nil
        else { return nil }
        return text
    }

    /// The app's blocks of a custom file alone, as the workspace reads a file the folder also has: the
    /// folder's own lines are the folder's.
    static func blocksOnly(_ data: Data) -> Data? {
        let blocks = managedBlocks(in: String(decoding: data, as: UTF8.self))
        return blocks.isEmpty ? nil : checkedMerge("blocks.custom.yaml", "", blocks: blocks).map { Data($0.utf8) }
    }

    /// A text file `write` leaves to the app: `user` already has it outside the list, and it holds none
    /// of the app's blocks to merge the folder's lines into.
    static func isLeftToApp(_ path: String, in user: URL) -> Bool {
        guard !UserConfigFiles.isScriptPath(path) else { return false }
        let target = user.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        guard path.hasSuffix(".custom.yaml") else { return true }
        return managedBlocks(in: (try? String(contentsOf: target, encoding: .utf8)) ?? "").isEmpty
    }

    /// Folder files the generation at `user` does not carry, sorted by path.
    static func unusedNames(in folder: URL, user: URL) -> [String] {
        let used = names(in: user)
        return UserConfigFiles.listed(in: folder).filter { !used.contains($0) }
    }
}

extension RecipePackageManager {
    /// Files in the 「Rime 配置」 folder the active generation does not use, sorted by name.
    public func unusedRimeConfigFiles() throws -> [String] {
        guard let userConfigDirectory, let user = try activeUserDataURL() else { return [] }
        return RimeConfigFolder.unusedNames(in: userConfigDirectory, user: user)
    }

    /// Reinstalls the active installation from its own installed files into a fresh generation, so
    /// the config folder is laid over it again. Files the host wrote beside the package (recipe
    /// inputs, keyboard lists) are carried into the new generation before `deploy` runs.
    @discardableResult
    public func reinstallActivePackage(deploy: @escaping Deploy) async throws -> InstalledRecipe? {
        guard let active = try activeInstallation() else { return nil }
        let previous = active.resourceURL.deletingLastPathComponent()
        let recorded = try JSONDecoder().decode(
            RecipeManifest.self,
            from: Data(contentsOf: previous.appendingPathComponent(InstalledPackageLayout.sourceFile)))
        let resources = active.resourceURL
        // The host's deploy check rewrites its keyboard lists and the package declaration after every
        // install, so the hashes recorded at import no longer match; the installed copies are the truth.
        let hostWritten = [
            InstalledPackageLayout.keyboardPackageFile, InstalledPackageLayout.keyboardSchemas,
            InstalledPackageLayout.keyboardSourceSchemas,
        ]
        let files = try recorded.files.map { file -> RecipeManifest.File in
            guard hostWritten.contains(file.path) else { return file }
            let data = try Data(contentsOf: resources.appendingPathComponent(file.path))
            return RecipeManifest.File(path: file.path, sha256: sha256Hex(data), size: data.count)
        }
        let manifest = RecipeManifest(
            id: recorded.id, repository: recorded.repository, revision: recorded.revision,
            recipePath: recorded.recipePath, license: recorded.license, schemaID: recorded.schemaID,
            requiredComponents: recorded.requiredComponents, files: files, origin: recorded.origin)
        var models: [String: RecipeFileResource] = [:]
        for file in manifest.files where RecipeResourceBudget.isModel(file.path) {
            models[file.path] = RecipeFileResource(
                url: resources.appendingPathComponent(file.path), size: file.size, sha256: file.sha256)
        }
        // Scripts the user's copy replaced were kept as the package wrote them; scripts of the user's own
        // are not the package's, so a later install must not carry them over.
        let originals = previous.appendingPathComponent(RimeConfigFolder.originalsDirectory, isDirectory: true)
        let userScripts = Set(
            RimeConfigFolder.names(in: active.userDataURL).filter(UserConfigFiles.isScriptPath)
                .map { "resources/" + $0 })
        return try await installResources(
            manifest, initialUserDataURL: nil,
            deploy: { deployment in
                try Self.copyMissing(
                    from: previous, to: deployment.resourceURL.deletingLastPathComponent(), skipping: userScripts)
                return try await deploy(deployment)
            }, fileResources: models, expectedActiveGeneration: .some(active.installation.generation),
            strictUserConfig: true
        ) { file in
            if UserConfigFiles.isScriptPath(file.path),
                let kept = try? Data(contentsOf: originals.appendingPathComponent(file.path))
            {
                return kept
            }
            let data = try Data(contentsOf: resources.appendingPathComponent(file.path))
            // The installed entry is the generated sandbox around the package's own rime.lua.
            return file.path == LuaSandbox.entryPath ? (LuaSandbox.restoreOriginal(data) ?? data) : data
        }
    }

    /// The user directory is the fresh snapshot, never the old generation's copy.
    private static func copyMissing(
        from source: URL, to target: URL, topLevel: Bool = true, prefix: String = "", skipping: Set<String> = []
    ) throws {
        let fm = FileManager.default
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = child.lastPathComponent
            let carriedSeparately = [InstalledPackageLayout.userDirectory, RimeConfigFolder.originalsDirectory]
            if topLevel && carriedSeparately.contains(name) { continue }
            if skipping.contains(prefix + name) { continue }
            let destination = target.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            let holdsSkipped = skipping.contains { $0.hasPrefix(prefix + name + "/") }
            if !fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
                if holdsSkipped, (try child.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                    // A folder with a file that must not come along is copied file by file.
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    try copyMissing(
                        from: child, to: destination, topLevel: false, prefix: prefix + name + "/", skipping: skipping)
                } else {
                    try fm.copyItem(at: child, to: destination)
                }
            } else if isDirectory.boolValue, (try child.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            {
                try copyMissing(
                    from: child, to: destination, topLevel: false, prefix: prefix + name + "/", skipping: skipping)
            }
        }
    }
}
