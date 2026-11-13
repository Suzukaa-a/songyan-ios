import SwiftUI
import UniformTypeIdentifiers

/// Lives in the existing learning-backup page: one place for complete configuration and learning.
struct ConfigurationBackupSections: View {
    @ObservedObject private var model = ConfigurationBackupModel.shared
    @State private var importing = false
    @State private var deleting: ConfigurationBackupItem?

    var body: some View {
        Group {
            Section {
                Button {
                    Task { await model.backUp(manual: true) }
                } label: {
                    HStack {
                        Text(String(localized: "立即备份"))
                        if model.busy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(model.busy)
                .accessibilityIdentifier("backup.create")
            } footer: {
                Text(model.busy && !model.progress.isEmpty ? model.progress : model.cloudStatus)
            }
            if model.cloudAvailable {
                Section {
                    Toggle(String(localized: "自动备份到 iCloud"), isOn: $model.automaticICloud)
                        .accessibilityIdentifier("backup.automaticICloud")
                    if model.cloudItems.isEmpty {
                        Text(String(localized: "还没有备份")).foregroundStyle(.secondary)
                    }
                    ForEach(model.cloudItems) { item in backupRow(item) }
                } header: {
                    Text(verbatim: "iCloud")
                } footer: {
                    Text(String(localized: "保留最近 10 份。重装松烟后，用同一个 Apple 账户登录就能恢复。"))
                }
            }
            Section {
                ForEach(model.localItems) { item in backupRow(item) }
                Button(String(localized: "从文件恢复…")) { importing = true }.disabled(model.busy)
            } header: {
                Text(String(localized: "本机"))
            } footer: {
                Text(String(localized: "改动后会自动在本机备份，保留最近 10 份。删除松烟时，本机备份也会被删除。"))
            }
            if model.pendingDependencies {
                Section {
                    ForEach(model.dependencyFailures, id: \.self) { Text($0).font(.footnote) }
                    Button(String(localized: "继续下载")) { Task { await model.resumeDependencies() } }
                        .disabled(model.busy)
                } header: {
                    Text(String(localized: "还没下载完"))
                }
            }
            if let notice = model.notice {
                Section { Text(notice).font(.footnote).textSelection(.enabled) }
            }
        }
        .task {
            await model.refreshCloud()
            await model.refreshLocal()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .zip]) { result in
            switch result {
            case .success(let url):
                Task {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    await model.prepareRestore(
                        .init(
                            url: url, date: Date(), bytes: 0, cloud: false, uploaded: false, downloaded: true,
                            error: nil))
                }
            case .failure(let error): model.notice = error.localizedDescription
            }
        }
        .confirmationDialog(
            String(localized: "恢复这份备份？"), isPresented: $model.confirmingRestore, titleVisibility: .visible
        ) {
            Button(String(localized: "恢复"), role: .destructive) { Task { await model.restorePrepared() } }
            Button(String(localized: "取消"), role: .cancel) { model.discardPrepared() }
        } message: {
            if let backup = model.prepared {
                Text(
                    String(
                        localized:
                            "备份时间：\(backup.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))。现在的键盘和设置会换成备份里的内容，输入方案和语法模型会重新下载。恢复前会先备份现在的内容。"
                    )
                )
            }
        }
        .confirmationDialog(
            String(localized: "删除这份备份？"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            if let item = deleting {
                Button(String(localized: "删除"), role: .destructive) {
                    deleting = nil
                    Task { await model.delete(item) }
                }
            }
            Button(String(localized: "取消"), role: .cancel) { deleting = nil }
        } message: {
            if let item = deleting {
                Text(
                    item.cloud
                        ? String(localized: "这份备份会从 iCloud 中删除，本机的备份会保留。")
                        : String(localized: "只删除本机的这份备份。"))
            }
        }
    }

    private func backupRow(_ item: ConfigurationBackupItem) -> some View {
        Button {
            Task { await model.prepareRestore(item) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.primary)
                Text(details(item)).font(.footnote).foregroundStyle(.secondary)
                if let error = item.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .disabled(model.busy)
        .swipeActions {
            Button(String(localized: "删除"), role: .destructive) { deleting = item }
        }
        .contextMenu {
            if !item.cloud {
                ShareLink(item: item.url) { Label(String(localized: "导出"), systemImage: "square.and.arrow.up") }
            }
            Button(String(localized: "删除"), systemImage: "trash", role: .destructive) { deleting = item }
        }
        .accessibilityIdentifier(item.cloud ? "backup.cloud" : "backup.local")
    }

    private func details(_ item: ConfigurationBackupItem) -> String {
        var parts = [HostStorePaths.fileSizeText(item.bytes)]
        if item.cloud { parts.append(item.uploaded ? String(localized: "已上传") : String(localized: "正在上传")) }
        if ConfigurationBackupStorage.isSafety(item.url) { parts.append(String(localized: "恢复前的备份")) }
        return parts.joined(separator: " · ")
    }
}

struct BackupReadyView: View {
    /// iPhones with a Home button and iPads need a globe key; on other iPhones the system draws its
    /// own below the keyboard, which leaves a bottom safe area on the screen.
    @MainActor private static var deviceNeedsGlobe: Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return true }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first
        return (window?.safeAreaInsets.bottom ?? 0) == 0
    }

    @Environment(\.scenePhase) private var phase
    @ObservedObject private var model = ConfigurationBackupModel.shared
    @State private var slow = false
    var body: some View {
        Group {
            if model.ready {
                HostRootView().disabled(model.restoring)
            } else if let error = model.startupError {
                VStack(spacing: 16) {
                    Text(error)
                    Button(String(localized: "重试")) { Task { await model.start() } }
                }.padding()
            } else if slow {
                ProgressView(String(localized: "正在准备…"))
            } else {
                // Starting is usually instant; a spinner flashing on every launch reads as a delay.
                Color(uiColor: .systemBackground).ignoresSafeArea()
            }
        }
        .task {
            // Editors open in this machine's shape, so whether it needs a globe key is settled first.
            let needed = Self.deviceNeedsGlobe
            await Task.detached { KeyboardSystemRequirements.seedNeedsInputModeSwitchKey(needed) }.value
            _ = await KeyboardPreviewPreferences.load()
            await model.start()
            model.sceneChanged(phase)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            slow = true
        }
        .onChange(of: phase) { _, phase in model.sceneChanged(phase) }
    }
}
