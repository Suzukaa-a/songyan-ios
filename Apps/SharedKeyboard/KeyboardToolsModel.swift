import Combine
import Foundation
import KeyboardCore
import QuickContentKit

/// The keyboard's tool state: the catalog read off the main thread, the panel's source and result,
/// and one bounded run at a time.
///
/// The catalog lives in the App Group store written by the host app. Every read and the run itself
/// happen away from the main thread (`ToolStore` is an actor; `ToolRunner` is a nonisolated async
/// value), so opening the panel or pressing a tool never stalls typing.
@MainActor
final class KeyboardToolsModel: ObservableObject {
    /// One catalog entry as the toolbar and the panel list it. The two lists already carry the
    /// store's enable and pin facts, so only the authored definition is kept.
    struct Item: Identifiable, Equatable {
        let definition: ToolDefinition

        var id: String { definition.id }

        init(definition: ToolDefinition) {
            self.definition = definition
        }

        init(_ entry: ToolStoreEntry) {
            self.init(definition: entry.definition)
        }
    }

    /// Enabled pinned tools in list order; the toolbar shows at most the store's own limit (two).
    @Published private(set) var pinned: [Item] = []
    /// Enabled tools the panel lists.
    @Published private(set) var enabled: [Item] = []
    /// Why the store could not be read; the built-in examples stay usable in that case.
    @Published private(set) var catalogError: String?
    @Published private(set) var isOpen = false
    @Published private(set) var panel: ToolPanelModel?
    @Published private(set) var selectedToolID: String?
    /// The one bounded result of the last run, shown before anything is written.
    @Published private(set) var result: String?
    @Published private(set) var runError: String?
    @Published private(set) var notice: String?
    @Published private(set) var isRunning = false

    private var catalogGate = LatestWinsReadGate()
    private var runTask: Task<Void, Never>?

    // MARK: - Facts the views read

    /// A replacement was refused because the field changed; the panel then offers insertion only.
    var replacementBlocked: ToolPanelReplacementBlock? { panel?.replacementBlocked }

    var prepared: ToolPanelPreparedText? { panel?.prepared }

    var source: ToolPanelSource? { panel?.source }

    /// Names follow the app's own language choice, like every other label in the panel.
    static let preferredLanguageTags: [String] = {
        let tags = Bundle.main.preferredLocalizations
        return tags.isEmpty ? ["zh-Hans"] : tags
    }()

    func displayName(for item: Item) -> String {
        item.definition.displayName(preferredLanguageTags: Self.preferredLanguageTags)
    }

    func availability(of source: ToolPanelSource) -> ToolPanelSourceUnavailable? {
        panel?.availability(of: source)
    }

    // MARK: - Catalog

    /// Reads the catalog for one input language. The built-in conversion depends on it, so a
    /// scheme switch re-reads with that language's example.
    func refresh(inputLanguage: InputLanguage) async {
        let token = catalogGate.begin()
        let builtins = KeyboardToolsStore.builtinDefinitions(for: inputLanguage)
        guard let root = KeyboardToolsStore.readRootURL() else {
            applyBuiltins(builtins, error: nil)
            return
        }
        let store = ToolStore(rootURL: root, builtins: builtins)
        do {
            let snapshot = try await store.load()
            guard catalogGate.accepts(token) else { return }
            pinned = snapshot.pinnedEntries.map { Item($0) }
            enabled = snapshot.enabledEntries.map { Item($0) }
            catalogError = nil
        } catch {
            guard catalogGate.accepts(token) else { return }
            // A damaged settings file must not take the built-in examples down with it: they are
            // part of the app, and only the user's own tools are hidden until the store is readable.
            applyBuiltins(builtins, error: KeyboardToolsWording.listUnreadable)
        }
    }

    private func applyBuiltins(_ builtins: [ToolDefinition], error: String?) {
        pinned = []
        enabled = builtins.map { Item(definition: $0) }
        catalogError = error
    }

    // MARK: - Panel lifetime

