import Foundation
import KeyboardCore
import PackageManager
import SwiftUI

/// What the Rime config screens share: the state of the user's files for the input scheme in use,
/// and applying them. Scripts the user has not agreed to yet are asked about before anything is applied.
@MainActor
final class RimeConfigModel: ObservableObject {
    struct ScriptConfirmation: Equatable {
        let scripts: [String]
        let keys: [String]
        let firstTime: Bool
    }

    @Published private(set) var packageID: String?
    @Published private(set) var overview: RimeConfigOverview?
    @Published private(set) var applying = false
    @Published var result: String?
    /// Files that now replace the scheme's own, told once after the first apply with them.
    @Published var overrideNotice: [String]?
    @Published var confirmation: ScriptConfirmation?
    /// The file to open in the editor, and the new-script prompt: state of the screen the rows sit in.
    @Published var editing: RimeEditRoute?
    @Published var restoringPath: String?
    @Published private(set) var restoring = false
    @Published var newScript = false
    @Published var scriptName = ""

    private let center = SchemeImportCenter.shared

    /// The files are edited in other apps too, so this runs on every return to the screen.
    func refresh() async {
        guard let target = await center.rimeConfigTarget() else {
            packageID = nil
            overview = nil
            return
        }
        packageID = target.packageID
        overview = try? await target.manager.rimeConfigOverview()
    }

    func apply(confirmed: [String] = []) async {
        guard !applying else { return }
        applying = true
        result = nil
        defer { applying = false }
        switch await center.applyRimeConfig(confirmed: confirmed) {
        case .needsConfirmation(let scripts, let keys, let firstTime):
            confirmation = ScriptConfirmation(scripts: scripts, keys: keys, firstTime: firstTime)
        case .finished(let text, let applied, let told):
            result = text
            if applied, !told.isEmpty { overrideNotice = told }
        }
        await refresh()
    }

    func createScript() async {
        guard RimeConfigEditor.isScriptName(scriptName), let packageID else {
            result = "名字只能用小写字母、数字和下划线。"
            return
        }
        do {
            let path = try await center.manager(packageID).createRimeScript(name: scriptName)
            await refresh()
            editing = RimeEditRoute(packageID: packageID, path: path, title: path)
        } catch {
            result = error.localizedDescription
        }
    }

    func confirmScripts() {
        guard let keys = confirmation?.keys else { return }
        confirmation = nil
        Task { await apply(confirmed: keys) }
    }

    func restore(_ path: String) async {
        guard let packageID, !restoring else { return }
        restoring = true
        result = nil
        defer { restoring = false }
        do {
            let removed = try await center.manager(packageID).restoreRimeConfigFile(path)
            result = removed ? "已恢复原样。应用更改后生效。" : "这个文件已经是原样。"
            await refresh()
        } catch {
            HostLog.append("restore config failed: \(error.localizedDescription)")
            result = "没能恢复这个文件，请重试。"
        }
    }

    func acknowledgeNotice() async {
        guard let paths = overrideNotice, let packageID else { return }
        overrideNotice = nil
        try? await center.manager(packageID).acknowledgeRimeConfigFiles(paths)
        await refresh()
    }
}

/// The alerts that go with applying: the scripts to agree to, and the one-time notice about files that
/// now replace the scheme's own.
private struct RimeConfigAlerts: ViewModifier {
    @ObservedObject var model: RimeConfigModel

    func body(content: Content) -> some View {
        content
            .alert(
                model.confirmation?.firstTime == true ? "使用你自己的扩展脚本？" : "以下扩展脚本有改动。",
                isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } })
            ) {
                Button("使用") { model.confirmScripts() }
                Button("取消", role: .cancel) { model.confirmation = nil }
            } message: {
                if let confirmation = model.confirmation {
                    let list = confirmation.scripts.joined(separator: "\n")
                    Text(
                        confirmation.firstTime
                            ? "扩展脚本能读取你输入的所有内容。松烟已禁止脚本运行命令、加载外部程序和联网，但脚本引擎自身的漏洞仍可能被利用。只使用你信任来源的脚本。\n\n" + list
                            : list)
                }
            }
            .alert(
                "以下文件已改成你的版本，输入方案更新时这些文件不会跟着更新；其余文件照常更新。",
                isPresented: Binding(
                    get: { model.overrideNotice != nil }, set: { if !$0 { Task { await model.acknowledgeNotice() } } })
            ) {
                Button("知道了") { Task { await model.acknowledgeNotice() } }
            } message: {
                Text((model.overrideNotice ?? []).joined(separator: "\n"))
            }
    }
}

extension View {
    fileprivate func rimeConfigAlerts(_ model: RimeConfigModel) -> some View {
        modifier(RimeConfigAlerts(model: model))
    }
}

/// Where a file opens in the editor.
struct RimeEditRoute: Hashable {
    let packageID: String
    let path: String
    let title: String
    var grammarExample = false
}

/// The Rime config rows of the input scheme screen. They are sections of the list they sit in, so
/// everything that presents something (alerts, the editor) is on the list through `rimeConfigHost`.
struct RimeConfigRows: View {
    @ObservedObject var model: RimeConfigModel
    @ObservedObject private var center = SchemeImportCenter.shared

