import CryptoKit
import KeyboardCore
import LayoutKit
import PackageManager
import SwiftUI

@main
struct ConfigurationBackupProbe: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack { LearningBackupView() }
                .task { await ConfigurationBackupChecks.run() }
        }
    }
}

@MainActor
enum ConfigurationBackupChecks {
    static var ran = false
    static func verifyRebuiltDependency(mainID: String) async throws {
        let center = SchemeImportCenter.shared
        await center.installBuiltinPackage().value
        let id = ProductionInputAvailability.builtinPackageID
        let keyboard = PublishedKeyboard(schemaID: BuiltinTemplateSchemas.quanpin, layout: .qwerty26, board: mainID)
        LayoutManager.shared.reload()
        _ = try await center.performReplaceKeyboards(packageID: id, requested: [keyboard], selecting: keyboard)
        let selected = try KeyboardRecipeStore.activation()!
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("backup-personal.dict.yaml")
        try Data("---\nname: personal\nversion: '1'\nsort: by_weight\n...\n松烟\tsong yan\t100\n".utf8).write(to: source)
        let dictionaries = RecipePackageManager(rootURL: DictionaryImportCenter.storeRoot)
        let input = try await dictionaries.prepareDictionaryImport(
            root: .init(path: source.lastPathComponent, location: source), builtinResources: RimePaths.builtinPackage()!
        )
        try await EngineOwnershipCoordinator.shared.withExclusive {
            _ = try await dictionaries.installDictionaryImport(input) {
                try await DictionaryDeployVerifier.verifyDictionaryWhileExclusive($0)
            }
        }
        let prepared = try await ConfigurationBackupIO.run {
            let (file, manifest) = try ConfigurationBackupStorage.create()
            guard
                manifest.files.contains(where: {
                    $0.domain == .dependencies && $0.path == "dictionary/backup-personal.dict.yaml"
                }),
                !manifest.files.contains(where: { $0.path.contains("songyan_basic.dict") })
            else { throw BackupFailure.message("个人词库和内置词库未正确区分") }
            let prepared = try ConfigurationBackupStorage.stage(file)
            let locations = try ConfigurationBackupStorage.sources()
            for domain in [ConfigurationBackupDomain.schemes, .recipes, .dictionaries] {
                if FileManager.default.fileExists(atPath: locations[domain]!.path) {
                    try FileManager.default.removeItem(at: locations[domain]!)
                }
            }
            try ConfigurationBackupStorage.restore(prepared)
            return prepared
        }
        LayoutManager.shared.reload()
        let errors = try await ConfigurationDependencyRestorer.restore { _ in }
        guard errors.isEmpty, let restored = try KeyboardRecipeStore.activation(),
            restored.selectedKeyboard == selected.selectedKeyboard,
            restored.generation != selected.generation, restored.keyboards == selected.keyboards
        else { throw BackupFailure.message("依赖重新安装或启用项恢复失败：" + errors.joined(separator: "；")) }
        guard try await dictionaries.activeInstallation() != nil else { throw BackupFailure.message("个人词库未重建") }
        try await verifyPartialDependencySelection(prepared: prepared)
        try FileManager.default.removeItem(at: prepared.directory)
    }

