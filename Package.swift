// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "PiMac",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "PiMac", targets: ["PiMacApp"])
  ],
  targets: [
    .executableTarget(
      name: "PiMacApp",
      // Legacy Fast extension is retained for compatibility tests, not loaded by the Server adapter.
      exclude: ["Resources/AppIcon.icns", "Resources/pimac-fast.ts"],
      resources: [
        .process("Resources/AppIcon.png"),
        .copy("Resources/t3-bridge"),
      ]
    ),
    .testTarget(name: "PiMacAppTests", dependencies: ["PiMacApp"]),
  ]
)
