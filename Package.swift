// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveSubs",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(name: "LiveSubs", path: "Sources/LiveSubs"),
        .executableTarget(name: "LiveSubsIcon", path: "Sources/LiveSubsIcon"),
        .testTarget(name: "LiveSubsTests", dependencies: ["LiveSubs"], path: "Tests/LiveSubsTests"),
    ],
    swiftLanguageModes: [.v5]
)
