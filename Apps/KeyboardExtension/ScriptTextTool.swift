import CryptoKit
import Foundation
import ScriptAddonKit
import ToolKit

/// The six limits the shared C bridge requires. They are injected by the host and the bridge has no
/// defaults; this type is deliberately separate from ToolKit's ToolLimits because the session budget
/// (timeout, input units, undo) and the engine budget (heap, source, request/response bytes) are
/// two different contracts. The values here are host policy, chosen next to the extension runtime
/// and never inside Tools/Script.
///
/// Why only the non-zero check: the shared contract defines each field as a required budget and the
/// bridge enforces the exact injected number. It publishes no platform-independent maximum (a valid
/// source size or heap budget depends on the device policy that chooses it), so inventing an upper
/// bound here would be a second, unsupported limit. A value that the bridge cannot accept surfaces as
/// an invalidConfiguration/outOfMemory-like error from the run instead of being silently clamped.
/// Zero or negative values are rejected here because the bridge treats every zero field as missing.
struct ScriptToolRuntimeLimits: Equatable, Sendable {
    let sourceBytes: Int
    let heapBytes: Int
    let durationMilliseconds: UInt32
    let computeMilliseconds: UInt32
    let requestCount: UInt32
    let responseBytes: Int
    let inputTextBytes: Int

    /// What both apps ship, from the shared contract header.
    static let shipped = ScriptToolRuntimeLimits(
        sourceBytes: Int(SONGYAN_SCRIPT_SHIPPED_SOURCE_BYTES),
        heapBytes: Int(SONGYAN_SCRIPT_SHIPPED_HEAP_BYTES),
        durationMilliseconds: SONGYAN_SCRIPT_SHIPPED_DURATION_MS,
        computeMilliseconds: SONGYAN_SCRIPT_SHIPPED_COMPUTE_MS,
        requestCount: SONGYAN_SCRIPT_SHIPPED_REQUEST_COUNT,
        responseBytes: Int(SONGYAN_SCRIPT_SHIPPED_RESPONSE_BYTES),
        inputTextBytes: Int(SONGYAN_SCRIPT_SHIPPED_INPUT_TEXT_BYTES))

    init(
        sourceBytes: Int, heapBytes: Int, durationMilliseconds: UInt32,
        computeMilliseconds: UInt32, requestCount: UInt32, responseBytes: Int, inputTextBytes: Int
    ) {
        precondition(sourceBytes > 0, "sourceBytes must be positive")
        precondition(heapBytes > 0, "heapBytes must be positive")
        precondition(durationMilliseconds > 0, "durationMilliseconds must be positive")
        precondition(computeMilliseconds > 0, "computeMilliseconds must be positive")
        precondition(requestCount > 0, "requestCount must be positive")
        precondition(responseBytes > 0, "responseBytes must be positive")
        precondition(inputTextBytes > 0, "inputTextBytes must be positive")
        self.sourceBytes = sourceBytes
        self.heapBytes = heapBytes
        self.durationMilliseconds = durationMilliseconds
        self.computeMilliseconds = computeMilliseconds
        self.requestCount = requestCount
        self.responseBytes = responseBytes
        self.inputTextBytes = inputTextBytes
    }

    var cLimits: songyan_script_limits {
        var limits = songyan_script_limits()
        limits.source_bytes = sourceBytes
        limits.heap_bytes = heapBytes
        limits.duration_ms = durationMilliseconds
        limits.compute_ms = computeMilliseconds
        limits.request_count = requestCount
        limits.response_bytes = responseBytes
        limits.input_text_bytes = inputTextBytes
        return limits
    }
}

