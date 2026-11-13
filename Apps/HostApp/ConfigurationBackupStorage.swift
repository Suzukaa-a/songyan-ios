import CryptoKit
import Foundation
import KeyboardCore
import LayoutKit
import PackageManager

/// Blocking file work, called only from ConfigurationBackupIO. No cloud account or live engine
/// database is part of a backup. Scheme installations are represented by portable dependencies.
enum ConfigurationBackupStorage {
    static var root: URL { HostStorePaths.applicationSupport.appendingPathComponent("ConfigurationBackups") }
    static var localArchives: URL { root.appendingPathComponent("archives") }
    static var journal: URL { root.appendingPathComponent("restore-journal.json") }

    static func sources() throws -> [ConfigurationBackupDomain: URL] {
        guard let group = KeyboardRecipeStore.sharedContainerURL() else {
            throw BackupFailure.message(String(localized: "无法访问键盘共享配置。请稍后重试。"))
        }
        return [
            .schemes: HostStorePaths.applicationSupport.appendingPathComponent("SchemePackages"),
            .dictionaries: HostStorePaths.applicationSupport.appendingPathComponent("DictionaryImportStore"),
            .rimeConfig: HostStorePaths.rimeConfig,
            .rimeConfigState: HostStorePaths.rimeConfigState,
            .recipes: group.appendingPathComponent("KeyboardRecipes"),
            .layouts: RimePaths.layoutStoreReadLocation().url,
            .symbols: SymbolLibraryStorage.defaultStoreDirectory(),
            .quickContent: group.appendingPathComponent("LocalQuickContent"),
            .appearance: group.appendingPathComponent("KeyboardAppearance"),
            .hints: group.appendingPathComponent("ShuangpinHints"),
            .options: RimePaths.optionPreferencesDirectory(),
            .learning: group.appendingPathComponent(LearningSnapshotStore.directoryName),
            .preferences: root.appendingPathComponent("preferences"),
            .dependencies: ConfigurationBackupDependencies.captureDirectory,
        ]
    }

    static func include(_ domain: ConfigurationBackupDomain, _ path: String) -> Bool {
        guard ![.schemes, .dictionaries, .recipes].contains(domain) else { return false }
        if domain == .rimeConfig {
            let parts = path.lowercased().split(separator: "/")
            if parts.contains("build") || RecipeResourceBudget.isModel(path.lowercased())
                || ["zip", "bin", "prism", "table", "reverse"].contains((path as NSString).pathExtension.lowercased())
            {
                return false
            }
        }
        return includeLegacy(domain, path)
    }

    private static func includeLegacy(_ domain: ConfigurationBackupDomain, _ path: String) -> Bool {
        let parts = path.split(separator: "/").map { $0.lowercased() }
        if parts.contains(where: {
            $0.hasPrefix(".") || $0.contains(".userdb") || $0 == "sync" || $0 == "staging" || $0.hasSuffix(".lock")
                || $0.hasSuffix(".log")
        }) {
            return false
        }
        if domain == .learning { return parts.first == "archives" || parts.first == "safety" }
        return true
    }

    static func capturePreferences() throws {
        guard let defaults = KeyboardRecipeStore.sharedDefaults() else {
            throw BackupFailure.message(String(localized: "键盘设置暂时无法读取。"))
        }
        let values = defaults.dictionaryRepresentation().filter { isPreference($0.key) }
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        let directory = root.appendingPathComponent("preferences")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("settings.plist")
        let previous = (try? Data(contentsOf: file)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary
        }
        if previous != values as NSDictionary { try data.write(to: file, options: .atomic) }
    }

    static func isPreference(_ key: String) -> Bool {
        key.hasPrefix("keyboard.")
            && ![
                "keyboard.needsInputModeSwitchKey", "keyboard.fullAccessSeenAt",
                "keyboard.lifecycleDiagnosticsEnabled", "keyboard.geometryDiagnosticsEnabled",
                "keyboard.frameTimingProbe",
            ].contains(key)
    }

