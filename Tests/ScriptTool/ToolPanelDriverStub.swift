// Test-only stand-in for the panel protocol. The production protocol lives in
// Apps/KeyboardExtension/ToolPanelView.swift together with the SwiftUI panel, which the test bundle
// does not compile (it would drag the keyboard view hierarchy and its packages into the tests).
// ToolDocumentGateway's driver only has to conform to the protocol to compile; the tests exercise
// the session and the document write path, not the panel UI.
protocol ToolPanelDriving: AnyObject {}
