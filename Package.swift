// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "audio-now",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser",
                 from: "1.5.0"),
    ],
    targets: [
        .target(name: "AudioNowCore"),
        .executableTarget(
            name: "audio",
            dependencies: [
                "AudioNowCore",
                .product(name: "ArgumentParser",
                         package: "swift-argument-parser"),
            ]),
        .executableTarget(name: "fakeworker", dependencies: ["AudioNowCore"]),
        // Plain executable test-runner: the CommandLineTools toolchain has
        // no Testing/XCTest modules. `make test` runs it; exit 0 = pass.
        .executableTarget(name: "coretests", dependencies: ["AudioNowCore"]),
    ]
)
