// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cicada",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(name: "Cicada", path: "Sources/Cicada"),
        .executableTarget(name: "CicadaIcon", path: "Sources/CicadaIcon"),
        .testTarget(name: "CicadaTests", dependencies: ["Cicada"], path: "Tests/CicadaTests"),
    ],
    swiftLanguageModes: [.v5]
)
