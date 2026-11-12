import Foundation
import ScriptAddonKit
import ToolKit

/// Reads the HostApp's script addons from the shared store root and turns the enabled, confirmed
/// ones into ToolKit tools. Loading is pure file/Keychain reading; the extension and the tests use
/// this same loader (tests pass a fixture root and an in-memory secret store). Nothing here logs
/// settings or secrets.
struct ScriptAddonCatalog {
    enum SkipReason: String, Equatable {
        case disabled
        case unconfirmed
        case declarationsChanged
        case unreadableScript
        case invalidHeader
    }

    struct Skipped: Equatable {
        let id: String
        let reason: SkipReason
    }

    struct LoadResult {
        var tools: [ScriptTextTool]
        var skipped: [Skipped]
    }

    let root: URL
    let runtimeLimits: ScriptToolRuntimeLimits
    let sessionLimits: ToolLimits
    let isFullAccess: Bool
    let secrets: any ScriptSecretStore
    /// Test seam: production leaves this empty and the tool uses the system URL loader.
    var urlSessionProtocolClasses: [AnyClass] = []

    /// Tools in the store's order, plus why each other addon was left out.
    func load() -> LoadResult {
        var result = LoadResult(tools: [], skipped: [])
        let store: ScriptAddonStore
        do {
            store = ScriptAddonStore(root: root, fileManager: .default)
            let addons = try store.list()
            for addon in addons {
                if !addon.state.enabled {
                    result.skipped.append(Skipped(id: addon.state.id, reason: .disabled))
                    continue
                }
                guard addon.state.confirmedDigest != nil else {
                    result.skipped.append(Skipped(id: addon.state.id, reason: .unconfirmed))
                    continue
                }
                guard let data = try? store.scriptBytes(id: addon.state.id),
                    let source = String(data: data, encoding: .utf8)
                else {
                    result.skipped.append(Skipped(id: addon.state.id, reason: .unreadableScript))
                    continue
                }
                let settings = resolvedSettings(for: addon.state)
                do {
                    let tool = try ScriptTextTool(
                        source: source, id: "script.addon.\(addon.state.id)",
                        limits: runtimeLimits, isFullAccess: isFullAccess,
                        settingsJSON: settings.json, settingsUnavailable: settings.unavailable,
                        urlSessionProtocolClasses: urlSessionProtocolClasses)
                    let confirmed = try? tool.declarations.confirmationDigest()
                    guard let confirmed, confirmed == addon.state.confirmedDigest else {
                        result.skipped.append(
                            Skipped(id: addon.state.id, reason: .declarationsChanged))
                        continue
                    }
                    result.tools.append(tool)
                } catch {
                    result.skipped.append(Skipped(id: addon.state.id, reason: .invalidHeader))
                }
            }
        } catch {
            // A missing root or an unreadable store simply means no tools; it is not an error the
            // keyboard should show on top of the field.
            return result
        }
        return result
    }

    private struct ResolvedSettings {
        var json: String?
        /// True when a declared secret exists in state but could not be read back: the tool then
        /// refuses to run with the fixed "re-enter the secret" prompt instead of running silently
        /// without the value the user filled in.
        var unavailable: Bool
    }

    /// The settings object the run receives: filled settings plus secret values read from the
    /// shared store. No value is ever logged, and a missing/unreadable declared secret is reported
    /// to the tool instead of being dropped.
    private func resolvedSettings(for state: ScriptAddonState) -> ResolvedSettings {
        var values = state.settings
        var unavailable = false
        for key in state.secretKeys {
            do {
                if let value = try secrets.secret(for: key, scriptID: state.id) {
                    values[key] = value
                } else {
                    unavailable = true
                }
            } catch {
                unavailable = true
            }
        }
        guard !values.isEmpty else { return ResolvedSettings(json: nil, unavailable: unavailable) }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return ResolvedSettings(json: nil, unavailable: true) }
        return ResolvedSettings(json: json, unavailable: unavailable)
    }
}
