// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PaperPlanner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PaperPlanner", path: "Sources/PaperPlanner")
    ]
)
