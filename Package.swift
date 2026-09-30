// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ElanPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ElanPlayer", path: "Sources/ElanPlayer")
    ]
)
