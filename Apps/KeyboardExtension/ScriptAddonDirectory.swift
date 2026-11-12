import Foundation
import ScriptAddonKit

/// The extension's production locations for script addons: the same App Group store root the Host
/// app writes, and the same shared Keychain service/group its secret store uses.
enum ScriptAddonDirectory {
    static func sharedRoot() -> URL? {
        guard let container = KeyboardRecipeStore.sharedContainerURL() else { return nil }
        return container.appendingPathComponent(
            "Library/Application Support/ScriptAddons", isDirectory: true)
    }

    static func secretStore() -> any ScriptSecretStore {
        KeychainScriptSecretStore(
            service: "app.songyan.script", accessGroup: KeyboardRecipeStore.groupID)
    }
}
