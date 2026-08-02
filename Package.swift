// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Encore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EncoreKit", targets: ["EncoreKit"]),
        .executable(name: "encore-probe", targets: ["encore-probe"]),
        .executable(name: "Encore", targets: ["Encore"]),
    ],
    targets: [
        // Objective-C shim. Every use of Apple's private virtual-display API is
        // confined to this target so the rest of the codebase stays on public API.
        .target(
            name: "CVirtualDisplay",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .target(
            name: "EncoreKit",
            dependencies: ["CVirtualDisplay"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "encore-probe",
            dependencies: ["EncoreKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app. Both roles in one bundle, chosen on launch.
        .executableTarget(
            name: "Encore",
            dependencies: ["EncoreKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pure-logic tests only — CI runners are headless, so creating a real
        // display would fail there. Hardware checks live in encore-probe.
        .testTarget(
            name: "EncoreKitTests",
            dependencies: ["EncoreKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