/// A failure the shared bridge reported. Script errors keep the script's own words, so the panel can
/// show them after the tool title; the other cases carry fixed localized copy.
enum ScriptToolError: Error, LocalizedError, Equatable, Sendable {
    case invalidHeader(line: Int, message: String)
    case unsupportedApiVersion(line: Int, message: String)
    case capabilityUnavailable
    case timedOut
    case outOfMemory
    case addressNotAllowed
    case networkFailure
    /// The script declares @connect hosts and the keyboard has no Full Access.
    case fullAccessRequired
    case requestLimitExceeded
    case responseTooLarge
    case fetchTimedOut
    /// A declared secret could not be read back from the shared Keychain group.
    case secretsUnavailable
    case script(line: Int, message: String)
    case invalidConfiguration(message: String)
    case engineUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidHeader(let line, _):
            let base = String(localized: "脚本开头格式有误")
            return line > 0 ? base + String(format: String(localized: "（第 %lld 行）"), line) : base
        case .unsupportedApiVersion:
            // Distinct from a malformed header: the script is fine but needs a newer app.
            return String(localized: "这个脚本需要更新版本的松烟。请先更新松烟。")
        case .capabilityUnavailable, .invalidConfiguration, .engineUnavailable:
            return String(localized: "这台设备上不可用")
        case .timedOut, .fetchTimedOut:
            return String(localized: "运行超时")
        case .outOfMemory:
            return String(localized: "脚本占用内存过多")
        case .addressNotAllowed:
            return String(localized: "这个脚本不能连接这个地址")
        case .networkFailure:
            return String(localized: "网络连接失败，请重试")
        case .fullAccessRequired:
            // User-visible because it names the setting the user has to change. A localized key
            // keeps the fixed prompt out of the raw-literal gate; the key itself is the Chinese copy
            // until the catalog supplies translations.
            return String(
                localized: "这个脚本需要联网。请到「设置」>「通用」>「键盘」中允许松烟完全访问后重试。")
        case .requestLimitExceeded:
            return String(localized: "请求次数超过上限")
        case .responseTooLarge:
            return String(localized: "服务器返回的内容太大")
        case .secretsUnavailable:
            // User-visible: the script cannot run safely without the value the user filled in.
            return String(
                localized: "无法读取这个脚本的密钥。请到「松烟」中重新填写该脚本的密钥后再试。")
        case .script(_, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return String(localized: "脚本运行出错") }
            return String(format: String(localized: "脚本返回了错误：%@"), trimmed)
        }
    }

    /// How this error surfaces in ToolKit's session. A script's own words and the out-of-memory
    /// diagnostic become toolError, while the engine deadline keeps ToolFailure.timedOut.
    var toolFailure: ToolFailure {
        switch self {
        case .timedOut: return .timedOut
        default: return .toolError(message: errorDescription)
        }
    }

    /// Whether the session will show this as the tool's own error rather than as no result.
    var toolFailureIsToolError: Bool {
        if case .toolError = toolFailure { return true }
        return false
    }

    /// A host-side failure is more specific than the bridge's single networkFailure code, so it
    /// wins when both are available.
    static func fromHostFailure(_ failure: ScriptHostFailure) -> ScriptToolError {
        switch failure {
        case .addressNotAllowed: return .addressNotAllowed
        case .requestLimitExceeded: return .requestLimitExceeded
        case .responseTooLarge: return .responseTooLarge
        case .fetchTimedOut: return .fetchTimedOut
        case .networkFailure: return .networkFailure
        }
    }

    /// The bridge's own network diagnostics identify the request limit and the response size cap.
    static func fromNetworkFailure(message: String?) -> ScriptToolError {
        switch ScriptHostFailure.fromBridgeMessage(message) {
        case .requestLimitExceeded: return .requestLimitExceeded
        case .responseTooLarge: return .responseTooLarge
        default: return .networkFailure
        }
    }

    static func fromEngine(
        _ code: songyan_script_error, line: Int, message: String?
    ) -> ScriptToolError {
        switch code {
        case SONGYAN_SCRIPT_ERROR_TIMEOUT: return .timedOut
        case SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY: return .outOfMemory
        case SONGYAN_SCRIPT_ERROR_ADDRESS_NOT_ALLOWED: return .addressNotAllowed
        case SONGYAN_SCRIPT_ERROR_NETWORK_FAILURE: return .networkFailure  // caller refines with fromNetworkFailure
        case SONGYAN_SCRIPT_ERROR_SCRIPT: return .script(line: line, message: message ?? "")
        case SONGYAN_SCRIPT_ERROR_CAPABILITY: return .capabilityUnavailable
        case SONGYAN_SCRIPT_ERROR_HEADER: return .invalidHeader(line: line, message: message ?? "invalid header")
        case SONGYAN_SCRIPT_ERROR_API_VERSION:
            return .unsupportedApiVersion(
                line: line, message: message ?? "the script declares a newer interface version")
        default: return .invalidConfiguration(message: message ?? "unknown engine result")
        }
    }
}

/// One shared-runtime script exposed as ToolKit's TextTool. The header is parsed once (the same C
/// parser the command-line tool uses), the injected limits and text are copied per run, and the run
/// drives the real QuickJS engine. A script without @connect stays offline: a fetch() fails with
/// networkFailure. A script that declares @connect may fetch, but only its declared hosts and only
/// while the keyboard has Full Access; otherwise the run stops with the fixed Full Access prompt.
final class ScriptTextTool: TextTool, @unchecked Sendable {
    let identity: ToolIdentity
    let requiredCapabilities: ToolCapabilities

