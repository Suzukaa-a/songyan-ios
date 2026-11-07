import Foundation
import QuickContentKit
import XCTest

/// Exercises the runner through its public surface only, so the test proves the API that the
/// keyboard and settings targets will call.
final class ToolRunnerTests: XCTestCase {
    // MARK: - Fixtures and helpers

    private func definition(_ steps: [ToolStep]) -> ToolDefinition {
        ToolDefinition(id: "test", name: ["en": "Test"], steps: steps)
    }

    private func run(
        _ steps: [ToolStep],
        input: String,
        limits: ToolRunnerLimits = ToolRunnerLimits(),
        openCCConverter: (any OpenCCToolConverting)? = nil
    ) async throws -> ToolRunnerResult {
        try await ToolRunner(limits: limits, openCCConverter: openCCConverter)
            .run(definition(steps), input: input)
    }

    private func assertRunFails(
        _ steps: [ToolStep],
        input: String,
        limits: ToolRunnerLimits = ToolRunnerLimits(),
        openCCConverter: (any OpenCCToolConverting)? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        matches expected: ToolRunnerError
    ) async {
        do {
            let result = try await run(
                steps, input: input, limits: limits, openCCConverter: openCCConverter)
            XCTFail("expected \(expected), got \(result)", file: file, line: line)
        } catch let error as ToolRunnerError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private struct FailingOpenCCConverter: OpenCCToolConverting {
        struct Failure: Error {}
        func convert(_ text: String, using config: OpenCCToolConfig) async throws -> String {
            throw Failure()
        }
    }

    // MARK: - Width

    func testWidthToHalfConvertsFullwidthLatinAndDigits() async throws {
        let result = try await run([.width(mode: .toHalf)], input: "ＡＢＣ１２３")
        XCTAssertEqual(result.text, "ABC123")
        XCTAssertFalse(result.inputWasTruncated)
    }

    func testWidthToFullConvertsAscii() async throws {
        let result = try await run([.width(mode: .toFull)], input: "ABC123")
        XCTAssertEqual(result.text, "ＡＢＣ１２３")
        XCTAssertFalse(result.inputWasTruncated)
    }

    // MARK: - Template

    func testTemplateWrapsTheWholeText() async throws {
        let result = try await run([.template(pattern: "「{text}」")], input: "软件")
        XCTAssertEqual(result.text, "「软件」")
        XCTAssertFalse(result.inputWasTruncated)
    }

    // MARK: - Ordering and the other transforms

    func testStepsRunInDeclarationOrder() async throws {
        let forward = try await run(
            [.replace(pattern: "a", replacement: "b"), .replace(pattern: "b", replacement: "c")],
            input: "a")
        XCTAssertEqual(forward.text, "c")

        let reversed = try await run(
            [.replace(pattern: "b", replacement: "c"), .replace(pattern: "a", replacement: "b")],
            input: "a")
        XCTAssertEqual(reversed.text, "b")
    }

    func testEveryTransformStepTypeRunsInOneDefinition() async throws {
        let steps: [ToolStep] = [
            .width(mode: .toHalf),
            .map(table: ["A": "B"]),
            .caseTransform(mode: .lower),
            .replace(pattern: "b+", replacement: "x"),
            .template(pattern: "「{text}」"),
        ]
        // ＡＢＣ -> ABC -> BBC -> bbc -> xc -> 「xc」
        let result = try await run(steps, input: "ＡＢＣ")
        XCTAssertEqual(result.text, "「xc」")
    }

    func testCaseModesUseEnglishCasing() async throws {
        let upper = try await run([.caseTransform(mode: .upper)], input: "Hello wORLD")
        XCTAssertEqual(upper.text, "HELLO WORLD")
        let lower = try await run([.caseTransform(mode: .lower)], input: "Hello wORLD")
        XCTAssertEqual(lower.text, "hello world")
    }

    func testCapitalizeUppercasesOnlyTheFirstCharacterOfEachWord() async throws {
        let result = try await run(
            [.caseTransform(mode: .capitalize)], input: "  hello wORLD\ttwo")
        XCTAssertEqual(result.text, "  Hello WORLD\tTwo")
    }

    // MARK: - Map and grapheme clusters

    func testMapMatchesWholeGraphemeClusters() async throws {
        let family = "👨‍👩‍👧‍👦"
        let table = ["é": "E", "🇯🇵": "JP", "👍": "THUMB", family: "FAMILY"]
        // The first grapheme is a decomposed é; Swift compares strings canonically.
        let result = try await run([.map(table: table)], input: "e\u{301}🇯🇵👍\(family)x")
        XCTAssertEqual(result.text, "EJPTHUMBFAMILYx")
    }

    func testMapLeavesUnmappedCharactersUntouched() async throws {
        let result = try await run([.map(table: ["a": "A"])], input: "ab😀c")
        XCTAssertEqual(result.text, "Ab😀c")
    }

    // MARK: - Input bound

    func testInputIsTruncatedOnAGraphemeBoundaryAndFlagged() async throws {
        let limits = ToolRunnerLimits(maximumInputUTF16Length: 2, maximumOutputUTF16Length: 64)
        let result = try await run([.template(pattern: "<{text}>")], input: "😀a", limits: limits)
        XCTAssertEqual(result.text, "<😀>")
        XCTAssertTrue(result.inputWasTruncated)
    }

    func testInputWithinTheBoundIsNotFlagged() async throws {
        let limits = ToolRunnerLimits(maximumInputUTF16Length: 3, maximumOutputUTF16Length: 64)
        let result = try await run([.template(pattern: "<{text}>")], input: "😀a", limits: limits)
        XCTAssertEqual(result.text, "<😀a>")
        XCTAssertFalse(result.inputWasTruncated)
    }

    func testDefaultInputLimitAllowsTheRequiredPathologicalRegexInput() async throws {
        let limits = ToolRunnerLimits()
        XCTAssertEqual(limits.maximumInputUTF16Length, 8_192)
        XCTAssertEqual(limits.maximumOutputUTF16Length, 16_384)
        XCTAssertEqual(limits.regexBudget, .milliseconds(100))
        XCTAssertGreaterThanOrEqual(limits.maximumInputUTF16Length, 5_001)

        let input = String(repeating: "a", count: 5_000) + "b"
        let result = try await run([.template(pattern: "{text}")], input: input)
        XCTAssertEqual(result.text, input)
        XCTAssertFalse(result.inputWasTruncated)
    }

    // MARK: - Output bound

    func testOutputBoundRejectsAnOversizedStepResult() async {
        let limits = ToolRunnerLimits(maximumInputUTF16Length: 64, maximumOutputUTF16Length: 6)
        await assertRunFails(
            [.template(pattern: "<{text}>")], input: "abcde", limits: limits,
            matches: .outputTooLong(step: 1, limit: 6))
    }

    func testOutputBoundIsCheckedAfterEveryStep() async {
        let limits = ToolRunnerLimits(maximumInputUTF16Length: 64, maximumOutputUTF16Length: 10)
        let step = ToolStep.template(pattern: "<{text}>")
        await assertRunFails(
            [step, step, step, step], input: "abc", limits: limits,
            matches: .outputTooLong(step: 4, limit: 10))
    }

    // MARK: - Regular expressions

    func testRegexReplacementMatchesFoundationSemantics() async throws {
        let result = try await run(
            [.replace(pattern: "(\\d+)", replacement: "[$1]")], input: "a1b22")
        XCTAssertEqual(result.text, "a[1]b[22]")
    }

    func testCatastrophicRegexTimesOutAndNeverReturnsAPartialResult() async throws {
        let input = String(repeating: "a", count: 5_000) + "b"
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let result = try await run(
                [.replace(pattern: "(a+)+$", replacement: "X")], input: input)
            XCTFail("expected a timeout, got \(result.text.prefix(16))")
        } catch let error as ToolRunnerError {
            XCTAssertEqual(
                error, .regexFailed(step: 1, reason: .timedOut(budget: .milliseconds(100))))
        }
        let elapsed = start.duration(to: clock.now)
        print("runner regex timeout elapsed: \(elapsed)")
        XCTAssertLessThan(elapsed, .milliseconds(200), "timed out after \(elapsed)")

        // A later run proves the abandoned match worker did not wedge the runner.
        let followUp = try await run([.width(mode: .toHalf)], input: "ＡＢＣ１")
        XCTAssertEqual(followUp.text, "ABC1")
    }

