// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spiralday",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 원격 업데이트 (appcast: https://spiralday.com/appcast.xml)
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Spiralday",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Spiralday",
            linkerSettings: [
                // .app 안의 Contents/Frameworks/Sparkle.framework 를 찾는다
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
