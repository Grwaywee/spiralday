// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Spiralday",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // 종이 · 저장소 · 페이지 그리기 · 넘김 엔진 (macOS · iOS 공용 · 소스 공개, PolyForm Noncommercial 1.0.0 — LICENSE · LICENSE-HISTORY.md)
        .library(name: "SpiraldayKit", targets: ["SpiraldayKit"]),
        // Spiralday Sync 클라이언트 엔진 (종단간 암호화 · 계정 없음 · 충돌 없는 합치기, macOS · iOS 공용)
        .library(name: "SpiraldaySync", targets: ["SpiraldaySync"]),
        // 테스트 · 앱 개발용: 메모리 안의 가짜 동기화 서버 · 메모리 앱 (제품 코드에서는 쓰지 않는다)
        .library(name: "SpiraldaySyncTesting", targets: ["SpiraldaySyncTesting"]),
    ],
    dependencies: [
        // 원격 업데이트 (appcast: https://spiralday.com/appcast.xml)
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // libsodium (XChaCha20-Poly1305 · crypto_kdf · Argon2id · HMAC-SHA256) — 동기화 엔진의 암호
        .package(url: "https://github.com/jedisct1/swift-sodium.git", "0.11.0"..<"0.12.0"),
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
        .target(
            name: "SpiraldaySync",
            dependencies: [.product(name: "Clibsodium", package: "swift-sodium")],
            path: "Sources/SpiraldaySync",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SpiraldaySyncTesting",
            dependencies: ["SpiraldaySync"],
            path: "Sources/SpiraldaySyncTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SpiraldaySyncTests",
            // SpiraldayKit: 엔진이 앱에 넣는 값을 앱의 진짜 모델로 읽어 본다 (AppDecodeTests)
            dependencies: ["SpiraldaySync", "SpiraldaySyncTesting", "SpiraldayKit"],
            path: "Tests/SpiraldaySyncTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Spiralday",
            dependencies: [
                "SpiraldayKit",
                // Spiralday Sync (기본은 꺼짐 — 설정 → 동기화에서 켤 때만 엔진을 만든다)
                "SpiraldaySync",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/Spiralday",
            linkerSettings: [
                // .app 안의 Contents/Frameworks/Sparkle.framework 를 찾는다
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "SpiraldayAppTests",
            // Mac 앱의 동기화 붙이기 (PlannerSyncHost · SyncController · 말 · 키체인): 가짜 서버 · 메모리 · 임시 폴더로
            dependencies: ["Spiralday", "SpiraldayKit", "SpiraldaySync", "SpiraldaySyncTesting"],
            path: "Tests/SpiraldayAppTests"
        ),
    ],
    // SpiraldayKit · 앱은 Swift 5 모드 그대로, 동기화 엔진만 Swift 6 (위의 swiftLanguageMode)
    swiftLanguageModes: [.v5]
)
