import Foundation

/// User-facing wording of this package.
///
/// The text lives in `Resources/Localizable.xcstrings` (Simplified Chinese is the source
/// language; Traditional Chinese and Japanese are translated), so the package owns its copy
/// instead of reading the host app's catalog, and no user-facing language is compiled into the
/// code. Caller-supplied detail (a native error, a schema ID) stays an argument.
enum RimeText {
    /// The compiled resource bundle of this package.
    static var catalog: Bundle { Bundle.module }

    /// The catalog entry `key`, in the interface language of the process.
    static func string(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: catalog)
    }

    /// The catalog entry `key` with its positional placeholders filled in. Every language's
    /// entry carries the same placeholders, so a translation may reorder them.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}
