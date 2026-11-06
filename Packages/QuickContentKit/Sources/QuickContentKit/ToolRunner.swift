import Foundation

/// Bounds and the deadline one run applies.
///
/// The input bound is larger than the interface's 1000-character selection limit on purpose: the
/// run must be able to hand the required pathological regular-expression fixture to the existing
/// matcher, so the deadline is measured on real work instead of on a prefix the runner cut short.
public struct ToolRunnerLimits: Equatable, Sendable {
    /// Longest input, in UTF-16 code units, that a run processes. Longer input is cut on a grapheme
    /// boundary, and the result reports `inputWasTruncated`.
    public var maximumInputUTF16Length: Int
    /// Longest text a step may produce. A step that grows the text past this bound fails the run
    /// with `ToolRunnerError.outputTooLong` instead of returning a silently clipped result.
    public var maximumOutputUTF16Length: Int
    /// Deadline for one `replace` step, forwarded to `RegexReplacement`.
    public var regexBudget: Duration
    /// Longest accepted regular-expression pattern, in UTF-16 code units.
    public var maximumRegexPatternUTF16Length: Int

    public init(
        maximumInputUTF16Length: Int = 8_192,
        maximumOutputUTF16Length: Int = 16_384,
        regexBudget: Duration = .milliseconds(100),
        maximumRegexPatternUTF16Length: Int = ToolDefinitionLimits.maximumPatternUTF16CodeUnits
    ) {
        self.maximumInputUTF16Length = maximumInputUTF16Length
        self.maximumOutputUTF16Length = maximumOutputUTF16Length
        self.regexBudget = regexBudget
        self.maximumRegexPatternUTF16Length = maximumRegexPatternUTF16Length
    }
}

/// The transformed text plus the one fact the interface needs before writing it back.
public struct ToolRunnerResult: Equatable, Sendable {
    public let text: String

    /// True when only the leading grapheme clusters of the input were processed. A caller must not
    /// replace the whole selection in that case, because the untransformed tail would be lost; it
    /// should insert at the cursor or leave the selection untouched instead.
    public let inputWasTruncated: Bool

    public init(text: String, inputWasTruncated: Bool) {
        self.text = text
        self.inputWasTruncated = inputWasTruncated
    }
}

/// Why a run stopped. The step number is 1-based, matching `ToolDefinitionError`, so the interface
/// can point at the same step that validation would name.
public enum ToolRunnerError: Error, Equatable, Sendable {
    /// The definition did not pass `ToolDefinition.validate()`; no step ran.
    case invalidDefinition(ToolDefinitionError)
    /// An `opencc` step was reached but no converter was injected.
    case converterUnavailable(step: Int, config: OpenCCToolConfig)
    /// The injected converter threw. Its own error stays with the converter for diagnostics.
    case conversionFailed(step: Int, config: OpenCCToolConfig)
    /// A `replace` step failed or exceeded its budget; the run never returns partial output.
    case regexFailed(step: Int, reason: RegexReplacementError)
    /// A step produced more text than `ToolRunnerLimits.maximumOutputUTF16Length`.
    case outputTooLong(step: Int, limit: Int)
    /// The platform's width transform was unavailable, so the step could not run.
    case widthTransformUnavailable(step: Int)
    /// A step threw a failure the runner cannot classify. Kept separate so the runner never
    /// guesses a more specific reason.
    case unexpectedFailure(step: Int)
}

/// The app-side OpenCC conversion the runner injects.
///
/// The package neither imports RimeBridge nor ships conversion data, so the bundled OpenCC
/// implementation stays in the app target. A definition that needs a conversion run without a
/// converter fails closed with `ToolRunnerError.converterUnavailable`.
public protocol OpenCCToolConverting: Sendable {
    func convert(_ text: String, using config: OpenCCToolConfig) async throws -> String
}

/// Adapts an existing asynchronous conversion call to `OpenCCToolConverting`.
public struct OpenCCToolConverter: OpenCCToolConverting, Sendable {
    public typealias Conversion =
        @Sendable (_ text: String, _ config: OpenCCToolConfig) async throws -> String

    private let conversion: Conversion

    public init(_ conversion: @escaping Conversion) {
        self.conversion = conversion
    }

    public func convert(_ text: String, using config: OpenCCToolConfig) async throws -> String {
        try await conversion(text, config)
    }
}

/// Executes a tool definition's steps in declaration order on one bounded string.
///
/// The runner is pure logic: it touches no files, no engine and no network. Conversion is injected
/// through `OpenCCToolConverting`; regular expressions reuse `RegexReplacement`, which runs the
/// ICU match off the caller's thread with a monotonic deadline. A timeout is reported, never
/// papered over with partially replaced text.
public struct ToolRunner: Sendable {
    public let limits: ToolRunnerLimits
    private let openCCConverter: (any OpenCCToolConverting)?

