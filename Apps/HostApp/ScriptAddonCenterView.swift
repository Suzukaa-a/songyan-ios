import ScriptAddonKit
import SwiftUI
import UIKit

/// The "scripts" screen: the addon list plus the four ways to add one. A script is an
/// addon like any other tool; this screen never implements a second run/preview model,
/// the keyboard's Tool panel does that from the same stored files.
struct ScriptAddonCenterView: View {
    @ObservedObject var center: ScriptAddonCenter
    @State private var showsPaste = false
    @State private var pasteText = ""
    @State private var showsLink = false
    @State private var linkText = ""
    @State private var importer = false
    @State private var editorTarget: EditorTarget?
    @State private var settingsTarget: ScriptAddonStore.Addon?
    @State private var pendingDeletes: [ScriptAddonStore.Addon] = []
    @State private var showGuide = false
    /// Set by the guide sheet's add button; staged once the sheet is gone, so the confirm sheet
    /// does not compete with a sheet that is still dismissing.
    @State private var stageExampleAfterGuide = false
    @State private var showAddOptions = false

    var body: some View {
        List {
            if let notice = center.notice {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.secondary)
                        Text(notice).font(.footnote)
                        Spacer(minLength: 0)
                        Button(String(localized: "好")) { center.clearNotice() }
                            .font(.footnote)
                    }
                }
            }
            if center.addons.isEmpty {
                emptyRow
            } else {
                ForEach(center.addons, id: \.state.id) { addon in
                    addonRow(addon)
                }
                .onMove(perform: center.reorder)
                .onDelete { indexSet in
                    pendingDeletes = indexSet.compactMap { index in
                        center.addons.indices.contains(index) ? center.addons[index] : nil
                    }
                }
            }
        }
        .navigationTitle(Text(String(localized: "脚本")))
        .toolbar {
            if !center.addons.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                        .accessibilityHint(String(localized: "拖动排序或删除脚本"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    addActions
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel(String(localized: "添加脚本"))
                }
            }
        }
        .sheet(isPresented: $showsPaste) { pasteSheet }
        .sheet(isPresented: $showsLink) { linkSheet }
        .sheet(
            isPresented: $showGuide,
            onDismiss: {
                guard stageExampleAfterGuide else { return }
                stageExampleAfterGuide = false
                center.stageMinimalExample()
            }
        ) { guideSheet }
        .sheet(item: $settingsTarget) { addon in
            NavigationStack {
                ScriptAddonSettingsView(center: center, addon: addon)
            }
        }
        .sheet(item: $editorTarget) { target in
            ScriptAddonEditorView(center: center, addon: target.addon)
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.javaScript]) { result in
            if case .success(let url) = result { center.importFile(url) }
        }
        .sheet(
            item: Binding(
                get: { center.pending.map { PendingBox(draft: $0) } },
                set: { if $0 == nil { center.cancelPending() } }
            )
        ) { box in
            ScriptAddonConfirmationView(center: center, draft: box.draft)
        }
        .alert(
            center.errorMessage ?? "",
            isPresented: Binding(
                get: { center.errorMessage != nil },
                set: { if !$0 { center.errorMessage = nil } })
        ) {
            Button(String(localized: "好")) { center.errorMessage = nil }
        }
        .confirmationDialog(
            String(localized: "添加脚本"),
            isPresented: $showAddOptions,
            titleVisibility: .visible
        ) {
            addActions
        }
        .onAppear {
            #if DEBUG
                // Screenshot probe only; Release has no auto-presented sheets.
                switch ProcessInfo.processInfo.environment["SONGYAN_SCRIPT_VISUAL_SHEET"] {
                case "paste": showsPaste = true
                case "link": showsLink = true
                default: break
                }
            #endif
        }
        .confirmationDialog(
            String(localized: "删除脚本？"),
            isPresented: Binding(
                get: { !pendingDeletes.isEmpty },
                set: { if !$0 { pendingDeletes = [] } })
        ) {
            Button(String(localized: "删除"), role: .destructive) {
                for addon in pendingDeletes { center.delete(addon: addon) }
                pendingDeletes = []
            }
            Button(String(localized: "取消"), role: .cancel) { pendingDeletes = [] }
        } message: {
            Text(
                String(
                    localized: "脚本的设置和密钥也会一起删除，且无法撤销。")
                    + "\n" + pendingDeletes.map { title(of: $0) }.joined(separator: "、"))
        }
    }

    @ViewBuilder
    private var addActions: some View {
        Button(String(localized: "粘贴脚本文字")) { showsPaste = true }
        Button(String(localized: "导入 .js 文件")) { importer = true }
        Button(String(localized: "从链接添加")) { showsLink = true }
        Button(String(localized: "新建并编辑")) { editorTarget = EditorTarget(addon: nil) }
    }

    private var emptyRow: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(String(localized: "还没有脚本")).font(.headline)
                } icon: {
                    Image(systemName: "curlybraces").foregroundStyle(.tint)
                }
                Text(
                    String(
                        localized:
                            "脚本处理你选中的文字，结果先预览。")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Button {
                    showAddOptions = true
                } label: {
                    Label(String(localized: "添加第一个脚本"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button(String(localized: "复制给 AI 的说明")) {
                    UIPasteboard.general.string = ScriptAddonCenter.aiGuide()
                }
                .font(.footnote)
                Button(String(localized: "查看不联网的最小示例")) { showGuide = true }
                    .font(.footnote)
            }
            .padding(.vertical, 4)
        }
    }

    private func addonRow(_ addon: ScriptAddonStore.Addon) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                NavigationLink {
                    ScriptAddonDetailView(center: center, addon: addon)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(of: addon))
                                .foregroundStyle(.primary)
                            if center.needsReconfirmation(addon) {
                                Label {
                                    Text(String(localized: "脚本要求有变化，需要重新确认"))
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                }
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                            if let summary = summaryLine(of: addon) {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(
                                        center.availabilityNote(addon) == nil
                                            ? Color.secondary : Color.orange)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(format: String(localized: "打开 %@ 的详情"), title(of: addon))
                )
                .accessibilityHint(String(localized: "查看它能读取的内容和会连接的网站"))
                Toggle(
                    "",
                    isOn: Binding(
                        get: { addon.state.enabled },
                        set: { center.setEnabled($0, addon: addon) })
                )
                .labelsHidden()
                .accessibilityLabel(
                    String(format: String(localized: "启用 %@"), title(of: addon))
                )
                .accessibilityValue(
                    center.availabilityNote(addon) != nil
                        ? String(localized: "不可用")
                        : addon.state.enabled
                            ? String(localized: "已启用") : String(localized: "已停用")
                )
                .opacity(center.availabilityNote(addon) == nil ? 1 : 0.35)
                .disabled(center.availabilityNote(addon) != nil)
                .accessibilityHint(
                    center.availabilityNote(addon) != nil
                        ? String(localized: "此脚本需要录音，键盘里会标为不可用")
                        : String(localized: "打开或关闭这个脚本"))
            }
            if center.needsReconfirmation(addon) {
                Button(String(localized: "重新确认")) { center.reconfirm(addon: addon) }
                    .font(.footnote)
            }
            if center.updatingID == addon.state.id {
                HStack(spacing: 6) {
                    ProgressView()
                    Text(String(localized: "检查更新"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeletes = [addon]
            } label: {
                Label(String(localized: "删除"), systemImage: "trash")
            }
        }
        .contextMenu {
            Button(String(localized: "编辑")) { editorTarget = EditorTarget(addon: addon) }
            Button(String(localized: "设置与密钥")) { settingsTarget = addon }
            Button(String(localized: "检查更新")) { center.checkForUpdate(addon: addon) }
            if let data = center.exportData(addon: addon) {
                ShareLink(item: scriptFile(data, title: title(of: addon))) {
                    Text(String(localized: "导出脚本"))
                }
            }
            Button(String(localized: "删除"), role: .destructive) { pendingDeletes = [addon] }
        }
    }

    private func title(of addon: ScriptAddonStore.Addon) -> String {
        (try? center.declarations(for: addon.state.id).name) ?? String(localized: "未命名脚本")
    }

    private func summaryLine(of addon: ScriptAddonStore.Addon) -> String? {
        if center.availabilityNote(addon) != nil {
            return String(localized: "录音不可用")
        }
        return (try? center.declarations(for: addon.state.id).summary) ?? nil
    }

    private var pasteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                if let error = center.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $pasteText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 300)
                    if pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(String(localized: "在这里粘贴或编写脚本"))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 6)
                            .allowsHitTesting(false)
                    }
                }
                Button(String(localized: "插入最小示例")) {
                    pasteText = ScriptAddonCenter.minimalExample()
                }
                .font(.footnote)
                Text(String(localized: "粘贴后先确认脚本要求，再添加。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .onAppear { center.errorMessage = nil }
            .navigationTitle(Text(String(localized: "粘贴脚本")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { showsPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "继续")) {
                        if center.stage(source: Data(pasteText.utf8)) { showsPaste = false }
                    }
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var linkSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "脚本链接（https）"), text: $linkText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel(String(localized: "脚本链接（https）"))
                    Text(
                        String(
                            localized:
                                "只支持 HTTPS 链接；脚本只在这里下载一次，之后可在详情页检查更新。")
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if center.isDownloading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(String(localized: "下载中…"))
                    }
                }
                if let error = center.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .onAppear { center.errorMessage = nil }
            .navigationTitle(Text(String(localized: "从链接添加")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { showsLink = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if center.isDownloading {
                        ProgressView()
                    } else {
                        Button(String(localized: "下载")) { downloadLinkedScript() }
                            .disabled(!ScriptAddonURLValidation.isValidHTTPS(linkText))
                    }
                }
            }
        }
    }

    private func downloadLinkedScript() {
        guard let url = URL(string: linkText.trimmingCharacters(in: .whitespacesAndNewlines)),
            ScriptAddonURLValidation.isValidHTTPS(linkText)
        else {
            center.errorMessage = String(localized: "请输入有效的 HTTPS 链接")
            return
        }
        Task {
            if await center.importLink(url) { showsLink = false }
        }
    }

    private var guideSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "把这个说明复制给 AI，让它生成一个脚本"))
                        .font(.headline)
                    Text(ScriptAddonCenter.aiGuide())
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Divider()
                    Text(String(localized: "不联网的最小示例"))
                        .font(.headline)
                    Text(ScriptAddonCenter.minimalExample())
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button(String(localized: "添加这个例子")) {
                        stageExampleAfterGuide = true
                        showGuide = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .navigationTitle(Text(String(localized: "给 AI 的说明")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "完成")) { showGuide = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "复制说明")) {
                        UIPasteboard.general.string = ScriptAddonCenter.aiGuide()
                    }
                }
            }
        }
    }
}

/// Wraps a draft so it can drive a sheet's item binding.
struct PendingBox: Identifiable {
    let draft: ScriptAddonCenter.Draft
    var id: String { draft.id }
}
