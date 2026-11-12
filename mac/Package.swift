// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NeverSleep",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NeverSleep", targets: ["NeverSleep"]),
        .executable(name: "NeverSleepHelper", targets: ["NeverSleepHelper"]),
    ],
    targets: [
        // XPC protocol + identifiers shared by the app and the privileged helper.
        .target(name: "NeverSleepShared"),
        // Platform-light logic (lid-mode state machine, command validation) that can be unit tested.
        .target(name: "NeverSleepCore"),
        .executableTarget(
            name: "NeverSleep",
            dependencies: ["NeverSleepShared", "NeverSleepCore"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        ),
        .executableTarget(
            name: "NeverSleepHelper",
            dependencies: ["NeverSleepShared"]
        ),
        // Unit tests for the lid-mode engine and command validation. A plain executable
        // (`swift run NeverSleepSelfTest`) because the Command Line Tools ship without the
        // Swift Testing / XCTest macro plugins.
        .executableTarget(name: "NeverSleepSelfTest", dependencies: ["NeverSleepCore"]),
    ],
    swiftLanguageModes: [.v5]
)
