import Foundation
import ToolKit
import XCTest

// Real-runtime evidence for the in-extension TextTool. The engine, the shared C bridge, ToolKit's
// ToolSession and ToolDocumentGateway are the production implementations; only the document proxy is
// a double here, because a UITextDocumentProxy cannot be constructed in a unit test.

/// The one double in these tests: the document surface the gateway writes through. It models the
/// same reads/writes UIKit exposes (insertText replaces the selection; deleteBackward removes one
/// composed character) and records the visible text, so write-back is asserted on what the user
/// would see.
final class FakeToolTextDocumentProxy: ToolTextDocumentProxy {
    var documentIdentity: UUID? = UUID()
    private var characters: [Character]
    private var caret: Int
    private var selection: Range<Int>?
    var isSecureTextEntry: Bool? = false
    private(set) var insertedTexts: [String] = []
    private(set) var deleteBackwardCalls = 0

    init(text: String) {
        characters = Array(text)
        caret = characters.count
    }

    var visibleText: String { String(characters) }
    var textBeforeCaret: String? { String(characters[..<caret]) }
    var textAfterCaret: String? { String(characters[caret...]) }
    var selectedText: String? { selection.map { String(characters[$0]) } }

    func insertText(_ text: String) {
        insertedTexts.append(text)
        let inserted = Array(text)
        if let selection {
            characters.replaceSubrange(selection, with: inserted)
            caret = selection.lowerBound + inserted.count
            self.selection = nil
        } else {
            characters.insert(contentsOf: inserted, at: caret)
            caret += inserted.count
        }
    }

    func deleteBackward() {
        deleteBackwardCalls += 1
        if let selection {
            characters.removeSubrange(selection)
            caret = selection.lowerBound
            self.selection = nil
        } else if caret > 0 {
            caret -= 1
            characters.remove(at: caret)
        }
    }
}

final class ScriptToolTests: XCTestCase {
    private let runtimeLimits = ScriptToolRuntimeLimits(
        sourceBytes: 262_144, heapBytes: 8_388_608, durationMilliseconds: 4_000, computeMilliseconds: 4_000,
        requestCount: 1, responseBytes: 65_536, inputTextBytes: 65_536)
    private let toolLimits = ToolLimits(
        maximumInputUnits: 20_000, runTimeout: 4.0, undoWindow: 30, maximumResults: 3)

    func testMinimalExampleRunsThroughSessionAndWritesVisibleText() async throws {
        let tool = try ScriptTextTool.bundled(named: "minimal.js", limits: runtimeLimits)
        XCTAssertEqual(tool.identity.title, "加书名号")
        XCTAssertEqual(tool.requiredCapabilities, .text)

        let proxy = FakeToolTextDocumentProxy(text: "一段测试文字")
        let gateway = ToolDocumentGateway(
            proxy: proxy, sessionID: UUID().uuidString, limits: toolLimits)

        let start = gateway.start(tool: tool, now: 0)
        guard case .run(let request) = start else {
            return XCTFail("the session did not start the tool: \(start)")
        }
        XCTAssertEqual(request.input.text, "一段测试文字")
        XCTAssertEqual(request.input.isTruncated, false)

        // The real engine executes the bundled example.
        let results = try await tool.run(input: request.input)
        XCTAssertEqual(results, ["「一段测试文字」"])

        XCTAssertTrue(gateway.complete(results, token: request.runToken, now: 0.05))
        XCTAssertEqual(gateway.preview?.results, ["「一段测试文字」"])

        let writeStart = gateway.replace(now: 0.1)
        guard case .requested(let write) = writeStart else {
            return XCTFail("the write was not requested: \(writeStart)")
        }
        XCTAssertEqual(write.text, "「一段测试文字」")
        XCTAssertTrue(gateway.apply(writeStart, at: 0.1))

        // The visible text of the (fake) proxied field is the asserted result.
        XCTAssertEqual(proxy.visibleText, "「一段测试文字」")
        XCTAssertEqual(proxy.insertedTexts, ["「一段测试文字」"])
        XCTAssertGreaterThan(proxy.deleteBackwardCalls, 0)
        guard case .wrote(let wrote) = gateway.phase else {
            return XCTFail("the session did not record the write: \(gateway.phase)")
        }
        XCTAssertEqual(wrote.request.text, "「一段测试文字」")

        // Undo goes through the same gateway and restores the visible text.
        let undoStart = gateway.undo(now: 0.2)
        XCTAssertTrue(gateway.applyUndo(undoStart, at: 0.2))
        XCTAssertEqual(proxy.visibleText, "一段测试文字")
    }

