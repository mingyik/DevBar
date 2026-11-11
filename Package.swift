// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "DevBar",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "DevBar", targets: ["DevBar"])
  ],
  dependencies: [
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.10.0")
  ],
  targets: [
    .target(name: "DevBarCore"),
    .target(name: "DevBarCapture", dependencies: ["DevBarCore"]),
    .executableTarget(
      name: "DevBar",
      dependencies: [
        "DevBarCore",
        "DevBarCapture",
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
      ],
      resources: [.copy("Resources/Assets.xcassets")]
    ),
    .testTarget(name: "DevBarCoreTests", dependencies: ["DevBarCore"]),
    .testTarget(name: "DevBarTests", dependencies: ["DevBar"]),
    .testTarget(name: "DevBarCaptureTests", dependencies: ["DevBarCapture"]),
  ],
  swiftLanguageModes: [.v6]
)
