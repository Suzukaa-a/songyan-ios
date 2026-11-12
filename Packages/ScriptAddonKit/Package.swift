// swift-tools-version: 6.0
//
// ScriptAddonKit — the host-side model for user scripts as one kind of addon.
//
// A script is stored as its original bytes and described by the same Tool contract the
// keyboard uses; the shared C runtime parses the header and executes a run. This package
// owns only what the host app stores: the byte-exact file, a versioned local state JSON,
// the declaration digest that drives re-confirmation, and the secret store boundary so
// secrets never enter a file.

import PackageDescription

let package = Package(
    name: "ScriptAddonKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ScriptAddonKit", targets: ["ScriptAddonKit"])
    ],
    targets: [
        .target(name: "ScriptAddonKit"),
        .testTarget(name: "ScriptAddonKitTests", dependencies: ["ScriptAddonKit"]),
    ],
    swiftLanguageModes: [.v6]
)
