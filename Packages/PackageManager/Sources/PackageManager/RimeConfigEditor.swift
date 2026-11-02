import Foundation

/// A file of the user's that replaces a file of the package in use; `updated` when the package has a
/// newer version of its own since the copy was made.
public struct RimeConfigOverride: Equatable, Sendable {
    public let path: String
    public let updated: Bool
}

/// Where the user's Rime configuration stands, for the screen that manages it.
public struct RimeConfigOverview: Equatable, Sendable {
    /// The user's files that replace a file of the package in use.
    public let overrides: [RimeConfigOverride]
    /// Of `overrides`, the paths the user has not been told about yet.
    public let unacknowledged: [String]
    /// Files with scripts the next install leaves out because the user has not agreed to them.
    public let unusedScripts: [String]
    public let fileCount: Int
}

/// A file of the user's, opened for editing.
public struct RimeConfigText: Equatable, Sendable {
    public let path: String
    public let text: String
    public var isScript: Bool { path.hasSuffix(".lua") }
}

/// How saving the editor's text ended.
public enum RimeConfigSave: Equatable, Sendable {
    case saved
    /// The text is not valid YAML (`line` is the 1-based line the reader stopped at, when it says); nothing was written.
    case invalid(line: Int?)
    /// Refused for another reason; the message is ready to show.
    case refused(String)
}

/// Whether applying may go ahead: scripts that are new or changed need the user's yes first.
public enum RimeConfigReadiness: Equatable, Sendable {
    case ready
    /// `scripts` as shown to the user; `keys` identify exactly them (path and content) to hand back with the yes;
    /// `firstTime`: the user has not been told what a script can do yet.
    case needsConfirmation(scripts: [String], keys: [String], firstTime: Bool)
}

/// The names the editor works with, kept in one place.
public enum RimeConfigEditor {
    /// The key of the settings every input method shares.
    public static let globalPath = "default.custom.yaml"

    /// `<id>.custom.yaml` for an input method, or nil when the id cannot name a file.
    public static func customPath(inputMethod id: String) -> String? {
        let path = id + ".custom.yaml"
        return UserConfigFiles.isCreatableName(path) ? path : nil
    }

    /// Whether `name` can name a new script: lowercase letters, digits and underscores.
    public static func isScriptName(_ name: String) -> Bool {
        (1...40).contains(name.utf8.count)
            && name.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
    }

    public static func scriptPath(name: String) -> String? {
        isScriptName(name) ? "lua/\(name).lua" : nil
    }

    /// Whether the file at `path` holding `text` brings a script: a Lua file, or a configuration file that names a Lua component.
    public static func hasScripts(path: String, text: String) -> Bool {
        path.hasSuffix(".lua") || (path.hasSuffix(".yaml") && !UserScripts.components(path, Data(text.utf8)).isEmpty)
    }

    static func message(_ error: UserConfigError) -> String {
        error.errorDescription ?? "没能保存这个文件。"
    }
}

