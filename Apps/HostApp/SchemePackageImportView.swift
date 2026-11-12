import Foundation
import KeyboardCore
import PackageManager
import SwiftUI
import UniformTypeIdentifiers

/// Import scheme: file and URL entry points that feed the same install flow once recognized.
///
/// - The entry state shows only "import from file" / "import from URL"; the parameter,
///   plan, prepare and install sections are hidden until a source exists.
/// - The recognition result shows name / contained schemes / source / size; the pre-install
///   list is "recognized", not marked as verified. Optional configuration links to the companion configuration page.
/// - Install/update never applies automatically; success returns to the "Installed" list for explicit apply.
/// - Advanced parameters and diagnostics are collapsed; the main action shows no recipe/workspace/package-ID details.
struct SchemePackageImportView: View {
    @ObservedObject var center = SchemeImportCenter.shared
    /// Rime source / raw schema IDs are shown only under developer options.
    @AppStorage(HostAppKeys.developerOptionsEnabled) var developerOptions = false
    /// Opens for recipe configuration against one source (nil = new import).
    var installedPackageID: String?
    var initialSourceURL: URL?
    var downloadedSource: SchemeURLDownloadService.Result?
    @State private var initialized = false
    @ObservedObject private var downloadService = SchemeURLDownloadService.shared
    @State private var recognizedNames: [String: String] = [:]
    @StateObject private var switcher = InputSchemeSwitch()

    /// One use of fileImporter: pick a scheme package source, or supply a local file for a declared external resource.
    enum ImporterPurpose: Equatable {
        case packageSource
        case externalResource(requirementPath: String)
    }

    @State var showingImporter = false
    @State var importerPurpose: ImporterPurpose = .packageSource
    @State var selectedRecipePath: String?
    /// Generic stages (config, grammar, ...) appended after the root recipe, in order.
    /// Each step has a stable UUID identity (the same recipe may appear several times with independent parameters); array order is execution order.
    struct StageSlot: Identifiable, Equatable {
        let id: UUID
        var path: String
    }
    @State var stageSlots: [StageSlot] = []
    /// Parameter drafts per stage, keyed by stage UUID (independent of slot order, so delete/move does not mix drafts).
    @State var stageDrafts: [UUID: [Int: RecipeArgumentDraft]] = [:]
    /// Root recipe parameter drafts, keyed by declaration index (keeps ordered duplicate declarations).
    /// Three-state draft: enabled=false omits the parameter (`${name:-...}` uses the built-in default);
    /// enabled=true with an empty value is an explicit empty `name=`; enabled=true with a value is `name=value`.
    @State var argumentDrafts: [Int: RecipeArgumentDraft] = [:]
    /// Ordered extra name=value rows. Each row has its own three-state draft, allowing unknown and duplicate names;
    /// path, order and value all feed the plan fingerprint.
    @State var extraRootArguments: [Int: ExtraArgumentDraft] = [:]
    @State var extraStageArguments: [UUID: [Int: ExtraArgumentDraft]] = [:]

    /// Extra parameter row drafts (free-form name=value, not limited to declared parameters). Empty or invalid names are dropped on collection with a notice.
    struct ExtraArgumentDraft: Equatable {
        var enabled = true
        var name = ""
        var value = ""
    }

    /// Three-state input for one declared parameter; matches the collection rules one to one, so an empty text field never stands for omission.
    struct RecipeArgumentDraft {
        var enabled = false
        var value = ""
    }

    var isInstalledMode: Bool { installedPackageID != nil }

    var selectedRecipe: SchemeImportCenter.DiscoveredRecipe? {
        selectedRecipePath.flatMap { path in center.recipes.first(where: { $0.path == path }) }
    }

    /// Root recipe and all selected follow-up stages, in the user's order.
    private var orderedRecipes: [SchemeImportCenter.DiscoveredRecipe] {
        var result: [SchemeImportCenter.DiscoveredRecipe] = []
        if let selectedRecipe { result.append(selectedRecipe) }
        for slot in stageSlots {
            if let recipe = center.recipes.first(where: { $0.path == slot.path }) { result.append(recipe) }
        }
        return result
    }

    /// External resources declared by all selected recipes (including stages); the recipe-declared path is authoritative.
    var declaredResources: [RecipeExternalResource] {
        var seen = Set<String>()
        return orderedRecipes.flatMap(\.downloads).filter { seen.insert($0.path).inserted }
    }

