import Foundation

/// The language a human-readable tool message is written in. Callers pass the app's interface
/// language; the package never guesses it from the tool file, whose language tags only name the
/// tool.
public enum ToolLanguage: String, CaseIterable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case english = "en"

    /// Picks the first preferred tag that is available, matching a base tag such as `en-US`
    /// against `en`. Unsupported preferences fall back to Simplified Chinese, the app's source
    /// language.
    public static func resolve(preferredLanguageTags: [String]) -> ToolLanguage {
        for tag in preferredLanguageTags {
            if let match = exactMatch(tag) {
                return match
            }
            let lowered = tag.lowercased()
            if let match = allCases.first(where: { lowered.hasPrefix($0.rawValue.lowercased() + "-") }) {
                return match
            }
        }
        return .simplifiedChinese
    }

    /// The language of the current process, for callers that show the message directly.
    public static var current: ToolLanguage {
        resolve(preferredLanguageTags: Locale.preferredLanguages)
    }

    /// The package resource bundle for this language, so a caller can word a message in a language
    /// other than the process language (an error can surface while the interface is in another
    /// language). A missing language falls back to the bundle's own resolution instead of failing
    /// on an error path.
    var resourceBundle: Bundle {
        guard
            let path = Bundle.module.path(forResource: rawValue, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return .module
        }
        return bundle
    }

    private static func exactMatch(_ tag: String) -> ToolLanguage? {
        allCases.first { $0.rawValue.caseInsensitiveCompare(tag) == .orderedSame }
    }
}

/// A rejected tool file. `reason` is what validation found; `message(in:)` turns it into one
/// short human sentence that first says what is wrong and then what to do. The text lives in
/// `Resources/Localizable.xcstrings`, so no user-facing language is compiled into the source and
/// the error path reads it through the platform's localized-bundle lookup instead of opening files
/// itself.
public struct ToolDefinitionError: Error, Equatable, Sendable, LocalizedError {
    public enum Reason: Equatable, Sendable {
        /// The URL is not an ordinary file (a directory, a missing file or a remote URL).
        case notAFile
        /// The file is larger than the byte budget, which is also the read limit.
        case fileTooLarge(maximumKilobytes: Int)
        /// The bytes are not a JSON object, or their shape is not a tool file at all.
        case unreadable
        /// `formatVersion` is a version this build does not know.
        case unsupportedFormatVersion(String)
        case missingField(path: String)
        case invalidField(path: String)
        case noSteps
        case tooManySteps(count: Int)
        case unsupportedStepType(step: Int, type: String)
        case unavailableOpenCCConfig(step: Int, config: String)
        case invalidRegex(step: Int)
    }

    public let reason: Reason

    public init(reason: Reason) {
        self.reason = reason
    }

    public var errorDescription: String? {
        message(in: .current)
    }

    /// The message in `language`, with the failure details filled in. Each language's catalog
    /// entry carries the same positional format placeholders, so the wording may reorder them.
    public func message(in language: ToolLanguage) -> String {
        let template = String(
            localized: String.LocalizationValue(messageKey),
            bundle: language.resourceBundle)
        return String(format: template, arguments: arguments)
    }

    private var messageKey: String {
        switch reason {
        case .notAFile: "tool.error.notAFile"
        case .fileTooLarge: "tool.error.fileTooLarge"
        case .unreadable: "tool.error.unreadable"
        case .unsupportedFormatVersion: "tool.error.unsupportedFormatVersion"
        case .missingField: "tool.error.missingField"
        case .invalidField: "tool.error.invalidField"
        case .noSteps: "tool.error.noSteps"
        case .tooManySteps: "tool.error.tooManySteps"
        case .unsupportedStepType: "tool.error.unsupportedStepType"
        case .unavailableOpenCCConfig: "tool.error.unavailableOpenCCConfig"
        case .invalidRegex: "tool.error.invalidRegex"
        }
    }

    private var arguments: [CVarArg] {
        switch reason {
        case .notAFile, .unreadable, .noSteps:
            return []
        case .fileTooLarge(let maximumKilobytes):
            return [String(maximumKilobytes)]
        case .unsupportedFormatVersion(let version):
            return [version]
        case .missingField(let path), .invalidField(let path):
            return [path]
        case .tooManySteps(let count):
            return [String(count), String(ToolDefinitionLimits.maximumSteps)]
        case .unsupportedStepType(let step, let type):
            return [String(step), type]
        case .unavailableOpenCCConfig(let step, let config):
            return [String(step), config]
        case .invalidRegex(let step):
            return [String(step)]
        }
    }
}
