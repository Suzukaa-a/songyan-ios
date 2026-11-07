import CryptoKit
import Foundation
import KeyboardCore
import OSLog
import PackageManager
import RimeBridge
import SwiftUI

extension SchemeImportCenter {
    func beginSourceImport() {
        guard !busy else { return }
        declinePackageLearning()
        prepared = nil
        preparedSourceURL = nil
        lastInstalledPackageID = nil
        installedWorkspace = nil
        error = nil
        message = nil
        userNotice = nil
        diagnostics = []
        retryState.succeeded()
        resetRecipePlanningState()
    }

    func accept(
        _ urls: [URL], sourceURL: URL? = nil, recommendation: RecommendedSchemeSource? = nil,
        onFinished: (() -> Void)? = nil
    ) {
        guard !busy else {
            message = String(localized: "上一项导入还没完成，请稍后再选择文件。")
            onFinished?()
            return
        }
        guard !urls.isEmpty else {
            onFinished?()
            return
        }
        let capture = ImportCapture(target: nil, sourceURL: sourceURL, recommendation: recommendation)
        Task {
            defer { onFinished?() }
            await prepareRecognizedImport(urls, capture: capture)
        }
    }

    /// Fixed context of one import attempt: the installed package it updates (nil = new install) and
    /// the source URL recorded with it, resolved once so later center state cannot retarget it.
    struct ImportCapture {
        let target: InstalledPackage?
        let sourceURL: URL?
        let recommendation: RecommendedSchemeSource?

        init(target: InstalledPackage?, sourceURL: URL?, recommendation: RecommendedSchemeSource? = nil) {
            self.target = target
            self.sourceURL = sourceURL
            self.recommendation = recommendation
        }
    }

