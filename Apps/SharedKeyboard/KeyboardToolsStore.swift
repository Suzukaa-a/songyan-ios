import Foundation
import KeyboardCore
import QuickContentKit

/// Where the keyboard finds the tool catalog, and which built-in conversion it runs.
///
/// The host app is the only writer (its keyboard-tools page); the keyboard only reads. Both sides
/// use the same directory name under the same App Group container root, so the same relative path
/// addresses the same store from either process.
enum KeyboardToolsStore {
    /// Directory inside the App Group container root. The host app's keyboard-tools page uses the
    /// same value; together with the file names `ToolStore` appends, it is the on-disk contract.
    static let directoryName = "KeyboardTools"

    /// Read-only catalog location. Reading the shared container is allowed without Full Access
    /// (only writing is not), and nothing here writes; when the container is unavailable the
    /// process-local directory with the same relative layout is read instead.
    static func readRootURL() -> URL? {
        if let container = KeyboardRecipeStore.sharedContainerURL() {
            return container.appendingPathComponent(directoryName, isDirectory: true)
        }
        guard
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }
        return support.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Host-app write location. The host is the single writer: it probes the App Group first (the
    /// same create/write/read/delete probe the layout store uses) and falls back to its own
    /// container, so the relative path stays `KeyboardTools` either way. The keyboard reads the
    /// same location through `readRootURL()` and never writes.
    static func hostWriteRootURL() -> URL {
        RimePaths.probedStoreDirectory(
            sharedName: directoryName, localName: directoryName, label: "tools"
        ).url
    }

    /// The built-in conversion follows the input language, because that is the text form the user
    /// works in: a simplified user gets simplified (t2s), a traditional user the Taiwan form the
    /// app documents (s2twp), and a Japanese user has no Chinese regional variant, so the generic
    /// traditional form applies (s2t).
    static func simplificationConfig(for language: InputLanguage) -> OpenCCToolConfig {
        switch language {
        case .simplifiedChinese: return .t2s
        case .traditionalChinese: return .s2twp
        case .japanese: return .s2t
        }
    }

    static func builtinDefinitions(for language: InputLanguage) -> [ToolDefinition] {
        BuiltinToolDefinitions.all(simplificationConfig: simplificationConfig(for: language))
    }
}
