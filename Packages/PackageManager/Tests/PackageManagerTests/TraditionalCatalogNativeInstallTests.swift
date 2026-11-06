import Foundation
import XCTest

/// Opt-in end-to-end acceptance for the four traditional-Chinese catalogue entries: the real
/// PackageManager reads the pinned upstream archives, installs them through the real store
/// transaction, the deploy callback runs a real librime cold deploy into the context's build
/// directory, and a fresh prebuilt engine must return candidates for a code read off the installed
/// dictionary. The engine work and the pinned archive set live in
/// Tools/BuildRimeIOS/scripts/traditional-catalog-harness.sh (one process per entry).
///
/// This test skips unless TRADITIONAL_CATALOG_NATIVE=1: a real deploy compiles dictionaries and is
/// far too slow for the ordinary suite. Skipping is deliberate and visible, never a silent pass.
final class TraditionalCatalogNativeInstallTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testFourEntriesInstallDeployNativelyAndTypeCandidates() throws {
        guard ProcessInfo.processInfo.environment["TRADITIONAL_CATALOG_NATIVE"] == "1" else {
            throw XCTSkip(
                "opt-in macOS native catalogue acceptance is off; set TRADITIONAL_CATALOG_NATIVE=1 (and NATIVE_ENGINE_ROOT / TRADITIONAL_CATALOG_SOURCES) to run the four entries"
            )
        }
        let script = repoRoot().appendingPathComponent("Tools/BuildRimeIOS/scripts/traditional-catalog-harness.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path), "missing \(script.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["TRADITIONAL_CATALOG_NATIVE"] = "1"
        // This test runs while swift test holds the package build lock, so the wrapper must reuse
        // the products this process already built instead of starting a nested swift build.
        environment["TRADITIONAL_CATALOG_PM_BIN"] = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0, text)
        let passed = text.components(separatedBy: "RESULT: pass").count - 1
        XCTAssertEqual(passed, 4, "every entry must install, deploy and type candidates:\n\(text)")
        for item in ["rime-bopomofo", "rime-cangjie", "rime-quick", "rime-cantonese"] {
            XCTAssertTrue(text.contains("PASS: \(item)"), "\(item) did not pass:\n\(text)")
        }
    }
}
