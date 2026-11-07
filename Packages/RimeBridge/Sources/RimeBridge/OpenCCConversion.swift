import Foundation
import RimeKit

/// Typed failures of an offline OpenCC conversion.
///
/// Diagnostics are the native layer's English text; the interface decides whether and how to show
/// them, so this type carries no user-facing wording of its own.
public enum OpenCCConversionError: Error, Equatable, Sendable {
    /// The URL is not an absolute local file URL, so it cannot name a bundled config.
    case invalidConfigURL
    /// OpenCC could not open the config or one of the dictionaries it names.
    case configUnavailable(diagnostic: String?)
    /// The native ABI refused the request, for example text above its byte limit.
    case invalidInput
    /// OpenCC failed while converting the text.
    case conversionFailed(diagnostic: String?)
    /// A native result or diagnostic could not be allocated.
    case outOfMemory
}

/// Converts text with one of the OpenCC configs shipped in
/// `Resources/EngineResources/opencc`.
///
/// The native side builds a standalone OpenCC converter per call and never touches librime's
/// service, registry or session state, so a conversion neither needs nor disturbs the engine
/// singleton. Loading the `.ocd2` dictionaries is disk-bound, so `convert` is synchronous and must
/// run off the main thread; the keyboard tools panel runs it asynchronously on the caller's
/// engine-operation queue.
public struct OpenCCConverter: Sendable {
    /// Absolute file URL of one shipped config. OpenCC resolves the dictionaries it names relative
    /// to this file's directory.
    public let configURL: URL

    /// Refuses anything but an absolute file URL, so a tool can never name a remote config or one
    /// that would resolve against the process working directory.
    public init(configURL: URL) throws {
        guard configURL.isFileURL, configURL.path.hasPrefix("/") else {
            throw OpenCCConversionError.invalidConfigURL
        }
        self.configURL = configURL
    }

    /// Runs the conversion synchronously; never call this on the main thread.
    public func convert(_ text: String) throws -> String {
        var output: UnsafeMutablePointer<CChar>?
        var outputLength = 0
        var diagnostic: UnsafeMutablePointer<CChar>?
        let status = configURL.path.withCString { configPath in
            text.withCString { input in
                rb_opencc_convert(configPath, input, text.utf8.count, &output, &outputLength, &diagnostic)
            }
        }
        defer {
            rb_opencc_free(output)
            rb_opencc_free(diagnostic)
        }
        let reason = diagnostic.map { String(cString: $0) }
        switch status.rawValue {
        case RB_OPENCC_OK.rawValue:
            guard let output,
                let converted = String(
                    bytes: UnsafeRawBufferPointer(start: output, count: outputLength), encoding: .utf8)
            else {
                throw OpenCCConversionError.conversionFailed(diagnostic: reason)
            }
            return converted
        case RB_OPENCC_CONFIG_UNAVAILABLE.rawValue:
            throw OpenCCConversionError.configUnavailable(diagnostic: reason)
        case RB_OPENCC_INVALID_ARGUMENT.rawValue:
            throw OpenCCConversionError.invalidInput
        case RB_OPENCC_OUT_OF_MEMORY.rawValue:
            throw OpenCCConversionError.outOfMemory
        default:
            throw OpenCCConversionError.conversionFailed(diagnostic: reason)
        }
    }

    /// One-shot form for a single conversion.
    public static func convert(_ text: String, configURL: URL) throws -> String {
        try OpenCCConverter(configURL: configURL).convert(text)
    }
}
