import Foundation
import ScriptAddonKit
import ToolKit
import XCTest

/// In-memory secret store for the fixture: the production store is the shared Keychain group.
final class MemoryScriptSecretStore: ScriptSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    /// Simulates a Keychain read that fails (for example a missing access group).
    var failsReads = false

    init(_ values: [String: String] = [:]) { self.values = values }

    func setSecret(_ value: String, for key: String, scriptID: String) throws {
        lock.lock()
        values["\(scriptID).\(key)"] = value
        lock.unlock()
    }

    func secret(for key: String, scriptID: String) throws -> String? {
        if failsReads { throw KeychainReadFailure() }
        lock.lock()
        defer { lock.unlock() }
        return values["\(scriptID).\(key)"]
    }

    func deleteSecret(for key: String, scriptID: String) throws {
        lock.lock()
        values.removeValue(forKey: "\(scriptID).\(key)")
        lock.unlock()
    }

    func deleteAllSecrets(scriptID: String) throws {
        lock.lock()
        values = values.filter { !$0.key.hasPrefix("\(scriptID).") }
        lock.unlock()
    }
}

struct KeychainReadFailure: Error {}

/// Minimal provider for the panel-driver check: the production provider lives in the extension
/// target, but the panel only needs ToolKit's list of tools.
struct TestToolProvider: ToolToolProviding {
    var tools: [any TextTool]
}

