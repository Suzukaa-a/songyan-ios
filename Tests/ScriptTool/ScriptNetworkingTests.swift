import Foundation
import ToolKit
import XCTest

/// The transport double for the networking tests: a URLProtocol installed into the tool's real
/// URLSession. The request path (URLSession, redirects, size cap, cancellation) is production code;
/// only the bytes on the wire are local.
final class ScriptNetworkingURLProtocol: URLProtocol {
    struct Route {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "text/plain"]
        var body = Data()
        var redirect: String?
        var delay: TimeInterval = 0
    }

    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func reset() {
        lock.lock()
        routes = [:]
        recorded = []
        lock.unlock()
    }

    static func route(_ path: String, _ route: Route) {
        lock.lock()
        routes[path] = route
        lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private static func route(for path: String) -> Route? {
        lock.lock()
        defer { lock.unlock() }
        return routes[path]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        Self.lock.unlock()
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let route = Self.route(for: url.path) ?? Route(status: 404)
        if let location = route.redirect, let target = URL(string: location) {
            var redirectRequest = request
            redirectRequest.url = target
            client?.urlProtocol(
                self, wasRedirectedTo: redirectRequest,
                redirectResponse: HTTPURLResponse(
                    url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": location])!)
            stopLoading()
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: route.status, httpVersion: "HTTP/1.1",
            headerFields: route.headers)!
        let deliver = { [weak self] in
            guard let self, let client = self.client else { return }
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: route.body)
            client.urlProtocolDidFinishLoading(self)
        }
        if route.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + route.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}

final class ScriptNetworkingTests: XCTestCase {
    private func limits(
        requestCount: UInt32 = 2, responseBytes: Int = 65_536, durationMilliseconds: UInt32 = 2_000
    ) -> ScriptToolRuntimeLimits {
        ScriptToolRuntimeLimits(
            sourceBytes: 262_144, heapBytes: 8_388_608, durationMilliseconds: durationMilliseconds,
            computeMilliseconds: 4_000,
            requestCount: requestCount, responseBytes: responseBytes, inputTextBytes: 65_536)
    }

    private func source(url: String, extra: String = "") -> String {
        """
        // @api 1
        // @name 联网
        // @connect api.example.test
        export default async ({ text }) => {
            \(extra)
            const response = await fetch("\(url)");
            return await response.text();
        };
        """
    }

    private func makeTool(
        _ source: String, limits: ScriptToolRuntimeLimits? = nil, isFullAccess: Bool = true
    ) throws -> ScriptTextTool {
        try ScriptTextTool(
            source: source, id: "script.network", limits: limits ?? self.limits(),
            isFullAccess: isFullAccess,
            urlSessionProtocolClasses: [ScriptNetworkingURLProtocol.self])
    }

    override func setUp() {
        super.setUp()
        ScriptNetworkingURLProtocol.reset()
    }

    func testDeclaredHostFetchReachesTheDocumentWriteBack() async throws {
        ScriptNetworkingURLProtocol.route(
            "/data", .init(body: Data("从网络返回".utf8)))
        let tool = try makeTool(source(url: "https://api.example.test/data"))
        let proxy = FakeToolTextDocumentProxy(text: "文字")
        let gateway = ToolDocumentGateway(
            proxy: proxy, sessionID: UUID().uuidString,
            limits: ToolLimits(
                maximumInputUnits: 20_000, runTimeout: 4, undoWindow: 30, maximumResults: 3))
        guard case .run(let request) = gateway.start(tool: tool, now: 0) else {
            return XCTFail("the session did not start the tool")
        }
        let results = try await tool.run(input: request.input)
        XCTAssertEqual(results, ["从网络返回"])
        XCTAssertEqual(ScriptNetworkingURLProtocol.requests.count, 1)
        XCTAssertEqual(ScriptNetworkingURLProtocol.requests.first?.url?.host, "api.example.test")
        XCTAssertTrue(gateway.complete(results, token: request.runToken, now: 0.1))
        let write = gateway.replace(now: 0.2)
        XCTAssertTrue(gateway.apply(write, at: 0.2))
        XCTAssertEqual(proxy.visibleText, "从网络返回")
    }

    func testUndeclaredHostIsRefusedBeforeAnyTransport() async throws {
        let tool = try makeTool(source(url: "https://evil.example.test/data"))
        do {
            _ = try await tool.run(
                input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
            XCTFail("an undeclared host should have been refused")
        } catch let error as ScriptToolError {
            XCTAssertEqual(error, .addressNotAllowed)
            XCTAssertEqual(error.toolFailure, .toolError(message: error.errorDescription))
        }
        XCTAssertTrue(ScriptNetworkingURLProtocol.requests.isEmpty)
    }

    /// The user's own service: a host typed into a url setting is reachable without @connect,
    /// and plain http to it works only because it is on the local network.
    func testHostTypedIntoAUrlSettingIsReachable() async throws {
        ScriptNetworkingURLProtocol.route("/api", .init(body: Data("自建服务".utf8)))
        let source = """
            // @api 1
            // @name 自建服务
            // @setting endpoint url 服务地址
            export default async ({ settings }) => {
                const response = await fetch(settings.endpoint + "/api");
                return await response.text();
            };
            """
        let tool = try ScriptTextTool(
            source: source, id: "script.own", limits: limits(), isFullAccess: true,
            settingsJSON: #"{"endpoint":"http://192.168.1.20:11434"}"#,
            urlSessionProtocolClasses: [ScriptNetworkingURLProtocol.self])
        XCTAssertTrue(tool.allowsNetworking)
        let outputs = try await tool.run(
            input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
        XCTAssertEqual(outputs, ["自建服务"])
    }

    func testPublicHostTypedIntoAUrlSettingNeedsHttps() async throws {
        let source = """
            // @api 1
            // @name 自建服务
            // @setting endpoint url 服务地址
            export default async ({ settings }) => (await fetch(settings.endpoint)).text();
            """
        let tool = try ScriptTextTool(
            source: source, id: "script.own", limits: limits(), isFullAccess: true,
            settingsJSON: #"{"endpoint":"http://llm.example.test/v1"}"#,
            urlSessionProtocolClasses: [ScriptNetworkingURLProtocol.self])
        do {
            _ = try await tool.run(
                input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
            XCTFail("plain http to a public host should have been refused")
        } catch let error as ScriptToolError {
            XCTAssertEqual(error, .addressNotAllowed)
        }
        XCTAssertTrue(ScriptNetworkingURLProtocol.requests.isEmpty)
    }

    /// A declared @timeout outlasts the host duration, and the session gets the same budget.
    func testDeclaredTimeoutOutlastsTheHostDuration() async throws {
        ScriptNetworkingURLProtocol.route(
            "/slow", .init(body: Data("慢模型".utf8), delay: 0.4))
        let source = """
            // @api 1
            // @name 慢模型
            // @connect api.example.test
            // @timeout 5
            export default async () => (await fetch("https://api.example.test/slow")).text();
            """
        let tool = try makeTool(source, limits: limits(durationMilliseconds: 150))
        XCTAssertEqual(tool.runTimeout, 6)
        let outputs = try await tool.run(
            input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
        XCTAssertEqual(outputs, ["慢模型"])
    }

    func testRedirectToUndeclaredHostIsRefused() async throws {
        ScriptNetworkingURLProtocol.route(
            "/redirect", .init(redirect: "https://evil.example.test/data"))
        let tool = try makeTool(source(url: "https://api.example.test/redirect"))
        do {
            _ = try await tool.run(
                input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
            XCTFail("a redirect to an undeclared host should have been refused")
        } catch let error as ScriptToolError {
            XCTAssertEqual(error, .addressNotAllowed)
        }
    }

    func testResponseOverTheInjectedLimit() async throws {
        ScriptNetworkingURLProtocol.route(
            "/data", .init(body: Data(repeating: 0x61, count: 200)))
        let tool = try makeTool(
            source(url: "https://api.example.test/data"), limits: limits(responseBytes: 16))
        do {
            _ = try await tool.run(
                input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
            XCTFail("an oversized response should have been refused")
        } catch let error as ScriptToolError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testRequestCountOverTheInjectedLimit() async throws {
        ScriptNetworkingURLProtocol.route("/data", .init(body: Data("ok".utf8)))
        let tool = try makeTool(
            source(
                url: "https://api.example.test/data",
                extra: "await fetch(\"https://api.example.test/data\");"),
            limits: limits(requestCount: 1))
        do {
            _ = try await tool.run(
                input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
            XCTFail("the second request should have been refused")
        } catch let error as ScriptToolError {
            XCTAssertEqual(error, .requestLimitExceeded)
        }
    }

    func testNetworkingScriptWithoutFullAccessShowsTheSettingPrompt() async throws {
        let tool = try makeTool(
            source(url: "https://api.example.test/data"), isFullAccess: false)
        do {
            _ = try await tool.run(
                input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
            XCTFail("a networking script without Full Access should have been refused")
        } catch let error as ScriptToolError {
            XCTAssertEqual(error, .fullAccessRequired)
            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(message.contains("完全访问"), message)
        }
        XCTAssertTrue(ScriptNetworkingURLProtocol.requests.isEmpty)
    }

    func testOfflineScriptStillRunsWithoutFullAccess() async throws {
        let tool = try ScriptTextTool(
            source: """
                // @api 1
                // @name 离线
                export default async ({ text }) => text + "!";
                """, id: "script.offline", limits: limits(), isFullAccess: false)
        let results = try await tool.run(
            input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
        XCTAssertEqual(results, ["文字!"])
    }

    func testFetchTimeoutUsesTheRunBudget() async throws {
        ScriptNetworkingURLProtocol.route(
            "/slow", .init(body: Data("late".utf8), delay: 1.0))
        let tool = try makeTool(
            source(url: "https://api.example.test/slow"),
            limits: limits(durationMilliseconds: 120))
        do {
            _ = try await tool.run(
                input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
            XCTFail("the slow response should have hit the run budget")
        } catch let error as ScriptToolError {
            XCTAssertEqual(error, .fetchTimedOut)
        }
    }
}
