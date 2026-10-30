// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TranscribeAndSend",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TSApp", targets: ["TSApp"])],
    targets: [
        .target(name: "TSCore"),
        .target(name: "TSMac", dependencies: ["TSCore"]),
        .executableTarget(name: "TSApp", dependencies: ["TSCore", "TSMac"], exclude: []),
        .testTarget(name: "TSCoreTests", dependencies: ["TSCore"]),
        .testTarget(name: "TSMacTests", dependencies: ["TSCore", "TSMac"]),
        .testTarget(name: "TSAppTests", dependencies: ["TSApp", "TSCore", "TSMac"])
    ]
)
