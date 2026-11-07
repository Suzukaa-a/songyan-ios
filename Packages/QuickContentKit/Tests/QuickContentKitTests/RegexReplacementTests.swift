import Foundation
import XCTest

@testable import QuickContentKit

final class RegexReplacementTests: XCTestCase {
    private func foundationReplacement(
        _ input: String,
        pattern: String,
        replacement: String
    ) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: input.utf16.count)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
    }

    // MARK: Standard semantics

    func testStandardReplacementMatchesFoundation() async throws {
        let input = "Hello 123 World"
        let pattern = "([A-Za-z]+) (\\d+)"
        let replacement = "$2-$1"
        let actual = try await RegexReplacement().replace(input, pattern: pattern, replacement: replacement)
        XCTAssertEqual(actual, try foundationReplacement(input, pattern: pattern, replacement: replacement))
    }

    func testEmptyMatchReplacementMatchesFoundation() async throws {
        let input = "abc"
        let pattern = "x*"
        let replacement = "-"
        let actual = try await RegexReplacement().replace(input, pattern: pattern, replacement: replacement)
        XCTAssertEqual(actual, try foundationReplacement(input, pattern: pattern, replacement: replacement))
    }

    func testEmptyReplacementDeletesMatches() async throws {
        let input = "a1b22c"
        let pattern = "\\d+"
        let actual = try await RegexReplacement().replace(input, pattern: pattern, replacement: "")
        XCTAssertEqual(actual, try foundationReplacement(input, pattern: pattern, replacement: ""))
        XCTAssertEqual(actual, "abc")
    }

    func testUnicodeReplacementMatchesFoundation() async throws {
        let input = "松烟🙂輸入法"
        let pattern = "(\\p{Han}+)"
        let replacement = "「$1」"
        let actual = try await RegexReplacement().replace(input, pattern: pattern, replacement: replacement)
        XCTAssertEqual(actual, try foundationReplacement(input, pattern: pattern, replacement: replacement))
    }

    // MARK: Boundary validation

    func testInputTooLongRejectedBeforePatternIsCompiled() async throws {
        let limits = RegexReplacementLimits(maximumInputUTF16Length: 1000)
        let input = String(repeating: "a", count: 5000) + "b"
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await RegexReplacement(limits: limits).replace(input, pattern: "(", replacement: "X")
            XCTFail("expected inputTooLong")
        } catch let error as RegexReplacementError {
            XCTAssertEqual(error, .inputTooLong(limit: 1000))
        }
        print("input-too-long elapsed: \(start.duration(to: clock.now))")
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(50))
    }

    func testPatternTooLongRejected() async throws {
        let limits = RegexReplacementLimits(maximumPatternUTF16Length: 256)
        let pattern = String(repeating: "a", count: 257)
        do {
            _ = try await RegexReplacement(limits: limits).replace("a", pattern: pattern, replacement: "X")
            XCTFail("expected patternTooLong")
        } catch let error as RegexReplacementError {
            XCTAssertEqual(error, .patternTooLong(limit: 256))
        }
    }

    func testInvalidPatternRejected() async throws {
        do {
            _ = try await RegexReplacement().replace("abc", pattern: "(", replacement: "X")
            XCTFail("expected invalidPattern")
        } catch let error as RegexReplacementError {
            XCTAssertEqual(error, .invalidPattern)
        }
    }

    // MARK: Deadline

    func testCatastrophicPatternTimesOutAndWorkerReturns() async throws {
        let limits = RegexReplacementLimits(
            maximumInputUTF16Length: 6000,
            maximumPatternUTF16Length: 256,
            budget: .milliseconds(100)
        )
        let replacer = RegexReplacement(limits: limits)
        let input = String(repeating: "a", count: 5000) + "b"
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await replacer.replace(input, pattern: "(a+)+$", replacement: "X")
            XCTFail("expected timedOut")
        } catch let error as RegexReplacementError {
            XCTAssertEqual(error, .timedOut(budget: .milliseconds(100)))
        }
        let elapsed = start.duration(to: clock.now)
        print("catastrophic elapsed: \(elapsed)")
        XCTAssertLessThan(elapsed, .milliseconds(200))
        // A follow-up call proves the worker finished instead of being abandoned.
        let followUp = try await replacer.replace("a-b", pattern: "-", replacement: "+")
        XCTAssertEqual(followUp, "a+b")
    }

    // MARK: Main thread

    @MainActor
    func testMainThreadHeartbeatNotBlockedDuringCatastrophicMatch() async throws {
        let limits = RegexReplacementLimits(maximumInputUTF16Length: 6000, budget: .milliseconds(100))
        let replacer = RegexReplacement(limits: limits)
        let input = String(repeating: "a", count: 5000) + "b"

        let heartbeat = Task { @MainActor in
            let clock = ContinuousClock()
            let start = clock.now
            var samples: [Duration] = [.zero]
            while !Task.isCancelled {
                samples.append(clock.now - start)
                try? await Task.sleep(for: .milliseconds(5))
            }
            return samples
        }
        try? await Task.sleep(for: .milliseconds(20))

        do {
            _ = try await replacer.replace(input, pattern: "(a+)+$", replacement: "X")
            XCTFail("expected timedOut")
        } catch is RegexReplacementError {
            // Expected.
        }

        heartbeat.cancel()
        let samples = await heartbeat.value
        XCTAssertGreaterThanOrEqual(samples.count, 3)
        var maxGap = Duration.zero
        for (previous, next) in zip(samples, samples.dropFirst()) {
            maxGap = max(maxGap, next - previous)
        }
        print("main-thread max heartbeat gap: \(maxGap)")
        XCTAssertLessThan(maxGap, .milliseconds(50), "main thread was blocked for \(maxGap)")
    }
}
