import AppearanceKit
import CandidateKit
import KeyboardCore
import SkinKit
import SwiftUI

/// Serial background queue for host-side appearance/layout configuration I/O.
///
/// Separate from `KeyboardResourceReadQueue` (low-priority reads): this queue runs operations that may create
/// directories, write files atomically and read them back (appearance/layout persistence), in order.
/// The main thread only awaits results and never touches disk.
///
/// Shared by `AppearanceManager` and `LayoutManager`.
enum HostConfigIOQueue {
    private static let serial = SerialIOQueue(label: "app.songyan.host.config.io", qos: .utility)

    /// Runs configuration I/O on the serial background queue without blocking the caller.
    static func async<T>(_ body: @escaping @Sendable () throws -> T) async throws -> sending T {
        try await serial.async(body)
    }
}

/// Unified appearance-item manager (the host app's only writer).
///
/// Replaces the separate `SkinManager` and `CandidateBarManager` selections:
/// the user works with one appearance item = keyboard skin + candidate-area layout behavior + display mode,
/// and save/apply/import/export all act on that single identity, so two selections cannot drift apart.
///
/// Storage layers:
///   - local draft store: `KeyboardAppearanceDrafts/` (editing and saving; works without the shared container);
///   - shared snapshot: `KeyboardAppearance/active.json` (the only source the keyboard extension reads).
///
/// Threading and disk discipline:
///   - init does no disk I/O: state starts from built-in defaults, and reads run on
///     `HostConfigIOQueue` while the main thread only applies results;
///   - reads use a latest-wins gate plus a cancellation gate: a late read never overwrites a newer read or a
///     completed save/apply (user actions invalidate in-flight reads first);
///   - saves, deletes and applies finish on the same background queue before their results update the UI.
@MainActor final class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()

    /// Local draft store (including read-only built-in defaults).
    @Published private(set) var projects: [AppearanceDocument] = [.systemDefault]
    @Published private(set) var unreadable: [UnreadableAppearance] = []
    @Published private(set) var isMutating = false
    /// The currently applied appearance (the one in the shared snapshot).
    @Published private(set) var applied: AppearanceDocument = .systemDefault
    /// Where the applied snapshot came from (applied snapshot / built-in default).
    @Published private(set) var appliedSource: AppearanceSnapshotSource = .systemDefault
    /// Display mode committed together with apply.
    @Published var editingAppearance: SkinAppearance = .system
    @Published var message: String?
    /// Explicit error (read/write failure reason).
    @Published var error: String?
    /// Whether the first (or latest) background read is still running; avoids showing "not read yet" as a false
    /// "appearance not found" conclusion.
    @Published private(set) var isLoading = true
    /// The local placeholder default is not the keyboard's applied state; "in use" is shown only once a shared read confirms it.
    @Published private(set) var sharedReadConfirmed = false

    /// Latest-wins gate for background reads: a late read must not overwrite a newer read or a completed user action.
    private var loadGate = LatestWinsReadGate()
    /// In-flight read task; `reload()` and user actions cancel it (only the result is dropped, not the underlying I/O).
    private var loadTask: Task<Void, Never>?

    /// Init does not touch disk: starts from the built-in defaults, then reads on the background queue.
    init() {
        reload()
    }

    /// Re-reads the snapshot and drafts on `HostConfigIOQueue`; returns immediately.
    ///
    /// `message` carries only operation results; the notice for an appearance from a degraded
    /// source comes from `appliedSourceNotice`, to avoid duplication.
    func reload() {
        guard !isMutating else { return }
        message = nil
        error = nil
        isLoading = true
        let token = loadGate.begin()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result = await Self.readState()
            // Cancellation gate + latest-wins gate: UI state is overwritten only if both pass.
            guard let self,
                StructuredRefreshOutcome.shouldApply(
                    isCancelled: Task.isCancelled,
                    accepted: self.loadGate.accepts(token))
            else { return }
            self.applyLoadedState(result)
        }
    }

    /// Background read (Sendable values in and out; the closure captures no MainActor objects).
    private nonisolated static func readState() async -> AppearanceLoadResult {
        do {
            return try await HostConfigIOQueue.async {
                var result = AppearanceLoadResult()
                let local = RimePaths.localAppearanceStore()

                if let shared = RimePaths.sharedAppearanceStore() {
                    let read = shared.read()
                    result.applied = read.snapshot.document
                    result.appliedSource = read.source
                    result.sharedReadConfirmed = read.error == nil
                    result.editingAppearance = read.snapshot.document.appearance
                    result.error = read.error
                } else {
                    let sharedError = "键盘暂时无法读取外观，外观仍保留在本机。"
                    result.error = result.error.map { $0 + "\n" + sharedError } ?? sharedError
                }

                do {
                    let catalog = try local.catalog()
                    result.projects = catalog.documents
                    result.unreadable = catalog.unreadable
                } catch {
                    result.projects = [.systemDefault]
                    if result.error == nil { result.error = "无法读取外观。" }
                }
                return result
            }
        } catch {
            // The queue only throws if this closure throws; read paths already convert failures to `error`, so this is purely defensive.
            var result = AppearanceLoadResult()
            result.error = "无法读取外观。"
            return result
        }
    }

    /// Applies the background result on the main thread.
    private func applyLoadedState(_ result: AppearanceLoadResult) {
        projects = result.projects
        unreadable = result.unreadable
        applied = result.applied
        appliedSource = result.appliedSource
        sharedReadConfirmed = result.sharedReadConfirmed
        editingAppearance = result.editingAppearance
        error = result.error
        isLoading = false
    }

    private func beginMutation() throws {
        guard !isMutating else { throw AppearanceApplyFailure(text: "另一项操作正在进行，请稍后再试。") }
        loadGate.invalidate()
        loadTask?.cancel()
        isLoading = false
        isMutating = true
        message = nil
        error = nil
    }

    private func updateCatalog(_ catalog: AppearanceCatalog) {
        projects = catalog.documents
        unreadable = catalog.unreadable
    }

    func save(_ document: AppearanceDocument, replacing: Bool) async throws {
        try beginMutation()
        defer { isMutating = false }
        let catalog = try await HostConfigIOQueue.async {
            let store = RimePaths.localAppearanceStore()
            try store.save(document, replacing: replacing)
            return try store.catalog()
        }
        updateCatalog(catalog)
    }

    @discardableResult
    func remove(_ id: String) async -> Bool {
        do {
            try beginMutation()
            defer { isMutating = false }
            let catalog = try await HostConfigIOQueue.async {
                let store = RimePaths.localAppearanceStore()
                try store.remove(id)
                return try store.catalog()
            }
            updateCatalog(catalog)
            return true
        } catch {
            self.error = "外观没有删除，请重试。"
            return false
        }
    }

    /// Display mode is captured with the document; a failed apply keeps the previous UI selection.
    @discardableResult
    func apply(_ document: AppearanceDocument, persistDraft: Bool = true, appearance: SkinAppearance? = nil) async
        -> Bool
    {
        var target = document
        target.appearance = appearance ?? editingAppearance
        let snapshot = target
        do {
            try beginMutation()
            defer { isMutating = false }
            let catalog = try await HostConfigIOQueue.async {
                let local = RimePaths.localAppearanceStore()
                guard let shared = RimePaths.sharedAppearanceStore() else {
                    throw AppearanceApplyFailure(text: "键盘暂时无法读取外观，请稍后重试。")
                }
                if !snapshot.isSystemDefault {
                    if persistDraft, !snapshot.isBuiltin { try local.save(snapshot, replacing: true) }
                    try shared.save(snapshot, replacing: true)
                }
                let catalog = try local.catalog()
                try shared.apply(snapshot)
                return catalog
            }
            applied = snapshot.normalized()
            appliedSource = .applied
            sharedReadConfirmed = true
            editingAppearance = applied.appearance
            updateCatalog(catalog)
            message = "已应用，下次打开键盘时生效。"
            NotificationCenter.default.post(name: .keyboardAppearanceChanged, object: nil)
            return true
        } catch {
            HostLog.append("appearance apply failed: \(error.localizedDescription)")
            self.error = (error as? AppearanceApplyFailure)?.text ?? "外观没有应用，请重试。"
            return false
        }
    }

    func recoveryDocument(for item: UnreadableAppearance) -> AppearanceDocument? {
        let id = String(item.fileName.dropLast(AppearanceDocument.fileExtension.count))
        if sharedReadConfirmed, applied.id == id { return applied }
        return ([AppearanceDocument.systemDefault] + AppearanceDocument.builtinPresets).first { $0.id == id }
    }

    func exportUnreadable(_ item: UnreadableAppearance) async throws -> Data {
        try await HostConfigIOQueue.async { try RimePaths.localAppearanceStore().readUnreadable(item) }
    }

    @discardableResult
    func removeUnreadable(_ item: UnreadableAppearance) async -> Bool {
        do {
            try beginMutation()
            defer { isMutating = false }
            let catalog = try await HostConfigIOQueue.async {
                let store = RimePaths.localAppearanceStore()
                try store.removeUnreadable(item)
                return try store.catalog()
            }
            updateCatalog(catalog)
            return true
        } catch {
            self.error = "文件没有删除，请重试。"
            return false
        }
    }

    func restoreUnreadable(_ item: UnreadableAppearance, from url: URL? = nil) async -> Bool {
        let recovery = recoveryDocument(for: item)
        do {
            try beginMutation()
            defer { isMutating = false }
            let catalog = try await HostConfigIOQueue.async {
                let store = RimePaths.localAppearanceStore()
                let document: AppearanceDocument
                if let url {
                    document = try AppearanceImportSupport.decode(documentAt: url)
                } else if let recovery {
                    document = recovery
                } else {
                    throw AppearanceApplyFailure(text: "请先选择要恢复的外观文件。")
                }
                guard document.id + AppearanceDocument.fileExtension == item.fileName else {
                    throw AppearanceApplyFailure(text: "这个文件属于另一个外观，请选择原来的外观文件。")
                }
                if document.isSystemDefault {
                    try store.removeUnreadable(item)
                } else {
                    try store.save(document, replacing: true)
                }
                return try store.catalog()
            }
            updateCatalog(catalog)
            message = "已恢复外观。"
            return true
        } catch {
            self.error = (error as? AppearanceApplyFailure)?.text ?? "外观没有恢复，请检查文件后重试。"
            return false
        }
    }

    /// "In use / has unapplied changes" check: compares both appearance content and display mode.
    func applicationStatus(for document: AppearanceDocument) -> String? {
        guard !isLoading, sharedReadConfirmed, document.id == applied.id else { return nil }
        return document.normalized() == applied.normalized() && editingAppearance == applied.appearance
            ? UserTerminology.statusInUse : "修改未应用"
    }

    /// Candidate-area layout summary for list rows (layout parameters belong to the item).
    func candidateSummary(for document: AppearanceDocument) -> String {
        CandidateAreaSummary.text(for: document.candidateBar)
    }

    /// Notice shown when the applied appearance comes from a degraded source (nil = normal apply path).
    ///
    /// No "appearance not found" conclusion before the first background read completes, so "still reading" is never shown as fact.
    var appliedSourceNotice: String? {
        if isLoading { return "正在读取外观设置…" }
        guard sharedReadConfirmed else { return nil }
        switch appliedSource {
        case .applied:
            guard !projects.contains(where: { $0.id == applied.id }) else { return nil }
            return "键盘正在使用「\(applied.name)」，它已不在列表中。"
        case .systemDefault: return "当前正在使用「系统默认」外观。"
        }
    }
}

