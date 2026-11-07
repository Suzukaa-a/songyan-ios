// swift-tools-version: 6.0
//
// SkinKit: skin definitions (colors, fonts, key caps) and the keyboard appearance policy.
// User-facing wording lives in Resources/Localizable.xcstrings (zh-Hans source, zh-Hant and ja
// translations) and is read through the package bundle.
import PackageDescription

let package = Package(
    name: "SkinKit",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SkinKit", targets: ["SkinKit"])
    ],
    targets: [
        .target(name: "SkinKit", resources: [.process("Resources")]),
        .testTarget(
            name: "SkinKitTests",
            dependencies: ["SkinKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
