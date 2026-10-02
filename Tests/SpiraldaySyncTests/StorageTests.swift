// 동기화 상태 저장소 (메모리 · 파일 일지) · Keychain · 서버 주소 설정
import XCTest
@testable import SpiraldaySync
import SpiraldaySyncTesting

final class StorageTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("spiralday-sync-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMemoryStorage() async throws {
        let s = MemorySyncStorage()
        try await s.write(StorageBatch(meta: ["a": 1], put: [("k", ["x": 1])]))
        try await s.write(StorageBatch(put: [("j", 2)], del: ["k"]))
        let d = try await s.load()
        XCTAssertEqual(d.meta, ["a": 1])
        XCTAssertEqual(d.records.map(\.0), ["j"])
        try await s.clear()
        let e = try await s.load()
        XCTAssertNil(e.meta)
        XCTAssertTrue(e.records.isEmpty)
    }

    func testFileStorageJournalReplayAndCompaction() async throws {
        let s = FileSyncStorage(directory: dir)
        _ = try await s.load()
        for i in 0..<200 {
            try await s.write(StorageBatch(meta: ["n": JSONValue(i)], put: [("r\(i % 7)", .string(String(repeating: "가", count: 5000) + "\(i)"))]))
        }
        try await s.write(StorageBatch(del: ["r0"]))
        // 다시 열면 같은 내용
        let again = FileSyncStorage(directory: dir)
        let d = try await again.load()
        XCTAssertEqual(d.meta, ["n": 199])
        XCTAssertEqual(d.records.map(\.0), ["r1", "r2", "r3", "r4", "r5", "r6"])
        XCTAssertEqual(d.records.first { $0.0 == "r3" }?.1.stringValue?.hasSuffix("199"), true) // 199 % 7 == 3
        XCTAssertEqual(d.records.first { $0.0 == "r2" }?.1.stringValue?.hasSuffix("198"), true)
        // 사본으로 줄였다 (일지가 1MiB 를 넘지 않는다)
        let journal = try Data(contentsOf: dir.appendingPathComponent("journal.jsonl"))
        XCTAssertLessThan(journal.count, 2 << 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.json").path))
    }

    func testFileStorageIgnoresTornLastLineAndStaleJournal() async throws {
        let s = FileSyncStorage(directory: dir)
        _ = try await s.load()
        try await s.write(StorageBatch(meta: ["v": 1], put: [("a", 1)]))
        try await s.write(StorageBatch(put: [("b", 2)]))
        // 쓰다가 꺼진 마지막 줄
        let jurl = dir.appendingPathComponent("journal.jsonl")
        let h = try FileHandle(forWritingTo: jurl)
        try h.seekToEnd()
        try h.write(contentsOf: Data(#"{"g":0,"put":{"c":"#.utf8))
        try h.close()
        var d = try await FileSyncStorage(directory: dir).load()
        XCTAssertEqual(d.records.map(\.0), ["a", "b"])
        // 사본을 새로 쓴 뒤 일지를 비우기 전에 꺼짐 → 옛 일지 줄은 다시 덮지 않는다
        let s2 = FileSyncStorage(directory: dir)
        _ = try await s2.load()
        try await s2.write(StorageBatch(put: [("a", 10)]))
        try await s2.compactNow()
        let stale = #"{"g":0,"put":{"a":1}}"# + "\n"
        try Data(stale.utf8).write(to: jurl)
        d = try await FileSyncStorage(directory: dir).load()
        XCTAssertEqual(d.records.first { $0.0 == "a" }?.1, 10)
        try await s2.clear()
        d = try await FileSyncStorage(directory: dir).load()
        XCTAssertTrue(d.records.isEmpty)
        XCTAssertNil(d.meta)
    }

    func testCorruptSnapshotIsSetAsideNotFatal() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{깨진".utf8).write(to: dir.appendingPathComponent("state.json"))
        let d = try await FileSyncStorage(directory: dir).load()
        XCTAssertNil(d.meta)
        XCTAssertTrue(d.records.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("state.json.corrupt-") })
    }

    /// 엔진이 파일 저장소로 껐다 켜도 오프라인 편집이 남는다
    func testEngineWithFileStorageKeepsOfflineQueue() async throws {
        let server = FakeSyncServer()
        let net = FakeNet()
        let host = MemoryHost()
        let book = addBook(host, "책", withComment("처음"))
        let creds = MemoryCredentialStore()
        var e = SyncEngine(SyncEngineOptions(host: host, transport: server.transport(net: net), storage: FileSyncStorage(directory: dir),
                                             credentials: creds, platform: .iPad, auto: false))
        try await e.initialize()
        try await e.createGroup(deviceName: "iPad")
        try await e.syncNow()
        net.offline = true
        host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "오프라인"]) }
        try await e.syncNow()
        var st = await e.status
        XCTAssertEqual(st.state, .offline)
        XCTAssertGreaterThan(st.pending, 0)
        await e.dispose()
        net.offline = false
        e = SyncEngine(SyncEngineOptions(host: host, transport: server.transport(net: net), storage: FileSyncStorage(directory: dir),
                                         credentials: creds, platform: .iPad, auto: false))
        try await e.initialize()
        st = await e.status
        XCTAssertGreaterThan(st.pending, 0)
        try await e.syncNow()
        st = await e.status
        XCTAssertEqual(st.pending, 0)
        XCTAssertEqual(st.state, .idle)
    }
}

