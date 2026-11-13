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
                Toggle(String(localized: "自动备份到 iCloud"), isOn: $model.automatic)
                    .accessibilityIdentifier("backup.automatic")
                Text(model.cloudStatus).font(.footnote).foregroundStyle(.secondary)
                Button(String(localized: "立即完整备份")) { Task { await model.backUp(manual: true) } }
                    .disabled(model.busy)
                    .accessibilityIdentifier("backup.create")
                Button(String(localized: "刷新备份列表")) {
                    Task {
                        await model.refreshCloud()
                        await model.refreshLocal()
                    }
                }
                if model.busy {
                    HStack {
                        ProgressView()
                        Text(model.progress).font(.footnote)
                    }
                }
            } header: {
                Text(String(localized: "完整配置备份"))
            } footer: {
                Text(
                    String(
                        localized:
                            "保存方案来源、所选配置、我的键盘及启用项、布局和页面搭配、符号库、个人词库、设置及学习快照。输入方案本体、可下载词库和语法模型只记录依赖，恢复时重新下载。自动备份间隔至少 5 分钟，后台执行和上传时机由系统安排。"
                    )
                )
            }
            Section {
                if model.cloudItems.isEmpty {
                    Text(
                        model.cloudAvailable
                            ? String(localized: "暂未发现 iCloud 备份") : String(localized: "连接 iCloud 后显示历史备份")
                    )
                    .foregroundStyle(.secondary)
                }
                ForEach(model.cloudItems) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        backupRow(item)
                        HStack {
                            Button(String(localized: "下载并恢复")) { Task { await model.prepareRestore(item) } }
                            Spacer()
                            Button(String(localized: "删除"), role: .destructive) { deleting = item }
                                .accessibilityIdentifier("backup.delete.cloud")
                        }.buttonStyle(.borderless)
                    }.disabled(model.busy)
                }
            } header: {
                Text(String(localized: "iCloud 历史备份"))
            } footer: {
                Text(String(localized: "重装后登录同一 Apple 账户，在这里选择备份下载并恢复。恢复前会校验全部文件，并保存当前配置的完整备份。历史备份不会自动删除。"))
            }
            Section {
                Button(String(localized: "从文件恢复完整备份")) { importing = true }.disabled(model.busy)
                ForEach(model.localItems) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        backupRow(item)
                        HStack {
                            Button(String(localized: "恢复")) { Task { await model.prepareRestore(item) } }.disabled(
                                model.busy)
                            Spacer()
                            ShareLink(item: item.url) {
                                Label(String(localized: "导出"), systemImage: "square.and.arrow.up")
                            }
                            Button(String(localized: "删除"), role: .destructive) { deleting = item }
                                .disabled(model.busy)
                                .accessibilityIdentifier("backup.delete.local")
                        }.buttonStyle(.borderless)
                    }
                }
            } header: {
                Text(String(localized: "本机完整备份"))
            } footer: {
                Text(String(localized: "本机备份可能随卸载一并删除。请确认 iCloud 显示“已上传”，或导出到其他位置。"))
            }
            if model.pendingDependencies {
                Section {
                    ForEach(model.dependencyFailures, id: \.self) { Text($0).font(.footnote) }
                    Button(String(localized: "继续恢复依赖")) { Task { await model.resumeDependencies() } }.disabled(
                        model.busy)
                } header: {
                    Text(String(localized: "尚未完成的依赖"))
                } footer: {
                    Text(String(localized: "联网后可继续下载。有些本地导入的方案或模型没有来源地址，需要先重新导入；布局、页面搭配和学习快照会保留。"))
                }
            }
            Section {
                Text(model.learningSummary).font(.footnote)
            } header: {
                Text(String(localized: "完整备份中的学习快照"))
            } footer: {
                Text(
                    String(
                        localized: "键盘在空闲时按方案收集学习数据，最多每 15 分钟一次，需要允许完全访问。未使用或未收集的方案不会虚报为已备份。下方仍可单独备份、导入和合并当前方案的学习数据。"))
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
            String(localized: "恢复这份完整备份？"), isPresented: $model.confirmingRestore, titleVisibility: .visible
        ) {
            Button(String(localized: "保存当前配置并恢复"), role: .destructive) { Task { await model.restorePrepared() } }
            Button(String(localized: "取消"), role: .cancel) { model.discardPrepared() }
        } message: {
            if let backup = model.prepared {
                Text(
                    String(
                        localized:
                            "备份时间：\(backup.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))。键盘页面搭配、符号库和设置将替换为备份内容，方案和模型按记录下载并恢复启用项，下载可能较大。学习数据会在使用对应键盘时安全合并。"
                    )
                )
            }
        }
        .alert(
            String(localized: "删除这份备份？"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            if let item = deleting {
                Button(item.cloud ? String(localized: "删除 iCloud 备份") : String(localized: "删除本机备份"), role: .destructive)
                {
                    deleting = nil
                    Task { await model.delete(item) }
                }
            }
            Button(String(localized: "取消"), role: .cancel) { deleting = nil }
        } message: {
            if let item = deleting {
                Text(
                    item.cloud
                        ? String(
                            localized: "将删除 iCloud 中的这份备份，并同步到使用同一账户的设备。本机副本会保留。此操作不能撤销。\n\(item.url.lastPathComponent)"
                        )
                        : String(localized: "仅删除本机的这份备份，iCloud 副本会保留。此操作不能撤销。\n\(item.url.lastPathComponent)"))
            }
        }
    }

    private func backupRow(_ item: ConfigurationBackupItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.primary)
            Text(item.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text(HostStorePaths.fileSizeText(item.bytes))
                if item.cloud { Text(item.uploaded ? String(localized: "已上传") : String(localized: "等待上传或上传中")) }
            }.font(.caption).foregroundStyle(.secondary)
            if let error = item.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

struct BackupReadyView: View {
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var model = ConfigurationBackupModel.shared
    var body: some View {
        Group {
            if model.ready {
                HostRootView().disabled(model.restoring)
            } else if let error = model.startupError {
                VStack(spacing: 16) {
                    Text(error)
                    Button(String(localized: "重试")) { Task { await model.start() } }
                }.padding()
            } else {
                ProgressView(String(localized: "正在检查配置…"))
            }
        }
        .task {
            await model.start()
            model.sceneChanged(phase)
        }
        .onChange(of: phase) { _, phase in model.sceneChanged(phase) }
    }
}
