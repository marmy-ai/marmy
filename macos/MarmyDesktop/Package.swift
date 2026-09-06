// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MarmyDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarmyCore", targets: ["MarmyCore"]),
        .executable(name: "MarmyDesktop", targets: ["MarmyDesktop"]),
    ],
    targets: [
        .target(name: "MarmyCore"),
        .executableTarget(name: "MarmyDesktop", dependencies: ["MarmyCore"]),
        .testTarget(name: "MarmyCoreTests", dependencies: ["MarmyCore"]),
    ]
)
