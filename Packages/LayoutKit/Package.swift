// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LayoutKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "LayoutKit", targets: ["LayoutKit"])],
    targets: [
        .target(name: "LayoutKit", resources: [.process("Resources")]),
        .testTarget(name: "LayoutKitTests", dependencies: ["LayoutKit"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
