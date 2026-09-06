// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MarmyDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarmyCore", targets: ["MarmyCore"]),
        .library(name: "MarmyRuntime", targets: ["MarmyRuntime"]),
        .executable(name: "MarmyDesktop", targets: ["MarmyDesktop"]),
        .executable(name: "marmy-agent-launch", targets: ["marmy-agent-launch"]),
    ],
    targets: [
        .target(name: "MarmyCore"),
        .target(name: "MarmyRuntime", dependencies: ["MarmyCore"]),
        .executableTarget(name: "marmy-agent-launch", dependencies: ["MarmyRuntime"]),
        .executableTarget(name: "MarmyDesktop", dependencies: ["MarmyCore", "MarmyRuntime"]),
        .testTarget(name: "MarmyCoreTests", dependencies: ["MarmyCore"]),
        .testTarget(name: "MarmyRuntimeTests", dependencies: ["MarmyRuntime", "MarmyCore"]),
    ]
)
