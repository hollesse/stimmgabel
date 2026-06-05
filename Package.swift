// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Stimmgabel",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .library(name: "MenubarUI", targets: ["MenubarUI"]),
        .library(name: "DriverIPC", targets: ["DriverIPC"]),
    ],
    targets: [
        .target(
            name: "AudioEngine",
            dependencies: ["DriverIPC"],
            path: "Sources/AudioEngine",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
            ]
        ),
        .target(
            name: "MenubarUI",
            dependencies: ["AudioEngine"],
            path: "Sources/MenubarUI"
        ),
        // Pure-C ring buffer used by both the driver bundle and the DriverIPCTests target.
        // No framework dependencies — the ring buffer is stdlib-only.
        .target(
            name: "DriverIPC",
            path: "Sources/DriverIPC",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "AudioEngineTests",
            dependencies: ["AudioEngine"],
            path: "Tests/AudioEngineTests"
        ),
        .testTarget(
            name: "DriverIPCTests",
            dependencies: ["DriverIPC"],
            path: "Tests/DriverIPCTests"
        ),
        .testTarget(
            name: "MenubarUITests",
            dependencies: ["MenubarUI"],
            path: "Tests/MenubarUITests"
        ),
    ]
)
