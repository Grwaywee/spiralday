import XCTest
import Security
import SpiraldayKit
import SpiraldaySync
import SpiraldaySyncTesting
@testable import Spiralday

/// Mac 앱의 비밀 보관: 로그인 키체인(Developer ID 앱이라 데이터 보호 키체인은 쓰지 않는다) · 앱 데이터 폴더 안의 SyncState.
/// 진짜 키체인을 쓰는 테스트는 `SPIRALDAY_KEYCHAIN_TEST=1` 일 때만, 실행마다 새로 만든 테스트용 서비스 이름으로 돈다
/// (사용자의 Spiralday 항목 "com.spiralday.sync" 는 읽지도 쓰지도 않는다).
@MainActor
final class SyncKeychainTests: XCTestCase {
    private var dirs: [URL] = []
    private var services: [String] = []

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
        for s in services {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s] as CFDictionary)
        }
        services = []
    }

    private func tempStore() -> (PlannerStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-sync-keychain-\(UUID().uuidString)")
        dirs.append(dir)
        return (PlannerStore(folder: dir), dir)
    }

    private func freshDefaults() -> UserDefaults { SyncMemoryDefaults() }

    private func testService() -> String {
        let s = "com.spiralday.mac.sync.test.\(UUID().uuidString)"
        services.append(s)
        return s
    }

    private func requireKeychain() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPIRALDAY_KEYCHAIN_TEST"] == "1",
                          "진짜 키체인 테스트는 SPIRALDAY_KEYCHAIN_TEST=1 일 때만 (테스트용 서비스 이름으로)")
    }

    /// 앱의 구성: 로그인 키체인 · 앱 데이터 폴더 안의 SyncState (Time Machine 제외). 만들기만으로는 키체인도 네트워크도 건드리지 않는다
    func testLiveEnvironmentUsesTheLoginKeychainAndTheAppDataFolder() async throws {
        let (store, dir) = tempStore()
        let service = testService()
        let env = try XCTUnwrap(SyncController.Environment.live(store: store, keychainService: service, defaults: freshDefaults()))
        let creds = try XCTUnwrap(env.credentials as? KeychainCredentialStore)
        XCTAssertEqual(creds.service, service)
        XCTAssertFalse(creds.useDataProtectionKeychain, "Developer ID 앱은 로그인 키체인")
        XCTAssertNil(creds.accessGroup)
        XCTAssertEqual(SyncController.Environment.keychainService, "com.spiralday.sync", "앱의 진짜 항목 이름 (테스트는 쓰지 않는다)")
        XCTAssertEqual(env.platform, .mac)
        XCTAssertEqual(env.backupRoot, dir.appendingPathComponent("SyncBackups", isDirectory: true))
        XCTAssertTrue(env.watchesSystem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("SyncState").path), "켜기 전에는 폴더도 만들지 않는다")

        // 엔진을 만들 때 (켤 때): 데이터 폴더 안에 SyncState, Time Machine 에서 뺀다. initialize 전이라 키체인은 아직
        let host = PlannerSyncHost(store: store)
        let engine = try env.makeEngine(host, URL(string: "https://sync.example.invalid")!, MemoryCredentialStore())
        let state = dir.appendingPathComponent("SyncState", isDirectory: true)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(try state.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(engine.platform, .mac)
        await engine.dispose()
        XCTAssertNotEqual(SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary, nil),
                          errSecSuccess, "테스트용 항목도 만들지 않았다")
    }

    /// 로그인 키체인에 두고 · 읽고 · 지운다 (테스트용 서비스 이름)
    func testKeychainCredentialRoundTrip() async throws {
        try requireKeychain()
        let store = KeychainCredentialStore(service: testService(), useDataProtectionKeychain: false)
        let none = try await store.get()
        XCTAssertNil(none)
        let c = Credentials(gid: "g-\(UUID().uuidString)", deviceId: "d1", token: "t1", key: Data(repeating: 7, count: 32).base64EncodedString())
        try await store.set(c)
        let read = try await store.get()
        XCTAssertEqual(read, c)
        let c2 = Credentials(gid: c.gid, deviceId: "d1", token: "t2", key: c.key)
        try await store.set(c2)
        let read2 = try await store.get()
        XCTAssertEqual(read2, c2, "있으면 고친다 (항목이 둘이 되지 않는다)")
        try await store.set(nil)
        let gone = try await store.get()
        XCTAssertNil(gone)
        try await store.set(nil)    // 없어도 괜찮다
    }

    /// 깨진 항목은 "그룹 없음" 이 아니라 CredentialsUnreadable → 설정에서 [정리하고 다시 시작하기]
    func testBrokenKeychainItemIsReportedAndCanBeCleared() async throws {
        try requireKeychain()
        let service = testService()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: "group-credentials", kSecValueData as String: Data("깨짐".utf8)]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        let broken = KeychainCredentialStore(service: service, useDataProtectionKeychain: false)
        let (store, _) = tempStore()
        let d = freshDefaults()
        d.set("https://sync.spiralday.com", forKey: SyncController.Key.groupURL)
        let env = SyncController.Environment(suggestedName: "x", credentials: broken, defaults: d,
                                             makeEngine: { _, _, _ in XCTFail("엔진을 만들지 않는다"); throw CancellationError() },
                                             backupRoot: FileManager.default.temporaryDirectory, watchesSystem: false)
        let c = SyncController(store: store, env: env)
        await c.start(state: AppState(kind: .daily))
        XCTAssertTrue(c.credsUnreadable)
        XCTAssertFalse(c.inGroup)
        let r = await c.forget()
        XCTAssertTrue(r.ok, r.message ?? "")
        let after = try await broken.get()
        XCTAssertNil(after, "깨진 항목을 지웠다")
    }

    /// 켜고 → 끄고 다시 켜면 로그인 키체인의 자격으로 같은 그룹에 → 이 Mac 에서 끄면 항목을 지운다
    func testControllerKeepsTheGroupInTheLoginKeychainAcrossLaunches() async throws {
        try requireKeychain()
        let server = FakeSyncServer()
        let service = testService()
        let d = freshDefaults()
        func launch() async -> (SyncController, PlannerStore) {
            let (store, _) = tempStore()
            let env = SyncController.Environment(
                suggestedName: "서재 Mac", credentials: KeychainCredentialStore(service: service, useDataProtectionKeychain: false), defaults: d,
                makeEngine: { host, _, creds in
                    SyncEngine(SyncEngineOptions(host: host, transport: server.transport(ip: "10.0.0.1"), storage: MemorySyncStorage(),
                                                 credentials: creds, platform: .mac, scanDelayMs: 10, pushDelayMs: 10, pollMs: 200))
                },
                pollIntervalMs: 20, backupRoot: FileManager.default.temporaryDirectory.appendingPathComponent("kc-\(UUID().uuidString)"),
                watchesSystem: false)
            let c = SyncController(store: store, env: env)
            await c.start(state: AppState(kind: .daily))
            return (c, store)
        }
        let (first, store) = await launch()
        store.createBook(name: "내 플래너", start: Dates.day(Date()), end: nil)
        let r = await first.create(deviceName: "서재 Mac")
        XCTAssertTrue(r.ok, r.message ?? "")
        first.recoveryConfirmed()
        await first.dispose()

        let (second, _) = await launch()
        XCTAssertTrue(second.inGroup, "다시 켜면 키체인의 자격으로 같은 그룹")
        let left = await second.leave()
        XCTAssertTrue(left.ok, left.message ?? "")
        await second.dispose()
        let gone = try await KeychainCredentialStore(service: service, useDataProtectionKeychain: false).get()
        XCTAssertNil(gone, "이 Mac 에서 끄면 키체인 항목도 지운다")
        XCTAssertNil(d.string(forKey: SyncController.Key.groupURL))
    }
}