    private let source: String
    private let limits: ScriptToolRuntimeLimits
    /// The user's values of the url settings; the shared address rule allows their hosts.
    private let settingURLs: [String]
    /// The script declares a host or a url setting, so a run may go online.
    private let usesNetwork: Bool
    /// The wall-clock budget of one run: the script's @timeout, or the host's duration.
    let runTimeout: Double?
    /// Header declarations, used by the addon catalog to check confirmation and to show what the
    /// script needs. Parsed by the shared C parser in the initializer.
    let declarations: ScriptDeclarations
    /// Whether this tool instance may use the network; the runtime fingerprint uses it so a Full
    /// Access change rebuilds the tools.
    var allowsNetworking: Bool { usesNetwork && isFullAccess }
    /// Digest of everything that changes what this tool runs: the script bytes, the resolved
    /// settings (including secret values, hashed only), and the Full Access decision. The keyboard
    /// compares revisions on each appearance and rebuilds its tools when one changed.
    let revision: String
    private let settingsJSON: String?
    /// Set when a declared secret could not be read; the run then fails with the fixed prompt
    /// instead of silently running without the value the user filled in.
    private let settingsUnavailable: Bool
    private let isFullAccess: Bool
    /// Test seam only: production leaves this empty and uses the system URL loader.
    private let urlSessionProtocolClasses: [AnyClass]
    private let headerPointer: UnsafeMutablePointer<songyan_script_header>

