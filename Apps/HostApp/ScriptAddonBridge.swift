import Foundation
import ScriptAddonKit

/// Host app marshalling for the shared C script runtime (Tools/Script): the same header
/// parser, the same pinned QuickJS build and the same network host the keyboard extension
/// uses. Nothing here parses JavaScript or runs an engine of its own.
struct ScriptAddonBridge: Sendable {
    enum BridgeError: Error, Equatable {
        case invalidConfiguration
        case header(message: String, line: Int)
        case runtime(message: String, line: Int)
        case cancelled
    }

    /// Cancels a try run from the UI; the same flag the keyboard's runs and fetches observe.
    typealias RunCancellation = ScriptRunCancellation

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

    /// Runs once for the editor's try box, the way the keyboard runs it: the real header (so a
    /// declared @timeout counts), the shared address rule and the same network host, so a script
    /// that reaches the user's service here reaches it from the keyboard too. Console lines are
    /// collected and the thrown error's line comes from the shared result.
    func tryRun(
        source: Data, inputText: String?, settingsJSON: String?, limits: ScriptAddonLimits,
        cancellation: RunCancellation? = nil, onLog: @Sendable (String) -> Void
    ) throws -> TryRunResult {
        guard limits.isRunnable else { throw BridgeError.invalidConfiguration }
        let declarations = try parseDeclarations(source: source)
        let engineLimits = songyan_script_limits(
            source_bytes: limits.sourceBytes, heap_bytes: limits.heapBytes,
            duration_ms: limits.durationMilliseconds, compute_ms: limits.computeMilliseconds,
            request_count: limits.requestCount,
            response_bytes: limits.responseBytes, input_text_bytes: limits.maximumInputTextBytes)
        let engine = try Engine(source: source, limits: engineLimits)
        let values =
            (settingsJSON?.data(using: .utf8)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
        let settingURLs = declarations.settings.filter { $0.kind == .url }.compactMap {
            values[$0.key] as? String
        }
        let context = ScriptFetchHostContext(
            header: engine.header, settingURLs: settingURLs, requestLimit: limits.requestCount,
            responseLimit: limits.responseBytes, cancellation: cancellation ?? RunCancellation())
        let collector = LogCollector()
        context.onLog = { collector.lines.append($0) }
        defer { context.releaseAllocations() }
        engine.host = ScriptFetchHost.make(context)
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
                // The shared fetch host answers synchronously, so a run never waits on it here.
                throw BridgeError.runtime(message: "the run is waiting on a request", line: 0)
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
            let options = (0..<Int(setting.option_count)).map {
                String(cString: setting.options[$0]!)
            }
            return ScriptDeclarations.Setting(
                key: String(cString: setting.key), kind: kind,
                label: String(cString: setting.label), options: options)
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

    fileprivate static func text(_ failure: songyan_script_header_error) -> String {
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
        let header: UnsafeMutablePointer<songyan_script_header>
        private let limits: songyan_script_limits
        var host = songyan_script_host()

        init(source: Data, limits: songyan_script_limits) throws {
            self.header = .allocate(capacity: 1)
            self.limits = limits
            var value = songyan_script_header()
            var failure = songyan_script_header_error()
            let status = source.withUnsafeBytes { raw in
                songyan_script_header_parse(
                    raw.bindMemory(to: CChar.self).baseAddress, source.count, &value, &failure)
            }
            header.initialize(to: value)
            guard status == SONGYAN_SCRIPT_OK else {
                throw BridgeError.header(message: ScriptAddonBridge.text(failure), line: Int(failure.line))
            }
        }

        deinit {
            songyan_script_header_free(header)
            header.deinitialize(count: 1)
            header.deallocate()
        }

        func makeRun(source: Data, inputText: String, settingsJSON: String) -> OpaquePointer? {
            var limits = limits
            let pointer = UnsafePointer(header)
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