final class ScriptAddonCatalogTests: XCTestCase {
    private var root: URL!
    private var store: ScriptAddonStore!
    private let runtimeLimits = ScriptToolRuntimeLimits(
        sourceBytes: 262_144, heapBytes: 8_388_608, durationMilliseconds: 4_000,
        requestCount: 4, responseBytes: 65_536, inputTextBytes: 65_536)
    private let sessionLimits = ToolLimits(
        maximumInputUnits: 20_000, runTimeout: 4, undoWindow: 30, maximumResults: 3)
    private var secrets: MemoryScriptSecretStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScriptAddonCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ScriptAddonStore(root: root)
        secrets = MemoryScriptSecretStore()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        ScriptNetworkingURLProtocol.reset()
        try super.tearDownWithError()
    }

    @discardableResult
    private func addScript(
        id: String, source: String, order: Int = 0, enabled: Bool = true,
        confirmed: Bool = true, settings: [String: String] = [:], secretKeys: [String] = []
    ) throws -> ScriptAddonStore.Addon {
        let parser = try ScriptTextTool(
            source: source, id: "fixture.\(id)", limits: runtimeLimits)
        var state = ScriptAddonState(id: id, order: order, scriptDigest: "", scriptByteCount: 0)
        state.enabled = enabled
        state.settings = settings
        state.secretKeys = secretKeys
        state.confirmedDigest = confirmed ? try parser.declarations.confirmationDigest() : nil
        return try store.add(
            id: id, script: Data(source.utf8), state: state, maximumSourceBytes: 1_000_000)
    }

    private func catalog(
        isFullAccess: Bool = true, urlSessionProtocols: [AnyClass] = []
    ) -> ScriptAddonCatalog {
        var catalog = ScriptAddonCatalog(
            root: root, runtimeLimits: runtimeLimits, sessionLimits: sessionLimits,
            isFullAccess: isFullAccess, secrets: secrets)
        catalog.urlSessionProtocolClasses = urlSessionProtocols
        return catalog
    }

    private func offlineSource(name: String, body: String = "return text + \"!\"") -> String {
        """
        // @api 1
        // @name \(name)
        export default async ({ text }) => { \(body); };
        """
    }

    func testOnlyEnabledConfirmedScriptsBecomeToolsInStoreOrder() throws {
        try addScript(id: "a", source: offlineSource(name: "甲"), order: 2)
        try addScript(id: "b", source: offlineSource(name: "乙"), order: 1)
        try addScript(id: "off", source: offlineSource(name: "停用"), order: 0, enabled: false)
        try addScript(id: "unconfirmed", source: offlineSource(name: "未确认"), confirmed: false)

        let result = catalog().load()
        XCTAssertEqual(result.tools.map(\.identity.id), ["script.addon.b", "script.addon.a"])
        XCTAssertEqual(result.tools.map(\.identity.title), ["乙", "甲"])
        XCTAssertEqual(
            Set(result.skipped.map(\.reason)), [.disabled, .unconfirmed])
    }

    func testFilledSettingsAreInjectedIntoTheRun() async throws {
        let source = """
            // @api 1
            // @name 带设置
            // @setting prefix text 前缀
            export default async ({ text, settings }) => settings.prefix + text;
            """
        try addScript(id: "s", source: source, settings: ["prefix": "你好"])
        let result = catalog().load()
        XCTAssertEqual(result.tools.count, 1)
        XCTAssertEqual(result.tools[0].declarations.settingKeys, ["prefix"])
        let outputs = try await result.tools[0].run(
            input: ToolInput(text: "世界", scope: .precedingSegment, isTruncated: false))
        XCTAssertEqual(outputs, ["你好世界"])
    }

    func testSecretValuesAreInjectedButNeverExposedInTheResultOrLogs() async throws {
        let source = """
            // @api 1
            // @name 密钥
            // @secret token 令牌
            export default async ({ text, settings }) => {
                console.log("token=" + settings.token);
                return settings.token + text;
            };
            """
        try addScript(id: "k", source: source, secretKeys: ["token"])
        try secrets.setSecret("s3cret", for: "token", scriptID: "k")
        let result = catalog().load()
        XCTAssertEqual(result.tools.count, 1)
        let outputs = try await result.tools[0].run(
            input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
        XCTAssertEqual(outputs, ["s3cret文字"])
        XCTAssertEqual(result.tools[0].declarations.secrets.map(\.key), ["token"])
    }

    func testDeclaredHostFetchThroughCatalogUsesTheScriptDeclaration() async throws {
        ScriptNetworkingURLProtocol.route("/data", .init(body: Data("网络文字".utf8)))
        let source = """
            // @api 1
            // @name 联网
            // @connect api.example.test
            export default async ({ text }) => {
                const response = await fetch("https://api.example.test/data");
                return await response.text();
            };
            """
        try addScript(id: "net", source: source)
        let result = catalog(urlSessionProtocols: [ScriptNetworkingURLProtocol.self]).load()
        XCTAssertEqual(result.tools.count, 1)
        let outputs = try await result.tools[0].run(
            input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
        XCTAssertEqual(outputs, ["网络文字"])
        XCTAssertEqual(ScriptNetworkingURLProtocol.requests.count, 1)
        XCTAssertEqual(ScriptNetworkingURLProtocol.requests.first?.url?.host, "api.example.test")
    }

    func testNetworkingScriptWithoutFullAccessShowsThePromptWhileOfflineScriptRuns() async throws {
        let network = """
            // @api 1
            // @name 联网
            // @connect api.example.test
            export default async ({ text }) => text;
            """
        try addScript(id: "net", source: network, order: 0)
        try addScript(id: "local", source: offlineSource(name: "离线"), order: 1)
        let result = catalog(isFullAccess: false).load()
        XCTAssertEqual(result.tools.count, 2)
        do {
            _ = try await result.tools[0].run(
                input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
            XCTFail("a networking script without Full Access should be refused")
        } catch let error as ScriptToolError {
            XCTAssertEqual(error, .fullAccessRequired)
            XCTAssertTrue(error.errorDescription?.contains("完全访问") == true)
        }
        let offline = try await result.tools[1].run(
            input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
        XCTAssertEqual(offline, ["文字!"])
        XCTAssertTrue(ScriptNetworkingURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testAudioScriptIsListedButUnavailableWhileTextScriptRemainsReady() throws {
        let audio = """
            // @api 1
            // @name 声音脚本
            // @input audio
            export default async ({ text }) => text;
            """
        try addScript(id: "audio", source: audio, order: 0)
        try addScript(id: "plain", source: offlineSource(name: "文本"), order: 1)
        let result = catalog().load()
        XCTAssertEqual(result.tools.count, 2)
        XCTAssertEqual(result.skipped.count, 0)

        let provider = TestToolProvider(tools: result.tools)
        let driver = ToolPanelDriver(
            configuration: ToolConfiguration(provider: provider, limits: sessionLimits),
            gateway: { nil })
        let entries = driver.entries
        XCTAssertEqual(entries.map(\.identity.id), ["script.addon.audio", "script.addon.plain"])
        let audioEntry = try XCTUnwrap(entries.first { $0.identity.id == "script.addon.audio" })
        XCTAssertEqual(audioEntry.availability, .missingCapabilities([.audio]))
        XCTAssertFalse(audioEntry.isAvailable)
        XCTAssertNotNil(audioEntry.unavailableText)
        let textEntry = try XCTUnwrap(entries.first { $0.identity.id == "script.addon.plain" })
        XCTAssertEqual(textEntry.availability, .ready)
        XCTAssertTrue(textEntry.isAvailable)
        XCTAssertNil(textEntry.unavailableText)

        // The row exists but the run is refused before any engine work: a text-only host cannot
        // supply the declared audio input.
        var session = ToolSession(limits: sessionLimits, sessionID: "fixture-session")
        let snapshot = ToolDocumentSnapshot(
            documentID: ToolDocumentID(rawValue: "fixture-document"), privacy: .normal,
            selectedText: nil, textBeforeCaret: "文字")
        let effect = session.start(
            tool: result.tools[0], hostCapabilities: .text, document: snapshot, now: 0)
        XCTAssertEqual(effect, .none)
        XCTAssertEqual(
            session.phase,
            .failed(.unavailable(.missingCapabilities([.audio]))))
    }

    func testUnreadableSecretIsVisibleInsteadOfSilentlyRunning() async throws {
        let source = """
            // @api 1
            // @name 密钥缺失
            // @secret token 令牌
            export default async ({ text, settings }) => settings.token + text;
            """
        try addScript(id: "missing", source: source, secretKeys: ["token"])
        secrets.failsReads = true
        let result = catalog().load()
        XCTAssertEqual(result.tools.count, 1, "the tool stays listed so the user sees the prompt")
        do {
            _ = try await result.tools[0].run(
                input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
            XCTFail("an unreadable secret must not run silently")
        } catch let error as ScriptToolError {
            XCTAssertEqual(error, .secretsUnavailable)
            XCTAssertTrue(error.errorDescription?.contains("密钥") == true)
        }
    }

    func testStaleConfirmationIsSkippedAfterDeclarationsChange() throws {
        try addScript(id: "stale", source: offlineSource(name: "甲"))
        // The script bytes changed or its declarations were edited elsewhere: the confirmed digest
        // no longer matches what the parser sees, so the catalog must ask for confirmation again.
        var state = try store.load(id: "stale").state
        state.confirmedDigest = String(repeating: "0", count: 64)
        try store.updateState(state)
        let result = catalog().load()
        XCTAssertTrue(result.tools.isEmpty)
        XCTAssertEqual(result.skipped.map(\.reason), [.declarationsChanged])
    }
}
