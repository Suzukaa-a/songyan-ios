// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PackageManager",
    // User-facing wording lives in Resources/Localizable.xcstrings, one entry per language.
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "PackageManager", targets: ["PackageManager"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
        .package(path: "../KeyboardCore"),
    ],
    targets: [
        .target(
            name: "PackageManager",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"), .product(name: "Yams", package: "Yams"),
                .product(name: "KeyboardCore", package: "KeyboardCore"),
            ], resources: [.copy("Resources/RimePrelude"), .process("Resources/Localizable.xcstrings")]),
        .testTarget(
            name: "PackageManagerTests",
            dependencies: ["PackageManager", .product(name: "KeyboardCore", package: "KeyboardCore")],
            resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
