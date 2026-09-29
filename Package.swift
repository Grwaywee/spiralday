// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spiralday",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Spiralday", path: "Sources/Spiralday")
    ]
)
