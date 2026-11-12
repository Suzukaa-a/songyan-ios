#if canImport(UIKit)
    import SwiftUI
    import ToolKit
    import UIKit

    extension KeyboardViewController {
        /// The single tool gateway for the document this controller owns. Limits are
        /// injected until the shared script bridge supplies production values, so no
        /// limit is guessed here. Returns nil while the proxy is mid-handoff or the
        /// keyboard is not active, matching the other host writers.
        func toolDocumentGateway(limits: ToolLimits) -> ToolDocumentGateway? {
            guard isBoundHost, !hostDocumentAttachPending, let document = writableDocument() else {
                return nil
            }
            if let gateway = toolDocumentGateway, toolDocumentGatewayDocument == document {
                return gateway
            }
            let gateway = ToolDocumentGateway(
                proxy: LiveToolTextDocumentProxy(proxy: textDocumentProxy),
                sessionID: UUID().uuidString, limits: limits)
            toolDocumentGateway = gateway
            toolDocumentGatewayDocument = document
            return gateway
        }

        /// Installs or replaces the injected tool runtime. The panel is rebuilt
        /// (retiring the previous hosting first) so a configuration that arrives
        /// after startup takes effect; nil removes the toolbar entry and the panel.
        func applyToolConfiguration(_ configuration: ToolConfiguration?) {
            toolConfiguration = configuration
            installPanelHost()
        }

        /// Rebuilds the panel once the host handoff has settled. At viewDidLoad the
        /// proxy is not attached yet, so a tool runtime injected there cannot produce
        /// a driver; this re-evaluates after attach (host bind and every appearance).
        /// It never reinstalls once a tool panel was actually built.
        func reapplyToolPanelIfNeeded() {
            guard let configuration = toolConfiguration, !configuration.provider.tools.isEmpty,
                !toolPanelInstalledAvailable
            else { return }
            installPanelHost()
        }

        /// Whether the tool entry may be offered right now: an injected runtime with
        /// at least one tool, an owned editable field, and no password field. Read by
        /// the toolbar entry on every panel body pass, so switching to a password
        /// field removes the entry without rebuilding the panel.
        func toolPanelIsAvailable() -> Bool {
            guard let configuration = toolConfiguration, !configuration.provider.tools.isEmpty
            else { return false }
            guard isBoundHost, !hostDocumentAttachPending, writableDocument() != nil else {
                return false
            }
            return textDocumentProxy.isSecureTextEntry != true
        }

        /// Drops the gateway when the owned document goes away.
        func resetToolDocumentGateway() {
            toolDocumentGateway = nil
            toolDocumentGatewayDocument = nil
        }

        /// A driver for the tool panel, or nil when there is nothing to show: no
        /// injected tool runtime, no tools, no owned editable field, or a password
        /// field. The driver delegates every intent to ToolKit's one session and to
        /// the document gateway above.
        func toolPanelDriver() -> ToolPanelDriver? {
            guard let configuration = toolConfiguration, !configuration.provider.tools.isEmpty
            else { return nil }
            guard isBoundHost, !hostDocumentAttachPending, writableDocument() != nil,
                textDocumentProxy.isSecureTextEntry != true
            else { return nil }
            return ToolPanelDriver(
                configuration: configuration,
                gateway: { [weak self] in
                    guard let self, self.isBoundHost, !self.hostDocumentAttachPending else {
                        return nil
                    }
                    return self.toolDocumentGateway(limits: configuration.limits)
                })
        }
    }

    /// The toolbar entry that opens the tool panel. Styled by the extension like the
    /// other idle-toolbar slots; the shared panel view only gets the open action.
    /// It disappears by itself when the current field may not use tools.
    @MainActor
    func toolPanelToolbarEntry(
        open: @escaping () -> Void, isAvailable: @escaping @MainActor () -> Bool
    ) -> some View {
        Group {
            if isAvailable() {
                Button(action: open) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "工具"))
                .accessibilityIdentifier("keyboard.toolPanel.entry")
            }
        }
    }
#endif
