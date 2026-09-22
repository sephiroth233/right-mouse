// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RightMouse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RightMouseCore", targets: ["RightMouseCore"]),
        .executable(name: "RightMouse", targets: ["RightMouse"]),
        .executable(name: "RightMouseCheck", targets: ["RightMouseCheck"])
    ],
    targets: [
        .target(name: "RightMouseCore", path: "Packages/RightMouseCore/Sources/RightMouseCore"),
        .executableTarget(name: "RightMouse", dependencies: ["RightMouseCore"], path: "Apps/RightMouse"),
        .executableTarget(name: "RightMouseCheck", dependencies: ["RightMouseCore"], path: "tools/RightMouseCheck"),
        .testTarget(name: "RightMouseCoreTests", dependencies: ["RightMouseCore"], path: "Packages/RightMouseCore/Tests/RightMouseCoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
