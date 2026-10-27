// swift-tools-version:5.9
import PackageDescription
import Foundation

let taglib = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/vendor/taglib-install-universal").path
// Decoder-only LGPL FFmpeg, built as shared libraries by scripts/build-ffmpeg.sh and
// bundled in Contents/Frameworks. The second rpath lets `swift test` find them.
let ffmpeg = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/vendor/ffmpeg-install-universal").path

let package = Package(
    name: "CoverFlow",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Core ML Stable Diffusion, used to refine generated album scenes.
        .package(url: "https://github.com/apple/ml-stable-diffusion.git", exact: "1.1.1")
    ],
    targets: [
        .target(name: "CProjectM", path: "Sources/CProjectM", linkerSettings: [.linkedFramework("OpenGL")]),
        .target(name: "CArtworkTags", path: "Sources/CArtworkTags",
                cxxSettings: [.unsafeFlags(["-I", taglib + "/include/taglib"])],
                linkerSettings: [.unsafeFlags(["-L", taglib + "/lib"]), .linkedLibrary("tag"), .linkedLibrary("z"), .linkedFramework("CoreFoundation")]),
        .target(name: "CFFmpegAudio", path: "Sources/CFFmpegAudio",
                cSettings: [.unsafeFlags(["-I", ffmpeg + "/include"])],
                linkerSettings: [.unsafeFlags(["-L", ffmpeg + "/lib",
                                               "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                               "-Xlinker", "-rpath", "-Xlinker", ffmpeg + "/lib"]),
                                 .linkedLibrary("avformat"), .linkedLibrary("avcodec"),
                                 .linkedLibrary("swresample"), .linkedLibrary("avutil")]),
        .executableTarget(
            name: "CoverFlow",
            dependencies: ["CProjectM", "CArtworkTags", "CFFmpegAudio",
                           .product(name: "StableDiffusion", package: "ml-stable-diffusion")],
            path: "Sources/CoverFlow",
            resources: [.copy("Visualizer/Presets"), .copy("Visualizer/Shaders")]
        ),
        .testTarget(name: "CoverFlowTests", dependencies: ["CoverFlow"], resources: [.copy("Fixtures")])
    ],
    cxxLanguageStandard: .cxx17
)
