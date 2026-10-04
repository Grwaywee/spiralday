import XCTest
import SpiraldayKit
import SpiraldaySync
import SpiraldaySyncTesting
@testable import Spiralday

/// 회귀 (2026-10-04 형광펜 사고) — Mac 앱의 진짜 PlannerStore + PlannerSyncHost 두 대 (임시 폴더) + 가짜 서버.
/// 그룹을 만든 Mac 의 플래너는 형광펜 이름을 바꾸고 id 5 를 지웠다. 처음 켠 기기(예시 플래너만)가 합류하면 받은 책을 처음 만들 때
/// (호스트 updateBook: 파일 없음 → transform(nil) → 엔진의 emptyPlannerData) 기본 형광펜이 이 기기의 편집으로 올라가 두 기기 모두
/// 기본 형광펜이 됐다. iOS 호스트(apple/Sync/PlannerSyncHost.swift)의 updateBook 도 같은 길이었다 (파일 없음 → cur = nil).
/// 고친 것: 엔진은 이 기기에 없던 책을 만들 때 넣기 직전의 비교를 하지 않고, 기본 형광펜은 "설정 안 됨" (도장 없음).
/// 펼친 책 파일을 잃은 채 켜면 PlannerStore 가 그 책을 booksOpenedWithoutFile 로 기억하고, 호스트는 엔진이 받아들일 때까지 .missing
@MainActor
final class DefaultFillHostTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    struct Dev {
        let store: PlannerStore
        let host: PlannerSyncHost
        let engine: SyncEngine
    }

    private func dev(_ server: FakeSyncServer, ip: String, platform: SyncPlatform, dir given: URL? = nil,
                     storage: MemorySyncStorage = MemorySyncStorage(), credentials: MemoryCredentialStore = MemoryCredentialStore()) -> Dev {
        let dir = given ?? FileManager.default.temporaryDirectory.appendingPathComponent("mac-host-defaults-\(UUID().uuidString)")
        if given == nil { dirs.append(dir) }
        let store = PlannerStore(folder: dir)
        let host = PlannerSyncHost(store: store)
        let engine = SyncEngine(SyncEngineOptions(host: host, transport: server.transport(ip: ip), storage: storage,
                                                  credentials: credentials, platform: platform, auto: false,
                                                  scanDelayMs: 5, pushDelayMs: 5, pollMs: 100))
        store.onSaved = { b, l in
            if let b { engine.localChanged(bookId: b.uuidString) }
            if l { engine.localChanged(library: true) }
        }
        store.onDeleted = { engine.localChanged(deletedBooks: [$0.uuidString]) }
        return Dev(store: store, host: host, engine: engine)
    }

    private func sync(_ devs: Dev...) async throws {
        for _ in 0..<3 { for d in devs { d.store.saveNow(); try await d.engine.syncNow() } }
    }

    static let ownerCats: [Highlighter] = [
        Highlighter(id: 0, name: "개발 업무", hex: "8EDCD2", counts: true),
        Highlighter(id: 1, name: "외부 일정", hex: "F8B38A", counts: true),
        Highlighter(id: 2, name: "일반 업무", hex: "A9CFF3", counts: true),
        Highlighter(id: 3, name: "개인 일정", hex: "F3DB78", counts: false),
        Highlighter(id: 4, name: "운동", hex: "CDB6EF", counts: false),
        Highlighter(id: 6, name: "휴식·이동", hex: "CFCFD4", counts: false),
        Highlighter(id: 7, name: "비 계획", hex: "B9E4A8", counts: true),
    ]

    /// 책 파일의 형광펜 (앱이 여는 그대로 — PlannerStore.decodeFile)
    private func fileCategories(_ d: Dev, _ book: UUID) -> [Highlighter]? {
        guard case let .data(raw) = d.store.readBookRaw(book) else { return nil }
        return (try? PlannerStore.decodeFile(PlannerData.self, from: raw))?.prefs.categories
    }

    func testFreshDeviceJoiningKeepsTheCreatorsCustomCategories() async throws {
        let server = FakeSyncServer()
        // 그룹을 만든 Mac: 형광펜을 바꾼 플래너 한 권 (+ 예시 플래너)
        let mac = dev(server, ip: "10.0.0.1", platform: .mac)
        mac.store.seedSampleBookIfNeeded()
        let book = mac.store.createBook(name: "나의 업무 일지", start: Dates.parse("2026-09-29")!, end: nil, cover: 4)
        mac.store.editPrefs {
            $0.categories = Self.ownerCats
            $0.defaultTheme = 4
            $0.motto = "회귀 시험의 첫 장 글"
        }
        mac.store.saveNow()
        XCTAssertEqual(fileCategories(mac, book), Self.ownerCats)
        try await mac.engine.initialize()
        _ = try await mac.engine.createGroup(deviceName: "검증 Mac")
        try await mac.engine.syncNow()

        // 처음 켠 기기: 책장이 없어 새로 만들고 예시 플래너만 꽂는다 (내 플래너 없음)
        let fresh = dev(server, ip: "10.0.0.2", platform: .iPhone)
        XCTAssertTrue(fresh.store.libraryCreated)
        fresh.store.seedSampleBookIfNeeded()
        XCTAssertTrue(fresh.store.userBooks.isEmpty)
        try await fresh.engine.initialize()
        let offer = try await mac.engine.startPairing(mode: .qr)
        let join = try await fresh.engine.joinGroup(offer.qrText!, deviceName: "새 iPhone")
        _ = try await offer.wait(intervalMs: 5)
        try await offer.approve(enteredDigits: join.confirmDigits)
        guard case .approved = try await join.waitForApproval(intervalMs: 5) else { return XCTFail("승인") }
        try await join.accept()
        try await sync(fresh, mac)

        XCTAssertEqual(fresh.store.userBooks.map(\.id), [book], "받은 책")
        XCTAssertEqual(fresh.store.library.activeID, book, "들어온 기기는 받은 내 책을 편다")
        let freshCats = fileCategories(fresh, book)
        let macCats = fileCategories(mac, book)
        let macOpen = mac.store.data.prefs.categories
        XCTAssertEqual(fresh.store.data.prefs.defaultTheme, 4, "기본값과 같은 단일 필드는 도장을 받지 않아 그룹 값이 남는다")
        XCTAssertEqual(fresh.store.data.prefs.motto, "회귀 시험의 첫 장 글")
        XCTAssertEqual(freshCats, Self.ownerCats, "들어온 기기")
        XCTAssertEqual(macCats, Self.ownerCats, "그룹을 만든 Mac 의 파일")
        XCTAssertEqual(macOpen, Self.ownerCats, "그룹을 만든 Mac 의 펼친 책")
        XCTAssertFalse(macOpen.contains { $0.id == 5 }, "지운 형광펜 5 가 살아나지 않는다")
    }

    /// 같은 실패 모양 (Kit 쪽 기본값): 펼친 책의 파일이 꺼져 있는 동안 사라지면 PlannerStore.loadBook 이 빈 책(PlannerData())을 편다.
    /// 예전 호스트는 펼친 책을 메모리에서 읽어(readBook — 'missing' 이 아니었다) 엔진이 그 빈 값을 이 기기의 편집으로 비교했다 →
    /// 할 일 · COMMENT 를 지우고 형광펜을 기본값으로 되돌린 것이 모든 기기에 갔다. 이제 저장소가 그 책을 booksOpenedWithoutFile 로
    /// 기억하고 호스트는 .missing → 엔진이 동기화된 내용으로 되살린다. (Windows · Android: web store.missingFiles 도 같다)
    /// A 와 B (내용이 있는 책을 함께 씀) → B 를 끄고 펼친 책 파일만 지운 뒤 같은 폴더 · 같은 동기화 상태로 다시 켠 B2
    private func lostOpenFile() async throws -> (a: Dev, b2: Dev, book: UUID, d1: Date) {
        let server = FakeSyncServer()
        let a = dev(server, ip: "10.0.0.1", platform: .mac)
        let book = a.store.createBook(name: "나의 업무 일지", start: Dates.parse("2026-09-29")!, end: nil)
        let d1 = Dates.parse("2026-10-01")!
        a.store.editDay(d1) { $0.comment = "A 의 글"; $0.tasks = [PlanTask(text: "할 일", cat: 0, row: 0)] }
        a.store.saveNow()
        try await a.engine.initialize()
        _ = try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent("mac-host-defaults-\(UUID().uuidString)")
        dirs.append(dirB)
        let storageB = MemorySyncStorage(), credsB = MemoryCredentialStore()
        let b = dev(server, ip: "10.0.0.2", platform: .mac, dir: dirB, storage: storageB, credentials: credsB)
        try await b.engine.initialize()
        let offer = try await a.engine.startPairing(mode: .qr)
        let join = try await b.engine.joinGroup(offer.qrText!, deviceName: "B")
        _ = try await offer.wait(intervalMs: 5)
        try await offer.approve(enteredDigits: join.confirmDigits)
        guard case .approved = try await join.waitForApproval(intervalMs: 5) else { throw XCTSkip("승인되지 않음") }
        try await join.accept()
        try await sync(a, b)
        a.store.editPrefs { $0.categories = Self.ownerCats }      // 합류 뒤의 진짜 편집 (합류 경로의 문제와 섞이지 않게)
        try await sync(a, b)
        XCTAssertEqual(b.store.data.prefs.categories, Self.ownerCats)
        XCTAssertEqual(b.store.library.activeID, book)
        XCTAssertTrue(b.store.booksOpenedWithoutFile.isEmpty)

        // B 를 끄고, 꺼져 있는 동안 펼친 책의 파일만 사라진다 → 같은 폴더 · 같은 동기화 상태로 다시 켠다
        await b.engine.stop()
        try FileManager.default.removeItem(at: dirB.appendingPathComponent("books/\(book.uuidString).json"))
        let b2 = dev(server, ip: "10.0.0.2", platform: .mac, dir: dirB, storage: storageB, credentials: credsB)
        XCTAssertEqual(b2.store.library.activeID, book)
        XCTAssertEqual(b2.store.booksOpenedWithoutFile, [book], "파일 없이 연 책")
        XCTAssertEqual(b2.store.data.prefs.categories, Prefs.defaultCategories, "Kit 이 편 빈 책")
        let read = await b2.host.readBook(id: book.uuidString)
        XCTAssertEqual(read, .missing, "호스트는 빈 책이 아니라 파일 없음으로 알린다")
        try await b2.engine.initialize()
        return (a, b2, book, d1)
    }

    func testOpenBookFileMissingAtLaunchIsNotUploadedAsAnEmptyBook() async throws {
        let (a, b2, book, d1) = try await lostOpenFile()
        try await sync(b2, a)
        let aDay = a.store.day(d1)
        let (aCats, bCats) = (a.store.data.prefs.categories, b2.store.data.prefs.categories)
        XCTAssertEqual(aDay.comment, "A 의 글", "다른 기기의 COMMENT 가 지워지지 않는다")
        XCTAssertEqual(aDay.tasks.count, 1, "다른 기기의 할 일이 지워지지 않는다")
        XCTAssertEqual(aCats, Self.ownerCats, "다른 기기의 형광펜이 기본값이 되지 않는다")
        XCTAssertEqual(bCats, Self.ownerCats, "되살린 기기")
        XCTAssertEqual(b2.store.day(d1).comment, "A 의 글", "되살린 기기의 펼친 책")
        XCTAssertTrue(b2.store.booksOpenedWithoutFile.isEmpty, "엔진이 받아들인 뒤에는 보통 책")
        XCTAssertEqual(fileCategories(b2, book), Self.ownerCats, "되살린 책 파일")
    }

    /// 엔진이 되살리기 전에 사용자가 빈 책에 쓴 글(저장까지 됨)도 남는다 — 되살린 내용 + 새 글
    func testWhatIsWrittenIntoTheEmptyBookBeforeTheRestoreStays() async throws {
        let (a, b2, book, d1) = try await lostOpenFile()
        let d3 = Dates.parse("2026-10-03")!
        b2.store.editDay(d3) { $0.comment = "빈 책에 쓴 글" }
        b2.store.saveNow()
        XCTAssertEqual(b2.store.booksOpenedWithoutFile, [book], "파일을 써도 엔진이 받아들일 때까지는 파일 없음")
        try await sync(b2, a)
        for s in [a.store, b2.store] {
            XCTAssertEqual(s.day(d1).comment, "A 의 글")
            XCTAssertEqual(s.day(d3).comment, "빈 책에 쓴 글")
            XCTAssertEqual(s.data.prefs.categories, Self.ownerCats)
        }
    }
}
