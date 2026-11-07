import Foundation
import QuickContentKit

/// Every new user-visible string the keyboard tools add, in one place.
///
/// The copy lives in `Resources/KeyboardToolsPanel.xcstrings` so the main catalog stays untouched;
/// the keys are shared by the toolbar, the panel and the settings entry.
enum KeyboardToolsWording {
    /// String catalog table compiled from `Resources/KeyboardToolsPanel.xcstrings`.
    private static let table = "KeyboardToolsPanel"

    // MARK: Panel chrome

    static let panelTitle = String(localized: "tools.panel.title", table: table)
    static let done = String(localized: "tools.panel.done", table: table)
    static let running = String(localized: "tools.running", table: table)

    // MARK: Source

    static let sourceHeader = String(localized: "tools.source.header", table: table)
    static let sourceSelection = String(localized: "tools.source.selection", table: table)
    static let sourceParagraph = String(localized: "tools.source.paragraph", table: table)
    static let sourceClipboard = String(localized: "tools.source.clipboard", table: table)
    static let selectionUnavailable = String(localized: "tools.source.unavailable.selection", table: table)
    static let paragraphUnavailable = String(localized: "tools.source.unavailable.paragraph", table: table)
    static let clipboardUnavailable = String(localized: "tools.source.unavailable.clipboard", table: table)

    // MARK: Tools and result

    static let listHeader = String(localized: "tools.list.header", table: table)
    static let listEmpty = String(localized: "tools.list.empty", table: table)
    static let listUnreadable = String(localized: "tools.list.unreadable", table: table)
    static let resultHeader = String(localized: "tools.result.header", table: table)

    // MARK: Actions

    static let replace = String(localized: "tools.action.replace", table: table)
    static let insert = String(localized: "tools.action.insert", table: table)
    static let copy = String(localized: "tools.action.copy", table: table)
    static let copied = String(localized: "tools.notice.copied", table: table)
    static let copyFailed = String(localized: "tools.notice.copyFailed", table: table)
    static let textChanged = String(localized: "tools.notice.textChanged", table: table)
    static let writeFailed = String(localized: "tools.notice.writeFailed", table: table)
    static let conversionUnavailable = String(localized: "tools.error.conversionUnavailable", table: table)
    static let outputTooLong = String(localized: "tools.error.outputTooLong", table: table)
    static let genericFailure = String(localized: "tools.error.generic", table: table)

    // MARK: Empty and protected fields

    static let noInput = String(localized: "tools.panel.noInput", table: table)
    static let protectedField = String(localized: "tools.panel.protected", table: table)

    // MARK: Toolbar and settings entry

    static let toolbarButton = String(localized: "tools.toolbar.button", table: table)
    static let pinnedHint = String(localized: "tools.toolbar.pinnedHint", table: table)
    static let manageTools = String(localized: "tools.manage", table: table)
    static let manageToolsHint = String(localized: "tools.manage.hint", table: table)

    static func sourceName(_ source: ToolPanelSource) -> String {
        switch source {
        case .selection: return sourceSelection
        case .paragraphBeforeCursor: return sourceParagraph
        case .clipboard: return sourceClipboard
        }
    }

    static func sourceUnavailable(_ reason: ToolPanelSourceUnavailable) -> String {
        switch reason {
        case .nothingSelected: return selectionUnavailable
        case .noTextBeforeCursor: return paragraphUnavailable
        case .clipboardHasNoText: return clipboardUnavailable
        }
    }

    static func truncatedNotice(_ source: ToolPanelSource) -> String {
        switch source {
        case .selection:
            return String(localized: "tools.result.truncated.selection", table: table)
        case .paragraphBeforeCursor:
            return String(localized: "tools.result.truncated.paragraph", table: table)
        case .clipboard:
            return String(localized: "tools.result.truncated.clipboard", table: table)
        }
    }
}