    static func verifyPartialDependencySelection(prepared: PreparedConfigurationBackup) async throws {
        let directory = ConfigurationBackupDependencies.pendingDirectory
        try FileManager.default.copyItem(
            at: prepared.directory.appendingPathComponent("dependencies"), to: directory)
        var dependencies = try ConfigurationBackupDependencies.read(from: directory)
        let schemeSelection = dependencies.selection!
        let dictionaryKeyboard = PublishedKeyboard(schemaID: BuiltinTemplateSchemas.quanpin, layout: .qwerty26)
        let dictionaryKey = KeyboardRecipeStore.rosterKey(kind: .userDictionary, packageID: nil)!
        dependencies.selection?.keyboardsBySource?[dictionaryKey] = [dictionaryKeyboard]
        dependencies.schemes.append(
            .init(
                id: "unavailable-test-origin", name: "来源缺失测试", entry: "missing", revision: "fixture",
                url: nil, target: nil, builtin: false, models: [], recipes: [], customizations: [:]))
        try JSONEncoder().encode(dependencies).write(
            to: directory.appendingPathComponent(ConfigurationBackupDependencies.filename))
        try ConfigurationBackupDependencies.saveProgress(
            .init(completed: ["scheme:" + schemeSelection.packageID!]))
        let errors = try await ConfigurationDependencyRestorer.restore { _ in }
        guard errors.count == 1, let selected = try KeyboardRecipeStore.activation(),
            selected.packageID == schemeSelection.packageID,
            selected.selectedKeyboard == schemeSelection.selectedKeyboard
        else { throw BackupFailure.message("部分依赖失败时丢失原启用方案") }

        // On a later retry, the selected dictionary may already be complete and skipped.
        // It must still replace the scheme published by another completed dependency.
        var dictionarySelection = schemeSelection
        dictionarySelection.resourceKind = .userDictionary
        dictionarySelection.packageID = nil
        dictionarySelection.selectedSchemaID = dictionaryKeyboard.schemaID
        dictionarySelection.selectedLayout = dictionaryKeyboard.layout
        dictionarySelection.selectedBoard = dictionaryKeyboard.board
        dictionarySelection.publishedKeyboards = [dictionaryKeyboard]
        dependencies.selection = dictionarySelection
        try JSONEncoder().encode(dependencies).write(
            to: directory.appendingPathComponent(ConfigurationBackupDependencies.filename))
        let retryErrors = try await ConfigurationDependencyRestorer.restore { _ in }
        guard retryErrors.count == 1, let selected = try KeyboardRecipeStore.activation(),
            selected.kind == .userDictionary, selected.selectedKeyboard == dictionaryKeyboard,
            try ConfigurationBackupDependencies.readProgress().completed.contains("dictionary")
        else { throw BackupFailure.message("重试依赖时丢失已完成的词库启用项") }
        try FileManager.default.removeItem(at: directory)
    }

