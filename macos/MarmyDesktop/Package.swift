// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MarmyDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarmyCore", targets: ["MarmyCore"]),
        .library(name: "MarmyRuntime", targets: ["MarmyRuntime"]),
        .library(name: "MarmyUI", targets: ["MarmyUI"]),
        .executable(name: "MarmyDesktop", targets: ["MarmyDesktop"]),
        .executable(name: "marmy-agent-launch", targets: ["marmy-agent-launch"]),
    ],
    dependencies: [
        // Pinned to the exact v1.20.0 commit: the embedded terminal is the part
        // of the app that must not change under us.
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            revision: "5d14406844143538cd8f8851d2d8a67c1fe443e5"),
    ],
    targets: [
        .target(name: "MarmyCore"),
        .target(name: "MarmyRuntime", dependencies: ["MarmyCore"]),
        .target(
            name: "MarmyUI",
            dependencies: [
                "MarmyCore",
                "MarmyRuntime",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]),
        .executableTarget(name: "marmy-agent-launch", dependencies: ["MarmyRuntime"]),
        .executableTarget(name: "MarmyDesktop", dependencies: ["MarmyUI", "MarmyRuntime"]),
        .testTarget(name: "MarmyCoreTests", dependencies: ["MarmyCore"]),
        .testTarget(
            name: "MarmyRuntimeTests", dependencies: ["MarmyRuntime", "MarmyCore"],
            // Screens captured from the real CLIs, read as they were captured.
            resources: [.copy("Fixtures")]),
        .testTarget(name: "MarmyUITests", dependencies: ["MarmyUI", "MarmyCore", "MarmyRuntime"]),
    ]
)
