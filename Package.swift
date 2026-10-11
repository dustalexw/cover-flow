// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CoverFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CProjectM", path: "Sources/CProjectM", linkerSettings: [.linkedFramework("OpenGL")]),
        .executableTarget(
            name: "CoverFlow",
            dependencies: ["CProjectM"],
            path: "Sources/CoverFlow",
            resources: [.copy("Visualizer/Presets")]
        ),
        .testTarget(name: "CoverFlowTests", dependencies: ["CoverFlow"], resources: [.copy("Fixtures")])
    ]
)
