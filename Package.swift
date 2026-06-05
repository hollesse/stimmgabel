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
    ],
    targets: [
        .target(
            name: "AudioEngine",
            path: "Sources/AudioEngine",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .target(
            name: "MenubarUI",
            dependencies: ["AudioEngine"],
            path: "Sources/MenubarUI"
        ),
        .testTarget(
            name: "AudioEngineTests",
            dependencies: ["AudioEngine"],
            path: "Tests/AudioEngineTests"
        ),
    ]
)
