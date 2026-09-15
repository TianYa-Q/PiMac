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
      exclude: ["Resources/AppIcon.icns"],
      resources: [.process("Resources/AppIcon.png")]
    ),
    .testTarget(name: "PiMacAppTests", dependencies: ["PiMacApp"]),
  ]
)
