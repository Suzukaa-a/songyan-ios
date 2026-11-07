import Foundation

/// Limits and deadline applied before a regular expression replacement runs.
public struct RegexReplacementLimits: Equatable, Sendable {
    public var maximumInputUTF16Length: Int
    public var maximumPatternUTF16Length: Int
    public var budget: Duration

    public init(
        maximumInputUTF16Length: Int = 1000,
        maximumPatternUTF16Length: Int = 256,
        budget: Duration = .milliseconds(100)
    ) {
        self.maximumInputUTF16Length = maximumInputUTF16Length
        self.maximumPatternUTF16Length = maximumPatternUTF16Length
        self.budget = budget
    }

    fileprivate var budgetNanoseconds: UInt64 {
        let components = budget.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        return UInt64(components.seconds) &* 1_000_000_000
            &+ UInt64(components.attoseconds / 1_000_000_000)
    }
}

public enum RegexReplacementError: Error, Equatable, Sendable {
    case inputTooLong(limit: Int)
    case patternTooLong(limit: Int)
    case invalidPattern
    case timedOut(budget: Duration)
}

/// Runs a regular expression replacement on a background queue with a monotonic deadline.
public struct RegexReplacement: Sendable {
    public let limits: RegexReplacementLimits

    public init(limits: RegexReplacementLimits = RegexReplacementLimits()) {
        self.limits = limits
    }

    /// Replaces matches of `pattern` in `input` using `replacement` as the template.
    ///
    /// Validation happens once on the caller's thread; matching runs off the caller's thread.
    public func replace(_ input: String, pattern: String, replacement: String) async throws -> String {
        guard input.utf16.count <= limits.maximumInputUTF16Length else {
            throw RegexReplacementError.inputTooLong(limit: limits.maximumInputUTF16Length)
        }
        guard pattern.utf16.count <= limits.maximumPatternUTF16Length else {
            throw RegexReplacementError.patternTooLong(limit: limits.maximumPatternUTF16Length)
        }
        let limits = self.limits
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        try Self.perform(input, pattern: pattern, replacement: replacement, limits: limits)
                    }
                )
            }
        }
    }

    private static func perform(
        _ input: String,
        pattern: String,
        replacement: String,
        limits: RegexReplacementLimits
    ) throws -> String {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            throw RegexReplacementError.invalidPattern
        }
        let range = NSRange(location: 0, length: input.utf16.count)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ limits.budgetNanoseconds
        var exceeded = false
        var matches: [NSTextCheckingResult] = []
        regex.enumerateMatches(in: input, options: .reportProgress, range: range) { result, _, stop in
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                exceeded = true
                stop.pointee = true
                return
            }
            if let result {
                matches.append(result)
            }
        }
        guard !exceeded, DispatchTime.now().uptimeNanoseconds < deadline else {
            throw RegexReplacementError.timedOut(budget: limits.budget)
        }

        let text = input as NSString
        let output = NSMutableString(capacity: text.length)
        var cursor = 0
        for match in matches {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw RegexReplacementError.timedOut(budget: limits.budget)
            }
            let matchRange = match.range
            if matchRange.location > cursor {
                output.append(text.substring(with: NSRange(location: cursor, length: matchRange.location - cursor)))
            }
            output.append(regex.replacementString(for: match, in: input, offset: 0, template: replacement))
            cursor = matchRange.location + matchRange.length
        }
        if cursor < text.length {
            output.append(text.substring(from: cursor))
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw RegexReplacementError.timedOut(budget: limits.budget)
        }
        return output as String
    }
}