    /// Opens the panel with a fresh read of the field. `toolID` runs that tool at once: a pinned
    /// toolbar tool opens its preview in one tap and still writes nothing until the user says so.
    func open(controller: KeyboardController, toolID: String? = nil) {
        result = nil
        runError = nil
        notice = nil
        selectedToolID = nil
        isRunning = false
        isOpen = true
        guard let editor = controller.readToolTextSource() else {
            panel = nil
            notice = KeyboardToolsWording.writeFailed
            return
        }
        let panel = ToolPanelModel(editor: editor)
        guard !panel.isProtectedField else {
            self.panel = nil
            notice = KeyboardToolsWording.protectedField
            return
        }
        self.panel = panel
        if panel.prepared == nil { notice = KeyboardToolsWording.noInput }
        if let toolID { run(toolID: toolID, controller: controller) }
    }

    func close() {
        runTask?.cancel()
        runTask = nil
        isOpen = false
        panel = nil
        selectedToolID = nil
        result = nil
        runError = nil
        notice = nil
        isRunning = false
    }

    /// Switches the processed text.
    func choose(_ source: ToolPanelSource) {
        guard var panel else { return }
        guard panel.choose(source) else {
            notice =
                panel.availability(of: source).map(KeyboardToolsWording.sourceUnavailable)
                ?? KeyboardToolsWording.noInput
            return
        }
        self.panel = panel
        result = nil
        runError = nil
        notice = nil
    }

    // MARK: - Run

    /// Runs one tool on the panel's current text. A new run replaces the previous preview; the
    /// panel never writes on its own.
    func run(toolID: String, controller: KeyboardController) {
        guard let item = enabled.first(where: { $0.id == toolID }),
            let input = panel?.prepared?.text
        else { return }
        runTask?.cancel()
        selectedToolID = toolID
        result = nil
        runError = nil
        notice = nil
        isRunning = true
        let definition = item.definition
        runTask = Task { [weak self] in
            let runner = ToolRunner(openCCConverter: KeyboardToolsOpenCCAdapter())
            do {
                let outcome = try await runner.run(definition, input: input)
                guard let self, !Task.isCancelled else { return }
                self.isRunning = false
                self.result = outcome.text
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isRunning = false
                self.runError = Self.message(for: error)
            }
        }
    }

    // MARK: - Write

    /// Applies the previewed result. Returns true when the panel was closed because the field was
    /// written; the caller then returns to the keys.
    @discardableResult
    func apply(_ option: ToolPanelWriteOption, controller: KeyboardController) -> Bool {
        guard let result else { return false }
        switch option {
        case .copy:
            if controller.copyToolResult(result) {
                notice = KeyboardToolsWording.copied
            } else {
                notice = KeyboardToolsWording.copyFailed
            }
            return false
        case .insert:
            guard !result.isEmpty else { return false }
            guard controller.insertExternalLiteral(result) else {
                notice = KeyboardToolsWording.writeFailed
                return false
            }
            close()
            return true
        case .replace:
            guard var panel else { return false }
            let decision = panel.replacementDecision(current: controller.readToolTextSource())
            switch decision {
            case .replace(let anchor):
                guard controller.replaceToolAnchor(anchor, with: result) else {
                    notice = KeyboardToolsWording.writeFailed
                    return false
                }
                self.panel = panel
                close()
                return true
            case .insertOnly(let block):
                // M-D3: a changed original only offers insertion; nothing is written by this tap.
                panel.noteReplacementBlocked(block)
                self.panel = panel
                notice = Self.notice(for: block, prepared: panel.prepared)
                return false
            }
        }
    }

    /// Why the replace action was withdrawn. A truncated selection says what was processed; a
    /// changed field says the only remaining action is insertion.
    private static func notice(
        for block: ToolPanelReplacementBlock, prepared: ToolPanelPreparedText?
    ) -> String? {
        switch block {
        case .sourceWasTruncated:
            return prepared.map { KeyboardToolsWording.truncatedNotice($0.source) }
        case .textChanged, .documentChanged, .documentUnavailable:
            return KeyboardToolsWording.textChanged
        }
    }

    /// One-line reason for a failed run; the runner's typed errors carry no user wording.
    private static func message(for error: Error) -> String {
        guard let failure = error as? ToolRunnerError else {
            return KeyboardToolsWording.genericFailure
        }
        switch failure {
        case .converterUnavailable, .conversionFailed:
            return KeyboardToolsWording.conversionUnavailable
        case .outputTooLong:
            return KeyboardToolsWording.outputTooLong
        case .invalidDefinition, .regexFailed, .widthTransformUnavailable, .unexpectedFailure:
            return KeyboardToolsWording.genericFailure
        }
    }
}
