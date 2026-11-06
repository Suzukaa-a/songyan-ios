import CandidateKit
import KeyboardCore
import QuickContentKit
import SwiftUI
import UIKit

/// The keyboard tool panel: the one place a tool runs and its result is written (M-D2, M-D3).
///
/// It never opens by itself and never writes without a tap: the toolbar opens it, the source list
/// says exactly which text will be processed, and replace / insert / copy write or copy the
/// previewed result. The tool sees one bounded string; it never sees the field, the app or the
/// keyboard.
struct KeyboardToolsPanel: View {
    @ObservedObject var controller: KeyboardController
    @ObservedObject var model: KeyboardToolsModel
    let onClose: () -> Void
    @Environment(\.keyboardAppearance) private var appearance
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sourceSection
                    toolSection
                    resultSection
                }
                .padding(.bottom, 12)
            }
            .sharpCandidateScrollEdges()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dynamicTypeSize(.small ... .accessibility3)
        .accessibilityElement(children: .contain)
        // The panel's own way out, also reachable with the VoiceOver escape gesture: closing the
        // panel returns to the keys, and it closes before anything else in the keyboard does.
        .accessibilityAction(.escape) { onClose() }
        .onAppear { titleFocused = true }
    }

    private var titleBar: some View {
        KeyboardToolsTitleBar {
            KeyboardToolsTitle(text: KeyboardToolsWording.panelTitle)
                .accessibilityFocused($titleFocused)
        } trailing: {
            KeyboardToolsDismissButton(
                title: KeyboardToolsWording.done, minHeight: 40, action: onClose)
        }
        .frame(minHeight: 40)
    }

    // MARK: - Source

    private var sourceSection: some View {
        KeyboardToolsSection(title: KeyboardToolsWording.sourceHeader, topPadding: 4) {
            ForEach(Array(ToolPanelSource.allCases.enumerated()), id: \.element) { index, source in
                if index > 0 { KeyboardToolsSeparator() }
                sourceRow(source)
            }
            KeyboardToolsSeparator()
            previewBlock
        }
    }

    private func sourceRow(_ source: ToolPanelSource) -> some View {
        let unavailable = model.availability(of: source)
        // Before the first pasteboard read, "no clipboard text" is not a fact; say nothing yet.
        let clipboardUnread = source == .clipboard && !model.clipboardWasRead
        let detail: String? = clipboardUnread ? nil : unavailable.map(KeyboardToolsWording.sourceUnavailable)
        return KeyboardToolsRow(
            icon: sourceIcon(source),
            title: KeyboardToolsWording.sourceName(source),
            detail: detail,
            mark: .check(model.source == source),
            accessibilityLabel: KeyboardToolsWording.sourceName(source),
            accessibilityHint: nil
        ) {
            choose(source)
        }
        // The clipboard's content is unknown until it is read, so that row always accepts a tap;
        // the other sources are disabled while they hold nothing.
        .disabled(unavailable != nil && source != .clipboard)
        .accessibilityIdentifier("keyboard.tools.source." + source.rawValue)
    }

    @ViewBuilder
    private var previewBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let prepared = model.prepared {
                Text(prepared.text)
                    .font(.callout)
                    .foregroundStyle(Color(uiColor: appearance.text(on: "key")))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(prepared.text)
                if prepared.wasTruncated {
                    Text(KeyboardToolsWording.truncatedNotice(prepared.source))
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: appearance.text(on: "key", secondary: true)))
                }
            } else {
                Text(KeyboardToolsWording.noInput)
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: appearance.text(on: "key", secondary: true)))
            }
        }
        .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
        .padding(.vertical, 10)
    }

    private func sourceIcon(_ source: ToolPanelSource) -> String {
        switch source {
        case .selection: return "text.cursor"
        case .paragraphBeforeCursor: return "text.alignleft"
        case .clipboard: return "list.clipboard"
        }
    }

    private func choose(_ source: ToolPanelSource) {
        KeyboardFeedbackService.shared.selectionChanged()
        if source == .clipboard {
            // Read the pasteboard only for this explicit tap; a keyboard without Full Access
            // writes it nothing, so the panel reports an empty clipboard instead of guessing.
            model.choose(.clipboard, clipboardText: UIPasteboard.general.string)
        } else {
            model.choose(source)
        }
    }

    // MARK: - Tools

    private var toolSection: some View {
        KeyboardToolsSection(title: KeyboardToolsWording.listHeader) {
            if model.enabled.isEmpty {
                KeyboardToolsRow(
                    title: model.catalogError ?? KeyboardToolsWording.listEmpty,
                    titleLineLimit: 2,
                    accessibilityLabel: model.catalogError ?? KeyboardToolsWording.listEmpty
                ) {}
                .disabled(true)
            } else {
                ForEach(Array(model.enabled.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { KeyboardToolsSeparator() }
                    KeyboardToolsRow(
                        icon: "wand.and.stars",
                        title: model.displayName(for: item),
                        mark: .check(model.selectedToolID == item.id),
                        accessibilityLabel: model.displayName(for: item),
                        accessibilityHint: nil
                    ) {
                        run(item)
                    }
                    .disabled(model.isRunning || model.prepared == nil)
                    .accessibilityIdentifier("keyboard.tools.tool." + item.id)
                }
            }
            if model.isRunning {
                KeyboardToolsSeparator()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(KeyboardToolsWording.running)
                        .font(.footnote)
                        .foregroundStyle(Color(uiColor: appearance.text(on: "key", secondary: true)))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
                .frame(minHeight: KeyboardToolsStyle.rowMinHeight)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(KeyboardToolsWording.running)
            }
        }
    }

    private func run(_ item: KeyboardToolsModel.Item) {
        KeyboardFeedbackService.shared.keyPressed()
        model.run(toolID: item.id, controller: controller)
    }

    // MARK: - Result

    @ViewBuilder
    private var resultSection: some View {
        if let runError = model.runError {
            messageCard(runError, isError: true)
        }
        if let result = model.result {
            KeyboardToolsSection(title: KeyboardToolsWording.resultHeader) {
                Text(result)
                    .font(.callout)
                    .foregroundStyle(Color(uiColor: appearance.text(on: "key")))
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
                    .padding(.vertical, 10)
                    .accessibilityLabel(result)
                KeyboardToolsSeparator()
                actionRow
            }
        }
        if let notice = model.notice {
            messageCard(notice, isError: false)
        }
    }

    /// Replace is offered only while the anchor still points at field text; once a replacement was
    /// refused, the panel keeps insert and copy (M-D3: "变了只提供「插入」").
    private var showsReplace: Bool {
        guard model.replacementBlocked == nil, let prepared = model.prepared else { return false }
        return prepared.anchor != nil
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if showsReplace {
                actionButton(KeyboardToolsWording.replace, role: "accent") { apply(.replace) }
                    .accessibilityIdentifier("keyboard.tools.replace")
            }
            actionButton(
                KeyboardToolsWording.insert, role: showsReplace ? "control" : "accent"
            ) { apply(.insert) }
            .accessibilityIdentifier("keyboard.tools.insert")
            actionButton(KeyboardToolsWording.copy, role: "control") { apply(.copy) }
                .accessibilityIdentifier("keyboard.tools.copy")
        }
        .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
        .padding(.vertical, 8)
    }

    private func actionButton(
        _ title: String, role: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: KeyboardToolsStyle.rowMinHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyboardToolsKeyButtonStyle(role: role))
        .accessibilityLabel(title)
    }

    private func apply(_ option: ToolPanelWriteOption) {
        KeyboardFeedbackService.shared.keyPressed()
        _ = model.apply(option, controller: controller)
    }

    private func messageCard(_ message: String, isError: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isError {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(appearance.accentForeground)
                    .accessibilityHidden(true)
            }
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color(uiColor: appearance.text(on: "panel")))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Where the settings panel sends the user for tool management.
extension HostAppLink {
    /// Host-app route for the keyboard-tools page. The keyboard can only open the app; the app
    /// decides which settings screen it lands on.
    static var toolsSettingsURL: URL? { URL(string: scheme + "://tools") }
}
