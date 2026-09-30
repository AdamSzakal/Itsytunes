// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Itsytunes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Itsytunes", path: "Sources/Itsytunes")
    ]
)
