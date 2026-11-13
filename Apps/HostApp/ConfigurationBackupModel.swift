import BackgroundTasks
import Foundation
import KeyboardCore
import PackageManager
import SwiftUI

struct ConfigurationBackupItem: Identifiable, Sendable {
    let url: URL
    let date: Date
    let bytes: Int64
    let cloud: Bool
    let uploaded: Bool
    let downloaded: Bool
    let error: String?
    var id: String { url.absoluteString }
}

@MainActor
final class ConfigurationBackupModel: NSObject, ObservableObject {
    static let shared = ConfigurationBackupModel()
    nonisolated static let containerID = "iCloud.app.songyan.ime"
    static let backgroundTaskID = "app.songyan.ime.configuration-backup"
    private static var backgroundRegistered = false

    /// Local backups run on their own; this only decides whether they also go to iCloud.
    @Published var automaticICloud = false {
        didSet {
            KeyboardRecipeStore.sharedDefaults()?.set(
                automaticICloud, forKey: LearningSnapshotStore.automaticICloudBackupKey)
            if automaticICloud {
                scheduleBackgroundBackup()
            } else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskID)
            }
        }
    }
    @Published private(set) var ready = false
    @Published private(set) var startupError: String?
    @Published private(set) var cloudStatus = String(localized: "正在检查 iCloud…")
    @Published private(set) var cloudAvailable = false
    @Published private(set) var cloudItems: [ConfigurationBackupItem] = []
    @Published private(set) var localItems: [ConfigurationBackupItem] = []
    @Published private(set) var busy = false
    @Published private(set) var restoring = false
    @Published private(set) var progress = ""
    @Published var notice: String?
    @Published var confirmingRestore = false
    @Published private(set) var prepared: PreparedConfigurationBackup?
    @Published var revision = UUID()
    @Published private(set) var pendingDependencies = false
    @Published private(set) var dependencyFailures: [String] = []

    private var query: NSMetadataQuery?
    private var cloudDirectory: URL?
    private var automaticTask: Task<Void, Never>?
    private var lastStamp: String?
    private var lastArchive: URL?
    private var lastAutomaticBackup = Date.distantPast
    private var deletedCloudArchives: Set<String> = []
    private struct AutomaticState: Codable, Sendable {
        let stamp: String
        let filename: String
        let date: Date
        var formatVersion: Int? = 2
    }

    override private init() {
        super.init()
        automaticICloud = LearningSnapshotStore.automaticICloudBackupEnabled(KeyboardRecipeStore.sharedDefaults())
    }

    static func registerBackgroundTask() {
        guard !backgroundRegistered else { return }
        // The handler is main-actor code: with a nil queue the system calls it on a background queue
        // and Swift's isolation check traps. The expiration handler may come from any queue.
        backgroundRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: .main) {
            task in
            let work = Task { @MainActor in
                let model = ConfigurationBackupModel.shared
                await model.start()
                await model.refreshCloud()
                await model.backUp(manual: false)
                model.scheduleBackgroundBackup()
                task.setTaskCompleted(success: model.notice == nil)
            }
            task.expirationHandler = { @Sendable in work.cancel() }
        }
    }

    func start() async {
        guard !ready else { return }
        do {
            let state = try await ConfigurationBackupIO.run { () -> AutomaticState? in
                try ConfigurationBackupStorage.recoverInterruptedRestore()
                let file = ConfigurationBackupStorage.root.appendingPathComponent("automatic-state.json")
                guard let data = try? Data(contentsOf: file), data.count < 16384 else { return nil }
                return try? JSONDecoder().decode(AutomaticState.self, from: data)
            }
            if let state, state.formatVersion == 2, !state.filename.contains("/"),
                state.filename.hasSuffix(".songyanbackup")
            {
                lastStamp = state.stamp
                lastArchive = ConfigurationBackupStorage.localArchives.appendingPathComponent(state.filename)
                lastAutomaticBackup = state.date
            }
            ready = true
            startupError = nil
            Task { await ConfigurationBackupStorage.convertLearningCopies() }
            deletedCloudArchives = try await ConfigurationBackupIO.run {
                let url = ConfigurationBackupStorage.root.appendingPathComponent("deleted-cloud-archives.json")
                guard FileManager.default.fileExists(atPath: url.path) else { return [] }
                return try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: url))
            }
            await refreshPendingDependencies()
            await refreshCloud()
            await refreshLocal()
        } catch { startupError = String(localized: "上次恢复没有完成，松烟暂时无法打开：\(error.localizedDescription)") }
    }

    func sceneChanged(_ phase: ScenePhase) {
        automaticTask?.cancel()
        automaticTask = nil
        if phase == .active {
            automaticTask = Task {
                await start()
                await refreshCloud()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    await backUp(manual: false)
                }
            }
        } else if phase == .background {
            scheduleBackgroundBackup()
        }
    }

    func scheduleBackgroundBackup() {
        guard automaticICloud, Self.backgroundRegistered else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskID)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request) } catch
        { /* Foreground backup remains available when background refresh is disabled. */  }
    }

    func refreshCloud() async {
        do {
            let directory = try await ConfigurationBackupIO.run { () -> URL? in
                guard FileManager.default.ubiquityIdentityToken != nil,
                    let root = FileManager.default.url(forUbiquityContainerIdentifier: Self.containerID)
                else { return nil }
                let result = root.appendingPathComponent("Documents/Backups", isDirectory: true)
                try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
                return result
            }
            guard let directory else {
                query?.stop()
                query = nil
                cloudItems = []
                cloudDirectory = nil
                cloudAvailable = false
                cloudStatus = String(localized: "iCloud 不可用，备份只存在本机。要用 iCloud，请在系统设置中登录 Apple 账户并打开 iCloud 云盘。")
                return
            }
            cloudAvailable = true
            cloudStatus = String(localized: "备份包括我的键盘、键盘布局、页面搭配、符号库、词库、设置和学习数据。输入方案和语法模型在恢复时重新下载。")
            if query == nil || cloudDirectory != directory {
                query?.stop()
                NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
                NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
                cloudDirectory = directory
                let query = NSMetadataQuery()
                query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope, NSMetadataQueryUbiquitousDataScope]
                query.predicate = NSPredicate(format: "%K ENDSWITH %@", NSMetadataItemFSNameKey, ".songyanbackup")
                NotificationCenter.default.addObserver(
                    self, selector: #selector(queryChanged), name: .NSMetadataQueryDidFinishGathering, object: query)
                NotificationCenter.default.addObserver(
                    self, selector: #selector(queryChanged), name: .NSMetadataQueryDidUpdate, object: query)
                self.query = query
                query.start()
            }
        } catch {
            cloudAvailable = false
            cloudStatus = String(localized: "iCloud 暂时不可用：\(error.localizedDescription)")
        }
    }

    @objc private func queryChanged() {
        guard let query, let cloudDirectory else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        cloudItems = query.results.compactMap { result in
            guard let item = result as? NSMetadataItem,
                let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                url.deletingLastPathComponent().standardizedFileURL == cloudDirectory.standardizedFileURL
            else { return nil }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let error =
                (item.value(forAttribute: NSMetadataUbiquitousItemUploadingErrorKey) as? NSError)
                ?? (item.value(forAttribute: NSMetadataUbiquitousItemDownloadingErrorKey) as? NSError)
            return ConfigurationBackupItem(
                url: url, date: item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date ?? .distantPast,
                bytes: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0,
                cloud: true,
                uploaded: item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? Bool ?? false,
                downloaded: status == NSMetadataUbiquitousItemDownloadingStatusCurrent
                    || status == NSMetadataUbiquitousItemDownloadingStatusDownloaded,
                error: error?.localizedDescription)
        }.sorted { $0.date > $1.date }
    }

    func refreshLocal() async {
        do {
            localItems = try await ConfigurationBackupIO.run { () -> [ConfigurationBackupItem] in
                let directory = ConfigurationBackupStorage.localArchives
                let files =
                    FileManager.default.fileExists(atPath: directory.path)
                    ? try FileManager.default.contentsOfDirectory(
                        at: directory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]) : []
                return try files.filter { $0.pathExtension == "songyanbackup" }.map { url in
                    let values = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                    return ConfigurationBackupItem(
                        url: url, date: values.creationDate ?? .distantPast, bytes: Int64(values.fileSize ?? 0),
                        cloud: false, uploaded: false, downloaded: true, error: nil)
                }.sorted { $0.date > $1.date }
            }
        } catch { notice = error.localizedDescription }
    }

    func backUp(manual: Bool) async {
        guard ready, !busy, prepared == nil,
            !SchemeImportCenter.shared.busy, !DictionaryImportCenter.shared.busy
        else { return }
        busy = true
        notice = nil
        progress = String(localized: "正在准备…")
        defer {
            busy = false
            progress = ""
        }
        // The keyboard's latest learning copy goes into this backup as an archive.
        await ConfigurationBackupStorage.convertLearningCopies()
        do {
            let stamp = try await ConfigurationBackupIO.run { try ConfigurationBackupStorage.changeStamp() }
            guard manual || stamp != nil else { return }
            if manual || stamp != lastStamp || lastArchive == nil {
                if !manual && Date().timeIntervalSince(lastAutomaticBackup) < 5 * 60 { return }
                progress = String(localized: "正在备份…")
                let result = try await ConfigurationBackupIO.run {
                    let result = try ConfigurationBackupStorage.create()
                    try ConfigurationBackupStorage.prune(ConfigurationBackupStorage.localArchives)
                    return result
                }
                // Keep the stamp from before capture: edits made while the ZIP is being
                // compressed must still trigger the next backup.
                lastStamp = stamp
                lastArchive = result.0
                lastAutomaticBackup = Date()
                let state = AutomaticState(
                    stamp: lastStamp ?? "", filename: result.0.lastPathComponent, date: lastAutomaticBackup)
                try await ConfigurationBackupIO.run {
                    try JSONEncoder().encode(state).write(
                        to: ConfigurationBackupStorage.root.appendingPathComponent("automatic-state.json"),
                        options: .atomic)
                }
            }
            if manual || automaticICloud, let lastArchive, let cloudDirectory,
                !deletedCloudArchives.contains(lastArchive.lastPathComponent),
                FileManager.default.fileExists(atPath: lastArchive.path)
            {
                progress = String(localized: "正在上传到 iCloud…")
                try await ConfigurationBackupIO.run {
                    try Self.upload(lastArchive, directory: cloudDirectory)
                    try ConfigurationBackupStorage.prune(cloudDirectory)
                }
            }
            await refreshLocal()
        } catch is CancellationError {} catch { notice = error.localizedDescription }
    }

    nonisolated private static func upload(_ file: URL, directory: URL) throws {
        let fm = FileManager.default
        let target = directory.appendingPathComponent(file.lastPathComponent)
        if fm.fileExists(atPath: target.path) { return }
        let temp = ConfigurationBackupStorage.root.appendingPathComponent("upload-\(UUID()).songyanbackup")
        try fm.copyItem(at: file, to: temp)
        defer { try? fm.removeItem(at: temp) }
        try fm.setUbiquitous(true, itemAt: temp, destinationURL: target)
    }

    func prepareRestore(_ item: ConfigurationBackupItem) async {
        guard !busy else { return }
        discardPrepared()
        busy = true
        notice = nil
        progress = item.cloud ? String(localized: "正在从 iCloud 下载…") : String(localized: "正在读取备份…")
        defer {
            busy = false
            progress = ""
        }
        do {
            let file = item.url
            if item.cloud {
                try await ConfigurationBackupIO.run { try FileManager.default.startDownloadingUbiquitousItem(at: file) }
                var complete = false
                for _ in 0..<300 {
                    complete = try await ConfigurationBackupIO.run {
                        var refreshedFile = file
                        refreshedFile.removeAllCachedResourceValues()
                        let values = try refreshedFile.resourceValues(forKeys: [
                            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey,
                        ])
                        if let error = values.ubiquitousItemDownloadingError { throw error }
                        return values.ubiquitousItemDownloadingStatus == .current
                            || values.ubiquitousItemDownloadingStatus == .downloaded
                    }
                    if complete { break }
                    try await Task.sleep(for: .seconds(1))
                }
                guard complete else { throw BackupFailure.message(String(localized: "还没下载完，请检查网络后重试。")) }
            }
            prepared = try await ConfigurationBackupIO.run {
                var coordinationError: NSError?
                var result: Result<PreparedConfigurationBackup, Error>?
                NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
                    result = Result { try ConfigurationBackupStorage.stage(url) }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw ConfigurationBackupError.invalidArchive }
                return try result.get()
            }
            confirmingRestore = true
        } catch { notice = error.localizedDescription }
    }

    func discardPrepared() {
        let directory = prepared?.directory
        prepared = nil
        confirmingRestore = false
        if let directory {
            Task { try? await ConfigurationBackupIO.run { try FileManager.default.removeItem(at: directory) } }
        }
    }

    func restorePrepared() async {
        guard let prepared, !busy else { return }
        guard !SchemeImportCenter.shared.busy, !DictionaryImportCenter.shared.busy else {
            notice = String(localized: "输入方案正在更新，完成后再恢复。")
            return
        }
        busy = true
        restoring = true
        confirmingRestore = false
        notice = nil
        let activity = ProcessActivityAssertion(reason: "Songyan configuration restore")
        defer { activity.end() }
        progress = String(localized: "正在备份现在的内容…")
        defer {
            busy = false
            restoring = false
            progress = ""
        }
        do {
            _ = try await ConfigurationBackupIO.run {
                _ = try ConfigurationBackupStorage.create(safety: true)
                try ConfigurationBackupStorage.prune(ConfigurationBackupStorage.localArchives)
            }
            progress = String(localized: "正在恢复…")
            try await EngineOwnershipCoordinator.shared.withExclusive {
                try await ConfigurationBackupIO.run { try ConfigurationBackupStorage.restore(prepared) }
            }
            discardPrepared()
            LayoutManager.shared.reload()
            lastStamp = nil
            lastArchive = nil
            dependencyFailures = try await ConfigurationDependencyRestorer.restore { progress = $0 }
            await refreshPendingDependencies()
            AppearanceManager.shared.reload()
            ShuangpinHintManager.shared.reload()
            await SchemeImportCenter.shared.refresh()
            await DictionaryImportCenter.shared.refresh()
            await KeyboardSelectionCenter.shared.refresh()
            await FuzzyPinyinCenter.shared.refresh()
            await TypoCorrectionCenter.shared.refresh()
            await PredictionCenter.shared.refresh()
            await LuaComponentsCenter.shared.refresh()
            NotificationCenter.default.post(name: .keyboardAppearanceChanged, object: nil)
            notice =
                pendingDependencies
                ? String(localized: "布局和设置已恢复，还有一些内容没下载完。请查看下方原因后继续下载。")
                : String(localized: "已恢复。学习数据会在下次使用键盘时合并，恢复前的内容在本机备份里。")
            revision = UUID()
            await refreshLocal()
        } catch {
            await refreshPendingDependencies()
            notice = String(localized: "恢复未完成：\(error.localizedDescription)")
        }
    }

    func refreshPendingDependencies() async {
        do {
            pendingDependencies = try await ConfigurationDependencyRestorer.pending() != nil
            dependencyFailures = try await ConfigurationBackupIO.run {
                try ConfigurationBackupDependencies.readProgress().failures.values.sorted()
            }
        } catch { notice = error.localizedDescription }
    }

    func resumeDependencies() async {
        guard !busy, !SchemeImportCenter.shared.busy, !DictionaryImportCenter.shared.busy else { return }
        busy = true
        restoring = true
        let activity = ProcessActivityAssertion(reason: "Songyan dependency restore")
        defer {
            busy = false
            restoring = false
            progress = ""
            activity.end()
        }
        do {
            dependencyFailures = try await ConfigurationDependencyRestorer.restore { progress = $0 }
            await refreshPendingDependencies()
            await SchemeImportCenter.shared.refresh()
            await DictionaryImportCenter.shared.refresh()
            await KeyboardSelectionCenter.shared.refresh()
            notice = pendingDependencies ? String(localized: "还有内容没下载完，请查看原因后重试。") : String(localized: "已全部下载完成。")
            revision = UUID()
        } catch { notice = String(localized: "下载未完成：\(error.localizedDescription)") }
    }

    /// Deletes exactly the chosen copy. A cloud tombstone prevents the foreground backup loop
    /// from immediately uploading the same local archive again; a new backup still uploads normally.
    func delete(_ item: ConfigurationBackupItem) async {
        guard !busy, prepared == nil else { return }
        let parent = item.cloud ? cloudDirectory : ConfigurationBackupStorage.localArchives
        guard let parent, (item.cloud ? cloudItems : localItems).contains(where: { $0.id == item.id }) else { return }
        busy = true
        progress = item.cloud ? String(localized: "正在删除 iCloud 备份…") : String(localized: "正在删除本机备份…")
        defer {
            busy = false
            progress = ""
        }
        do {
            if item.cloud {
                // Save intent before deletion, so process termination cannot resurrect the file.
                let names = deletedCloudArchives.union([item.url.lastPathComponent])
                try await ConfigurationBackupIO.run {
                    try FileManager.default.createDirectory(
                        at: ConfigurationBackupStorage.root, withIntermediateDirectories: true)
                    try JSONEncoder().encode(names).write(
                        to: ConfigurationBackupStorage.root.appendingPathComponent("deleted-cloud-archives.json"),
                        options: .atomic)
                }
                deletedCloudArchives = names
            }
            try await ConfigurationBackupIO.run { try ConfigurationBackupStorage.deleteArchive(item.url, from: parent) }
            if item.cloud { cloudItems.removeAll { $0.id == item.id } } else { await refreshLocal() }
            notice =
                item.cloud
                ? String(localized: "已从 iCloud 删除这份备份。") : String(localized: "已删除这份本机备份。")
        } catch { notice = String(localized: "删除未完成：\(error.localizedDescription)") }
    }
}