    static func verifyModelResolution() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("download-fixture.gram")
        try Data("model-fixture".utf8).write(to: file)
        let resource = try RecipeFileResource.reference(at: file)
        let record = ConfigurationBackupDependencies.Model(
            path: "test.gram", sha256: resource.sha256, bytes: resource.size,
            url: URL(string: "https://example.invalid/model.gram")!)
        var calls = 0
        let cached = try await ConfigurationDependencyRestorer.resolveModels(
            [record], available: ["test.gram": resource]
        ) { _ in
            calls += 1
            return resource
        }
        guard cached["test.gram"]?.sha256 == resource.sha256, calls == 0 else {
            throw BackupFailure.message("可用模型被重复下载")
        }
        _ = try await ConfigurationDependencyRestorer.resolveModels([record], available: [:]) { _ in
            calls += 1
            return resource
        }
        guard calls == 1 else { throw BackupFailure.message("缺失模型未下载") }
        let mismatch = ConfigurationBackupDependencies.Model(
            path: record.path, sha256: String(repeating: "0", count: 64), bytes: record.bytes, url: record.url)
        var refused = false
        do {
            _ = try await ConfigurationDependencyRestorer.resolveModels([mismatch], available: [:]) { _ in resource }
        } catch { refused = true }
        guard refused else { throw BackupFailure.message("错误模型未拒绝") }
    }

    static func run() async {
        guard !ran else { return }
        ran = true
        var result: [String: Any] = [:]
        do {
            result = try await ConfigurationBackupIO.run {
                let fm = FileManager.default
                let locations = try ConfigurationBackupStorage.sources()
                let main = BuiltinLayouts.qwerty26.copy(name: "主布局副本")
                var abc = KeyboardPagePresets.englishQwerty.materialized()
                abc.id = "backup-abc-copy"
                var numeric = KeyboardPagePresets.numericKeypad.materialized()
                numeric.id = "backup-numeric-copy"
                var symbols = KeyboardPagePresets.symbolsSystem.materialized()
                symbols.id = "backup-symbol-copy"
                let composition = KeyboardComposition(
                    mainLayoutID: main.id, symbolPageID: symbols.id, numericPageID: numeric.id, englishPageID: abc.id)
                let registry = try LayoutRegistry(
                    layouts: BuiltinLayouts.all + [main], pages: KeyboardPagePresets.all + [abc, numeric, symbols],
                    compositions: ["wanxiang:qwerty26": composition])
                try LayoutStore(directoryURL: locations[.layouts]!).save(registry)
                let keyboard = PublishedKeyboard(schemaID: "wanxiang", layout: .qwerty26, board: main.id)
                var activation = KeyboardRecipeStore.Activation(
                    generation: "", revision: "fixture", recipeEnabled: false, publishedAt: Date(),
                    resourceKind: .userScheme)
                activation.packageID = "fixture"
                activation.selectedSchemaID = "wanxiang"
                activation.selectedLayout = .qwerty26
                activation.selectedBoard = main.id
                activation.publishedKeyboards = [keyboard]
                activation.keyboardsBySource = ["userScheme:fixture": [keyboard]]
                try fm.createDirectory(at: locations[.recipes]!, withIntermediateDirectories: true)
                try JSONEncoder().encode(activation).write(
                    to: locations[.recipes]!.appendingPathComponent("active.json"))
                let resource = locations[.recipes]!.appendingPathComponent("versions/fixture/resources/model.gram")
                try fm.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 42, count: 4 * 1024 * 1024).write(to: resource)
                let slot = locations[.schemes]!.appendingPathComponent("fixture")
                let generation = slot.appendingPathComponent("versions/fixture")
                try fm.createDirectory(
                    at: generation.appendingPathComponent("resources"), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: [
                    "id": "fixture", "revision": "fixture", "generation": "fixture", "schemaID": "wanxiang",
                    "activatedAt": 0,
                ]).write(to: slot.appendingPathComponent("active.json"))
                try JSONSerialization.data(withJSONObject: ["url": "https://example.invalid/scheme.zip"]).write(
                    to: slot.appendingPathComponent("source-url.json"))
                try JSONSerialization.data(withJSONObject: [
                    "id": "fixture", "repository": "user/import", "revision": "fixture", "recipePath": "recipe.yaml",
                    "license": "fixture", "schemaID": "wanxiang", "requiredComponents": [],
                    "files": [
                        ["path": "model.gram", "sha256": String(repeating: "a", count: 64), "size": 4 * 1024 * 1024]
                    ], "origin": "userScheme",
                ]).write(to: generation.appendingPathComponent("source.json"))
                try fm.copyItem(at: resource, to: generation.appendingPathComponent("resources/model.gram"))
                try Data("patch:\n  menu/page_size: 7\n".utf8).write(
                    to: generation.appendingPathComponent("resources/default.custom.yaml"))
                for domain in [
                    ConfigurationBackupDomain.rimeConfig, .rimeConfigState, .symbols,
                    .quickContent, .appearance, .hints, .options,
                ] {
                    try fm.createDirectory(at: locations[domain]!, withIntermediateDirectories: true)
                    try Data("fixture-\(domain.rawValue)".utf8).write(
                        to: locations[domain]!.appendingPathComponent("retained.txt"))
                }
                let learning = try LearningBackupArchive(
                    sourceID: "userScheme:fixture", resourceRevision: "fixture", sourceName: "测试学习快照",
                    engineVersion: "test", createdAt: Date(),
                    dictionaries: [.init(name: "words", data: Data("learned fixture".utf8))])
                try LearningSnapshotStore(root: locations[.learning]!).save(learning)
                KeyboardRecipeStore.sharedDefaults()?.set(37, forKey: "keyboard.backupFixture")
                KeyboardRecipeStore.sharedDefaults()?.set(true, forKey: "keyboard.needsInputModeSwitchKey")
                let (file, manifest) = try ConfigurationBackupStorage.create()
                guard manifest.version == 2,
                    !manifest.presentDomains.contains(.schemes), !manifest.presentDomains.contains(.recipes),
                    !manifest.presentDomains.contains(.dictionaries), manifest.totalBytes < 1024 * 1024
                else { throw BackupFailure.message("依赖本体被打包") }
                let prepared = try ConfigurationBackupStorage.stage(file)
                let recorded = try ConfigurationBackupDependencies.read(
                    from: prepared.directory.appendingPathComponent("dependencies"))
                guard recorded.schemes.first?.models.first?.bytes == 4 * 1024 * 1024, recorded.selection == activation,
                    recorded.schemes.first?.customizations["default.custom.yaml"] != nil
                else { throw BackupFailure.message("依赖记录不完整") }
                // Only this test's disposable simulator is used. Emulate a fresh app's empty
                // configuration stores without uninstalling or touching any physical device.
                for domain in ConfigurationBackupDomain.allCases where domain != .preferences {
                    if let path = locations[domain], fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
                }
                KeyboardRecipeStore.sharedDefaults()?.removeObject(forKey: "keyboard.backupFixture")
                try ConfigurationBackupStorage.restore(prepared)
                let restored = try LayoutStore(directoryURL: locations[.layouts]!).load()
                guard restored == registry,
                    try ConfigurationBackupDependencies.read(from: ConfigurationBackupDependencies.pendingDirectory)
                        .selection == activation,
                    !fm.fileExists(atPath: resource.path),
                    KeyboardRecipeStore.sharedDefaults()?.integer(forKey: "keyboard.backupFixture") == 37,
                    KeyboardRecipeStore.sharedDefaults()?.bool(forKey: "keyboard.needsInputModeSwitchKey") == true,
                    try LearningSnapshotStore(root: locations[.learning]!).pendingRestores().count == 1
                else { throw BackupFailure.message("配置或启用项往返不一致") }
                for domain in [
                    ConfigurationBackupDomain.rimeConfig, .rimeConfigState, .symbols,
                    .quickContent, .appearance, .hints, .options,
                ] {
                    guard
                        try String(
                            contentsOf: locations[domain]!.appendingPathComponent("retained.txt"), encoding: .utf8)
                            == "fixture-\(domain.rawValue)"
                    else {
                        throw BackupFailure.message("数据缺失")
                    }
                }
                // Deleting one local/cloud-shaped copy never removes the other or a parent folder.
                let cloud = ConfigurationBackupStorage.root.appendingPathComponent("test-cloud")
                try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
                let cloudFile = cloud.appendingPathComponent(file.lastPathComponent)
                try fm.copyItem(at: file, to: cloudFile)
                try ConfigurationBackupStorage.deleteArchive(file, from: ConfigurationBackupStorage.localArchives)
                guard fm.fileExists(atPath: cloudFile.path), !fm.fileExists(atPath: file.path) else {
                    throw BackupFailure.message("删除范围错误")
                }
                do {
                    try ConfigurationBackupStorage.deleteArchive(
                        cloudFile, from: ConfigurationBackupStorage.localArchives)
                    throw BackupFailure.message("错误目录删除未被拒绝")
                } catch ConfigurationBackupError.unsafeFile {}
                try fm.removeItem(at: cloud)
                try fm.removeItem(at: prepared.directory)
                try fm.removeItem(at: ConfigurationBackupDependencies.pendingDirectory)
                return [
                    "passed": true, "domains": manifest.presentDomains.map(\.rawValue), "files": manifest.files.count,
                    "customPagesAndLayout": 4, "selectionPreserved": true, "pendingLearningRestores": 1,
                    "devicePermissionsNotRestored": true, "resourceBodiesExcluded": true, "deletionScoped": true,
                    "mainID": main.id, "payloadBytes": manifest.totalBytes,
                ]
            }
            try await verifyModelResolution()
            result["modelDependencyResolution"] = true
            try await verifyRebuiltDependency(mainID: result["mainID"] as! String)
            result["rebuiltDependencySelection"] = true
            result["partialRetrySelection"] = true
            await ConfigurationBackupModel.shared.start()
        } catch { result = ["passed": false, "error": String(describing: error)] }
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(
            "configuration-backup-report.json")
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(
            to: report, options: .atomic)
    }
}