    public init(
        limits: ToolRunnerLimits = ToolRunnerLimits(),
        openCCConverter: (any OpenCCToolConverting)? = nil
    ) {
        self.limits = limits
        self.openCCConverter = openCCConverter
    }

    /// Validates `definition`, then runs its steps in order.
    ///
    /// Args:
    ///   - definition: The tool to run. It is validated again so an in-memory model cannot bypass
    ///     the file format's rules.
    ///   - input: The selected text, or the paragraph before the cursor, already bounded by the
    ///     caller's own selection rules.
    public func run(_ definition: ToolDefinition, input: String) async throws -> ToolRunnerResult {
        do {
            try definition.validate()
        } catch let error as ToolDefinitionError {
            throw ToolRunnerError.invalidDefinition(error)
        }

        let (truncatedInput, wasTruncated) = Self.truncate(
            input, toUTF16Length: limits.maximumInputUTF16Length)

        var text = truncatedInput
        for (offset, step) in definition.steps.enumerated() {
            let stepNumber = offset + 1
            text = try await apply(step, stepNumber: stepNumber, to: text)
            guard text.utf16.count <= limits.maximumOutputUTF16Length else {
                throw ToolRunnerError.outputTooLong(
                    step: stepNumber, limit: limits.maximumOutputUTF16Length)
            }
        }
        return ToolRunnerResult(text: text, inputWasTruncated: wasTruncated)
    }

    // MARK: - Steps

    private func apply(_ step: ToolStep, stepNumber: Int, to text: String) async throws -> String {
        switch step {
        case .opencc(let config):
            guard let openCCConverter else {
                throw ToolRunnerError.converterUnavailable(step: stepNumber, config: config)
            }
            do {
                return try await openCCConverter.convert(text, using: config)
            } catch {
                throw ToolRunnerError.conversionFailed(step: stepNumber, config: config)
            }

        case .replace(let pattern, let replacement):
            let replacer = RegexReplacement(
                limits: RegexReplacementLimits(
                    maximumInputUTF16Length: limits.maximumOutputUTF16Length,
                    maximumPatternUTF16Length: limits.maximumRegexPatternUTF16Length,
                    budget: limits.regexBudget))
            do {
                return try await replacer.replace(
                    text, pattern: pattern, replacement: replacement)
            } catch let error as RegexReplacementError {
                throw ToolRunnerError.regexFailed(step: stepNumber, reason: error)
            } catch {
                // RegexReplacement documents RegexReplacementError as its only failure type.
                throw ToolRunnerError.unexpectedFailure(step: stepNumber)
            }

        case .map(let table):
            var result = String()
            result.reserveCapacity(text.count)
            for character in text {
                result.append(table[String(character)] ?? String(character))
            }
            return result

        case .caseTransform(let mode):
            switch mode {
            case .upper:
                return text.uppercased()
            case .lower:
                return text.lowercased()
            case .capitalize:
                return Self.capitalize(text)
            }

        case .width(let mode):
            let reverse = mode == .toFull
            guard
                let transformed = text.applyingTransform(
                    .fullwidthToHalfwidth, reverse: reverse)
            else {
                throw ToolRunnerError.widthTransformUnavailable(step: stepNumber)
            }
            return transformed

        case .template(let pattern):
            return pattern.replacingOccurrences(of: ToolDefinition.textPlaceholder, with: text)
        }
    }

    /// Uppercases the first grapheme cluster of every whitespace-separated word and leaves the rest
    /// of the word unchanged, which is the capitalization rule the step model defines.
    private static func capitalize(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)
        var startsWord = true
        for character in text {
            if startsWord, !character.isWhitespace {
                result.append(contentsOf: String(character).uppercased())
                startsWord = false
            } else {
                result.append(character)
                if character.isWhitespace {
                    startsWord = true
                }
            }
        }
        return result
    }

    /// Cuts the input to the longest prefix that fits the UTF-16 budget without splitting a
    /// grapheme cluster, so a truncated preview never ends in half an emoji or a broken accent.
    private static func truncate(
        _ input: String, toUTF16Length limit: Int
    ) -> (text: String, wasTruncated: Bool) {
        guard input.utf16.count > limit else {
            return (input, false)
        }
        var text = String()
        var used = 0
        for character in input {
            let width = String(character).utf16.count
            guard used + width <= limit else { break }
            text.append(character)
            used += width
        }
        return (text, true)
    }
}
