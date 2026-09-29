// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TinyPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TinyPlayer", path: "Sources/TinyPlayer")
    ]
)
