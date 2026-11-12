// swift-tools-version: 6.0
//
// ToolKit — UI-independent "tool" contract and one run's state machine.
//
// Boundaries:
//   - No UIKit/SwiftUI: both the host app and the keyboard extension can use it,
//     and swift test runs on macOS.
//   - The keyboard owns the document. This package only models which text a tool
//     receives, where a result may be written, and the phases of one run
//     (cancel, timeout, preview, replace/insert, undo).
//   - Limits (timeout, input cap, undo window) are injected by the caller; no
//     production value is guessed here.
//   - No user-facing strings: failures are typed and the UI maps them.

import PackageDescription

let package = Package(
    name: "ToolKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ToolKit", targets: ["ToolKit"])
    ],
    targets: [
        .target(name: "ToolKit"),
        .testTarget(name: "ToolKitTests", dependencies: ["ToolKit"]),
    ],
    swiftLanguageModes: [.v6]
)
