// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Understudy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UnderstudyKit", targets: ["UnderstudyKit"]),
        .executable(name: "understudy-probe", targets: ["understudy-probe"]),
        .executable(name: "understudy-host", targets: ["understudy-host"]),
        .executable(name: "understudy-client", targets: ["understudy-client"]),
    ],
    targets: [
        // Objective-C shim. Every use of Apple's private virtual-display API is
        // confined to this target so the rest of the codebase stays on public API.
        .target(
            name: "CVirtualDisplay",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .target(
            name: "UnderstudyKit",
            dependencies: ["CVirtualDisplay"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "understudy-probe",
            dependencies: ["UnderstudyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Runs on the Mac being extended: creates the virtual display, captures
        // and encodes it, and streams to a paired client.
        .executableTarget(
            name: "understudy-host",
            dependencies: ["UnderstudyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Runs on the spare MacBook: receives frames and draws them fullscreen.
        .executableTarget(
            name: "understudy-client",
            dependencies: ["UnderstudyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pure-logic tests only — CI runners are headless, so creating a real
        // display would fail there. Hardware checks live in understudy-probe.
        .testTarget(
            name: "UnderstudyKitTests",
            dependencies: ["UnderstudyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
