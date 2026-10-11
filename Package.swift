// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CoverFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CoverFlow",
            path: "Sources/CoverFlow"
        )
    ]
)