    var body: some View {
        Section {
            Button("应用更改") { Task { await model.apply() } }
                .disabled(center.busy || model.applying || model.restoring)
            if model.applying { ProgressView("正在应用…") }
            if let result = model.result {
                Text(result).font(.footnote).foregroundStyle(.secondary)
            }
            if let overview = model.overview, !overview.unusedScripts.isEmpty {
                Text("你的扩展脚本还没有使用。点「应用更改」并确认后才会使用。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let packageID = model.packageID {
                NavigationLink("修改输入方式") { RimeInputMethodListView(packageID: packageID, model: model) }
                NavigationLink("方案文件") { RimePackageFilesView(packageID: packageID, model: model) }
                Button("新建扩展脚本") {
                    model.scriptName = ""
                    model.newScript = true
                }
            }
        } header: {
            Text("Rime 配置")
        } footer: {
            Text("用 xxx.custom.yaml 等文件修改输入方案，和电脑上的 Rime 一样。文件在「文件」App 的「我的 iPhone › 松烟 › Rime 配置」里，改完轻点「应用更改」才会生效。")
        }
        if let overview = model.overview, !overview.overrides.isEmpty {
            Section("改过的文件") {
                ForEach(overview.overrides, id: \.path) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.path).font(.body.monospaced())
                            if entry.updated {
                                Text("\(entry.path) 有新版本，你改过的版本仍在使用")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("恢复原样") { model.restoringPath = entry.path }
                            .disabled(model.restoring || model.applying || center.busy)
                            .font(.footnote).buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

private struct RimeConfigHost: ViewModifier {
    @ObservedObject var model: RimeConfigModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task {
                await Task.detached {
                    try? FileManager.default.createDirectory(
                        at: HostStorePaths.rimeConfig, withIntermediateDirectories: true)
                }.value
                await model.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.refresh() } }
            }
            .rimeConfigAlerts(model)
            .confirmationDialog(
                "恢复「\(model.restoringPath ?? "")」？",
                isPresented: Binding(
                    get: { model.restoringPath != nil }, set: { if !$0 { model.restoringPath = nil } }),
                titleVisibility: .visible
            ) {
                if let path = model.restoringPath {
                    Button("恢复原样", role: .destructive) {
                        model.restoringPath = nil
                        Task { await model.restore(path) }
                    }
                }
                Button("取消", role: .cancel) { model.restoringPath = nil }
            } message: {
                Text("你对这个文件的修改会删除。")
            }
            .alert("新建扩展脚本", isPresented: $model.newScript) {
                TextField("名字", text: $model.scriptName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("新建") { Task { await model.createScript() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只能用小写字母、数字和下划线。")
            }
            .navigationDestination(item: $model.editing) { route in
                RimeFileEditorView(route: route, model: model)
            }
    }
}

extension View {
    func rimeConfigHost(_ model: RimeConfigModel) -> some View { modifier(RimeConfigHost(model: model)) }
}

/// 「修改输入方式」: pick an input method of the scheme in use (or the settings they share) to edit.
struct RimeInputMethodListView: View {
    let packageID: String
    @ObservedObject var model: RimeConfigModel
    @ObservedObject private var center = SchemeImportCenter.shared

    private var schemas: [KeyboardSchemaDescriptor] {
        center.installedPackages.first { $0.id == packageID }?.schemas ?? []
    }

    var body: some View {
        List {
            NavigationLink("全局设置") {
                RimeFileEditorView(
                    route: RimeEditRoute(packageID: packageID, path: RimeConfigEditor.globalPath, title: "全局设置"),
                    model: model)
            }
            ForEach(schemas, id: \.id) { schema in
                if let path = RimeConfigEditor.customPath(inputMethod: schema.id) {
                    NavigationLink(UserTerminology.inputMethodName(schema)) {
                        RimeFileEditorView(
                            route: RimeEditRoute(
                                packageID: packageID, path: path, title: UserTerminology.inputMethodName(schema)),
                            model: model)
                    }
                }
            }
        }
        .navigationTitle("修改输入方式")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A read-only look at the files of the scheme in use, each with a 「修改」 that makes the user's copy and opens it.
struct RimePackageFilesView: View {
    let packageID: String
    @ObservedObject var model: RimeConfigModel
    @ObservedObject private var center = SchemeImportCenter.shared
    @State private var paths: [String]?

    var body: some View {
        List {
            if let paths {
                ForEach(paths, id: \.self) { path in
                    NavigationLink(path) { RimePackageFileView(packageID: packageID, path: path, model: model) }
                        .font(.body.monospaced())
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("方案文件")
        .navigationBarTitleDisplayMode(.inline)
        .task { paths = (try? await center.manager(packageID).rimeConfigPackageFiles()) ?? [] }
    }
}

private struct RimePackageFileView: View {
    let packageID: String
    let path: String
    @ObservedObject var model: RimeConfigModel
    @ObservedObject private var center = SchemeImportCenter.shared
    @State private var text: String?
    @State private var loaded = false
    @State private var editing: RimeEditRoute?

    var body: some View {
        ScrollView {
            Text(text ?? (loaded ? "文件太大，不能在这里查看。" : ""))
                .font(.footnote.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("修改") { editing = RimeEditRoute(packageID: packageID, path: path, title: path) }
        }
        .navigationDestination(item: $editing) { RimeFileEditorView(route: $0, model: model) }
        .task {
            text = try? await center.manager(packageID).rimeConfigPackageText(path)
            loaded = true
        }
    }
}

@MainActor
final class RimeFileEditorModel: ObservableObject {
    enum Failure: Equatable {
        case invalid(line: Int?)
        case message(String)
    }

    @Published var text = ""
    @Published private(set) var baseline = ""
    @Published private(set) var loading = true
    @Published private(set) var loadFailure: String?
    @Published private(set) var failure: Failure?
    @Published private(set) var saved = false
    @Published private(set) var saving = false
    /// Set with each refused save so the refusal is announced once; the inline line stays below the text.
    @Published var failureAlert = false
    private let manager: RecipePackageManager
    let route: RimeEditRoute

    init(route: RimeEditRoute) {
        self.route = route
        manager = SchemeImportCenter.shared.manager(route.packageID)
    }

    var dirty: Bool { text != baseline }
    var hasScripts: Bool { RimeConfigEditor.hasScripts(path: route.path, text: text) }

    func load() async {
        do {
            let file = try await manager.openRimeConfigFile(route.path, grammarExample: route.grammarExample)
            text = file.text
            baseline = file.text
        } catch {
            loadFailure = (error as? LocalizedError)?.errorDescription ?? "没能打开这个文件。"
        }
        loading = false
    }

    func edited() {
        failure = nil
        saved = false
    }

    func save() async {
        guard dirty, !saving else { return }
        let snapshot = text
        saving = true
        saved = false
        failure = nil
        defer {
            saving = false
            failureAlert = failure != nil
        }
        do {
            switch try await manager.saveRimeConfigFile(route.path, text: snapshot) {
            case .saved:
                baseline = snapshot
                saved = text == snapshot
            case .invalid(let line): failure = .invalid(line: line)
            case .refused(let message): failure = .message(message)
            }
        } catch {
            failure = .message((error as? LocalizedError)?.errorDescription ?? "没能保存这个文件。")
        }
    }
}

/// The in-app editor for one file of the user's. Saving checks the file and refuses it with the line when it
/// is not valid; leaving with unsaved edits asks first; after a save, 「应用更改」 is one tap away.
struct RimeFileEditorView: View {
    @StateObject private var editor: RimeFileEditorModel
    @ObservedObject var model: RimeConfigModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false
    @State private var toast: String?

    init(route: RimeEditRoute, model: RimeConfigModel) {
        _editor = StateObject(wrappedValue: RimeFileEditorModel(route: route))
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            if editor.hasScripts {
                Label("这个文件带有扩展脚本。扩展脚本能读取你输入的内容，只在你信任来源时使用。", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.15))
            }
            if editor.loading {
                ProgressView().frame(maxHeight: .infinity)
            } else if let failure = editor.loadFailure {
                Text(failure).foregroundStyle(.secondary).padding().frame(maxHeight: .infinity)
            } else {
                TextEditor(text: $editor.text)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 6)
                    .onChange(of: editor.text) { _, _ in editor.edited() }
                    .accessibilityIdentifier("rime-file-editor.text")
                status
            }
        }
        .navigationTitle(editor.route.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    if editor.dirty { confirmDiscard = true } else { dismiss() }
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel("返回")
                .disabled(editor.saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await editor.save() } }
                    .disabled(!editor.dirty || editor.loading || editor.saving || editor.loadFailure != nil)
            }
        }
        .confirmationDialog("放弃修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃", role: .destructive) { dismiss() }
            Button("继续修改", role: .cancel) {}
        } message: {
            Text("你改的内容还没有保存。")
        }
        .interactiveDismissDisabled(editor.dirty || editor.saving)
        .rimeConfigAlerts(model)
        .onChange(of: editor.saved) { _, saved in if saved { toast = "已保存" } }
        .alert("没有保存", isPresented: $editor.failureAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(failureText ?? "")
        }
        .savedToast($toast)
        .task { await editor.load() }
    }

    private var failureText: String? {
        switch editor.failure {
        case .invalid(let line?): return "第 \(line) 行格式有误，没有保存。"
        case .invalid(nil): return "格式有误，没有保存。"
        case .message(let text): return text
        case nil: return nil
        }
    }

    @ViewBuilder
    private var status: some View {
        if editor.saving {
            ProgressView("正在保存…").padding(10)
        } else if let text = failureText {
            Text(text)
                .font(.footnote).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        } else if editor.saved {
            HStack {
                Text("已保存。应用更改后生效。").font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("应用更改") { Task { await model.apply() } }
                    .font(.footnote).disabled(model.applying)
            }
            .padding(10)
            if let result = model.result {
                Text(result).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
    }
}
