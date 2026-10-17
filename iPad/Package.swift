// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "CoverFlowiPadCore", platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.library(name: "iPadSignal", targets: ["iPadSignal"])],
  targets: [
    .binaryTarget(name: "onnxruntime", path: "Vendor/onnxruntime.xcframework"),
    .target(
      name: "NativeMDX", dependencies: ["onnxruntime"], path: "Native", publicHeadersPath: "include"
    ),
    .target(name: "iPadSignal", dependencies: ["NativeMDX"], path: "Core"),
    .testTarget(
      name: "iPadSignalTests", dependencies: ["iPadSignal"], path: "Tests",
      resources: [.copy("Fixtures")]),
  ], cxxLanguageStandard: .cxx17)
