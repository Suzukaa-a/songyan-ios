import Darwin
import XCTest

// The shared contract and runner are compiled into this bundle from Tools/Script/src. main.c is
// compiled with -Dmain=songyan_script_cli_main, so the exact command-line path used on macOS is
// callable here; the tests feed it the same arguments the shell runners do and compare its bytes.
@_silgen_name("songyan_script_cli_main")
private func scriptCLIMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

final class ScriptContractTests: XCTestCase {
    private var resourceRoot: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        resourceRoot = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ScriptContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    /// Runs the shared command-line entry in this process and returns its exit code and stdout.
    private func runCLI(_ arguments: [String]) throws -> (status: Int32, output: Data) {
        // argv[0] is the program name, as in a real process; the subcommand starts at argv[1].
        let arguments = ["songyan-script"] + arguments
        let outputURL = scratch.appendingPathComponent("stdout-\(UUID().uuidString).json")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let descriptor = open(outputURL.path, O_WRONLY | O_TRUNC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let saved = dup(STDOUT_FILENO)
        XCTAssertGreaterThanOrEqual(saved, 0)
        dup2(descriptor, STDOUT_FILENO)
        close(descriptor)
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        let status = argv.withUnsafeMutableBufferPointer { buffer in
            scriptCLIMain(Int32(arguments.count), buffer.baseAddress)
        }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        for pointer in argv where pointer != nil { free(pointer) }
        return (status, (try? Data(contentsOf: outputURL)) ?? Data())
    }

    private func caseDirectories(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func readText(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func expect(
        name: String, expected: Data, expectedStatus: Int32, actualStatus: Int32,
        actualOutput: Data, failures: inout [String]
    ) {
        if actualStatus != expectedStatus {
            failures.append("\(name): exit \(actualStatus), expected \(expectedStatus)")
            return
        }
        if actualOutput != expected {
            let actualText = String(data: actualOutput, encoding: .utf8) ?? "<non UTF-8>"
            let expectedText = String(data: expected, encoding: .utf8) ?? "<non UTF-8>"
            failures.append("\(name): output differs\n--- expected\n\(expectedText)\n--- actual\n\(actualText)")
        }
    }

    private func expectedStatus(for expected: Data) -> Int32 {
        if expected.range(of: Data("\"cliError\"".utf8)) != nil { return 64 }
        if expected.range(of: Data("\"ok\": false".utf8)) != nil { return 1 }
        return 0
    }

    func testContractCasesMatchSharedExpectations() throws {
        let cases = try caseDirectories(in: resourceRoot.appendingPathComponent("tests/cases"))
        // Pinned to the shared directory, like the Android runner: a sync that silently drops case
        // folders must fail here instead of staying green with fewer checks.
        XCTAssertEqual(cases.count, 30, "contract case count must match Tools/Script/tests/cases")
        var failures: [String] = []
        for caseURL in cases {
            let name = caseURL.lastPathComponent
            var script = caseURL.appendingPathComponent("script.js")
            if !FileManager.default.fileExists(atPath: script.path) {
                script = resourceRoot.appendingPathComponent("examples/\(name).js")
            }
            let capabilities = readText(caseURL.appendingPathComponent("capabilities.txt")) ?? "text"
            let result = try runCLI(["header", "--script", script.path, "--capabilities", capabilities])
            let expected = try Data(contentsOf: caseURL.appendingPathComponent("expected.json"))
            expect(
                name: name, expected: expected, expectedStatus: expectedStatus(for: expected),
                actualStatus: result.status, actualOutput: result.output, failures: &failures)
        }
        print("contract cases: \(cases.count). (shared Tools/Script/tests/cases)")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func executionArguments(for caseURL: URL) throws -> [String] {
        let name = caseURL.lastPathComponent
        var arguments = ["run"]
        let scriptsFile = caseURL.appendingPathComponent("scripts.txt")
        if FileManager.default.fileExists(atPath: scriptsFile.path) {
            let relatives = try String(contentsOf: scriptsFile, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for relative in relatives {
                arguments += ["--script", caseURL.appendingPathComponent(relative).path]
            }
        } else {
            var script = caseURL.appendingPathComponent("script.js")
            if !FileManager.default.fileExists(atPath: script.path) {
                script = resourceRoot.appendingPathComponent("examples/\(name).js")
            }
            arguments += ["--script", script.path]
        }
        let optionalFiles: [(String, String)] = [
            ("input.txt", "--text-file"),
            ("settings.json", "--settings-file"),
            ("fetch.txt", "--fetch"),
        ]
        for (file, flag) in optionalFiles {
            let url = caseURL.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) { arguments += [flag, url.path] }
        }
        if let logLimit = readText(caseURL.appendingPathComponent("logLimit.txt")) {
            arguments += ["--log-limit", logLimit]
        }
        if FileManager.default.fileExists(atPath: caseURL.appendingPathComponent("cancel.txt").path) {
            arguments.append("--cancel-pending")
        }
        arguments += ["--capabilities", readText(caseURL.appendingPathComponent("capabilities.txt")) ?? "text"]

        var limits: [String: String] = [
            "sourceBytes": "1048576",
            "heapBytes": "8388608",
            "durationMs": "4000",
            "requestCount": "8",
            "responseBytes": "1048576",
            "inputTextBytes": "20000",
        ]
        let limitsFile = caseURL.appendingPathComponent("limits.txt")
        if let text = try? String(contentsOf: limitsFile, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                if limits[key] != nil { limits[key] = parts[1].trimmingCharacters(in: .whitespaces) }
            }
        }
        let flags: [(String, String)] = [
            ("sourceBytes", "--source-bytes"),
            ("heapBytes", "--heap-bytes"),
            ("durationMs", "--duration-ms"),
            ("requestCount", "--request-count"),
            ("responseBytes", "--response-bytes"),
            ("inputTextBytes", "--input-text-bytes"),
        ]
        for (key, flag) in flags { arguments += [flag, limits[key] ?? ""] }
        return arguments
    }

    func testExecutionCasesMatchSharedExpectations() throws {
        let cases = try caseDirectories(in: resourceRoot.appendingPathComponent("tests/execution/cases"))
        // Pinned to the shared directory, like the Android runner.
        XCTAssertEqual(
            cases.count, 54, "execution case count must match Tools/Script/tests/execution/cases")
        var failures: [String] = []
        for caseURL in cases {
            let name = caseURL.lastPathComponent
            let arguments = try executionArguments(for: caseURL)
            let result = try runCLI(arguments)
            let expected = try Data(contentsOf: caseURL.appendingPathComponent("expected.json"))
            expect(
                name: name, expected: expected, expectedStatus: expectedStatus(for: expected),
                actualStatus: result.status, actualOutput: result.output, failures: &failures)
        }
        print("execution cases: \(cases.count). (shared Tools/Script/tests/execution/cases)")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
