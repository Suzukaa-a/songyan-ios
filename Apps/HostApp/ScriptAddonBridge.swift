import Foundation
import ScriptAddonKit

/// Host app marshalling for the shared C script runtime (Tools/Script): the same header
/// parser and the same pinned QuickJS build the keyboard extension uses. Nothing here
/// parses JavaScript or runs an engine of its own. HostApp links those C sources and
/// includes their headers in its bridging header (project registration pending).
struct ScriptAddonBridge: Sendable {
    enum BridgeError: Error, Equatable {
        case invalidConfiguration
        case header(message: String, line: Int)
        case runtime(message: String, line: Int)
        case cancelled
    }

    /// Cancels a try run from the UI. The engine loop reads this flag between steps and calls
    /// the shared runtime's own cancel; the C API is never called from two threads.
    final class RunCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    struct TryRunResult: Equatable {
        var outputs: [String]
        var logs: [String]
        var errorMessage: String?
        var errorLine: Int?
    }

    // MARK: - Header

    func parseDeclarations(source: Data) throws -> ScriptDeclarations {
        var header = songyan_script_header()
        var failure = songyan_script_header_error()
        let bytes = [UInt8](source) + [0]
        let status: songyan_script_error = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                songyan_script_header_parse($0, source.count, &header, &failure)
            }
        }
        guard status == SONGYAN_SCRIPT_OK else {
            songyan_script_header_free(&header)
            throw BridgeError.header(message: Self.text(failure), line: Int(failure.line))
        }
        defer { songyan_script_header_free(&header) }
        return Self.declarations(from: header)
    }

    // MARK: - Try run

    /// Runs once for the editor's try box. No network callbacks are supplied, so fetch
    /// fails with networkFailure instead of opening a socket; console lines are collected
    /// and the thrown error's line comes from the shared result.
    func tryRun(
        source: Data, inputText: String?, settingsJSON: String?, limits: ScriptAddonLimits,
        cancellation: RunCancellation? = nil, onLog: @Sendable (String) -> Void
    ) throws -> TryRunResult {
        guard limits.isRunnable else { throw BridgeError.invalidConfiguration }
        let declarations = try parseDeclarations(source: source)
        let engineLimits = songyan_script_limits(
            source_bytes: limits.sourceBytes, heap_bytes: limits.heapBytes,
            duration_ms: limits.durationMilliseconds, request_count: limits.requestCount,
            response_bytes: limits.responseBytes, input_text_bytes: limits.maximumInputTextBytes)
        let collector = LogCollector()
        let host = songyan_script_host(
            userdata: Unmanaged.passUnretained(collector).toOpaque(), authorize: nil, fetch: nil,
            log: { userdata, text, length in
                guard let userdata, let text else { return }
                let raw = UnsafeRawBufferPointer(start: text, count: length)
                let line = String(decoding: raw.bindMemory(to: UInt8.self), as: UTF8.self)
                Unmanaged<LogCollector>.fromOpaque(userdata).takeUnretainedValue().lines.append(line)
            })
        let engine = Engine(declarations: declarations, limits: engineLimits, host: host)
        guard
            let run = engine.makeRun(
                source: source, inputText: inputText ?? "", settingsJSON: settingsJSON ?? "{}")
        else { throw BridgeError.invalidConfiguration }
        defer { songyan_script_run_destroy(run) }
        for _ in 0..<100_000 {
            if cancellation?.isCancelled == true {
                songyan_script_run_cancel(run)
            }
            switch songyan_script_run_step(run) {
            case SONGYAN_SCRIPT_STEP_RUNNING:
                continue
            case SONGYAN_SCRIPT_STEP_DONE:
                var result = songyan_script_run_result()
                songyan_script_run_result_take(run, &result)
                defer { songyan_script_run_result_free(&result) }
                let outputs = Self.strings(result)
                collector.lines.forEach(onLog)
                return TryRunResult(
                    outputs: outputs, logs: collector.lines,
                    errorMessage: result.message.map { String(cString: $0) },
                    errorLine: result.line > 0 ? Int(result.line) : nil)
            case SONGYAN_SCRIPT_STEP_FAILED, SONGYAN_SCRIPT_STEP_INVALID:
                var failure = songyan_script_run_result()
                songyan_script_run_result_take(run, &failure)
                defer { songyan_script_run_result_free(&failure) }
                throw BridgeError.runtime(
                    message: failure.message.map { String(cString: $0) } ?? "script failed",
                    line: Int(failure.line))
            case SONGYAN_SCRIPT_STEP_CANCELLED:
                throw BridgeError.cancelled
            default:
                throw BridgeError.runtime(
                    message: "network access is not available in the try box", line: 0)
            }
        }
        throw BridgeError.runtime(message: "the run did not finish", line: 0)
    }

    // MARK: - Marshalling

    private static func declarations(from header: songyan_script_header) -> ScriptDeclarations {
        let hosts = (0..<header.connect_count).map { String(cString: header.connects[$0]!) }
        let settings = (0..<header.setting_count).map { index -> ScriptDeclarations.Setting in
            let setting = header.settings[index]
            let kind: ScriptDeclarations.SettingKind =
                switch setting.kind {
                case SONGYAN_SCRIPT_SETTING_URL: .url
                case SONGYAN_SCRIPT_SETTING_CHOICE: .choice
                default: .text
                }
            return ScriptDeclarations.Setting(
                key: String(cString: setting.key), kind: kind,
                label: String(cString: setting.label))
        }
        let secrets = (0..<header.secret_count).map { index in
            ScriptDeclarations.Secret(
                key: String(cString: header.secrets[index].key),
                label: String(cString: header.secrets[index].label))
        }
        return ScriptDeclarations(
            apiVersion: Int(header.api), name: String(cString: header.name),
            summary: header.description.map { String(cString: $0) }, connectHosts: hosts,
            settings: settings, secrets: secrets,
            needsAudio: header.needs & SONGYAN_SCRIPT_CAPABILITY_AUDIO.rawValue != 0)
    }

    private static func text(_ failure: songyan_script_header_error) -> String {
        var failure = failure
        return withUnsafePointer(to: &failure.message) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }

    private static func strings(_ result: songyan_script_run_result) -> [String] {
        (0..<result.output_count).map { index in
            guard let pointer = result.outputs?[index] else { return "" }
            let length = result.output_lengths?[index] ?? 0
            let raw = UnsafeRawBufferPointer(start: pointer, count: length)
            return String(decoding: raw.bindMemory(to: UInt8.self), as: UTF8.self)
        }
    }

    private final class LogCollector {
        var lines: [String] = []
    }

    /// Owns the C header value for the lifetime of one run, so the configuration's
    /// header pointer stays valid while the run copies what it needs.
    private final class Engine {
        private let headerStorage: UnsafeMutablePointer<songyan_script_header>
        private let limits: songyan_script_limits
        private let host: songyan_script_host

        init(declarations: ScriptDeclarations, limits: songyan_script_limits, host: songyan_script_host) {
            self.headerStorage = .allocate(capacity: 1)
            self.limits = limits
            self.host = host
            var value = songyan_script_header()
            value.api = UInt32(declarations.apiVersion)
            value.name = strdup(declarations.name)
            value.description = declarations.summary.map { strdup($0) }
            value.needs =
                declarations.needsAudio
                ? SONGYAN_SCRIPT_CAPABILITY_AUDIO.rawValue : SONGYAN_SCRIPT_CAPABILITY_TEXT.rawValue
            headerStorage.initialize(to: value)
        }

        deinit {
            songyan_script_header_free(headerStorage)
            headerStorage.deinitialize(count: 1)
            headerStorage.deallocate()
        }

        func makeRun(source: Data, inputText: String, settingsJSON: String) -> OpaquePointer? {
            var limits = limits
            let pointer = headerStorage
            return source.withUnsafeBytes { sourceRaw in
                let sourcePointer = sourceRaw.bindMemory(to: CChar.self).baseAddress!
                return inputText.withCString { textPointer in
                    settingsJSON.withCString { settingsPointer in
                        withUnsafePointer(to: &limits) { limitsPointer in
                            var configuration = songyan_script_run_config(
                                source: sourcePointer, source_length: source.count,
                                header: pointer, host_capabilities: SONGYAN_SCRIPT_CAPABILITY_TEXT.rawValue,
                                limits: limitsPointer, settings_json: settingsPointer,
                                text: strlen(textPointer) > 0 ? textPointer : nil,
                                text_length: Int(strlen(textPointer)), audio: nil, audio_length: 0,
                                host: host)
                            return songyan_script_run_create(&configuration)
                        }
                    }
                }
            }
        }
    }
}