    func testRegexFailureKeepsItsStepNumber() async {
        let input = String(repeating: "a", count: 5_000) + "b"
        await assertRunFails(
            [.width(mode: .toHalf), .replace(pattern: "(a+)+$", replacement: "X")], input: input,
            matches: .regexFailed(step: 2, reason: .timedOut(budget: .milliseconds(100))))
    }

    // MARK: - OpenCC injection

    func testOpenCCStepWithoutAConverterFailsClosed() async {
        await assertRunFails(
            [.opencc(config: .s2twp)], input: "软件",
            matches: .converterUnavailable(step: 1, config: .s2twp))
    }

    func testMissingConverterKeepsTheStepThatNeededIt() async {
        await assertRunFails(
            [.width(mode: .toHalf), .opencc(config: .s2t)], input: "ＡＢＣ",
            matches: .converterUnavailable(step: 2, config: .s2t))
    }

    func testOpenCCConverterFailureIsATypedErrorWithStepAndConfig() async {
        let converter = OpenCCToolConverter { _, _ in throw FailingOpenCCConverter.Failure() }
        await assertRunFails(
            [.opencc(config: .t2jp)], input: "軟體", openCCConverter: converter,
            matches: .conversionFailed(step: 1, config: .t2jp))
    }

    // MARK: - Rejected definitions

    func testInvalidDefinitionIsRejectedBeforeAnyStepRuns() async {
        await assertRunFails(
            [.replace(pattern: "(", replacement: "x")], input: "a",
            matches: .invalidDefinition(ToolDefinitionError(reason: .invalidRegex(step: 1))))
    }
}
