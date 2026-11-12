"""Wiring contract for the in-extension tool panel.

The panel view and its presentation are covered by test_tool_panel; this probe guards
the plumbing that makes them reachable from the real keyboard extension: the shared
panel's injection slots, the host/presenter forwarding, the controller's closures and
the single-session driver. It reads production sources instead of running UIKit, so it
does not claim the panel was opened on a simulator.
"""
import unittest

from swift_probe import ROOT

SHARED = ROOT / "Apps/SharedKeyboard"
EXTENSION = ROOT / "Apps/KeyboardExtension"


def source(path):
    return path.read_text(encoding="utf-8")


class ToolPanelWiringTests(unittest.TestCase):
    def test_shared_panel_exposes_host_built_tool_panel_slots(self):
        text = source(SHARED / "KeyboardPanelView.swift")
        self.assertIn("let toolPanel: ((@escaping () -> Void) -> AnyView)?", text)
        self.assertIn("let toolPanelEntry: ((@escaping () -> Void) -> AnyView)?", text)
        self.assertIn("toolPanel { showsToolPanel = false }", text)
        self.assertIn("leadingSlot: toolPanelEntry.map", text)

    def test_host_forwards_both_slots_to_the_shared_panel(self):
        text = source(SHARED / "KeyboardPanelHost.swift")
        self.assertIn("private let toolPanel: ((@escaping () -> Void) -> AnyView)?", text)
        self.assertIn("private let toolPanelEntry: ((@escaping () -> Void) -> AnyView)?", text)
        self.assertIn("toolPanel: toolPanel,\n                toolPanelEntry: toolPanelEntry,", text)

    def test_extension_presenter_forwards_both_slots(self):
        text = source(EXTENSION / "ExtensionKeyboardPanel.swift")
        self.assertIn("let toolPanel: ((@escaping () -> Void) -> AnyView)?", text)
        self.assertIn("let toolPanelEntry: ((@escaping () -> Void) -> AnyView)?", text)
        self.assertIn("toolPanel: toolPanel,\n            toolPanelEntry: toolPanelEntry", text)

    def test_controller_builds_the_panel_closures_from_the_driver(self):
        text = source(EXTENSION / "KeyboardViewController.swift")
        self.assertIn("toolPanelDriver().map", text)
        self.assertIn("ToolPanelModel(driver: driver)", text)
        self.assertIn("ToolPanelView(", text)
        self.assertIn("model.dismiss()", text)
        self.assertIn("toolPanelToolbarEntry(", text)
        self.assertIn("toolPanel: toolPanel, toolPanelEntry: toolPanelEntry", text)
        self.assertIn("var toolConfiguration: ToolConfiguration?", text)

    def test_driver_delegates_to_the_one_session_and_gateway(self):
        text = source(EXTENSION / "ToolDocumentGateway.swift")
        self.assertIn("final class ToolPanelDriver: ToolPanelDriving", text)
        self.assertIn("gateway()?.phase ?? .idle", text)
        self.assertIn("gateway()?.chooseResult(index)", text)
        self.assertIn("gateway.retry(tool: tool", text)
        self.assertIn("gateway()?.cancel()", text)
        self.assertIn("gateway.apply(start, at: clock())", text)
        self.assertIn("gateway.applyUndo(start, at: clock())", text)
        self.assertIn("gateway()?.dismiss()", text)
        # No second state machine: the driver has no stored phase of its own.
        self.assertNotIn("var phase: ToolPhase =", text)
        self.assertNotIn("case running\n", text)

    def test_default_runtime_is_empty_and_hidden(self):
        controller = source(EXTENSION / "KeyboardViewController.swift")
        self.assertIn("var toolConfiguration: ToolConfiguration?", controller)
        driver = source(EXTENSION / "ToolDocumentGateway.swift")
        self.assertIn("struct EmptyToolProvider: ToolToolProviding", driver)
        self.assertIn("var tools: [any TextTool] { [] }", driver)
        wiring = source(EXTENSION / "ToolDocumentController.swift")
        self.assertIn("!configuration.provider.tools.isEmpty", wiring)
        self.assertIn("textDocumentProxy.isSecureTextEntry != true", wiring)
        self.assertIn("writableDocument() != nil", wiring)

    def test_reinstall_retires_first_and_dismiss_ends_the_run(self):
        controller = source(EXTENSION / "KeyboardViewController.swift")
        self.assertIn("retirePanelHost()", controller)
        self.assertIn("toolPanelInstalledAvailable = false", controller)
        self.assertIn("model.dismiss()", controller)
        self.assertIn("toolPanelIsAvailable()", controller)

    def test_attach_retries_the_panel_build(self):
        text = source(EXTENSION / "KeyboardViewController+HostDocument.swift")
        attach = text[text.index("func attachToHostDocument()"):]
        self.assertIn("hostDocumentAttachPending = false", attach)
        tail = attach[attach.index("hostDocumentAttachPending = false"):]
        self.assertIn("reapplyToolPanelIfNeeded()", tail)


if __name__ == "__main__":
    unittest.main()