    var body: some View {
        List {
            if let installedNotice = installedSuccessNotice {
                installedSection(installedNotice)
                PackageLearningOfferSection(center: center)
            } else if isInstalledMode {
                installedHeaderSection
            } else if center.prepared == nil {
                entrySection
            }
            if center.busy { progressSection }
            if let prepared = center.prepared, !isInstalledMode { recognizedSection(prepared) }
            // Recipe steps/parameters target scheme authors: a normal import installs directly; they show only when developer options are on or on the companion configuration page.
            if !center.recipes.isEmpty, isInstalledMode || developerOptions {
                configurationSection
            } else if !center.recipeDiscoveryErrors.isEmpty, isInstalledMode || developerOptions {
                Section(String(localized: "提示")) {
                    ForEach(Array(center.plannedDiagnostics.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.footnote).textSelection(.enabled)
                    }
                    if developerOptions {
                        DisclosureGroup(String(localized: "开发者诊断")) {
                            ForEach(Array(center.recipeDiscoveryErrors.enumerated()), id: \.offset) { _, message in
                                Text(message).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
            } else if isInstalledMode, center.installedWorkspace != nil, !center.busy {
                Section {
                    if developerOptions,
                        let id = center.installedWorkspace?.packageID,
                        SchemeImportCenter.recordedSourceTarget(packageID: id) != nil
                    {
                        NavigationLink(String(localized: "从 Rime 来源配置 / 更新")) {
                            RimeSourceInstallView(updatingPackageID: id)
                        }
                    } else {
                        Text("当前输入方案没有可调整的选项。").foregroundStyle(.secondary)
                    }
                }
            }
            if !declaredResources.isEmpty { externalResourceSection }
            if let planned = center.plannedRecipe { planSection(planned) }
            if let error = center.error { errorSection(error) }
            // User-facing notices (next step after install/update, etc.): independent of busy and not hidden when developer options are off.
            if let notice = center.userNotice, center.error == nil {
                Section { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }
            if let message = center.message, !center.busy { messageSection(message) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isInstalledMode ? String(localized: "方案选项") : UserTerminology.addInputScheme)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !initialized else { return }
            initialized = true
            await center.refresh()
            if let installedPackageID {
                center.openInstalledWorkspace(packageID: installedPackageID)
            } else {
                center.beginSourceImport()
                if let downloadedSource {
                    center.accept(
                        downloadedSource.localFileURLs, sourceURL: downloadedSource.requestedURL,
                        recommendation: downloadedSource.recommendation,
                        onFinished: { withExtendedLifetime(downloadedSource) {} })
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                switch importerPurpose {
                case .packageSource:
                    center.accept([url])
                case .externalResource(let requirementPath):
                    center.provideExternalResource(url, requirementPath: requirementPath)
                }
            case .failure(let failure): center.report(failure)
            }
        }
        .onChange(of: center.prepared == nil) { _, isNil in
            if !isNil, let prepared = center.prepared {
                // A newly imported package is a new configuration context: clear local drafts so stages/parameters of the old package do not leak in.
                stageSlots = []
                stageDrafts = [:]
                extraStageArguments = [:]
                argumentDrafts = [:]
                extraRootArguments = [:]
                selectedRecipePath = nil
                center.discoverRecipes(in: prepared)
            }
        }
        .onChange(of: center.installedWorkspace == nil) { _, isNil in
            if !isNil {
                // A newly opened workspace is a new configuration context: clear local drafts.
                stageSlots = []
                stageDrafts = [:]
                extraStageArguments = [:]
                argumentDrafts = [:]
                extraRootArguments = [:]
                selectedRecipePath = nil
            }
        }
        // Changing the root selection, its parameters or the stages immediately invalidates the existing plan:
        // patches/entries in the old plan may come from another recipe or other inputs.
        .onChange(of: selectedRecipePath) { _, path in
            center.invalidatePlannedRecipeForRootChange()
            if isInstalledMode {
                restoreArguments(path: path, into: nil)
            }
        }
        .onChange(of: rootArguments()) { _, _ in center.invalidatePlannedRecipeForRootChange() }
        .onChange(of: stageArguments()) { _, _ in center.invalidatePlannedRecipeForRootChange() }
    }

    private var allowedContentTypes: [UTType] {
        switch importerPurpose {
        case .packageSource: return [.zip, .folder, .yaml]
        case .externalResource(let path): return [importerType(for: path)]
        }
    }

    /// External resources match the declared path's extension exactly; without an extension they are treated as data files.
    private func importerType(for path: String) -> UTType {
        let ext = (path as NSString).pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), !ext.isEmpty { return type }
        return .data
    }

    // MARK: - Installed package mode

    private var installedHeaderSection: some View {
        Section {
            if let workspace = center.installedWorkspace {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.displayName).font(.headline)
                    if developerOptions {
                        Text("版本 \(String(workspace.revision.prefix(7)))…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup(String(localized: "详细信息")) {
                    // Raw schema IDs show only under developer options; the normal flow shows only the count.
                    if developerOptions {
                        LabeledRow(
                            label: String(localized: "输入方式标识"),
                            value: workspace.schemaIDs.joined(separator: "、"))
                    } else {
                        LabeledRow(
                            label: String(localized: "输入方式"),
                            value: String(localized: "\(workspace.schemaIDs.count) 种"))
                    }
                    if !workspace.snapshot.fileResources.isEmpty {
                        if developerOptions {
                            LabeledRow(
                                label: String(localized: "模型文件"),
                                value: workspace.snapshot.fileResources.keys.joined(separator: "、"))
                        } else {
                            let grams = workspace.snapshot.fileResources.keys.filter { $0.hasSuffix(".gram") }.count
                            if grams > 0 {
                                LabeledRow(
                                    label: String(localized: "语法模型"),
                                    value: String(localized: "\(grams) 个"))
                            }
                            if workspace.snapshot.fileResources.keys.contains(where: Prediction.isDatabasePath) {
                                LabeledRow(
                                    label: String(localized: "联想词库"),
                                    value: String(localized: "已安装"))
                            }
                        }
                    }
                }
            } else if center.busy {
                Text("正在读取…").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("当前安装")
        }
    }

    // MARK: - Install success (installed, not applied; view schemes in detail)

    /// Shown after an install (as-is or configured) finishes while still on this page: success state plus a detail entry;
    /// it does not pop back to the main list or mark the new item as the current selection.
    private var installedSuccessNotice: String? {
        guard !center.busy, center.error == nil, center.lastInstalledPackageID != nil else { return nil }
        return isInstalledMode || center.lastInstallReplacedVersion
            ? String(localized: "更新完成") : String(localized: "安装完成")
    }

    private func installedSection(_ notice: String) -> some View {
        Section {
            Label(notice, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let packageID = center.lastInstalledPackageID {
                if switcher.phase == .done(packageID) {
                    Text(UserTerminology.statusInUse).foregroundStyle(.green)
                    NavigationLink(UserTerminology.userKeyboard) {
                        UserKeyboardManagementView(source: .active)
                    }
                } else {
                    UseInputSchemeRows(
                        switcher: switcher, packageID: packageID, title: String(localized: "开始使用"),
                        disabled: center.busy)
                    Text("轻点「开始使用」，键盘会换成这个输入方案。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                NavigationLink(String(localized: "查看方案详情")) {
                    SchemePackageDetailView(packageID: packageID)
                }
            } else {
                NavigationLink(String(localized: "查看方案")) {
                    SchemeDetailRouter()
                }
            }
        }
    }

    /// Fallback without a concrete package ID: open the scheme list and let the user choose.
    private struct SchemeDetailRouter: View {
        var body: some View {
            InputSchemeListView()
        }
    }

    // MARK: - Entry state: import from file / URL

    @ViewBuilder
    private var entrySection: some View {
        RecommendedInputMethodsView(center: center)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        Section {
            Button {
                importerPurpose = .packageSource
                showingImporter = true
            } label: {
                Label(String(localized: "从文件导入"), systemImage: "folder.badge.plus")
            }
            .disabled(center.busy || downloadService.isDownloading)
            NavigationLink {
                SchemeURLImportView(initialURL: initialSourceURL)
            } label: {
                Label(String(localized: "从链接导入"), systemImage: "link.badge.plus")
            }
            .disabled(center.busy || downloadService.isDownloading)
            if developerOptions {
                // A rime-install source expression (owner/repo@branch) is not a normal product path.
                NavigationLink {
                    RimeSourceInstallView(updatingPackageID: nil)
                } label: {
                    Label(String(localized: "从 Rime 来源安装"), systemImage: "shippingbox")
                }
                .disabled(center.busy || downloadService.isDownloading)
            }
        } footer: {
            Text("文件支持 ZIP、文件夹或方案文件；链接支持 ZIP 下载地址或 GitHub 仓库地址。")
        }
    }

    // MARK: - In progress

    private var progressSection: some View {
        Section {
            ProgressView {
                Text(center.message ?? "正在处理…")
            }
            if center.preparingExternalResource {
                Button {
                    guard center.preparingExternalResource, !showingImporter else { return }
                    center.cancelSourceOperation()
                } label: {
                    Text("取消")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("scheme-model-cancel")
                .disabled(showingImporter)
            }
            // Normal notices use plain language only (no IDs/paths); raw diagnostics show only under developer options.
            // (Normal notices render in a top-level block of body, independent of busy.)
            if developerOptions, !center.diagnostics.isEmpty {
                ForEach(center.diagnostics, id: \.self) { line in
                    Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } header: {
            Text("正在处理")
        }
    }

    // MARK: - Recognition result (recognized is not verified; fixed fields)

    private func recognizedSection(_ prepared: PreparedSchemeImport) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                // Raw declaration/id show only under developer options; the normal flow shows a human-readable name or nothing.
                Text(
                    developerOptions
                        ? (prepared.declaration.name.isEmpty ? prepared.declaration.id : prepared.declaration.name)
                        : (prepared.declaration.name.isEmpty ? UserTerminology.inputScheme : prepared.declaration.name)
                )
                .font(.headline)
                Text("包含 \(prepared.offeredSchemaIDs.count) 种输入方式")
                    .font(.caption).foregroundStyle(.secondary)
                if let replaced = center.preparedReplacedPackageName {
                    Text("将更新已安装的「\(replaced)」，原来的设置和输入习惯会保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            recognizedInputMethods(Array(prepared.offeredSchemaIDs.prefix(5)))
            if prepared.offeredSchemaIDs.count > 5 {
                DisclosureGroup(String(localized: "其余 \(prepared.offeredSchemaIDs.count - 5) 种输入方式")) {
                    recognizedInputMethods(Array(prepared.offeredSchemaIDs.dropFirst(5)))
                }
            }
            if developerOptions {
                DisclosureGroup(String(localized: "输入方式标识")) {
                    ForEach(prepared.schemaIDs, id: \.self) { id in
                        LabeledRow(
                            label: recognizedNames[id] ?? String(localized: "未命名输入方式"), value: id)
                    }
                }
            }
            LabeledRow(label: String(localized: "来自"), value: sourceSummary)
            LabeledRow(
                label: String(localized: "大小"),
                value: HostStorePaths.fileSizeText(prepared.resourceBytes))
            ForEach(Array(prepared.requiredModelPaths.enumerated()), id: \.element) { index, path in
                VStack(alignment: .leading, spacing: 8) {
                    Text(developerOptions ? "语法模型：\(path)" : "语法模型 \(index + 1)")
                        .font(.subheadline)
                    if let model = center.providedDownloadFiles[path] ?? prepared.fileResources[path] {
                        Text("已准备 \(HostStorePaths.fileSizeText(model.size))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("需要这个语法模型才能使用，请先下载或导入。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let url = SchemeGrammarRequirements.suggestedURL(for: path) {
                        if developerOptions {
                            Text(url.absoluteString).font(.caption2).textSelection(.enabled)
                        }
                        Button {
                            // Set by the picker action synchronously, before its
                            // sheet is presented. Never start a download behind it.
                            guard !center.busy, !showingImporter else { return }
                            center.downloadExternalResource(RecipeExternalResource(path: path, url: url))
                        } label: {
                            Text("下载模型（约 420 MB）")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        // Automatic List row actions invoke sibling buttons in
                        // this VStack. Each action must own its own hit region.
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("scheme-model-download-\(index + 1)")
                    }
                    Button {
                        guard !center.busy, !showingImporter else { return }
                        importerPurpose = .externalResource(requirementPath: path)
                        showingImporter = true
                    } label: {
                        Text("从文件导入模型")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("scheme-model-import-\(index + 1)")
                }.disabled(center.busy || showingImporter)
            }
            Button {
                center.install()
            } label: {
                Text(center.preparedUpdatesInstalledPackage ? String(localized: "更新") : String(localized: "安装"))
            }
            .disabled(
                center.busy || showingImporter
                    || prepared.requiredModelPaths.contains {
                        prepared.fileResources[$0] == nil && center.providedDownloadFiles[$0] == nil
                    })
        } header: {
            Text("方案信息")
        } footer: {
            if center.preparedUpdatesInstalledPackage { Text("更新后轻点「开始使用」，键盘会换用新版本。") }
        }
        .task(id: prepared.manifest.revision) {
            let names = await Task.detached(priority: .userInitiated) { prepared.schemaNames }.value
            guard !Task.isCancelled else { return }
            recognizedNames = names
        }
    }

    private func recognizedInputMethods(_ ids: [String]) -> some View {
        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
            Text(recognizedNames[id] ?? "未命名输入方式 \(index + 1)")
        }
    }

    /// Source: host for URL import, file name for file import.
    private var sourceSummary: String {
        if let sourceURL = center.preparedSourceURL {
            return sourceURL.host ?? String(localized: "下载链接")
        }
        return String(localized: "本机文件")
    }

    // MARK: - Check result and install (affected/missing items, required blocks; raw plan collapsed)

    private func planSection(_ planned: SchemeImportCenter.PlannedRecipeInstall) -> some View {
        Section {
            if !planned.summary.isEmpty {
                ForEach(planned.summary, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if !planned.changedPaths.isEmpty {
                if developerOptions {
                    DisclosureGroup(String(localized: "将修改 \(planned.changedPaths.count) 个文件")) {
                        ForEach(planned.changedPaths, id: \.self) { path in
                            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if developerOptions {
                DisclosureGroup(String(localized: "开发者详情")) {
                    LabeledRow(label: String(localized: "配置"), value: planned.recipePath)
                    LabeledRow(label: String(localized: "参数"), value: planned.rx)
                }
            }
            Button {
                // The current drafts are passed along so a failed install can be replayed from the same inputs.
                if isInstalledMode {
                    center.installPlannedRecipeOnInstalled(
                        currentRecipePath: selectedRecipePath ?? "",
                        currentArguments: rootArguments(),
                        currentStages: stageArguments())
                } else {
                    center.installPlannedRecipe(
                        currentRecipePath: selectedRecipePath ?? "",
                        currentArguments: rootArguments(),
                        currentStages: stageArguments())
                }
            } label: {
                Text(isInstalledMode ? String(localized: "更新") : String(localized: "安装"))
            }
            .disabled(center.busy || !planned.isDeployable)
        } header: {
            Text("检查结果")
        } footer: {
            if isInstalledMode { Text("更新后轻点「开始使用」，键盘会换用新版本。") }
        }
    }

    // MARK: - Nearby errors and notices

    private func errorSection(_ error: String) -> some View {
        // The status text must come from real transaction semantics (`center.failureState`); never claim "unchanged" across the board.
        // Unclassified failures show a neutral "cannot confirm" and ask the user to reload.
        let state = center.failureState ?? .unknown
        return Section {
            VStack(alignment: .leading, spacing: 4) {
                Label(String(localized: "操作未完成"), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.subheadline.bold())
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(state.stateLine)
                    .font(.caption).foregroundStyle(.secondary)
                if let nextStep = state.nextStep {
                    Text(nextStep).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(
                center.retryDecision == .requestInput
                    ? (installedPackageID != nil
                        ? String(localized: "重新载入") : String(localized: "重新选择文件"))
                    : String(localized: "重试")
            ) {
                // Retry on the failure page must replay the same selected file/scheme: first consume the same operation captured by the import center.
                // Only when there is truly nothing to replay does it fall back to an action explicitly labeled "reselect/load";
                // a button named "retry" must never reopen fileImporter.
                if center.retryLastOperation() { return }
                if let installedPackageID {
                    center.openInstalledWorkspace(packageID: installedPackageID)
                } else {
                    importerPurpose = .packageSource
                    showingImporter = true
                }
            }.disabled(center.busy)
            // When the install content is saved but the keyboard is unchanged, offer an explicit apply entry so users do not think they must reinstall.
            if state == .installedNotApplied, let packageID = center.lastInstalledPackageID {
                NavigationLink(String(localized: "打开已安装方案")) {
                    SchemePackageDetailView(packageID: packageID)
                }
            }
        } header: {
            Text("错误")
        }
    }

    private func messageSection(_ message: String) -> some View {
        Section {
            Text(message).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct RecommendedInputMethodsView: View {
    @ObservedObject var center = SchemeImportCenter.shared
    var onDownloaded: ((SchemeURLDownloadService.Result) -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var downloadService = SchemeURLDownloadService.shared
    @State private var showingOtherSchemes = false
    @State private var downloadingSourceID: String?
    @State private var pendingSource: RecommendedSchemeSource?

    var body: some View {
        let sources = RecommendedSchemeSource.ordered(preferredLanguages: Locale.preferredLanguages)
        VStack(alignment: .leading, spacing: 12) {
            Text("选择一个开始").font(.subheadline).foregroundStyle(.secondary)
            if let featured = sources.first {
                VStack(alignment: .leading, spacing: 12) {
                    Text("推荐").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    recommendationSummary(featured)
                    recommendationAction(featured, prominent: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("schemes.featured.\(featured.id)")
                DisclosureGroup(isExpanded: $showingOtherSchemes) {
                    VStack(spacing: 12) {
                        ForEach(Array(sources.dropFirst())) { source in
                            Divider()
                            let layout =
                                dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                            layout {
                                recommendationSummary(source)
                                recommendationAction(source, prominent: false)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Text("更多输入方式（\(sources.count - 1)）")
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("schemes.more")
            }
        }
        .onDisappear { if downloadingSourceID != nil { downloadService.cancel() } }
        .sheet(item: $pendingSource) { source in
            NavigationStack {
                Form {
                    Section {
                        Text(source.name).font(.headline)
                        Text(source.detail).foregroundStyle(.secondary)
                        Text(
                            "\(ByteCountFormatter.string(fromByteCount: source.byteCountHint, countStyle: .file)) · \(licenseNames(source))"
                        )
                        .font(.footnote).foregroundStyle(.secondary)
                        Link(String(localized: "查看项目主页"), destination: source.homepage)
                    }
                    Section {
                        Button(String(localized: "下载")) {
                            pendingSource = nil
                            startDownload(source)
                        }
                        .accessibilityIdentifier("schemes.confirmDownload")
                    }
                }
                .navigationTitle(String(localized: "下载「\(source.name)」？"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "取消")) { pendingSource = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func licenseNames(_ source: RecommendedSchemeSource) -> String {
        var seen = Set<String>()
        return source.archives.flatMap(\.licenses).map(\.name).filter { seen.insert($0).inserted }.joined(
            separator: ", ")
    }

    private func startDownload(_ source: RecommendedSchemeSource) {
        downloadingSourceID = source.id
        Task {
            guard let result = try? await downloadService.download(address: source.url.absoluteString) else { return }
            if let onDownloaded {
                onDownloaded(result)
            } else {
                center.accept(
                    result.localFileURLs, sourceURL: result.requestedURL, recommendation: result.recommendation,
                    onFinished: { withExtendedLifetime(result) {} })
            }
        }
    }

    private func recommendationSummary(_ source: RecommendedSchemeSource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "character.book.closed")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name).font(.headline)
                Text(source.detail).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                Text(
                    "\(ByteCountFormatter.string(fromByteCount: source.byteCountHint, countStyle: .file)) · \(licenseNames(source))"
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func recommendationAction(_ source: RecommendedSchemeSource, prominent: Bool) -> some View {
        if downloadingSourceID == source.id, downloadService.isDownloading {
            VStack(alignment: .leading, spacing: 8) {
                if let progress = downloadService.progress, let total = progress.totalBytes, total > 0 {
                    ProgressView(value: Double(min(progress.downloadedBytes, total)), total: Double(total))
                    Text(
                        "\(HostStorePaths.fileSizeText(progress.downloadedBytes)) / \(HostStorePaths.fileSizeText(total))"
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ProgressView(String(localized: "正在下载…"))
                    if let progress = downloadService.progress, progress.downloadedBytes > 0 {
                        Text("已下载 \(HostStorePaths.fileSizeText(progress.downloadedBytes))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button(String(localized: "取消")) { downloadService.cancel() }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("schemes.cancel.\(source.id)")
            }
            .accessibilityIdentifier("schemes.progress.\(source.id)")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if downloadingSourceID == source.id, let failure = downloadService.lastError {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                }
                if prominent {
                    downloadButton(source)
                        .buttonStyle(.borderedProminent)
                } else {
                    downloadButton(source)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func downloadButton(_ source: RecommendedSchemeSource) -> some View {
        Button {
            pendingSource = source
        } label: {
            Text("下载")
                .frame(minHeight: 32)
        }
        .disabled(center.busy || downloadService.isDownloading)
        .accessibilityLabel(String(localized: "下载\(source.name)"))
        .accessibilityIdentifier("schemes.download.\(source.id)")
    }

}
