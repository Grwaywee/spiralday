// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spiralday",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // 종이 · 저장소 · 페이지 그리기 · 넘김 엔진 (macOS · iOS 공용, 공개 MIT)
        .library(name: "SpiraldayKit", targets: ["SpiraldayKit"]),
    ],
    dependencies: [
        // 원격 업데이트 (appcast: https://spiralday.com/appcast.xml)
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "SpiraldayKit",
            path: "Sources/SpiraldayKit"
        ),
        .testTarget(
            name: "SpiraldayKitTests",
            dependencies: ["SpiraldayKit"],
            path: "Tests/SpiraldayKitTests"
        ),
        .executableTarget(
            name: "Spiralday",
            dependencies: [
                "SpiraldayKit",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/Spiralday",
            linkerSettings: [
                // .app 안의 Contents/Frameworks/Sparkle.framework 를 찾는다
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
