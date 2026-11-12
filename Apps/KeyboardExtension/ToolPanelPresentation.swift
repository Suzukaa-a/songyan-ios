import Foundation
import ToolKit

/// One addon row in the tool panel.
///
/// A built-in tool, a user script and an installed extension are the same kind of row: this view
/// layer never branches on what an addon is made of. The panel only knows the addon's identity and
/// whether the host can supply what the addon declared it needs.
struct ToolPanelEntry: Identifiable, Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case ready
        case missingCapabilities(ToolCapabilities)
    }

    let identity: ToolIdentity
    let availability: Availability

    var id: String { identity.id }
    var isAvailable: Bool { availability == .ready }

    /// Text shown under the row while it cannot run here; nil when the row can run.
    var unavailableText: String? {
        switch availability {
        case .ready:
            return nil
        case .missingCapabilities:
            return String(localized: "缺少这个工具需要的输入能力，暂时不能运行")
        }
    }
}

/// One line the panel can show the user. The tool's own error text wins over the fallback, as the
/// contract says a tool's message is shown as written.
enum ToolPanelMessage: Equatable, Sendable {
    case noTextInput
    case secureEntry
    case missingCapabilities(ToolCapabilities)
    case cancelled
    case timedOut
    case noResult
    case toolFailed(String?)
    case documentChanged
    case noTextField
    case unsupportedPartialReplacement
    case unsupportedInsertion
    case editedAfterWrite
    case undoExpired
    case sourceChanged

    var text: String {
        switch self {
        case .noTextInput:
            return String(localized: "这里没有可以交给工具的文字")
        case .secureEntry:
            return String(localized: "密码输入框不能使用工具")
        case .missingCapabilities:
            return String(localized: "当前设备缺少这个工具需要的输入能力")
        case .cancelled:
            return String(localized: "已取消这次运行")
        case .timedOut:
            return String(localized: "工具运行超时，请重试")
        case .noResult:
            return String(localized: "工具没有返回可用的结果")
        case .toolFailed(let message):
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? String(localized: "工具运行失败") : trimmed
        case .documentChanged:
            return String(localized: "输入框已经切换，请重新运行工具")
        case .noTextField:
            return String(localized: "这个输入框不能写入")
        case .unsupportedPartialReplacement:
            return String(localized: "这个输入框不支持只替换一部分文字")
        case .unsupportedInsertion:
            return String(localized: "有选中文字时不能插入，请先取消选中")
        case .editedAfterWrite:
            return String(localized: "写入后内容又被修改，无法撤销")
        case .undoExpired:
            return String(localized: "撤销时间已过")
        case .sourceChanged:
            return String(localized: "原文已变化，结果已插入到光标处")
        }
    }
}

/// A result the user can pick before anything is written.
struct ToolPanelResultRow: Identifiable, Equatable, Sendable {
    let index: Int
    let text: String
    let isSelected: Bool

    var id: Int { index }
}

/// Which actions the panel offers, in the order the panel draws them.
enum ToolPanelAction: Hashable, Sendable {
    case chooseResult(Int)
    case copy
    case replace
    case insert
    case undo
    case cancel
    case retry
}

/// The panel's coarse phase. It mirrors ToolKit's phase only for drawing; the state machine stays
/// ToolKit's ToolSession.
enum ToolPanelStatus: Equatable, Sendable {
    case tools
    case running
    case preview
    case writing
    case wrote
    case undoing
    case failed
}

/// Everything the panel draws, derived from ToolKit's phase. Read-only: no state machine lives here.
struct ToolPanelPresentation: Equatable, Sendable {
    let status: ToolPanelStatus
    /// Title of the addon the panel is about; nil while only the list is shown.
    let toolTitle: String?
    /// The one line under the title, when the user needs a reason or a result notice.
    let message: ToolPanelMessage?
    let resultRows: [ToolPanelResultRow]
    let actions: [ToolPanelAction]
    let showsToolList: Bool
    let isBusy: Bool

    static func make(
        phase: ToolPhase, preview: ToolPreview?, writeBlock: ToolWriteBlock?, now: Double,
        undoWindow: Double?, lastToolTitle: String? = nil
    ) -> ToolPanelPresentation {
        switch phase {
        case .idle:
            return ToolPanelPresentation(
                status: .tools, toolTitle: nil, message: nil, resultRows: [], actions: [],
                showsToolList: true, isBusy: false)
        case .running:
            return ToolPanelPresentation(
                status: .running, toolTitle: lastToolTitle, message: nil, resultRows: [],
                actions: [.cancel], showsToolList: false, isBusy: true)
        case .previewing(let preview):
            let rows = preview.results.enumerated().map { index, text in
                ToolPanelResultRow(index: index, text: text, isSelected: index == preview.selectedIndex)
            }
            return ToolPanelPresentation(
                status: .preview, toolTitle: preview.identity.title,
                message: writeBlock.map(message(forWriteBlock:)), resultRows: rows,
                actions: [.copy, .replace, .insert], showsToolList: false, isBusy: false)
        case .writing:
            return ToolPanelPresentation(
                status: .writing, toolTitle: preview?.identity.title ?? lastToolTitle, message: nil,
                resultRows: [], actions: [], showsToolList: false, isBusy: true)
        case .wrote(let wrote):
            let windowOpen = undoWindow.map { now - wrote.writtenAt <= $0 } ?? true
            let message: ToolPanelMessage? =
                writeBlock.map(message(forWriteBlock:))
                ?? (wrote.source == .changed ? .sourceChanged : (windowOpen ? nil : .undoExpired))
            return ToolPanelPresentation(
                status: .wrote, toolTitle: lastToolTitle, message: message, resultRows: [],
                actions: windowOpen ? [.undo] : [], showsToolList: false, isBusy: false)
        case .undoing:
            return ToolPanelPresentation(
                status: .undoing, toolTitle: lastToolTitle, message: nil, resultRows: [],
                actions: [], showsToolList: false, isBusy: true)
        case .failed(let failure):
            return ToolPanelPresentation(
                status: .failed, toolTitle: lastToolTitle, message: message(forFailure: failure),
                resultRows: [], actions: [.retry], showsToolList: false, isBusy: false)
        }
    }

    private static func message(forWriteBlock block: ToolWriteBlock) -> ToolPanelMessage {
        switch block {
        case .documentChanged: return .documentChanged
        case .secureEntry: return .secureEntry
        case .noText: return .noTextField
        case .unsupportedPartialReplacement: return .unsupportedPartialReplacement
        case .unsupportedInsertion: return .unsupportedInsertion
        case .editedAfterWrite: return .editedAfterWrite
        }
    }

    private static func message(forFailure failure: ToolFailure) -> ToolPanelMessage {
        switch failure {
        case .unavailable(.secureEntry): return .secureEntry
        case .unavailable(.noText): return .noTextInput
        case .unavailable(.missingCapabilities(let capabilities)): return .missingCapabilities(capabilities)
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .noResult: return .noResult
        case .toolError(let message): return .toolFailed(message)
        }
    }
}
