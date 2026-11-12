import Foundation

/// What went wrong with a script run or a script header, classified once so the Host app can
/// show localized user copy without leaking Swift type names, status codes or English engine
/// diagnostics. The raw diagnostics stay in developer logs only.
public enum ScriptAddonFailure: Equatable, Sendable {
    /// The declaration header is invalid; the line is 1-based when known.
    case header(line: Int?)
    /// The script threw or the engine rejected the run; the line is 1-based when known.
    case runtime(line: Int?)
    /// The run configuration was rejected before the engine started.
    case invalidConfiguration
    /// The user cancelled the run.
    case cancelled
    /// Anything unexpected: show a generic sentence, never the underlying description.
    case unknown

    /// Localization key the Host app resolves. These are catalog keys, not user copy.
    public var userMessageKey: String {
        switch self {
        case .header: "脚本开头格式有误"
        case .runtime: "脚本运行出错"
        case .invalidConfiguration: "无法运行脚本，请稍后重试。"
        case .cancelled: "运行已取消"
        case .unknown: "无法运行脚本，请稍后重试。"
        }
    }

    /// 1-based source line, when the failure carries one.
    public var line: Int? {
        switch self {
        case .header(let line), .runtime(let line): line
        case .invalidConfiguration, .cancelled, .unknown: nil
        }
    }
}