/// User-facing explanation for an apply failure (raw errors go only to the diagnostic log).
private struct AppearanceApplyFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

/// Full result of a background read (Sendable values; passed across queues, the closure holds no MainActor objects).
private struct AppearanceLoadResult: Sendable {
    var projects: [AppearanceDocument] = [.systemDefault]
    var unreadable: [UnreadableAppearance] = []
    var applied: AppearanceDocument = .systemDefault
    var appliedSource: AppearanceSnapshotSource = .systemDefault
    var sharedReadConfirmed = false
    var editingAppearance: SkinAppearance = .system
    var error: String?
}

/// Candidate-area layout summary (shared by list rows and detail; describes layout behavior only, no colors or font sizes).
enum CandidateAreaSummary {
    static func text(for bar: CandidateBarDefinition) -> String {
        let composition =
            [
                "composingOnly": "拼写行·输入时显示", "composingWithIdleRaw": "拼写行·始终显示",
                "hidden": "拼写行·隐藏",
            ][bar.compositionRow.visible.rawValue] ?? ""
        return [composition, expandedText(bar.expanded)]
            .joined(separator: " · ")
    }

    static func expandedText(_ expanded: CandidateBarDefinition.Expanded) -> String {
        switch expanded.mode {
        case .adaptive: return "展开·自适应"
        case .list: return "展开·单列"
        case .grid: return "展开·\(expanded.columns)列"
        }
    }

    static func icon(_ mode: CandidateBarDefinition.Expanded.Mode) -> String {
        switch mode {
        case .adaptive: return "text.alignleft"
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}