extension RecipePackageManager {
    /// The package in use as the user's files see it, and the folder: nil when there is no folder or package.
    private func rimeConfigContext() throws -> (folder: URL, package: PackageFiles, overrides: UserOverrides)? {
        guard let userConfigDirectory, let active = try activeInstallation() else { return nil }
        let generation = active.resourceURL.deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            RecipeManifest.self,
            from: Data(contentsOf: generation.appendingPathComponent(InstalledPackageLayout.sourceFile)))
        let package = PackageFiles.installed(
            manifest.files, resources: active.resourceURL,
            originals: generation.appendingPathComponent(RimeConfigFolder.originalsDirectory, isDirectory: true),
            id: manifest.id)
        return (userConfigDirectory, package, UserOverrides(folder: userConfigDirectory, state: userConfigState))
    }

    /// Paths of the active package's own files the user may override (plain text and scripts), sorted.
    public func rimeConfigPackageFiles() throws -> [String] {
        try rimeConfigContext()?.package.hashes.keys.filter(UserConfigSafety.safePath).sorted() ?? []
    }

    /// The package's own text of `path`, to read; nil when the file is too large to show or is not text.
    public func rimeConfigPackageText(_ path: String) throws -> String? {
        guard let context = try rimeConfigContext(), context.package.hashes[path] != nil,
            let data = context.package.read(path), data.count <= UserConfigFiles.maximumFileBytes,
            let text = UserConfigFiles.decode(data)
        else { return nil }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    public func rimeConfigOverview() throws -> RimeConfigOverview {
        guard let context = try rimeConfigContext() else {
            return RimeConfigOverview(overrides: [], unacknowledged: [], unusedScripts: [], fileCount: 0)
        }
        let plan = try RimeConfigFolder.plan(
            context.folder, package: context.package, state: userConfigState, strict: false)
        return RimeConfigOverview(
            overrides: context.overrides.entries(context.package).map {
                RimeConfigOverride(path: $0.path, updated: $0.updated)
            },
            unacknowledged: context.overrides.unacknowledged(context.package),
            unusedScripts: Array(Set(plan.unconfirmed.map(\.path))).sorted(),
            fileCount: UserConfigFiles.files(in: context.folder).count)
    }

    /// Opens the user's file at `path` (relative to the package) for editing. A package file gets the
    /// user's copy made first, which then replaces it (the package itself is never touched); a missing
    /// `xxx.custom.yaml` is made from the template. With `grammarExample` the text ends with commented-out
    /// grammar model parameters unless it has some; nothing of that is written before a save.
    public func openRimeConfigFile(_ path: String, grammarExample: Bool = false) throws -> RimeConfigText {
        guard let context = try rimeConfigContext() else { throw UserConfigError(path, .name) }
        let text: String
        if let existing = context.overrides.overrideFile(path) {
            text = try Self.rimeConfigText(existing, path)
            // A file the user's copy shadows keeps its base from the first edit; one made before the marks existed gets it now.
            if context.package.hashes[path] != nil { context.overrides.recordBase(path, package: context.package) }
        } else if context.package.hashes[path] != nil {
            text = try Self.rimeConfigText(try context.overrides.copyOf(path, package: context.package), path)
        } else if !path.contains("/"), path.hasSuffix(".custom.yaml"), UserConfigFiles.isCreatableName(path) {
            text = try Self.create(path, RimeConfigTemplates.customPatch(), folder: context.folder)
        } else {
            throw UserConfigError(path, .name)
        }
        return RimeConfigText(path: path, text: grammarExample ? GrammarParameterExample.appended(to: text) : text)
    }

    /// Makes the script `lua/<name>.lua` from the template; the package's own scripts are never replaced by accident.
    public func createRimeScript(name: String) throws -> String {
        guard let path = RimeConfigEditor.scriptPath(name: name), let context = try rimeConfigContext() else {
            throw UserConfigError(name, .name)
        }
        guard context.package.hashes[path] == nil else { throw RimeScriptNameTaken(name: name) }
        _ = try Self.create(path, RimeConfigTemplates.script(name: name), folder: context.folder)
        return path
    }

    /// Saves `text` as the user's file at `path` when it passes the checks every file of the folder passes.
    public func saveRimeConfigFile(_ path: String, text: String) throws -> RimeConfigSave {
        guard let context = try rimeConfigContext() else { return .refused("现在没法保存，请稍后再试。") }
        let data = Data(text.utf8)
        if let error = UserConfigFiles.check(path, data) {
            return error.problem == .invalidYAML
                ? .invalid(line: error.line) : .refused(RimeConfigEditor.message(error))
        }
        let others = UserConfigFiles.files(in: context.folder).filter { $0.path != path }
        guard others.count < UserConfigFiles.maximumFiles else {
            return .refused(RimeConfigEditor.message(UserConfigError(nil, .tooMany)))
        }
        let total = others.reduce(0) { $0 + ((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard total + data.count <= UserConfigFiles.maximumTotalBytes else {
            return .refused(RimeConfigEditor.message(UserConfigError(path, .tooLarge)))
        }
        guard let target = UserOverrides.inside(context.folder, path) else {
            return .refused(RimeConfigEditor.message(UserConfigError(path, .name)))
        }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        if context.package.hashes[path] != nil { context.overrides.recordBase(path, package: context.package) }
        return .saved
    }

    /// Deletes the user's version of `path`, so the package's own file is used again after the next apply.
    @discardableResult
    public func restoreRimeConfigFile(_ path: String) throws -> Bool {
        guard let context = try rimeConfigContext() else { throw UserConfigError(path, .name) }
        return try context.overrides.restore(path)
    }

    /// Records that the user has been told about these `paths`.
    public func acknowledgeRimeConfigFiles(_ paths: [String]) throws {
        try rimeConfigContext()?.overrides.acknowledge(paths)
    }

    /// Whether applying may go ahead. Scripts that are new or changed since the user last agreed need a yes
    /// first: unless `confirmed` holds the key of every one of them the result is `needsConfirmation` and
    /// nothing is recorded. Only the scripts in `confirmed` count as agreed to; another one that turned up
    /// since is asked about again.
    public func rimeConfigReadiness(confirmed: [String] = []) throws -> RimeConfigReadiness {
        guard let context = try rimeConfigContext() else { return .ready }
        let plan = try RimeConfigFolder.plan(
            context.folder, package: context.package, state: userConfigState, strict: false)
        guard !plan.unconfirmed.isEmpty else { return .ready }
        let scripts = UserScripts(state: userConfigState)
        guard plan.unconfirmed.allSatisfy({ confirmed.contains($0.key) }) else {
            return .needsConfirmation(
                scripts: plan.unconfirmed.map(\.id), keys: plan.unconfirmed.map(\.key),
                firstTime: !scripts.riskAccepted())
        }
        scripts.accept(plan.unconfirmed)
        return .ready
    }

    private static func rimeConfigText(_ file: URL, _ path: String) throws -> String {
        guard
            let data = try? BoundedLocalFile.read(
                file, maximumBytes: UserConfigFiles.maximumFileBytes, followingSymlinks: false),
            let text = UserConfigFiles.decode(data)
        else { throw UserConfigError(path, .notText) }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Writes a new file of the user's; an existing one is read back instead.
    private static func create(_ path: String, _ text: String, folder: URL) throws -> String {
        guard UserConfigFiles.files(in: folder).count < UserConfigFiles.maximumFiles else {
            throw UserConfigError(nil, .tooMany)
        }
        guard let target = UserOverrides.inside(folder, path),
            !UserConfigFiles.files(in: folder).contains(where: {
                $0.path != path && $0.path.lowercased() == path.lowercased()
            })
        else { throw UserConfigError(path, .name) }
        if FileManager.default.fileExists(atPath: target.path) {
            return try rimeConfigText(target, path)
        }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target, options: .atomic)
        return text
    }
}

/// The package already has a script with the name asked for; a new one would replace it.
public struct RimeScriptNameTaken: Error, LocalizedError, Equatable, Sendable {
    public let name: String
    public var errorDescription: String? { "输入方案里已经有叫「\(name)」的脚本，换个名字。" }
}
