// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LavaSec",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LavaSecCore", targets: ["LavaSecCore"])
    ],
    targets: [
        .target(name: "LavaSecCore"),
        .testTarget(name: "LavaSecCoreTests", dependencies: ["LavaSecCore"])
    ]
)
