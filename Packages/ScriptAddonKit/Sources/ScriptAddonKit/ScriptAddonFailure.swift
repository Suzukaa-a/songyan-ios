import Foundation

/// What went wrong with a script run or a script header, classified once so the Host app can
/// show localized user copy without leaking Swift type names, status codes or English engine
/// diagnostics. The raw diagnostics stay in developer logs only.
public enum ScriptAddonFailure: Equatable, Sendable {
    /// The declaration header is invalid; the line is 1-based when known.
    case header(line: Int?)
    /// The script threw an error of its own; its words are shown as written. The line is 1-based
    /// when known.
    case script(message: String, line: Int?)
    /// The script threw or the engine rejected the run for a reason with no user-facing wording;
    /// the line is 1-based when known.
    case runtime(line: Int?)
    case addressNotAllowed
    case networkFailure
    case timedOut
    case outOfMemory
    case requestLimitExceeded
    case responseTooLarge
    /// A downloaded script is over the source size limit.
    case tooLarge
    /// The device cannot offer what the script needs.
    case unavailable
    /// The run configuration was rejected before the engine started.
    case invalidConfiguration
    /// The user cancelled the run.
    case cancelled
    /// Anything unexpected: show a generic sentence, never the underlying description.
    case unknown
    /// A saved script or its settings could not be written or changed.
    case saveFailed
    /// The saved scripts could not be read back.
    case loadFailed
    /// A chosen file could not be read.
    case fileUnreadable
    /// A secret could not be stored in or removed from the Keychain.
    case secretNotSaved
    /// The script was already added.
    case duplicate
    /// The stored script is missing from disk.
    case scriptMissing
    /// The stored data was written by a newer app version.
    case newerAppRequired

    /// Localization key the Host app resolves. These are catalog keys, not user copy.
    public var userMessageKey: String {
        switch self {
        case .header: "脚本开头格式有误"
        case .script, .runtime: "脚本运行出错"
        case .addressNotAllowed: "这个脚本不能连接这个地址"
        case .networkFailure: "网络连接失败，请重试"
        case .timedOut: "运行超时"
        case .outOfMemory: "脚本占用内存过多"
        case .requestLimitExceeded: "请求次数超过上限"
        case .responseTooLarge: "服务器返回的内容太大"
        case .unavailable: "这台设备上不可用"
        case .tooLarge: "脚本文件太大"
        case .invalidConfiguration: "无法运行脚本，请稍后重试。"
        case .cancelled: "运行已取消"
        case .unknown: "无法运行脚本，请稍后重试。"
        case .saveFailed: "没能保存更改。请重试；如果一直这样，把脚本删掉后重新添加。"
        case .loadFailed: "没能读取脚本列表。请退出松烟后重新打开。"
        case .fileUnreadable: "没能读取这个文件。请确认文件还在，再试一次。"
        case .secretNotSaved: "没能保存脚本的密钥。请重试。"
        case .duplicate: "这个脚本已经添加过了"
        case .scriptMissing: "找不到这个脚本的文件。请把脚本删掉后重新添加。"
        case .newerAppRequired: "这个脚本由更新版本的松烟保存。请先更新松烟。"
        }
    }

    /// The script's own message, shown verbatim instead of a catalog sentence. Nil when empty.
    public var scriptMessage: String? {
        if case .script(let message, _) = self, !message.isEmpty { return message }
        return nil
    }

    /// 1-based source line, when the failure carries one.
    public var line: Int? {
        switch self {
        case .header(let line), .runtime(let line), .script(_, let line): line
        case .invalidConfiguration, .cancelled, .unknown, .saveFailed, .loadFailed, .fileUnreadable,
            .secretNotSaved, .duplicate, .scriptMissing, .newerAppRequired, .addressNotAllowed, .networkFailure,
            .timedOut, .outOfMemory, .requestLimitExceeded, .responseTooLarge, .unavailable, .tooLarge:
            nil
        }
    }

    /// Classifies an error thrown while saving or changing scripts. Anything that is not a known
    /// storage error falls back to the generic save failure; the raw text never reaches the UI.
    public static func forStorage(_ error: Error) -> ScriptAddonFailure {
        if let store = error as? ScriptAddonStore.StoreError {
            switch store {
            case .scriptTooLarge: return .tooLarge
            case .duplicateID: return .duplicate
            case .missingScript: return .scriptMissing
            case .unsupportedStateVersion: return .newerAppRequired
            case .invalidIdentifier: return .saveFailed
            }
        }
        if error is KeychainScriptSecretStore.KeychainError { return .secretNotSaved }
        return .saveFailed
    }
}
