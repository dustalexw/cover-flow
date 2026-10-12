// swift-tools-version:5.9
import PackageDescription
import Foundation

let taglib = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/vendor/taglib-install-universal").path

let package = Package(
    name: "CoverFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CProjectM", path: "Sources/CProjectM", linkerSettings: [.linkedFramework("OpenGL")]),
        .target(name: "CArtworkTags", path: "Sources/CArtworkTags",
                cxxSettings: [.unsafeFlags(["-I", taglib + "/include/taglib"])],
                linkerSettings: [.unsafeFlags(["-L", taglib + "/lib"]), .linkedLibrary("tag"), .linkedLibrary("z"), .linkedFramework("CoreFoundation")]),
        .executableTarget(
            name: "CoverFlow",
            dependencies: ["CProjectM", "CArtworkTags"],
            path: "Sources/CoverFlow",
            resources: [.copy("Visualizer/Presets")]
        ),
        .testTarget(name: "CoverFlowTests", dependencies: ["CoverFlow"], resources: [.copy("Fixtures")])
    ],
    cxxLanguageStandard: .cxx17
)