final class KeychainTests: XCTestCase {
    func testKeychainRoundTrip() async throws {
        let c = Credentials(gid: "G", deviceId: "D", token: "T", key: "K")
        // 데이터 보호 키체인은 서명된 앱에서만 열린다 → 명령줄 테스트는 SPIRALDAY_KEYCHAIN_TEST=1 일 때 로그인 키체인으로
        let legacy = ProcessInfo.processInfo.environment["SPIRALDAY_KEYCHAIN_TEST"] == "1"
        let store = KeychainCredentialStore(service: "com.spiralday.sync.test.\(UUID().uuidString)", useDataProtectionKeychain: !legacy)
        do {
            try await store.set(c)
        } catch let e as KeychainError where e.status == errSecMissingEntitlement || e.status == errSecNotAvailable {
            throw XCTSkip("이 환경에서는 데이터 보호 키체인을 쓸 수 없음 (\(e.status)) — 앱에서는 된다")
        }
        let got = try await store.get()
        XCTAssertEqual(got, c)
        let c2 = Credentials(gid: "G2", deviceId: "D2", token: "T2", key: "K2")
        try await store.set(c2)
        let got2 = try await store.get()
        XCTAssertEqual(got2, c2)
        try await store.set(nil)
        let gone = try await store.get()
        XCTAssertNil(gone)
    }
}

final class ServerConfigTests: XCTestCase {
    func testResolveOrderAndValidation() {
        let d = UserDefaults(suiteName: "spiralday-sync-test-\(UUID().uuidString)")!
        XCTAssertEqual(SyncServerConfig.resolve(bundle: Bundle(for: Self.self), defaults: d, environment: [:]).url.absoluteString, "https://sync.spiralday.com")
        XCTAssertEqual(SyncServerConfig.resolve(bundle: Bundle(for: Self.self), defaults: d, environment: [:]).source, .production)
        let env = ["SPIRALDAY_SYNC_URL": "http://127.0.0.1:8080/"]
        XCTAssertEqual(SyncServerConfig.resolve(defaults: d, environment: env).url.absoluteString, "http://127.0.0.1:8080")
        XCTAssertTrue(SyncServerConfig.setDeveloperOverride("https://staging.example.com", defaults: d))
        XCTAssertEqual(SyncServerConfig.resolve(defaults: d, environment: env).url.absoluteString, "https://staging.example.com")
        XCTAssertEqual(SyncServerConfig.resolve(defaults: d, environment: env).source, .developerOverride)
        XCTAssertFalse(SyncServerConfig.setDeveloperOverride("http://evil.example.com", defaults: d))
        XCTAssertTrue(SyncServerConfig.setDeveloperOverride(nil, defaults: d))
        XCTAssertEqual(SyncServerConfig.resolve(defaults: d, environment: env).source, .environment)
        for ok in ["https://sync.spiralday.com", "http://localhost:8080", "http://192.168.0.10:8080", "http://mac.local:8080", "http://[::1]:8080", "http://10.1.2.3"] {
            XCTAssertNotNil(SyncServerConfig.validate(ok), ok)
        }
        for bad in ["http://sync.spiralday.com", "ftp://x", "https://x.com/path", "https://x.com?q=1", "not a url", "", "http://172.32.0.1", "https://user:pw@x.com"] {
            XCTAssertNil(SyncServerConfig.validate(bad), bad)
        }
    }
}