    /// Recognition phase shared by `accept` and the direct update: reads the chosen files, and for an
    /// update also proves the package identity from the files themselves (`updatingInstallation`).
    /// `busy` is cleared once the result is in `prepared`, so an update can install right after.
    @discardableResult
    func prepareRecognizedImport(_ urls: [URL], capture: ImportCapture) async -> Bool {
        guard !busy else {
            message = String(localized: "上一项导入还没完成，请稍后再选择文件。")
            return false
        }
        let leases = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        declinePackageLearning()
        busy = true
        error = nil
        prepared = nil
        preparedSourceURL = capture.sourceURL
        diagnostics = []
        userNotice = nil
        lastInstalledPackageID = nil
        retryState.succeeded()
        resetRecipePlanningState()
        message =
            urls.count == 1 || capture.recommendation != nil
            ? String(localized: "正在读取…")
            : String(localized: "正在读取 \(urls.count) 个文件…")
        defer {
            busy = false
            for (url, scoped) in leases where scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let reader = manager("inspection")
            // ZIP extraction/directory reads are heavy IO: run on a background serial queue, with the security-scope lease held until the read completes.
            // A synchronous package read would block the MainActor, so await the background result explicitly.
            let picked = urls
            let recommendation = capture.recommendation
            // Importing a scheme that is already installed replaces it: the same main input method
            // means the same scheme, so newer files become a new version of that package instead of
            // a second copy. Learning data and the recorded download address stay with it.
            let known = installedPackages.map {
                InstalledSchemeIdentity(id: $0.id, name: $0.name, entrySchemaID: $0.active.installation.schemaID)
            }
            let installedResources = Dictionary(
                installedPackages.map { ($0.id, $0.active.resourceURL) }, uniquingKeysWith: { first, _ in first })
            let explicit = capture.target.map {
                InstalledSchemeIdentity(
                    id: $0.id, name: $0.name,
                    entrySchemaID: $0.active.installation.schemaID)
            }
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<PreparedSchemeImport, Error>) in
                DispatchQueue(label: "scheme-import.read", qos: .userInitiated).async {
                    continuation.resume(
                        with: Result {
                            let imported =
                                if let recommendation {
                                    try reader.prepareRecommended(recommendation, archiveURLs: picked)
                                } else {
                                    try reader.prepareSync(picked)
                                }
                            let existing =
                                explicit
                                ?? SchemeReimport.replacing(
                                    entrySchemaID: imported.manifest.schemaID,
                                    importedID: imported.declaration.id, installed: known)
                            guard let existing else { return imported }
                            let update = try imported.updatingInstallation(id: existing.id, name: existing.name)
                            // Grammar models the user added to the installed version are not in the
                            // new files; an update keeps them.
                            guard let location = installedResources[existing.id],
                                let record = try? RecipePackageManager.readInstalledRecipeSources(resources: location)
                            else { return update }
                            return try update.carryingModels(from: record)
                        })
                }
            }
            prepared = result
            diagnostics =
                result.diagnostics
                + result.schemaIDs.map {
                    String(localized: "包含输入方式：\($0)")
                }
            message = nil
        } catch {
            fail(.nothingCommitted, error)
            diagnostics = [error.localizedDescription]
            message = nil
            if capture.sourceURL != nil { preparedSourceURL = nil }
        }
        return prepared != nil
    }

    /// Whether this install already holds a user's built-in data, judged only from what an earlier
    /// version wrote: a built-in installation/marker, a published selection, Full Access ever seen,
    /// completed onboarding, or a saved script choice. Used only to decide a first install's locale
    /// default; an existing user is never re-seeded, including one whose install predates the switch.
    /// Nonisolated: it reads the option store off the main actor (see the caller's detached read).
    nonisolated private static func hasExistingBuiltinSettings(_ id: String) -> Bool {
        if KeyboardPresenceStamp.lastFullAccessSeen() != nil { return true }
        if UserDefaults.standard.bool(forKey: AppSettings.onboardingCompletedKey) { return true }
        if KeyboardRecipeStore.readSelection().data != nil { return true }
        let option = BuiltinScriptDefault.descriptor(
            resourceID: id, schemaID: BuiltinTemplateSchemas.sourceSchemaIDs[0], state: .simplified)
        let store = OptionStore(directory: RimePaths.optionPreferencesDirectory())
        do { return try store.value(for: option) != nil } catch {
            // A stored choice that cannot be read still belongs to an existing install.
            return true
        }
    }

    private static var builtinInstall: Task<Void, Never>?

    /// Installs the scheme bundled with the app as an ordinary installed scheme, so its input
    /// methods are added to 我的键盘 and published like any import. Runs once per launch and is
    /// silent unless it fails; a bundle that has not changed is not reinstalled. The built-in
    /// scheme's updates come with the app rather than from the user, so when it is in use the
    /// keyboard moves to the new version right away.
    func installBuiltinPackage() -> Task<Void, Never> {
        if let run = Self.builtinInstall { return run }
        let run = Task { await installBuiltinPackageIfNeeded() }
        Self.builtinInstall = run
        return run
    }

    private func installBuiltinPackageIfNeeded() async {
        let id = ProductionInputAvailability.builtinPackageID
        let store = manager(id)
        // Adding keyboards and other options reinstall the package under new revisions, so what
        // was installed from the bundle is recorded beside it rather than read from the installation.
        let marker = Self.storeRoot.appendingPathComponent(id).appendingPathComponent("bundled-revision")
        let prepared: PreparedSchemeImport
        let installed: ActiveRecipe?
        let recorded: String?
        do {
            guard let bundled = RimePaths.builtinPackage() else {
                throw RecipeInstallError.invalidResource(String(localized: "找不到内置输入方案，请重新安装 App。"))
            }
            (prepared, recorded) = try await Task.detached {
                (
                    try store.prepareBundledPackage(directory: bundled),
                    try? String(contentsOf: marker, encoding: .utf8)
                )
            }.value
            installed = try await store.activeInstallation()
        } catch {
            fail(.nothingCommitted, error)
            return
        }
        guard installed == nil || recorded != prepared.manifest.revision, !busy else { return }
        // Any state read here was written before this bootstrap, so a first install stays
        // distinguishable from an upgrade even though the install below writes the marker. The
        // option-store read is disk IO, so it runs detached instead of on the main actor.
        let priorSettings = await Task.detached { Self.hasExistingBuiltinSettings(id) }.value
        // Any prior installation or record (even of the same content revision: content is not an
        // install time) plus prior user data marks an existing install; only a first install is fresh.
        let hadBuiltinSettings = BuiltinScriptEraRecord.hostIndicatesExistingInstall(
            installed: installed != nil, recorded: recorded != nil, userSettings: priorSettings)
        // Record the era before this bootstrap writes anything: the keyboard boot keeps a pre-switch
        // install's script output and only a genuinely new install gets the locale default. Written
        // once, so a later fresh-looking launch cannot relabel an upgraded install.
        if let defaults = KeyboardRecipeStore.sharedDefaults(),
            defaults.string(forKey: TraditionalDefault.installEraKey) == nil
        {
            defaults.set(
                hadBuiltinSettings
                    ? BuiltinScriptInstallEra.legacy.rawValue
                    : BuiltinScriptInstallEra.current.rawValue,
                forKey: TraditionalDefault.installEraKey)
        }
        busy = true
        do {
            _ = try await EngineOwnershipCoordinator.shared.withExclusive {
                try await store.installSchemeImport(prepared, expectedGeneration: installed?.installation.generation) {
                    try await Self.verifyRecipeDeployment($0, packageID: id, packageName: prepared.declaration.name)
                        .receipt
                }
            }
            // Without the record the next launch only installs the same files again.
            let revision = prepared.manifest.revision
            await Task.detached { try? Data(revision.utf8).write(to: marker, options: .atomic) }.value
        } catch {
            busy = false
            fail(.nothingCommitted, error)
            return
        }
        busy = false
        await refresh()
        guard installed != nil, let shared = try? await AppliedSelectionLoader.loadWriteBaseline(),
            shared.recipeEnabled, shared.kind == .userScheme, shared.packageID == id,
            !shared.keyboards.isEmpty
        else { return }
        do {
            _ = try await performReplaceKeyboards(packageID: id, requested: shared.keyboards)
        } catch {
            fail(.installedNotApplied, error)
        }
    }

    func install() {
        guard !busy, let sourcePrepared = prepared else { return }
        // The recognized list of installed packages is already refreshed when this page appears, so
        // its generation is the baseline this update started from: a change made meanwhile (another
        // device, another screen, a deletion) is reported by the store instead of being overwritten.
        // A package with no current installation passes nil and installs as a first install.
        let baseline = installedPackages.first { $0.id == sourcePrepared.declaration.id }?
            .active.installation.generation
        Task { await performInstall(sourcePrepared, expectedGeneration: baseline) }
    }

    /// Install transaction of the recognized import, shared by `install` (file picker) and the direct
    /// update. `expectedGeneration` is the generation installed before this attempt: the store lock
    /// compares it before writing anything, so an installation changed meanwhile is reported instead
    /// of being overwritten. A first install passes nil. The committed revision is returned, or nil
    /// when nothing was committed.
    @discardableResult
    func performInstall(_ sourcePrepared: PreparedSchemeImport, expectedGeneration: String?) async -> String? {
        guard !busy else { return nil }
        retryState.begin(.installRecognizedImport)
        let prepared: PreparedSchemeImport
        do {
            // A scheme that is already installed keeps the grammar models it was given: they live
            // in its own source record, not in a new download. Without them an update of a scheme
            // that needs a model would be refused as if the download were incomplete.
            var models = providedDownloadFiles
            if let installed = try? await manager(sourcePrepared.declaration.id).activeInstallation(),
                let record = try? RecipePackageManager.readInstalledRecipeSources(resources: installed.resourceURL)
            {
                for (path, resource) in record.fileResources where models[path] == nil {
                    models[path] = resource
                }
            }
            prepared = try sourcePrepared.preparingModels(models)
        } catch {
            fail(.nothingCommitted, error)
            return nil
        }
        busy = true
        error = nil
        defer { busy = false }
        let sourceURLAtInstall = preparedSourceURL
        message = String(localized: "正在安装…")
        do {
            let manager = manager(prepared.declaration.id)
            let installed = try await EngineOwnershipCoordinator.shared.withExclusive {
                try await manager.installSchemeImport(prepared, expectedGeneration: expectedGeneration) { deployment in
                    try await Self.verifyRecipeDeployment(
                        deployment, packageID: prepared.declaration.id,
                        packageName: nil,
                        postValidation: { engine, enabled in
                            // Author-declared bindings must type their sample candidate on the live engine.
                            for binding in prepared.declaration.bindings where enabled.contains(binding.schemaID) {
                                try engine.validateSchemaForActivation(schemaID: binding.schemaID)
                                engine.clearComposition()
                                for key in binding.code {
                                    guard let event = RimeKey(character: key) else {
                                        throw RecipeInstallError.deployment(String(localized: "输入码不是有效按键"))
                                    }
                                    _ = try engine.processKey(event)
                                }
                                let state = engine.state()
                                guard let index = state.candidates.firstIndex(where: { $0.text == binding.candidate }),
                                    engine.selectCandidate(index)?.commitText == binding.candidate
                                else {
                                    throw RecipeInstallError.deployment(
                                        String(
                                            localized:
                                                "试打后没有出现预期的候选词：输入方式「\(binding.schemaID)」，键盘布局「\(binding.layout)」，输入码「\(binding.code)」"
                                        )
                                    )
                                }
                            }
                        }
                    ).receipt
                }
            }
            lastInstallReplacedVersion = installedPackages.contains { $0.id == prepared.declaration.id }
            self.prepared = nil
            preparedSourceURL = nil
            lastInstalledPackageID = prepared.declaration.id
            retryState.succeeded()
            // A file update keeps the download address an earlier import recorded, so later updates
            // can still fetch from it. A Rime source origin cannot survive an install that did not
            // come from that source, so it is cleared and the scheme counts as a local file again.
            let sourceWarning: String?
            if let sourceURLAtInstall {
                sourceWarning = saveSource(sourceURLAtInstall, packageID: prepared.declaration.id)
            } else if Self.recordedSourceTarget(packageID: prepared.declaration.id) != nil {
                sourceWarning = saveSource(nil, packageID: prepared.declaration.id)
            } else {
                sourceWarning = nil
            }
            diagnostics = []
            userNotice = UserNoticeLayering.installationNextStep(
                installedPackageID: prepared.declaration.id)
            message = sourceWarning
            await refresh()
            await offerPackageLearning(for: prepared)
            return installed.revision
        } catch {
            fail(.nothingCommitted, error)
            message = nil
            return nil
        }
    }
}