    static func changeStamp() throws -> String? {
        try capturePreferences()
        let locations = try sources()
        // A fresh install must offer the existing cloud history before creating empty backups.
        let hasConfiguration = [ConfigurationBackupDomain.recipes, .schemes, .dictionaries, .layouts].contains {
            guard let url = locations[$0] else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        guard hasConfiguration else { return nil }
        try ConfigurationBackupDependencies.capture(locations: locations)
        return try ConfigurationBackupArchive.changeStamp(sources: portableSources(locations), include: include)
    }

    static func create(safety: Bool = false) throws -> (URL, ConfigurationBackupManifest) {
        try capturePreferences()
        let locations = try sources()
        try ConfigurationBackupDependencies.capture(locations: locations)
        if let group = KeyboardRecipeStore.sharedContainerURL() {
            let transfers = LearningTransferStore(
                directory: group.appendingPathComponent(KeyboardLearningTransfer.directoryName))
            let snapshots = LearningSnapshotStore(root: locations[.learning]!)
            if let current = try transfers.read(), current.operation == .backup, current.status == .succeeded {
                try snapshots.save(transfers.readBackupOutput(requestID: current.id))
            }
            if let safety = try transfers.readLatestSafetyBackup() { try snapshots.saveSafety(safety) }
        }
        _ = try LayoutStore(directoryURL: locations[.layouts]!).load()
        if let activation = try KeyboardRecipeStore.activation(), !activation.generation.isEmpty {
            _ = try KeyboardRecipeStore.snapshot()
        }
        try FileManager.default.createDirectory(at: localArchives, withIntermediateDirectories: true)
        let date = Date().formatted(
            .iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(
                .omitted))
        let file = localArchives.appendingPathComponent(
            "\(safety ? String(localized: "恢复前") : String(localized: "松烟"))-\(date)-\(UUID().uuidString.prefix(8)).songyanbackup"
        )
        let version =
            "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))"
        let manifest = try ConfigurationBackupArchive.create(
            sources: portableSources(locations), destination: file, appVersion: version, include: include, version: 2)
        return (file, manifest)
    }

    private static func portableSources(_ locations: [ConfigurationBackupDomain: URL]) -> [ConfigurationBackupDomain:
        URL]
    {
        locations.filter { ![.schemes, .dictionaries, .recipes].contains($0.key) }
    }

    static func stage(_ file: URL) throws -> PreparedConfigurationBackup {
        let directory = root.appendingPathComponent("prepared-\(UUID())")
        let manifest = try ConfigurationBackupArchive.extract(file, to: directory)
        do {
            try validate(directory, manifest: manifest)
            return PreparedConfigurationBackup(directory: directory, manifest: manifest)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func validate(_ directory: URL, manifest: ConfigurationBackupManifest) throws {
        guard manifest.presentDomains.contains(.preferences),
            manifest.files.contains(where: { $0.domain == .preferences && $0.path == "settings.plist" })
        else { throw ConfigurationBackupError.invalidArchive }
        for file in manifest.files
        where !(manifest.version == 1 ? includeLegacy(file.domain, file.path) : include(file.domain, file.path)) {
            throw ConfigurationBackupError.invalidArchive
        }
        if manifest.version == 2 {
            guard manifest.presentDomains.contains(.dependencies),
                manifest.presentDomains.allSatisfy({ ![.schemes, .dictionaries, .recipes].contains($0) })
            else { throw ConfigurationBackupError.invalidArchive }
            let dependencies = try ConfigurationBackupDependencies.read(
                from: directory.appendingPathComponent("dependencies"))
            let allowed = Set(
                [ConfigurationBackupDependencies.filename]
                    + (dependencies.dictionary?.sources.filter { $0.url == nil }.map { "dictionary/" + $0.path } ?? []))
            guard Set(manifest.files.filter { $0.domain == .dependencies }.map(\.path)) == allowed else {
                throw ConfigurationBackupError.invalidArchive
            }
        }
        if manifest.presentDomains.contains(.recipes) {
            let recipeRoot = directory.appendingPathComponent("recipes")
            if let activation = try KeyboardRecipeStore.activation(rootURL: recipeRoot), !activation.generation.isEmpty
            {
                _ = try KeyboardRecipeStore.snapshot(rootURL: recipeRoot)
                for generation in activation.keptGenerations?.values ?? Dictionary<String, String>().values {
                    guard KeyboardRecipeStore.generationRecord(generation: generation, rootURL: recipeRoot) != nil
                    else {
                        throw ConfigurationBackupError.invalidArchive
                    }
                }
            }
        }
        if manifest.presentDomains.contains(.layouts) {
            _ = try LayoutStore(directoryURL: directory.appendingPathComponent("layouts")).load()
        }
        if manifest.presentDomains.contains(.learning) {
            _ = try LearningSnapshotStore(root: directory.appendingPathComponent("learning")).snapshots()
        }
        if manifest.presentDomains.contains(.preferences) {
            _ = try preferenceValues(directory.appendingPathComponent("preferences/settings.plist"))
        }
    }

    static func destinations() throws -> [String: URL] {
        var result = try sources().filter { $0.key != .recipes }.reduce(into: [String: URL]()) {
            $0[$1.key.rawValue] = $1.value
        }
        result["preferences"] = root.appendingPathComponent("preferences-to-apply")
        result["selection"] = try sources()[.recipes]!.appendingPathComponent("active.json")
        result["dependencies"] = ConfigurationBackupDependencies.pendingDirectory
        return result
    }

    static func recoverInterruptedRestore() throws {
        try ConfigurationRestoreTransaction.recover(journalURL: journal, destinations: destinations())
        try applyRestoredPreferences()
    }

    static func restore(_ prepared: PreparedConfigurationBackup) throws {
        try validate(prepared.directory, manifest: prepared.manifest)
        let locations = try sources()
        let recipeRoot = locations[.recipes]!
        let transferRoot = recipeRoot.deletingLastPathComponent().appendingPathComponent(
            KeyboardLearningTransfer.directoryName)
        try FileManager.default.createDirectory(at: transferRoot, withIntermediateDirectories: true)
        let transfers = LearningTransferStore(directory: transferRoot)
        guard let lease = try transfers.acquireWorkerLease() else {
            throw BackupFailure.message(String(localized: "键盘正在备份或合并学习数据，请完成后再恢复。"))
        }
        defer { lease.release() }
        if let current = try transfers.read(), current.status == .pending {
            _ = try transfers.cancel(requestID: current.id)
        }
        try FileManager.default.createDirectory(at: recipeRoot, withIntermediateDirectories: true)
        // Resource generations are immutable: add missing generations without removing those an
        // already-running keyboard may still hold. The active selection is replaced last.
        for file in prepared.manifest.files where file.domain == .recipes && file.path != "active.json" {
            guard file.path.hasPrefix("versions/") else { throw ConfigurationBackupError.invalidArchive }
            let source = prepared.directory.appendingPathComponent("recipes").appendingPathComponent(file.path)
            let target = recipeRoot.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: target.path) {
                guard FileManager.default.contentsEqual(atPath: source.path, andPath: target.path) else {
                    throw BackupFailure.message(String(localized: "现有方案版本与备份中的同名版本不一致，已停止恢复。"))
                }
            } else {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = target.deletingLastPathComponent().appendingPathComponent(".restore-\(UUID())")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: source, to: temporary)
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        }
        let learning = prepared.directory.appendingPathComponent("learning")
        if prepared.manifest.presentDomains.contains(.learning) {
            try LearningSnapshotStore(root: learning).prepareRestore(
                waitingForDependencies: prepared.manifest.version == 2)
        }
        let targets = try destinations()
        let replacedDomains = ConfigurationBackupDomain.allCases.filter {
            $0 != .recipes && (prepared.manifest.version == 1 || ![.schemes, .dictionaries].contains($0))
        }
        var replacements = replacedDomains.map { domain in
            ConfigurationRestoreTransaction.Replacement(
                key: domain.rawValue,
                source: prepared.manifest.presentDomains.contains(domain)
                    ? prepared.directory.appendingPathComponent(domain.rawValue) : nil,
                destination: targets[domain.rawValue]!)
        }
        let selection = prepared.directory.appendingPathComponent("recipes/active.json")
        if prepared.manifest.version == 1 {
            replacements.append(
                .init(
                    key: "selection", source: FileManager.default.fileExists(atPath: selection.path) ? selection : nil,
                    destination: targets["selection"]!))
        }
        try KeyboardRecipeStore.withConfigurationRestoreLock {
            try ConfigurationRestoreTransaction.install(replacements, journalURL: journal)
        }
        try applyRestoredPreferences()
    }

    private static func preferenceValues(_ file: URL) throws -> [String: Any] {
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1024 * 1024,
            let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
                as? [String: Any],
            values.keys.allSatisfy(isPreference)
        else { throw ConfigurationBackupError.invalidArchive }
        return values
    }

    static func deleteArchive(_ file: URL, from directory: URL) throws {
        guard file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
            file.pathExtension == "songyanbackup", !file.lastPathComponent.hasPrefix(".")
        else { throw ConfigurationBackupError.unsafeFile }
        var coordinationError: NSError?
        var deletionError: Error?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: &coordinationError) { url in
            do { try FileManager.default.removeItem(at: url) } catch { deletionError = error }
        }
        if let coordinationError { throw coordinationError }
        if let deletionError { throw deletionError }
    }

    private static func applyRestoredPreferences() throws {
        let directory = root.appendingPathComponent("preferences-to-apply")
        let file = directory.appendingPathComponent("settings.plist")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard let defaults = KeyboardRecipeStore.sharedDefaults() else {
            throw BackupFailure.message(String(localized: "键盘设置暂时无法写入。"))
        }
        let values = try preferenceValues(file)
        for key in defaults.dictionaryRepresentation().keys where isPreference(key) {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in values { defaults.set(value, forKey: key) }
        try FileManager.default.removeItem(at: directory)
    }
}

struct PreparedConfigurationBackup: Sendable {
    let directory: URL
    let manifest: ConfigurationBackupManifest
}

enum BackupFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

enum ConfigurationBackupIO {
    private static let queue = SerialIOQueue(label: "app.songyan.configuration-backup", qos: .utility)
    static func run<T>(_ work: @escaping @Sendable () throws -> T) async throws -> sending T {
        try await queue.async(work)
    }
}
