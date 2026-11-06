import Foundation
import QuickContentKit

@main
struct OpenCCToolRunnerMain {
    static func main() async throws {
        let configs = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let queue = DispatchQueue(label: "songyan.tool.opencc.verification")
        let converter = OpenCCToolConverter { text, config in
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(
                        with: Result {
                            try OpenCCConverter.convert(
                                text, configURL: configs.appendingPathComponent(config.rawValue + ".json"))
                        })
                }
            }
        }
        let runner = ToolRunner(openCCConverter: converter)
        let definition = ToolDefinition(
            id: "traditional", name: ["en": "Traditional"],
            steps: [.opencc(config: .s2twp), .template(pattern: "「{text}」")])
        let result = try await runner.run(definition, input: "软件")
        guard result.text == "「軟體」", !result.inputWasTruncated else {
            throw VerificationError.incorrectConversion
        }
        print("PASS: production tool runner converts 软件 to 軟體 then wraps the result")
        let text = "软件\u{0}软件"
        let complete = try await runner.run(definition, input: text)
        guard complete.text == "「軟體\u{0}軟體」" else {
            throw VerificationError.incorrectConversion
        }
        print("PASS: production tool runner preserves text after embedded NUL")
        print("ALL PASS")
    }

    enum VerificationError: Error { case incorrectConversion }
}
