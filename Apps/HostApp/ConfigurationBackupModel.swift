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

    @Published var automatic = true {
        didSet {
            KeyboardRecipeStore.sharedDefaults()?.set(automatic, forKey: LearningSnapshotStore.automaticBackupKey)
            if automatic {
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
    @Published private(set) var learningSummary = String(localized: "尚未收集学习快照。使用松烟键盘后会自动收集。")
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
    private struct AutomaticState: Codable, Sendable {
        let stamp: String
        let filename: String
        let date: Date
        var formatVersion: Int? = 2
    }

    override private init() {
        super.init()
        automatic =
            KeyboardRecipeStore.sharedDefaults()?.object(forKey: LearningSnapshotStore.automaticBackupKey) as? Bool
            ?? true
    }

    static func registerBackgroundTask() {
        guard !backgroundRegistered else { return }
        backgroundRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: nil) {
            task in
            let work = Task { @MainActor in
                let model = ConfigurationBackupModel.shared
                await model.start()
                await model.refreshCloud()
                await model.backUp(manual: false)
                model.scheduleBackgroundBackup()
                task.setTaskCompleted(success: model.notice == nil)
            }
            task.expirationHandler = { work.cancel() }
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
            await refreshPendingDependencies()
            await refreshCloud()
            await refreshLocal()
        } catch { startupError = String(localized: "未完成的恢复暂时无法回滚，已暂停加载配置：\(error.localizedDescription)") }
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
        guard automatic, Self.backgroundRegistered else { return }
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
                cloudStatus = String(localized: "iCloud 不可用。请登录 Apple 账户并开启 iCloud 云盘和松烟的 iCloud 权限。")
                return
            }
            cloudAvailable = true
            cloudStatus = String(localized: "已连接 iCloud。只有显示“已上传”的备份才能在重装后取回。")
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
            let result = try await ConfigurationBackupIO.run { () -> ([ConfigurationBackupItem], String) in
                let directory = ConfigurationBackupStorage.localArchives
                let files =
                    FileManager.default.fileExists(atPath: directory.path)
                    ? try FileManager.default.contentsOfDirectory(
                        at: directory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]) : []
                let items = try files.filter { $0.pathExtension == "songyanbackup" }.map { url in
                    let values = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                    return ConfigurationBackupItem(
                        url: url, date: values.creationDate ?? .distantPast, bytes: Int64(values.fileSize ?? 0),
                        cloud: false, uploaded: false, downloaded: true, error: nil)
                }.sorted { $0.date > $1.date }
                let learning = try LearningSnapshotStore(root: ConfigurationBackupStorage.sources()[.learning]!)
                    .snapshots()
                let summary: String
                if learning.isEmpty {
                    summary = String(localized: "尚未收集学习快照。使用松烟键盘后会自动收集，也可以在下方立即备份当前方案的学习数据。")
                } else {
                    summary = learning.sorted { $0.sourceName < $1.sourceName }.map {
                        "\($0.sourceName)：\($0.createdAt.formatted(date: .abbreviated, time: .shortened))"
                    }.joined(separator: "\n")
                }
                return (items, summary)
            }
            localItems = result.0
            learningSummary = result.1
        } catch { notice = error.localizedDescription }
    }

    func backUp(manual: Bool) async {
        guard ready, !busy, prepared == nil, manual || automatic,
            !SchemeImportCenter.shared.busy, !DictionaryImportCenter.shared.busy
        else { return }
        busy = true
        notice = nil
        progress = String(localized: "正在检查配置…")
        defer {
            busy = false
            progress = ""
        }
        do {
            let stamp = try await ConfigurationBackupIO.run { try ConfigurationBackupStorage.changeStamp() }
            guard manual || stamp != nil else { return }
            if manual || stamp != lastStamp || lastArchive == nil {
                if !manual && Date().timeIntervalSince(lastAutomaticBackup) < 5 * 60 { return }
                progress = String(localized: "正在生成完整备份…")
                let result = try await ConfigurationBackupIO.run { try ConfigurationBackupStorage.create() }
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
            if let lastArchive, let cloudDirectory,
                FileManager.default.fileExists(atPath: lastArchive.path)
            {
                progress = String(localized: "正在交给 iCloud 上传…")
                try await ConfigurationBackupIO.run { try Self.upload(lastArchive, directory: cloudDirectory) }
                if manual { notice = String(localized: "完整备份已生成。iCloud 会继续上传，请在列表中确认“已上传”状态。") }
            } else if manual {
                notice = String(localized: "完整备份已保存在本机。iCloud 恢复连接后会继续上传；也可以导出文件自行保管。")
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
        progress = item.cloud ? String(localized: "正在从 iCloud 下载并校验…") : String(localized: "正在校验完整备份…")
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
                guard complete else { throw BackupFailure.message(String(localized: "下载尚未完成，请检查网络后重试。")) }
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
            notice = String(localized: "输入方案正在更新，请等待完成后再恢复。")
            return
        }
        busy = true
        restoring = true
        confirmingRestore = false
        notice = nil
        let activity = ProcessActivityAssertion(reason: "Songyan configuration restore")
        defer { activity.end() }
        progress = String(localized: "正在保存恢复前备份…")
        defer {
            busy = false
            restoring = false
            progress = ""
        }
        do {
            _ = try await ConfigurationBackupIO.run { try ConfigurationBackupStorage.create(safety: true) }
            progress = String(localized: "正在恢复配置…")
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
                ? String(localized: "布局和设置已恢复，部分依赖尚未完成。请查看下方原因并继续恢复；记录和学习快照已保留。")
                : String(localized: "配置和依赖已恢复。下次使用对应键盘时会合并学习快照。恢复前的配置备份保留在本机列表中。")
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
            notice = pendingDependencies ? String(localized: "仍有依赖未完成，请查看原因后重试。") : String(localized: "依赖和键盘启用项已恢复。")
            revision = UUID()
        } catch { notice = String(localized: "依赖恢复未完成：\(error.localizedDescription)") }
    }

}
