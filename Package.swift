// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "CodeAtlas", platforms: [.macOS(.v14)], products: [
    .executable(name: "CodeAtlas", targets: ["CodeAtlas"]),
    .library(name: "AtlasCore", targets: ["AtlasCore"])
], targets: [
    .target(name: "AtlasCore"),
    .executableTarget(name: "CodeAtlas", dependencies: ["AtlasCore"], resources: [.copy("Resources/graph")]),
    .testTarget(name: "AtlasCoreTests", dependencies: ["AtlasCore"])
])
