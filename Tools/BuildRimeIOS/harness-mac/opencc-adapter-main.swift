// ---------------------------------------------------------------------------
// opencc-adapter-main.swift — macOS proof for the RimeBridge OpenCC adapter.
//
// Runs Packages/RimeBridge/Sources/RimeBridge/OpenCCConversion.swift against the
// REAL shipped configs and .ocd2 dictionaries (Resources/EngineResources/opencc),
// linked with the same rime_opencc.o the C harness checks. It verifies the
// caller-facing contract: conversion by config URL, typed failures for a missing
// or malformed config and for a non-file URL, empty input, and text OpenCC must
// leave alone.
//
// Usage: opencc-adapter-main <config-dir> <writable-scratch-dir>
// ---------------------------------------------------------------------------
import Foundation
import RimeKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS: \(name)") } else { fail(name) }
}

func expectConfigUnavailable(_ body: () throws -> String, _ name: String) {
    do {
        _ = try body()
        fail(name + " (no error thrown)")
    } catch OpenCCConversionError.configUnavailable {
        check(true, name)
    } catch {
        fail(name + " (threw \(error))")
    }
}

@main
struct OpenCCAdapterMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            fail("usage: opencc-adapter-main <config-dir> <scratch-dir>")
        }
        let configDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let scratchDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        func config(_ name: String) -> URL {
            configDirectory.appendingPathComponent(name)
        }

        do {
            let converter = try OpenCCConverter(configURL: config("s2twp.json"))
            check(try converter.convert("软件") == "軟體", "s2twp converts 软件 to 軟體")
            check(try converter.convert("") == "", "empty input converts to empty output")
            check(
                try converter.convert("软件\u{0}软件") == "軟體\u{0}軟體",
                "conversion preserves embedded NUL and following text")
            check(
                try converter.convert("🙂ＡＢＣ１") == "🙂ＡＢＣ１",
                "unicode text and full-width ASCII pass through unchanged")
            check(
                try converter.convert("信息") == "資訊",
                "a second conversion on the same converter value uses fresh native state")
        } catch {
            fail("s2twp conversion threw \(error)")
        }

        do {
            check(
                try OpenCCConverter.convert("軟體", configURL: config("t2s.json")) == "软体",
                "t2s converts 軟體 to 软体")
        } catch {
            fail("t2s conversion threw \(error)")
        }

        expectConfigUnavailable(
            { try OpenCCConverter.convert("软件", configURL: config("missing.json")) },
            "a missing config throws configUnavailable")
        expectConfigUnavailable(
            { try OpenCCConverter.convert("软件", configURL: config("s2twp.json.bak")) },
            "a nonexistent file next to a real config throws configUnavailable")

        do {
            let malformed = scratchDirectory.appendingPathComponent("invalid-config.json")
            try Data("{\"name\": \"broken\",".utf8).write(to: malformed)
            expectConfigUnavailable(
                { try OpenCCConverter.convert("软件", configURL: malformed) },
                "a malformed config throws configUnavailable")
        } catch {
            fail("cannot write the malformed config fixture: \(error)")
        }

        do {
            _ = try OpenCCConverter(configURL: URL(string: "https://example.com/s2twp.json")!)
            fail("a non-file URL must be rejected")
        } catch OpenCCConversionError.invalidConfigURL {
            check(true, "a non-file URL is rejected as invalidConfigURL")
        } catch {
            fail("a non-file URL threw \(error)")
        }

        print("ALL PASS")
    }
}
