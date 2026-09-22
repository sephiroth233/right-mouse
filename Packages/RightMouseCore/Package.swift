// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RightMouseCore", platforms: [.macOS(.v14)], products: [.library(name: "RightMouseCore", targets: ["RightMouseCore"])], targets: [.target(name: "RightMouseCore"), .testTarget(name: "RightMouseCoreTests", dependencies: ["RightMouseCore"])], swiftLanguageVersions: [.v5])