    /// Loads a script bundled as a folder reference. The bundle is the extension's (or the test
    /// bundle's); examples/minimal.js is the shipped minimal example and is not copied per target.
    static func bundled(
        named name: String, limits: ScriptToolRuntimeLimits, isFullAccess: Bool = false,
        settingsJSON: String? = nil, settingsUnavailable: Bool = false,
        urlSessionProtocolClasses: [AnyClass] = [], bundle: Bundle = Bundle(for: ScriptTextTool.self)
    ) throws -> ScriptTextTool {
        guard let url = bundle.resourceURL?.appendingPathComponent("examples/\(name)") else {
            throw ScriptToolError.invalidConfiguration(message: "no bundle resource for \(name)")
        }
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ScriptToolError.invalidConfiguration(
                message: "cannot read examples/\(name): \(error.localizedDescription)")
        }
        return try ScriptTextTool(
            source: source, id: "script.\(name)", limits: limits, isFullAccess: isFullAccess,
            settingsJSON: settingsJSON, settingsUnavailable: settingsUnavailable,
            urlSessionProtocolClasses: urlSessionProtocolClasses)
    }

    init(
        source: String, id: String, limits: ScriptToolRuntimeLimits, isFullAccess: Bool = false,
        settingsJSON: String? = nil, settingsUnavailable: Bool = false,
        urlSessionProtocolClasses: [AnyClass] = []
    ) throws {
        var header = songyan_script_header()
        var error = songyan_script_header_error()
        let sourceBytes = Array(source.utf8)
        let code = sourceBytes.withUnsafeBytes { raw -> songyan_script_error in
            let pointer = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
            return songyan_script_header_parse(pointer, sourceBytes.count, &header, &error)
        }
        guard code == SONGYAN_SCRIPT_OK, header.name != nil else {
            let line = Int(error.line)
            // error.message is a fixed C array (imported as a tuple), so decode up to the first NUL.
            let bytes = withUnsafeBytes(of: error.message) { raw in
                Array(raw.prefix { $0 != 0 })
            }
            let message = String(decoding: bytes, as: UTF8.self)
            throw ScriptToolError.fromEngine(code, line: line, message: message)
        }
        let pointer = UnsafeMutablePointer<songyan_script_header>.allocate(capacity: 1)
        pointer.initialize(to: header)
        self.headerPointer = pointer
        self.source = source
        self.limits = limits
        self.isFullAccess = isFullAccess
        self.settingsJSON = settingsJSON
        self.settingsUnavailable = settingsUnavailable
        self.urlSessionProtocolClasses = urlSessionProtocolClasses
        self.declarations = Self.declarations(from: header)
        var hasher = SHA256()
        hasher.update(data: Data(source.utf8))
        hasher.update(data: Data("\u{0}".utf8))
        hasher.update(data: Data((settingsJSON ?? "{}").utf8))
        hasher.update(data: Data("\u{0}".utf8))
        hasher.update(data: Data((isFullAccess ? "network" : "offline").utf8))
        hasher.update(data: Data("\u{0}".utf8))
        hasher.update(data: Data(id.utf8))
        self.revision = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let urlKeys = Set(declarations.settings.filter { $0.kind == .url }.map(\.key))
        let values =
            (settingsJSON?.data(using: .utf8)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
        self.settingURLs = urlKeys.sorted().compactMap { values[$0] as? String }
        self.usesNetwork = header.connect_count > 0 || !urlKeys.isEmpty
        var engineLimits = limits.cLimits
        // A little past the engine's own deadline, so the engine reports the timeout itself.
        self.runTimeout = Double(songyan_script_run_duration_ms(&header, &engineLimits)) / 1000 + 1
        self.identity = ToolIdentity(id: id, title: String(cString: header.name))
        var capabilities: ToolCapabilities = []
        if header.needs & UInt32(SONGYAN_SCRIPT_CAPABILITY_TEXT.rawValue) != 0 {
            capabilities.insert(.text)
        }
        if header.needs & UInt32(SONGYAN_SCRIPT_CAPABILITY_AUDIO.rawValue) != 0 {
            capabilities.insert(.audio)
        }
        self.requiredCapabilities = capabilities
    }

    deinit {
        songyan_script_header_free(headerPointer)
        headerPointer.deinitialize(count: 1)
        headerPointer.deallocate()
    }

    /// Runs the script on one background thread. QuickJS is single-threaded, so create, every step
    /// and destroy happen on that thread; only plain values cross back. The caller (normally the
    /// keyboard's MainActor) is free while the engine works, so the panel keeps publishing instead
    /// of blocking up to the duration limit.
    ///
    /// Cancellation is cooperative and observed only between steps: a synchronous step (one JS
    /// execution slice) cannot be interrupted from outside. The cancel side writes a flag only; the
    /// engine thread reads it and destroys the runtime itself, because the shared C API is never
    /// called from two threads.
    func run(input: ToolInput) async throws -> [String] {
        try Task.checkCancellation()
        // Refuse before the engine starts: a networking script without Full Access gets the fixed
        // prompt naming the setting, and an offline script is unaffected.
        if usesNetwork && !isFullAccess { throw ScriptToolError.fullAccessRequired }
        if settingsUnavailable { throw ScriptToolError.secretsUnavailable }
        let sourceBytes = Array(source.utf8)
        let textBytes = Array(input.text.utf8)
        let cancellation = ScriptRunCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let outputs = try self.execute(
                            sourceBytes: sourceBytes, textBytes: textBytes,
                            cancellation: cancellation)
                        continuation.resume(returning: outputs)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func execute(
        sourceBytes: [UInt8], textBytes: [UInt8], cancellation: ScriptRunCancellation
    ) throws -> [String] {
        let hostContext = ScriptFetchHostContext(
            header: UnsafePointer(headerPointer), settingURLs: settingURLs,
            requestLimit: limits.requestCount,
            responseLimit: limits.responseBytes, cancellation: cancellation,
            protocolClasses: urlSessionProtocolClasses)
        defer { hostContext.releaseAllocations() }
        // config.settings_json carries no length: the bridge reads it as a NUL-terminated string.
        let settingsBytes = Array((settingsJSON ?? "{}").utf8) + [0]
        return try sourceBytes.withUnsafeBytes { sourceRaw in
            try textBytes.withUnsafeBytes { textRaw in
                var limits = self.limits.cLimits
                return try settingsBytes.withUnsafeBytes { settingsRaw in
                    try withUnsafePointer(to: &limits) { limitsPointer in
                        var config = songyan_script_run_config()
                        config.source = sourceRaw.baseAddress?.assumingMemoryBound(to: CChar.self)
                        config.source_length = sourceBytes.count
                        config.header = UnsafePointer(headerPointer)
                        config.host_capabilities = UInt32(SONGYAN_SCRIPT_CAPABILITY_TEXT.rawValue)
                        config.limits = limitsPointer
                        config.settings_json =
                            settingsRaw.baseAddress?.assumingMemoryBound(to: CChar.self)
                        if textBytes.isEmpty {
                            config.text = nil
                            config.text_length = 0
                        } else {
                            config.text = textRaw.baseAddress?.assumingMemoryBound(to: CChar.self)
                            config.text_length = textBytes.count
                        }
                        config.audio = nil
                        config.audio_length = 0
                        config.host = ScriptFetchHost.make(hostContext)
                        return try Self.executeRun(
                            config: &config, cancellation: cancellation, host: hostContext)
                    }
                }
            }
        }
    }

    /// Mirrors the shared parser's header into ScriptAddonKit's value type, so the catalog can
    /// check the confirmation digest against what the user confirmed.
    private static func declarations(from header: songyan_script_header) -> ScriptDeclarations {
        let hosts = (0..<Int(header.connect_count)).map { String(cString: header.connects[$0]!) }
        let settings = (0..<Int(header.setting_count)).map { index -> ScriptDeclarations.Setting in
            let setting = header.settings[index]
            let kind: ScriptDeclarations.SettingKind =
                switch setting.kind {
                case SONGYAN_SCRIPT_SETTING_URL: .url
                case SONGYAN_SCRIPT_SETTING_CHOICE: .choice
                default: .text
                }
            let options = (0..<Int(setting.option_count)).map {
                String(cString: setting.options[$0]!)
            }
            return ScriptDeclarations.Setting(
                key: String(cString: setting.key), kind: kind,
                label: String(cString: setting.label), options: options)
        }
        let secrets = (0..<Int(header.secret_count)).map { index in
            ScriptDeclarations.Secret(
                key: String(cString: header.secrets[index].key),
                label: String(cString: header.secrets[index].label))
        }
        return ScriptDeclarations(
            apiVersion: Int(header.api), name: String(cString: header.name),
            summary: header.description.map { String(cString: $0) }, connectHosts: hosts,
            settings: settings, secrets: secrets,
            needsAudio: header.needs & UInt32(SONGYAN_SCRIPT_CAPABILITY_AUDIO.rawValue) != 0,
            timeoutSeconds: header.timeout_seconds > 0 ? Int(header.timeout_seconds) : nil)
    }

    private static func executeRun(
        config: inout songyan_script_run_config, cancellation: ScriptRunCancellation,
        host: ScriptFetchHostContext
    ) throws -> [String] {
        guard let run = songyan_script_run_create(&config) else {
            throw ScriptToolError.outOfMemory
        }
        defer { songyan_script_run_destroy(run) }
        var invalidStep = false
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            let step = songyan_script_run_step(run)
            if step == SONGYAN_SCRIPT_STEP_RUNNING {
                // RUNNING only means the engine still has queued work; the engine's own duration
                // interrupt ends a script that never finishes. Keep driving it.
                continue
            }
            if step == SONGYAN_SCRIPT_STEP_PENDING {
                // The host answers fetch synchronously, so a pending step means the bridge could
                // not get an answer from it.
                throw ScriptToolError.networkFailure
            }
            if step == SONGYAN_SCRIPT_STEP_INVALID {
                // The bridge rejected the configuration (source/input over a limit, a missing
                // limit, an invalid header for the run) and puts the reason in result.message.
                // Dropping this step would deliver an empty result list to the session, which
                // reports "no result" instead of the real cause.
                invalidStep = true
            }
            if step == SONGYAN_SCRIPT_STEP_CANCELLED { throw CancellationError() }
            break
        }
        if cancellation.isCancelled { throw CancellationError() }
        guard let resultPointer = songyan_script_run_result_get(run) else {
            throw ScriptToolError.engineUnavailable
        }
        let result = resultPointer.pointee
        let message = result.message.map { String(cString: $0) }
        if invalidStep {
            throw ScriptToolError.invalidConfiguration(
                message: message ?? "the run was rejected by the injected configuration")
        }
        guard result.error == SONGYAN_SCRIPT_OK else {
            // The host's own reason is more specific than the bridge's networkFailure code.
            if let failure = host.recordedFailure {
                throw ScriptToolError.fromHostFailure(failure)
            }
            if result.error == SONGYAN_SCRIPT_ERROR_NETWORK_FAILURE {
                throw ScriptToolError.fromNetworkFailure(message: message)
            }
            throw ScriptToolError.fromEngine(result.error, line: Int(result.line), message: message)
        }
        guard let outputs = result.outputs, let lengths = result.output_lengths else { return [] }
        return (0..<result.output_count).map { index in
            guard let bytes = outputs[index] else { return "" }
            let buffer = UnsafeBufferPointer(
                start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self),
                count: lengths[index])
            return String(decoding: buffer, as: UTF8.self)
        }
    }
}

/// Host policy for the in-extension runtime. The engine limits are the shared contract's shipped
/// values; the session's timeout matches their default duration and each script tool may extend it
/// with @timeout.
struct ScriptToolConfiguration: Sendable {
    let toolLimits: ToolLimits
    let runtimeLimits: ScriptToolRuntimeLimits

    static let shipped = ScriptToolConfiguration(
        toolLimits: ToolLimits(
            maximumInputUnits: 20_000,
            runTimeout: Double(SONGYAN_SCRIPT_SHIPPED_DURATION_MS) / 1000 + 1,
            undoWindow: 30, maximumResults: 3),
        runtimeLimits: .shipped)
}

enum ScriptToolRuntime {
}
