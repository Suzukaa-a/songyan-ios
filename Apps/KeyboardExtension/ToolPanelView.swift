import SwiftUI
import ToolKit
import UIKit

/// What the tool panel needs from its host. The host adapter (extension wiring, added separately)
/// delegates to the one ToolKit session and the one document gateway; the panel never keeps a copy
/// of that state machine.
@MainActor
protocol ToolPanelDriving: AnyObject {
    /// Every addon the host can list here: built-in tool, user script or installed extension.
    var entries: [ToolPanelEntry] { get }
    var phase: ToolPhase { get }
    var preview: ToolPreview? { get }
    var writeBlock: ToolWriteBlock? { get }
    var undoWindow: Double? { get }
    /// Title of the addon the panel is currently about (running, writing, wrote or failed).
    var lastToolTitle: String? { get }

    func run(_ identity: ToolIdentity)
    func chooseResult(_ index: Int)
    func retry()
    func cancel()
    func copy() -> String?
    func replace()
    func insert()
    func undo()
    func dismiss() -> ToolDismissOutcome
}

/// Thin observable bridge: forwards intents to the host adapter and republishes when the adapter
/// reports a change. It owns no phase of its own.
@MainActor
final class ToolPanelModel: ObservableObject {
    private let driver: any ToolPanelDriving
    private let clock: () -> Double

    init(
        driver: any ToolPanelDriving,
        clock: @escaping () -> Double = { Date.timeIntervalSinceReferenceDate }
    ) {
        self.driver = driver
        self.clock = clock
    }

    var entries: [ToolPanelEntry] { driver.entries }

    var presentation: ToolPanelPresentation {
        ToolPanelPresentation.make(
            phase: driver.phase, preview: driver.preview, writeBlock: driver.writeBlock,
            now: clock(), undoWindow: driver.undoWindow, lastToolTitle: driver.lastToolTitle)
    }

    /// Called by the host adapter when a run, write or undo moves the session forward.
    func refresh() { objectWillChange.send() }

    func run(_ identity: ToolIdentity) {
        driver.run(identity)
        refresh()
    }

    func chooseResult(_ index: Int) {
        driver.chooseResult(index)
        refresh()
    }

    func retry() {
        driver.retry()
        refresh()
    }

    func cancel() {
        driver.cancel()
        refresh()
    }

    func copy() -> String? {
        let text = driver.copy()
        refresh()
        return text
    }

    func replace() {
        driver.replace()
        refresh()
    }

    func insert() {
        driver.insert()
        refresh()
    }

    func undo() {
        driver.undo()
        refresh()
    }

    func dismiss() {
        _ = driver.dismiss()
        refresh()
    }
}

/// The tool panel: addon list, running state, result preview and the copy/replace/insert/undo
/// actions. It draws with the keyboard's existing tools visuals and returns through the same
/// title-bar dismiss a user already knows from keyboard settings.
struct ToolPanelView: View {
    @ObservedObject var model: ToolPanelModel
    @Environment(\.keyboardAppearance) private var appearance
    let dismiss: () -> Void
    @State private var copied = false
    /// The result the user chose to write. The session drops its preview after a write, so the
    /// panel keeps this only to offer "copy result" once the undo window has closed.
    @State private var lastWrittenResult: String?

