import Foundation

// The panel driver protocol is declared in the SwiftUI panel file; the probe
// needs only its contract, so it is repeated here verbatim.
@MainActor
protocol ToolPanelDriving: AnyObject {
    var entries: [ToolPanelEntry] { get }
    var phase: ToolPhase { get }
    var preview: ToolPreview? { get }
    var writeBlock: ToolWriteBlock? { get }
    var undoWindow: Double? { get }
    var lastToolTitle: String? { get }
    func run(_ identity: ToolIdentity)
    func chooseResult(_ index: Int)
    func retry()
    func cancel()
    func copy() -> String?
    func replace()
    func insert()
    func undo()
    func dismiss() -> ToolDismissOutcome
}

final class CancelFlag: @unchecked Sendable {
    var cancelled = false
}

final class SlowTool: TextTool, @unchecked Sendable {
    let identity: ToolIdentity
    let requiredCapabilities: ToolCapabilities = .text
    let delay: Double
    let results: [String]
    let flag: CancelFlag

    init(id: String = "slow", title: String = "Slow", delay: Double, results: [String], flag: CancelFlag) {
        self.identity = ToolIdentity(id: id, title: title)
        self.delay = delay
        self.results = results
        self.flag = flag
    }

    func run(input: ToolInput) async throws -> [String] {
        await withTaskCancellationHandler(
            operation: {
                try? await Task.sleep(nanoseconds: UInt64(max(0.0, delay) * 1_000_000_000))
                return results
            },
            onCancel: { flag.cancelled = true })
    }
}

final class AudioTool: TextTool, @unchecked Sendable {
    let identity = ToolIdentity(id: "audio", title: "Audio")
    let requiredCapabilities: ToolCapabilities = [.text, .audio]

    func run(input: ToolInput) async throws -> [String] { [] }
}

struct FakeProvider: ToolToolProviding {
    var tools: [any TextTool]
}

final class StrictProxy: ToolTextDocumentProxy {
    var documentIdentity: UUID? = UUID(uuidString: "00000000-0000-0000-0000-00000000B001")
    var characters: [Character] = Array("abc")
    var caret = 3
    var selection: Range<Int>?
    var isSecureTextEntry: Bool? = false

    var textBeforeCaret: String? { String(characters[0..<min(caret, characters.count)]) }
    var textAfterCaret: String? { String(characters[min(caret, characters.count)...]) }
    var selectedText: String? {
        guard let selection else { return nil }
        return String(characters[selection])
    }
    func insertText(_ text: String) {
        characters.insert(contentsOf: Array(text), at: caret)
        caret += text.count
    }
    func deleteBackward() {
        if caret > 0 {
            characters.remove(at: caret - 1)
            caret -= 1
        }
    }
}

var failures: [String] = []

func check(_ condition: Bool, _ name: String, _ detail: String = "") {
    if condition {
        print("PASS " + name)
    } else {
        failures.append(name + (detail.isEmpty ? "" : ": " + detail))
        print("FAIL " + name + " " + detail)
    }
}

func sleep(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0.0, seconds) * 1_000_000_000))
}

@main
struct Probe {
    static func main() async {
        let limits = ToolLimits(
            maximumInputUnits: 40, runTimeout: 0.05, undoWindow: nil, maximumResults: 4)
        let configuration = ToolConfiguration(provider: FakeProvider(tools: []), limits: limits)
        _ = configuration

        // 1. The timeout cancels the tool, not just the session.
        let timeoutFlag = CancelFlag()
        let timeoutTool = SlowTool(delay: 5, results: ["timeout-late"], flag: timeoutFlag)
        let timeoutProxy = StrictProxy()
        let timeoutGateway = ToolDocumentGateway(
            proxy: timeoutProxy, sessionID: UUID().uuidString, limits: limits)
        let timeoutDriver = ToolPanelDriver(
            configuration: ToolConfiguration(
                provider: FakeProvider(tools: [timeoutTool]), limits: limits),
            gateway: { timeoutGateway })
        timeoutDriver.run(timeoutTool.identity)
        await sleep(0.4)
        await MainActor.run {
            check(timeoutFlag.cancelled, "timeoutCancelsTheTool")
            check(
                timeoutDriver.phase == .failed(.timedOut), "timeoutPhase",
                String(describing: timeoutDriver.phase))
            check(timeoutDriver.preview == nil, "timeoutKeepsNoPreview")
        }

        // 2. A result arriving after the deadline never becomes a preview.
        let lateFlag = CancelFlag()
        let lateTool = SlowTool(delay: 0.3, results: ["late"], flag: lateFlag)
        let lateProxy = StrictProxy()
        let lateGateway = ToolDocumentGateway(
            proxy: lateProxy, sessionID: UUID().uuidString, limits: limits)
        let lateDriver = ToolPanelDriver(
            configuration: ToolConfiguration(
                provider: FakeProvider(tools: [lateTool]), limits: limits),
            gateway: { lateGateway })
        lateDriver.run(lateTool.identity)
        await sleep(0.6)
        await MainActor.run {
            check(lateDriver.preview == nil, "lateResultIgnored")
            check(
                lateDriver.phase == .failed(.timedOut), "lateResultPhase",
                String(describing: lateDriver.phase))
        }

        // 3. Closing the panel cancels the running tool and clears the session.
        let closeFlag = CancelFlag()
        let closeTool = SlowTool(delay: 5, results: ["closed"], flag: closeFlag)
        let closeProxy = StrictProxy()
        let closeGateway = ToolDocumentGateway(
            proxy: closeProxy, sessionID: UUID().uuidString, limits: limits)
        let closeDriver = ToolPanelDriver(
            configuration: ToolConfiguration(
                provider: FakeProvider(tools: [closeTool]), limits: limits),
            gateway: { closeGateway })
        closeDriver.run(closeTool.identity)
        let outcome = closeDriver.dismiss()
        await sleep(0.2)
        await MainActor.run {
            check(closeFlag.cancelled, "dismissCancelsTheTool")
            switch outcome {
            case .cancelled:
                check(true, "dismissReportsCancelledRun")
            default:
                check(false, "dismissReportsCancelledRun", String(describing: outcome))
            }
            check(closeDriver.phase == .idle, "dismissClearsTheSession", String(describing: closeDriver.phase))
        }

        // 4. Entries carry the declared capability gaps.
        await MainActor.run {
            let audio = AudioTool()
            let driver = ToolPanelDriver(
                configuration: ToolConfiguration(
                    provider: FakeProvider(tools: [timeoutTool, audio]), limits: limits),
                gateway: { timeoutGateway })
            check(driver.entries.count == 2, "entriesListed")
            let audioEntry = driver.entries.first { $0.identity.id == "audio" }
            check(audioEntry?.isAvailable == false, "missingCapabilityEntryUnavailable")
        }

        if failures.isEmpty {
            print("PASS all")
            exit(0)
        }
        print("FAILURES: " + String(failures.count))
        exit(1)
    }
}
