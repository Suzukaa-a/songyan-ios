#if canImport(UIKit)
    import Foundation
    import ScriptAddonKit
    import ToolKit

    /// The extension's ToolToolProviding implementation: the script runtime is one provider, so the
    /// panel and the write path keep seeing ToolKit's TextTool and never branch on what a tool is.
    struct ScriptToolProvider: ToolToolProviding {
        var tools: [any TextTool]
    }

    extension ScriptToolRuntime {
        /// Builds a ToolKit configuration from the HostApp's shared script store. Returns nil when no
        /// enabled, confirmed script exists: the toolbar/panel entry then stays hidden.
        static func storeConfiguration(
            configuration: ScriptToolConfiguration = .provisional, isFullAccess: Bool,
            root: URL? = ScriptAddonDirectory.sharedRoot(),
            secrets: (any ScriptSecretStore)? = nil
        ) -> ToolConfiguration? {
            guard let root else { return nil }
            let catalog = ScriptAddonCatalog(
                root: root, runtimeLimits: configuration.runtimeLimits,
                sessionLimits: configuration.toolLimits, isFullAccess: isFullAccess,
                secrets: secrets ?? ScriptAddonDirectory.secretStore())
            let tools = catalog.load().tools
            guard !tools.isEmpty else { return nil }
            return ToolConfiguration(
                provider: ScriptToolProvider(tools: tools), limits: configuration.toolLimits)
        }
    }

    extension KeyboardViewController {
        /// Installs the tool runtime once from viewDidLoad. applyToolConfiguration owns
        /// installPanelHost, so the panel is still built exactly once. An empty store installs no
        /// configuration, so nothing appears until the user adds a script in the Host app. Full
        /// Access is read from UIInputViewController.hasFullAccess (public since iOS 11); the system
        /// restarts the extension when the user changes it, and every re-read rebuilds the tools.
        func installToolRuntime() {
            applyToolConfiguration(scriptToolConfiguration())
        }

        /// Re-reads the shared store on every appearance so adding, deleting, enabling or
        /// re-confirming a script in the Host app is picked up the next time the keyboard shows.
        /// The panel is only rebuilt when the effective tool list (or Full Access) changed.
        func refreshScriptToolRuntimeIfNeeded() {
            let desired = scriptToolConfiguration()
            let desiredFingerprint = ScriptAddonCatalog.fingerprint(of: desired?.provider.tools ?? [])
            let currentFingerprint = ScriptAddonCatalog.fingerprint(
                of: toolConfiguration?.provider.tools ?? [])
            if desiredFingerprint == currentFingerprint { return }
            applyToolConfiguration(desired)
        }

        private func scriptToolConfiguration() -> ToolConfiguration? {
            ScriptToolRuntime.storeConfiguration(isFullAccess: hasFullAccess)
        }

    }
#endif