    func testScriptErrorKeepsTheScriptsOwnWords() async throws {
        let tool = try ScriptTextTool(
            source: """
                // @api 1
                // @name 出错
                export default async ({ text }) => { throw new Error("故意失败"); };
                """, id: "script.error", limits: runtimeLimits)
        let proxy = FakeToolTextDocumentProxy(text: "文字")
        let gateway = ToolDocumentGateway(
            proxy: proxy, sessionID: UUID().uuidString, limits: toolLimits)
        guard case .run(let request) = gateway.start(tool: tool, now: 0) else {
            return XCTFail("the session did not start the tool")
        }

        do {
            _ = try await tool.run(input: request.input)
            XCTFail("the script should have failed")
        } catch let error as ScriptToolError {
            guard case .script(let line, let message) = error else {
                return XCTFail("wrong mapping: \(error)")
            }
            XCTAssertGreaterThan(line, 0)
            XCTAssertTrue(message.contains("故意失败"), message)
            XCTAssertEqual(error.toolFailure, .toolError(message: error.errorDescription))
        }
    }

    func testOutOfMemoryMapsToTheEngineBudget() async throws {
        let tool = try ScriptTextTool(
            source: """
                // @api 1
                // @name 占内存
                export default async ({ text }) => {
                    const parts = [];
                    for (let index = 0; index < 200000; index++) { parts.push("填充" + index); }
                    return [parts.join("")];
                };
                """, id: "script.memory",
            limits: ScriptToolRuntimeLimits(
                sourceBytes: 262_144, heapBytes: 1_048_576, durationMilliseconds: 4_000, computeMilliseconds: 4_000,
                requestCount: 1, responseBytes: 65_536, inputTextBytes: 65_536))
        do {
            _ = try await tool.run(
                input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
            XCTFail("the script should have exhausted the heap")
        } catch let error as ScriptToolError {
            XCTAssertEqual(error, .outOfMemory)
            XCTAssertEqual(error.toolFailure, .toolError(message: error.errorDescription))
        }
    }

    func testEveryFixedErrorIsLocalizedCopyNotAnEnglishDiagnostic() {
        let fixed: [ScriptToolError] = [
            .capabilityUnavailable, .timedOut, .outOfMemory, .addressNotAllowed, .networkFailure,
            .requestLimitExceeded, .responseTooLarge, .fetchTimedOut, .invalidConfiguration(message: "x"),
            .engineUnavailable,
        ]
        for error in fixed {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(
                text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "\(error): \(text)")
        }
        XCTAssertEqual(ScriptToolError.addressNotAllowed.errorDescription, "这个脚本不能连接这个地址")
        XCTAssertEqual(ScriptToolError.networkFailure.errorDescription, "网络连接失败，请重试")
        XCTAssertEqual(ScriptToolError.timedOut.errorDescription, "运行超时")
        XCTAssertEqual(ScriptToolError.outOfMemory.errorDescription, "脚本占用内存过多")
        XCTAssertEqual(ScriptToolError.requestLimitExceeded.errorDescription, "请求次数超过上限")
        XCTAssertEqual(ScriptToolError.responseTooLarge.errorDescription, "服务器返回的内容太大")
        XCTAssertEqual(ScriptToolError.capabilityUnavailable.errorDescription, "这台设备上不可用")
        XCTAssertEqual(
            ScriptToolError.script(line: 2, message: "额度用完了").errorDescription, "额度用完了")
    }

    func testEngineDeadlineMapsToToolFailureTimedOut() async throws {
        let tool = try ScriptTextTool(
            source: """
                // @api 1
                // @name 超时
                export default async ({ text }) => { while (true) {} };
                """, id: "script.timeout",
            limits: ScriptToolRuntimeLimits(
                sourceBytes: 262_144, heapBytes: 8_388_608, durationMilliseconds: 50, computeMilliseconds: 4_000,
                requestCount: 1, responseBytes: 65_536, inputTextBytes: 65_536))
        do {
            _ = try await tool.run(
                input: ToolInput(text: "文字", scope: .precedingSegment, isTruncated: false))
            XCTFail("the script should have hit the engine deadline")
        } catch let error as ScriptToolError {
            XCTAssertEqual(error, .timedOut)
            XCTAssertEqual(error.toolFailure, .timedOut)
        }
    }
    func testUnsupportedApiVersionIsDistinctFromMalformedHeader() throws {
        let newer = """
            // @api 2
            // @name 新版本
            export default async ({ text }) => text;
            """
        do {
            _ = try ScriptTextTool(source: newer, id: "script.newer", limits: runtimeLimits)
            XCTFail("a newer @api should have been refused")
        } catch let error as ScriptToolError {
            guard case .unsupportedApiVersion(_, let message) = error else {
                return XCTFail("wrong mapping: \(error)")
            }
            let description = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(description.contains("newer script interface version"), description)
            XCTAssertTrue(description.contains("update the app"), description)
            XCTAssertNotEqual(description, ScriptToolError.invalidHeader(line: 1, message: message).errorDescription)
        }

        let malformed = """
            // @api 1
            export default async ({ text }) => text;
            """
        do {
            _ = try ScriptTextTool(source: malformed, id: "script.malformed", limits: runtimeLimits)
            XCTFail("a header without @name should have been refused")
        } catch let error as ScriptToolError {
            guard case .invalidHeader = error else { return XCTFail("wrong mapping: \(error)") }
            XCTAssertTrue(
                ScriptToolError.fromEngine(SONGYAN_SCRIPT_ERROR_HEADER, line: 1, message: "bad")
                    .errorDescription?.hasPrefix("script header:") == true)
        }
    }

    @MainActor
    func testEngineRunDoesNotBlockTheMainActor() async throws {
        let tool = try ScriptTextTool(
            source: """
                // @api 1
                // @name 慢脚本
                export default async ({ text }) => { while (true) {} };
                """, id: "script.slow",
            limits: ScriptToolRuntimeLimits(
                sourceBytes: 262_144, heapBytes: 8_388_608, durationMilliseconds: 600, computeMilliseconds: 4_000,
                requestCount: 1, responseBytes: 65_536, inputTextBytes: 65_536))
        let proxy = FakeToolTextDocumentProxy(text: "文字")
        let gateway = ToolDocumentGateway(
            proxy: proxy, sessionID: UUID().uuidString, limits: toolLimits)
        guard case .run(let request) = gateway.start(tool: tool, now: 0) else {
            return XCTFail("the session did not start the tool")
        }
        XCTAssertEqual(gateway.phase, .running)

        let startedAt = Date()
        let runTask = Task { try await tool.run(input: request.input) }
        // Suspend the main actor while the engine thread is busy. If run() were synchronous, this
        // sleep could only start after the 600 ms engine deadline and the timestamp below would be
        // late; with the background queue it happens immediately.
        try await Task.sleep(nanoseconds: 50_000_000)
        let mainActorTick = Date()
        XCTAssertEqual(gateway.phase, .running, "the running phase stays observable during the run")
        XCTAssertLessThan(
            mainActorTick.timeIntervalSince(startedAt), 0.4,
            "the main actor kept running while the engine was working")

        do {
            _ = try await runTask.value
            XCTFail("the script should have hit the engine deadline")
        } catch let error as ScriptToolError {
            XCTAssertEqual(error, .timedOut)
        }
        let finishedAt = Date()
        XCTAssertGreaterThan(finishedAt.timeIntervalSince(startedAt), 0.5)
        // The host delivers the run's outcome to the session after the result, not before it.
        XCTAssertEqual(gateway.phase, .running)
        _ = gateway.fail(
            message: "timed out", token: request.runToken,
            now: finishedAt.timeIntervalSince(startedAt))
        if case .failed(let failure) = gateway.phase {
            XCTAssertEqual(failure, .toolError(message: "timed out"))
        } else {
            XCTFail("the failure was not delivered: \(gateway.phase)")
        }
    }
    @MainActor
    func testRejectedConfigurationIsNotReportedAsNoResult() async throws {
        // A legal header whose source is larger than the injected source limit: the bridge rejects
        // the run at STEP_INVALID and carries the reason in result.message.
        let header = "// @api 1\n// @name 超长源码\n"
        let padding = "// " + String(repeating: "x", count: 262_200) + "\n"
        let source = header + padding + "export default async ({ text }) => text;\n"
        XCTAssertGreaterThan(source.utf8.count, 262_144)
        let tool = try ScriptTextTool(source: source, id: "script.oversize", limits: runtimeLimits)
        let proxy = FakeToolTextDocumentProxy(text: "文字")
        let gateway = ToolDocumentGateway(
            proxy: proxy, sessionID: UUID().uuidString, limits: toolLimits)
        guard case .run(let request) = gateway.start(tool: tool, now: 0) else {
            return XCTFail("the session did not start the tool")
        }
        do {
            _ = try await tool.run(input: request.input)
            XCTFail("the oversized source should have been rejected")
        } catch let error as ScriptToolError {
            guard case .invalidConfiguration(let message) = error else {
                return XCTFail("wrong mapping: \(error)")
            }
            XCTAssertFalse(message.isEmpty)
            // The host delivers the tool's own error, not an empty result list.
            XCTAssertNotEqual(error.toolFailure, .noResult)
            XCTAssertTrue(error.toolFailureIsToolError)
            _ = gateway.fail(
                message: error.errorDescription, token: request.runToken, now: 0.1)
            guard case .failed(let failure) = gateway.phase else {
                return XCTFail("the failure was not recorded: \(gateway.phase)")
            }
            XCTAssertNotEqual(failure, .noResult)
            guard case .toolError(let delivered) = failure else {
                return XCTFail("wrong failure: \(failure)")
            }
            XCTAssertEqual(delivered, error.errorDescription)
        }
    }
}