    var body: some View {
        VStack(spacing: 0) {
            KeyboardToolsTitleBar {
                // While a run is in flight the title names the script, so a failure or a result
                // can be attributed without reopening the panel.
                KeyboardToolsTitle(text: model.presentation.toolTitle ?? String(localized: "工具"))
            } trailing: {
                KeyboardToolsDismissButton(
                    title: String(localized: "完成"),
                    accessibilityHint: String(localized: "返回键盘")
                ) { dismiss() }
            }
            .frame(minHeight: 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if copied {
                        messageLine(String(localized: "已复制到剪贴板"), icon: "checkmark.circle")
                    }
                    content
                }
                .padding(.bottom, 24)
            }
            .sharpCandidateScrollEdges()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dynamicTypeSize(.small ... .accessibility3)
        .onChange(of: copied) { _, isCopied in
            guard isCopied else { return }
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { dismiss() }
    }

    @ViewBuilder
    private var content: some View {
        let presentation = model.presentation
        switch presentation.status {
        case .tools:
            // The title bar already says 工具; a second section header would waste a row of the
            // short keyboard panel. The card alone keeps the list visually grouped.
            KeyboardToolsCard {
                if model.entries.isEmpty {
                    // Reuses the Host app's existing "add and run a script" wording: no new
                    // localization key, but the empty panel says what to do next.
                    KeyboardToolsRow(
                        title: String(localized: "还没有可用的工具"),
                        detail: String(localized: "添加并运行你写的脚本")
                    ) {}
                    .disabled(true)
                } else {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { KeyboardToolsSeparator() }
                        KeyboardToolsRow(
                            icon: "wand.and.stars",
                            title: entry.identity.title,
                            detail: entry.unavailableText,
                            accessibilityValue: entry.unavailableText,
                            action: { model.run(entry.identity) }
                        )
                        .disabled(!entry.isAvailable)
                        .accessibilityIdentifier("keyboard.tool." + entry.id)
                    }
                }
            }
            .padding(.top, KeyboardToolsStyle.sectionTopPadding)
        case .preview:
            if let message = presentation.message {
                messageLine(message.text, icon: "info.circle")
            }
            KeyboardToolsSection(title: String(localized: "结果")) {
                ForEach(presentation.resultRows) { row in
                    KeyboardToolsRow(
                        title: row.text,
                        titleLineLimit: 6,
                        mark: row.isSelected ? .check(true) : .check(false),
                        isSelected: row.isSelected,
                        action: { model.chooseResult(row.index) })
                }
            }
            actionSection(presentation.actions)
        case .wrote:
            if let message = presentation.message {
                messageLine(message.text, icon: "info.circle")
            }
            // Until the undo window closes the session offers undo; afterwards the panel keeps
            // the written result copyable so an expired undo is not a dead end. The title bar's
            // 完成 is always the way out.
            actionSection(
                presentation.actions
                    + (lastWrittenResult != nil && !presentation.actions.contains(.copy)
                        ? [.copy] : []))
        case .failed:
            if let message = presentation.message {
                messageLine(message.text, icon: "info.circle")
            }
            actionSection(presentation.actions)
        case .running, .writing, .undoing:
            KeyboardToolsSection(title: String(localized: "状态")) {
                busyRow(presentation.status)
            }
            actionSection(presentation.actions)
        }
    }

    @ViewBuilder
    private func actionSection(_ actions: [ToolPanelAction]) -> some View {
        let rows = actions.compactMap(actionRow)
        if !rows.isEmpty {
            KeyboardToolsSection(title: String(localized: "操作")) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { KeyboardToolsSeparator() }
                    KeyboardToolsRow(
                        icon: row.icon, title: row.title, action: row.action)
                }
            }
        }
    }

    /// Captures the chosen result before the session leaves preview; undo-expired copy uses it.
    private func rememberSelectedResult() {
        let rows = model.presentation.resultRows
        lastWrittenResult = rows.first(where: \.isSelected)?.text ?? rows.first?.text
    }

    private struct ActionRow {
        let icon: String
        let title: String
        let action: () -> Void
    }

    private func actionRow(_ action: ToolPanelAction) -> ActionRow? {
        switch action {
        case .chooseResult:
            return nil
        case .copy:
            return ActionRow(icon: "doc.on.doc", title: String(localized: "复制")) {
                // A copy during preview consumes the result; after a write the session has no
                // preview left, so fall back to the text the panel remembered when it wrote.
                if let text = model.copy() ?? lastWrittenResult {
                    UIPasteboard.general.string = text
                    copied = true
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: String(localized: "已复制到剪贴板"))
                }
            }
        case .replace:
            return ActionRow(icon: "arrow.left.arrow.right", title: String(localized: "替换原文")) {
                rememberSelectedResult()
                model.replace()
            }
        case .insert:
            return ActionRow(icon: "text.insert", title: String(localized: "插入到光标处")) {
                rememberSelectedResult()
                model.insert()
            }
        case .undo:
            return ActionRow(icon: "arrow.uturn.backward", title: String(localized: "撤销")) {
                model.undo()
            }
        case .cancel:
            return ActionRow(icon: "xmark.circle", title: String(localized: "取消")) {
                model.cancel()
            }
        case .retry:
            return ActionRow(icon: "arrow.clockwise", title: String(localized: "重新运行")) {
                model.retry()
            }
        }
    }

    @ViewBuilder
    private func busyRow(_ status: ToolPanelStatus) -> some View {
        let title: String =
            switch status {
            case .running: String(localized: "正在运行")
            case .writing: String(localized: "正在写入")
            case .undoing: String(localized: "正在撤销")
            default: String(localized: "正在处理")
            }
        HStack(spacing: 8) {
            ProgressView()
                .tint(appearance.accentForeground)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .foregroundStyle(Color(uiColor: appearance.text(on: "key")))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
        .frame(maxWidth: .infinity, minHeight: KeyboardToolsStyle.rowMinHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func messageLine(_ text: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(uiColor: appearance.text(on: "panel", secondary: true)))
        .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
        .padding(.top, KeyboardToolsStyle.sectionTopPadding)
    }
}
