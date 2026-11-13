import Foundation
import KeyboardCore
import PackageManager

/// Resolves recorded intent through the normal verified installers. Failed items remain retryable;
/// an old publication generation from another installation is never written into active.json.
@MainActor
enum ConfigurationDependencyRestorer {
    static func pending() async throws -> ConfigurationBackupDependencies? {
        try await ConfigurationBackupIO.run {
            let directory = ConfigurationBackupDependencies.pendingDirectory
            guard
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(ConfigurationBackupDependencies.filename).path)
            else { return nil }
            return try ConfigurationBackupDependencies.read(from: directory)
        }
    }

    static func restore(progress update: (String) -> Void) async throws -> [String] {
        guard let dependencies = try await pending() else { return [] }
        var state = try await ConfigurationBackupIO.run { try ConfigurationBackupDependencies.readProgress() }
        let center = SchemeImportCenter.shared
        await center.refresh()
        // Restore the selected source last, so the final publication is the recorded selection.
        let selectedID = dependencies.selection?.kind == .userScheme ? dependencies.selection?.packageID : nil
        let schemes = dependencies.schemes.sorted {
            if ($0.id == selectedID) != ($1.id == selectedID) { return $1.id == selectedID }
            return $0.id < $1.id
        }
        for scheme in schemes {
            let key = "scheme:" + scheme.id
            guard !state.completed.contains(key) else { continue }
            update(String(localized: "正在恢复依赖：\(scheme.name)…"))
            do {
                try Task.checkCancellation()
                try await restoreScheme(scheme)
                try await publish(scheme, selection: dependencies.selection)
                state.completed.insert(key)
                state.failures[key] = nil
            } catch is CancellationError { throw CancellationError() } catch {
                state.failures[key] = "\(scheme.name)：\(error.localizedDescription)"
            }
            let saved = state
            try await ConfigurationBackupIO.run { try ConfigurationBackupDependencies.saveProgress(saved) }
        }
        if let dictionary = dependencies.dictionary, !state.completed.contains("dictionary") {
            update(String(localized: "正在恢复词库：\(dictionary.name)…"))
            do {
                try await restoreDictionary(dictionary, selection: dependencies.selection)
                state.completed.insert("dictionary")
                state.failures["dictionary"] = nil
            } catch is CancellationError { throw CancellationError() } catch {
                state.failures["dictionary"] = "\(dictionary.name)：\(error.localizedDescription)"
            }
            let saved = state
            try await ConfigurationBackupIO.run { try ConfigurationBackupDependencies.saveProgress(saved) }
        }
        // A restored source may have changed the active keyboard. Restore the recorded pair
        // even when another source failed, and also when that pair completed on an earlier try.
        state.failures["selection"] = nil
        do {
            if let selection = dependencies.selection {
                switch selection.kind {
                case .userScheme:
                    guard let scheme = schemes.first(where: { $0.id == selectedID }) else {
                        throw failure(String(localized: "备份缺少当前键盘的方案来源记录。"))
                    }
                    if state.completed.contains("scheme:" + scheme.id) {
                        try await publish(scheme, selection: selection)
                    }
                case .userDictionary:
                    guard let dictionary = dependencies.dictionary else {
                        throw failure(String(localized: "备份缺少当前键盘的词库来源记录。"))
                    }
                    if state.completed.contains("dictionary") {
                        try await publishDictionary(dictionary, selection: selection)
                    }
                }
            }
            if dependencies.selection?.recipeEnabled != true {
                try await EngineOpQueue.async { try KeyboardRecipeStore.setEnabled(false) }
            }
        } catch is CancellationError { throw CancellationError() } catch {
            state.failures["selection"] = String(localized: "键盘启用项：\(error.localizedDescription)")
        }
        let saved = state
        try await ConfigurationBackupIO.run { try ConfigurationBackupDependencies.saveProgress(saved) }
        if state.failures.isEmpty {
            try await ConfigurationBackupIO.run {
                try FileManager.default.removeItem(at: ConfigurationBackupDependencies.pendingDirectory)
            }
        }
        return state.failures.values.sorted()
    }

    private static func restoreScheme(_ scheme: ConfigurationBackupDependencies.Scheme) async throws {
        let center = SchemeImportCenter.shared
        guard !center.busy else { throw RecipeInstallError.busy }
        let manager = center.manager(scheme.id)
        let existing = try await manager.activeInstallation()
        var models: [String: RecipeFileResource] = [:]
        if let existing {
            let snapshot = try await centerSnapshot(existing)
            models = snapshot.fileResources.filter { RecipeResourceBudget.isModel($0.key) }
        }
        if existing == nil
            || (existing?.installation.revision != scheme.revision && (scheme.url != nil || scheme.target != nil))
        {
            if let target = scheme.target {
                guard await center.waitForSourceStep(center.acquireSource(target, updatingPackageID: scheme.id)),
                    center.error == nil
                else {
                    throw failure(center.error)
                }
                for source in center.acquiredSources { models.merge(source.models) { _, new in new } }
                models = try await resolveModels(scheme.models, available: models)
                center.providedDownloadFiles = models
                // Dependencies explicitly declared by the recorded source expression are needed
                // before planning; the same bounded HTTPS downloader is used by manual installs.
                for requirement in center.acquiredSources.flatMap(\.externalResources) {
                    if RecipeResourceBudget.isModel(requirement.path), models[requirement.path] != nil { continue }
                    center.downloadExternalResource(requirement)
                    guard await center.waitForSourceStep(center.sourceTask), center.error == nil else {
                        throw failure(center.error)
                    }
                }
                guard await center.waitForSourceStep(center.checkSourcePlan(entrySchemaID: scheme.entry)),
                    center.error == nil,
                    await center.waitForSourceStep(center.installSourcePlan()), center.error == nil
                else { throw failure(center.error) }
            } else {
                center.busy = true
                defer { center.busy = false }
                let prepared: PreparedSchemeImport
                var download: SchemeURLDownloadService.Result?
                if scheme.builtin {
                    guard let bundled = RimePaths.builtinPackage() else { throw failure(String(localized: "内置方案不可用。")) }
                    prepared = try await Task.detached { try manager.prepareBundledPackage(directory: bundled) }.value
                } else if let url = scheme.url {
                    let value = try await SchemeURLDownloadService.shared.download(address: url.absoluteString)
                    download = value
                    prepared = try await Task.detached {
                        let imported =
                            try value.recommendation.map {
                                try manager.prepareRecommended($0, archiveURLs: value.localFileURLs)
                            }
                            ?? manager.prepareSync(value.localFileURLs)
                        guard imported.schemaIDs.contains(scheme.entry) else {
                            throw failure(String(localized: "下载内容不包含备份记录的输入方式。"))
                        }
                        return try imported.updatingInstallation(id: scheme.id, name: scheme.name)
                    }.value
                } else {
                    throw failure(String(localized: "没有可下载的来源，请先重新导入原方案文件，再点“继续恢复依赖”。"))
                }
                defer { withExtendedLifetime(download) {} }
                models.merge(prepared.fileResources.filter { RecipeResourceBudget.isModel($0.key) }) { _, new in new }
                models = try await resolveModels(scheme.models, available: models)
                let ready = try prepared.preparingModels(models)
                try await EngineOwnershipCoordinator.shared.withExclusive {
                    _ = try await manager.installSchemeImport(
                        ready, expectedGeneration: existing?.installation.generation
                    ) {
                        try await SchemeImportCenter.verifyRecipeDeployment(
                            $0, packageID: scheme.id, packageName: scheme.name
                        ).receipt
                    }
                }
                if !scheme.builtin { _ = center.saveSource(scheme.url, packageID: scheme.id) }
            }
        } else {
            models = try await resolveModels(scheme.models, available: models)
        }
        // Recreate the effective custom patches after obtaining the source. Recompilation and
        // grammar validation use the same installation transaction as normal settings changes.
        center.busy = true
        defer { center.busy = false }
        let suppliedModels = models
        try await EngineOwnershipCoordinator.shared.withExclusive {
            guard let installed = try await manager.activeInstallation() else {
                throw failure(String(localized: "方案尚未安装。"))
            }
            let snapshot = try await centerSnapshot(installed)
            let sources = try await SchemeImportCenter.readInstalledSources(resources: installed.resourceURL)
            var invocations: [(DeclarativeRecipe, RecipePlanReceipt)] = []
            var ordinaryDownloads: [String: Data] = [:]
            for receipt in scheme.recipes {
                // Source expressions already replay their ordered recipes during acquisition.
                // App-generated patches are captured as effective customizations below.
                guard !receipt.recipePath.hasPrefix("source-repositories/"),
                    !receipt.recipePath.hasPrefix("configuration-"),
                    let bytes = sources.files[receipt.recipePath]
                else { continue }
                let recipe = try DeclarativeRecipe(path: receipt.recipePath, source: bytes)
                guard !recipe.installPatterns.isEmpty else { continue }
                for resource in recipe.downloads where !RecipeResourceBudget.isModel(resource.path) {
                    ordinaryDownloads[resource.path] = try await RecipePackageManager.fetchHTTPBytes(
                        resource.url, maximumBytes: RecipeResourceBudget.sourceFile)
                }
                invocations.append((recipe, receipt))
            }
            let restoredInvocations = invocations
            let restoredDownloads = ordinaryDownloads
            let plan = try await Task.detached {
                var files = snapshot.files.filter { !$0.key.hasSuffix(".custom.yaml") }
                files.merge(scheme.customizations) { _, saved in saved }
                let resourceFiles = snapshot.fileResources.merging(suppliedModels) { _, saved in saved }
                let begin = try DeclarativeRecipe(
                    path: "configuration-start.recipe.yaml", source: Data("recipe:\n  Rx: configuration-start\n".utf8))
                var plan = try DeclarativeRecipePlan(
                    recipe: begin, packageReference: "configuration-restore", selectedRecipe: "configuration-start",
                    arguments: [], packageFiles: sources.files.filter { $0.key != begin.path }, existingFiles: files,
                    sourceRevision: scheme.revision, expectedGeneration: installed.installation.generation,
                    packageFileResources: sources.fileResources.merging(suppliedModels) { _, saved in saved },
                    existingFileResources: resourceFiles, userCustomBaseline: snapshot.userCustomFiles,
                    sharedOpenCCDirectory: Bundle.main.url(
                        forResource: "opencc", withExtension: nil, subdirectory: "EngineResources"))
                for (recipe, receipt) in restoredInvocations {
                    let reference = String(
                        receipt.rx.split(separator: ":", omittingEmptySubsequences: false).first
                            ?? "configuration-restore")
                    plan = try plan.appending(
                        recipe: recipe, packageReference: reference,
                        selectedRecipe: recipe.declaredName ?? "", arguments: receipt.arguments,
                        packageFiles: sources.files, providedDownloads: restoredDownloads,
                        expectedDownloadSHA256: receipt.providedResourceSHA256,
                        sourceRevision: receipt.sourceRevision, packageFileResources: sources.fileResources,
                        providedDownloadFiles: suppliedModels)
                }
                var lines = ["recipe:", "  Rx: configuration-restore"]
                let downloads = scheme.models.compactMap { model in
                    model.url.map { "  - \(model.path)::\($0.absoluteString)" }
                }
                if !downloads.isEmpty { lines += ["download_files:"] + downloads }
                let paths = (Array(scheme.customizations.keys) + scheme.models.map(\.path)).sorted()
                if !paths.isEmpty { lines += ["install_files:"] + paths.map { "  - \($0)" } }
                let recipe = try DeclarativeRecipe(
                    path: "configuration-restore.recipe.yaml", source: Data((lines.joined(separator: "\n") + "\n").utf8)
                )
                return try plan.appending(
                    recipe: recipe, packageReference: "configuration-restore",
                    selectedRecipe: "configuration-restore", arguments: [], packageFiles: scheme.customizations,
                    sourceRevision: scheme.revision, packageFileResources: suppliedModels,
                    providedDownloadFiles: suppliedModels)
            }.value
            _ = try await manager.installRecipePlan(plan, packageID: scheme.id, schemaID: scheme.entry) {
                for path in snapshot.userCustomFiles.keys where scheme.customizations[path] == nil {
                    let stale = $0.userDataURL.appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: stale.path) {
                        try FileManager.default.removeItem(at: stale)
                    }
                }
                return try await SchemeImportCenter.verifyRecipeDeployment(
                    $0, packageID: scheme.id, packageName: scheme.name
                )
                .receipt
            }
        }
        await center.refresh()
    }

    nonisolated private static func failure(_ message: String?) -> BackupFailure {
        .message(message ?? String(localized: "依赖未能恢复，请检查网络或重新导入来源后重试。"))
    }

    private static func centerSnapshot(_ active: ActiveRecipe) async throws -> RecipeWorkspaceSnapshot {
        try await SchemeImportCenter.readWorkspaceSnapshot(
            resources: active.resourceURL, userConfiguration: active.userDataURL)
    }

    static func resolveModels(
        _ records: [ConfigurationBackupDependencies.Model], available: [String: RecipeFileResource],
        download: ((URL) async throws -> RecipeFileResource)? = nil
    ) async throws -> [String: RecipeFileResource] {
        var result = available
        for model in records {
            if let file = result[model.path], file.sha256 == model.sha256, file.size == model.bytes { continue }
            guard let url = model.url else { throw failure(String(localized: "\(model.path) 没有下载地址，请在方案中重新添加该模型后重试。")) }
            let file: RecipeFileResource
            if let download {
                file = try await download(url)
            } else {
                file = try await RecipeFileResource.download(
                    from: url, directory: SchemeImportCenter.modelStagingDirectory,
                    maximumBytes: RecipeResourceBudget.modelFile)
            }
            guard file.sha256 == model.sha256, file.size == model.bytes else {
                throw failure(String(localized: "\(model.path) 的下载内容与备份记录不同，已停止使用。"))
            }
            result[model.path] = file
        }
        return result
    }

    private static func publish(
        _ scheme: ConfigurationBackupDependencies.Scheme, selection: KeyboardRecipeStore.Activation?
    ) async throws {
        let key = KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: scheme.id)!
        let isSelected = selection?.rosterKey == key
        let roster = isSelected ? selection?.keyboards ?? [] : selection?.keyboardsBySource?[key] ?? []
        if !roster.isEmpty {
            _ = try await SchemeImportCenter.shared.performReplaceKeyboards(
                packageID: scheme.id, requested: roster,
                selecting: isSelected ? selection?.selectedKeyboard : nil)
        }
        if let current = try await SchemeImportCenter.shared.manager(scheme.id).activeInstallation() {
            try await ConfigurationBackupIO.run {
                try LearningSnapshotStore(root: ConfigurationBackupStorage.sources()[.learning]!)
                    .retargetPendingRestore(
                        sourceID: key, revision: current.installation.revision)
            }
        }
    }

    private static func restoreDictionary(
        _ dictionary: ConfigurationBackupDependencies.Dictionary, selection: KeyboardRecipeStore.Activation?
    ) async throws {
        let directory = ConfigurationBackupDependencies.pendingDirectory
        let manager = RecipePackageManager(
            rootURL: DictionaryImportCenter.storeRoot,
            userConfigDirectory: HostStorePaths.rimeConfig, userConfigStateDirectory: HostStorePaths.rimeConfigState)
        let sources = dictionary.sources.map { source in
            DictionaryImportFile(
                path: source.path, location: source.url ?? directory.appendingPathComponent("dictionary/" + source.path)
            )
        }
        guard let first = sources.first, let builtin = RimePaths.builtinPackage() else {
            throw failure(String(localized: "词库来源不可用。"))
        }
        let prepared = try await manager.prepareDictionaryImport(
            root: first, dependencies: Array(sources.dropFirst()), builtinResources: builtin)
        for source in dictionary.sources {
            guard prepared.sources.first(where: { $0.path == source.path })?.sha256 == source.sha256 else {
                throw failure(String(localized: "下载的词库内容与备份记录不同。"))
            }
        }
        try await EngineOwnershipCoordinator.shared.withExclusive {
            _ = try await manager.installDictionaryImport(prepared) { deployment in
                let receipt = try await DictionaryDeployVerifier.verifyDictionaryWhileExclusive(deployment)
                let summary = DictionaryImportCenter.Summary(
                    name: dictionary.name, entryCount: prepared.entryCount, files: sources.count)
                try JSONEncoder().encode(summary).write(
                    to: deployment.resourceURL.appendingPathComponent("host-import-summary.json"), options: .atomic)
                return receipt
            }
        }
        try await publishDictionary(dictionary, selection: selection)
    }

    private static func publishDictionary(
        _ dictionary: ConfigurationBackupDependencies.Dictionary, selection: KeyboardRecipeStore.Activation?
    ) async throws {
        let manager = RecipePackageManager(rootURL: DictionaryImportCenter.storeRoot)
        guard let active = try await manager.activeInstallation() else { throw failure(String(localized: "词库尚未安装。")) }
        try await EngineOwnershipCoordinator.shared.withExclusive {
            let key = KeyboardRecipeStore.rosterKey(kind: .userDictionary, packageID: nil)!
            let selected = selection?.kind == .userDictionary
            let roster = selected ? selection?.keyboards ?? [] : selection?.keyboardsBySource?[key] ?? []
            if !roster.isEmpty {
                try await EngineOpQueue.async {
                    try KeyboardRecipeStore.publish(
                        resources: active.resourceURL,
                        compiledBuild: active.userDataURL.appendingPathComponent("build"),
                        revision: active.installation.revision,
                        kind: .userDictionary, dictionaryName: dictionary.name,
                        selectedSchemaID: selected ? selection?.selectedSchemaID : roster.first?.schemaID,
                        layout: selected ? selection?.selectedLayout : roster.first?.layout,
                        board: selected ? selection?.selectedBoard : roster.first?.board, publishedKeyboards: roster)
                }
            }
            try await ConfigurationBackupIO.run {
                try LearningSnapshotStore(root: ConfigurationBackupStorage.sources()[.learning]!)
                    .retargetPendingRestore(sourceID: key, revision: active.installation.revision)
            }
        }
    }
}
