import XCTest
import SpiraldayKit
import SpiraldaySync
import SpiraldaySyncTesting
@testable import Spiralday

/// Mac 앱의 PlannerSyncHost 를 진짜 엔진 + 가짜 서버(메모리)에 붙인다: 두 PlannerStore(임시 폴더)가 같은 플래너가 되고,
/// 쓰는 중인 칸은 지키되 포커스만 있는 칸은 더 새 글을 받고(그때 그 칸의 ⌘Z 기록을 비우라고 알린다), 지운 책은 양쪽에서 사라지고,
/// 읽지 못한 책은 건드리지 않는다.
/// transform 이 불렸는지 (transform 은 @Sendable)
final class CalledFlag: @unchecked Sendable { var value = false }

@MainActor
final class PlannerSyncHostTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    struct Dev {
        let store: PlannerStore
        let host: PlannerSyncHost
        let engine: SyncEngine
        let dir: URL
    }

    private func dev(_ server: FakeSyncServer, ip: String) -> Dev {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-host-sync-\(UUID().uuidString)")
        dirs.append(dir)
        let store = PlannerStore(folder: dir)
        let host = PlannerSyncHost(store: store)
        let engine = SyncEngine(SyncEngineOptions(host: host, transport: server.transport(ip: ip), storage: MemorySyncStorage(),
                                                  credentials: MemoryCredentialStore(), platform: .mac, auto: false,
                                                  scanDelayMs: 5, pushDelayMs: 5, pollMs: 100))
        store.onSaved = { b, l in
            if let b { engine.localChanged(bookId: b.uuidString) }
            if l { engine.localChanged(library: true) }
        }
        store.onDeleted = { engine.localChanged(deletedBooks: [$0.uuidString]) }
        return Dev(store: store, host: host, engine: engine, dir: dir)
    }

    private func sync(_ devs: Dev...) async throws {
        for _ in 0..<3 { for d in devs { d.store.saveNow(); try await d.engine.syncNow() } }
    }

    private func pair(_ a: Dev, _ b: Dev) async throws {
        let offer = try await a.engine.startPairing(mode: .qr)
        let join = try await b.engine.joinGroup(offer.qrText!, deviceName: "B")
        _ = try await offer.wait(intervalMs: 5)
        try await offer.approve(enteredDigits: join.confirmDigits)
        guard case .approved = try await join.waitForApproval(intervalMs: 5) else { return XCTFail("승인") }
        try await join.accept()
    }

    let d1 = Dates.parse("2026-10-01")!
    var d2: Date { Dates.add(days: 1, to: d1) }

    func testTwoMacsBecomeTheSamePlanner() async throws {
        let server = FakeSyncServer()
        let a = dev(server, ip: "10.0.0.1")
        let book = a.store.createBook(name: "내 플래너", start: Dates.add(days: -3, to: d1), end: nil)
        let orig = UUID()
        a.store.editDay(d1) { $0.tasks = [PlanTask(id: orig, text: "견적서 비교", cat: 1, row: 0)]; $0.comment = "서재 Mac 에서" }
        a.store.saveNow()
        try await a.engine.initialize()
        _ = try await a.engine.createGroup(deviceName: "서재 Mac")
        try await a.engine.syncNow()

        let b = dev(server, ip: "10.0.0.2")
        XCTAssertTrue(b.store.libraryCreated)
        try await b.engine.initialize()
        try await pair(a, b)
        try await sync(a, b)
        XCTAssertEqual(b.store.library.activeID, book, "들어온 내가 만든 첫 책을 편다")
        XCTAssertEqual(b.store.day(d1).comment, "서재 Mac 에서")
        XCTAssertEqual(b.store.day(d1).tasks.map(\.id), [orig])

        // 두 Mac 에서 따로 → 로 넘겨도 사본은 하나 (결정적 미룸 id)
        a.store.setMark(d1, orig, .moved)
        b.store.setMark(d1, orig, .moved)
        try await sync(a, b)
        XCTAssertEqual(a.store.day(d2).tasks.map(\.id), [PlanTask.carryTaskId(orig)])
        XCTAssertEqual(b.store.day(d2).tasks.map(\.id), [PlanTask.carryTaskId(orig)])

        // b 가 COMMENT 를 쓰다가 (올라간 뒤) 포커스만 둔 채로 있는데 a 가 같은 칸을 고쳤다 → 더 새 a 의 글이 들어오고,
        // 그 칸의 ⌘Z 기록을 비우라고 알린다 (되돌리기가 a 의 글을 지우고 b 의 옛 글로 가지 않게)
        let key = "c|\(Dates.key(d2))"
        var removed = 0
        var replaced = 0
        b.host.editingKey = { key }
        b.host.onEditedItemRemoved = { removed += 1 }
        b.host.onEditedFieldReplaced = { replaced += 1 }
        b.store.dayField(d2, \.comment).wrappedValue = "회의 준"
        b.store.saveNow()
        try await b.engine.syncNow()
        try await a.engine.syncNow()
        XCTAssertEqual(a.store.day(d2).comment, "회의 준")
        XCTAssertEqual(replaced, 0)
        b.store.editingGrace = 0          // 그 뒤로 한동안 쓰지 않았다
        a.store.dayField(d2, \.comment).wrappedValue = "회의 준비 완료, 내일 발표"
        a.store.saveNow()
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        XCTAssertEqual(b.store.day(d2).comment, "회의 준비 완료, 내일 발표", "포커스만 있던 칸은 더 새 글을 받는다")
        XCTAssertEqual(replaced, 1, "쓰던 칸의 글이 바뀌었다 → ⌘Z 기록을 비운다")
        try await sync(b, a)
        XCTAssertEqual(a.store.day(d2).comment, "회의 준비 완료, 내일 발표", "되돌아가지 않는다")

        // b 가 그 칸에 이어 쓰는 중에 a 가 또 고쳤다 → 쓰는 중인 글이 이긴다 (화면의 글 · 커서 · 되돌리기를 흔들지 않는다)
        b.store.editingGrace = 5
        b.store.dayField(d2, \.comment).wrappedValue = "회의 준비 완료, 내일 발표 (서재에서 이어 씀)"
        a.store.dayField(d2, \.comment).wrappedValue = "거실 Mac 이 또 고침"
        a.store.saveNow()
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        XCTAssertEqual(b.store.day(d2).comment, "회의 준비 완료, 내일 발표 (서재에서 이어 씀)", "쓰는 중인 글은 지킨다")
        XCTAssertEqual(replaced, 1, "지킨 칸은 ⌘Z 기록도 그대로")
        b.host.editingKey = { nil }
        try await sync(b, a)
        XCTAssertEqual(a.store.day(d2).comment, "회의 준비 완료, 내일 발표 (서재에서 이어 씀)")

        // 다른 날의 편집은 쓰는 칸의 ⌘Z 기록을 건드리지 않는다
        b.host.editingKey = { key }
        a.store.editDay(d1) { $0.memos[0] = "다른 날 메모" }
        try await sync(a, b)
        XCTAssertEqual(b.store.day(d1).memos[0], "다른 날 메모")
        XCTAssertEqual(replaced, 1)
        b.host.editingKey = { nil }

        // b 가 쓰던 할 일을 a 가 지웠다 → 편집을 끝내라고 알린다
        let carried = PlanTask.carryTaskId(orig)
        b.host.editingKey = { "t|\(Dates.key(self.d2))|\(carried.uuidString)" }
        a.store.editDay(d2) { $0.tasks.removeAll() }
        try await sync(a, b)
        XCTAssertEqual(removed, 1)
        b.host.editingKey = { nil }

        // a 가 두 번째 책을 만들고, b 가 그 책을 펴 둔 채로 a 가 지운다 → b 는 다른 책을 펴고 파일도 지운다
        var closed: UUID?
        var gone: [String] = []
        b.host.onLibraryApplied = { r, removedBooks in
            if let c = r.closedBook { closed = c }
            gone += removedBooks.map(\.name)
        }
        let second = a.store.createBook(name: "두 번째", start: d1, end: nil)
        a.store.editDay(d1) { $0.comment = "둘째 책" }
        try await sync(a, b)
        XCTAssertTrue(b.store.activate(second))
        XCTAssertEqual(b.store.day(d1).comment, "둘째 책")
        a.store.deleteBook(second)
        try await sync(a, b)
        XCTAssertFalse(b.store.books.contains { $0.id == second })
        XCTAssertEqual(b.store.library.activeID, book)
        XCTAssertEqual(closed, second, "화면이 \"다른 기기에서 지운 플래너\" 안내를 띄울 수 있게 알린다")
        XCTAssertEqual(gone, ["두 번째"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.dir.appendingPathComponent("books/\(second.uuidString).json").path))

        // 펼치지 않은 책도 디스크에서 같다 (writeBookRaw), 펼치지 않은 책이 지워지면 이름을 알린다
        let third = a.store.createBook(name: "셋째", start: d1, end: nil)
        a.store.editDay(d1) { $0.comment = "셋째 책" }
        a.store.activate(book)
        try await sync(a, b)
        let raw = try Data(contentsOf: b.dir.appendingPathComponent("books/\(third.uuidString).json"))
        XCTAssertEqual(try PlannerStore.decodeFile(PlannerData.self, from: raw).days[Dates.key(d1)]?.comment, "셋째 책")
        closed = nil
        gone = []
        a.store.deleteBook(third)
        try await sync(a, b)
        XCTAssertNil(closed)
        XCTAssertEqual(gone, ["셋째"], "펼치지 않은 책이 빠짐 → 안내할 이름")
        await a.engine.dispose()
        await b.engine.dispose()
    }

    /// 읽지 못한 책 파일은 transform 을 부르지 않고 그대로 둔다 (원본을 덮어쓰지 않는다)
    func testUnreadableBookIsNeverTouched() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-host-unreadable-\(UUID().uuidString)")
        dirs.append(dir)
        let store = PlannerStore(folder: dir)
        let a = store.createBook(name: "A", start: d1, end: nil)
        let b = store.createBook(name: "B", start: d1, end: nil)
        store.activate(a)
        store.saveNow()
        let bURL = dir.appendingPathComponent("books/\(b.uuidString).json")
        try Data("{ 깨진 파일".utf8).write(to: bURL)
        let host = PlannerSyncHost(store: store)
        let read = await host.readBook(id: b.uuidString)
        XCTAssertEqual(read, .unreadable)
        let called = CalledFlag()
        try await host.updateBook(id: b.uuidString) { _ in
            called.value = true
            return ["days": [:], "weeks": [:]]
        }
        XCTAssertFalse(called.value, "읽지 못한 책은 transform 을 부르기 전에 돌아간다")
        XCTAssertEqual(try String(contentsOf: bURL, encoding: .utf8), "{ 깨진 파일")
        let badID = await host.readBook(id: "not-a-uuid")
        XCTAssertEqual(badID, .unreadable)
    }

    /// 책장 파일을 읽지 못한 실행: 비교하지도(nil) 넣지도 않는다
    func testUnreadableLibraryIsNeitherReadNorWritten() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-host-lib-\(UUID().uuidString)")
        dirs.append(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ 깨짐".utf8).write(to: dir.appendingPathComponent("library.json"))
        let store = PlannerStore(folder: dir)
        XCTAssertTrue(store.libraryUnreadable)
        let host = PlannerSyncHost(store: store)
        let lib = await host.readLibrary()
        XCTAssertNil(lib)
        let called = CalledFlag()
        try await host.updateLibrary { cur in called.value = true; return cur }
        XCTAssertFalse(called.value)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("library.json"), encoding: .utf8), "{ 깨짐")
    }

    /// transform 을 부른 뒤 넣지 못하면 던진다 (엔진이 넣은 것으로 적지 않게)
    func testFailedWriteAfterTransformThrows() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-host-throw-\(UUID().uuidString)")
        dirs.append(dir)
        let store = PlannerStore(folder: dir)
        let a = store.createBook(name: "A", start: d1, end: nil)
        let b = store.createBook(name: "B", start: d1, end: nil)
        store.activate(a)
        store.saveNow()
        let host = PlannerSyncHost(store: store)
        do {
            // 앱이 읽을 수 없는 모양 (days 가 배열) → 앱 모델로 읽지 못해 쓰지 않고 던진다
            try await host.updateBook(id: b.uuidString) { _ in ["days": [1, 2], "weeks": [:]] }
            XCTFail("던져야 한다")
        } catch {
            XCTAssertTrue(error is DecodingError || error is BookFileError, "\(error)")
        }
        guard case .data = store.readBookRaw(b) else { return XCTFail("원래 파일은 그대로 읽힌다") }
        // 펼친 책도: 읽지 못하는 값이면 던지고 화면의 내용은 그대로
        store.editDay(d1) { $0.comment = "그대로" }
        do {
            try await host.updateBook(id: a.uuidString) { _ in ["days": "망가짐"] }
            XCTFail("던져야 한다")
        } catch {}
        XCTAssertEqual(store.day(d1).comment, "그대로")
    }

    /// 펼치지 않은 책은 Mac 의 JSONEncoder 와 같은 바이트로 쓴다 (기기마다 파일이 같은 바이트)
    func testNonOpenBookIsWrittenInMacEncoderBytes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-host-bytes-\(UUID().uuidString)")
        dirs.append(dir)
        let store = PlannerStore(folder: dir)
        let a = store.createBook(name: "A", start: d1, end: nil)
        let b = store.createBook(name: "B", start: d1, end: nil)
        store.activate(a)
        store.saveNow()
        let host = PlannerSyncHost(store: store)
        let task: JSONValue = ["id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "text": "1/2 정리", "mark": 4, "cat": .null,
                               "carriedFrom": .null, "row": 0]
        let day: JSONValue = ["tasks": [task], "slots": .array((0..<144).map { _ in -1 }), "comment": "https://spiralday.com/a",
                              "memoTags": ["", "", ""], "memos": ["", "", ""], "theme": .null, "notes": [], "ddays": [],
                              "dayOff": false]
        try await host.updateBook(id: b.uuidString) { cur in
            guard case .object(var o)? = cur else { return cur }
            o["days"] = ["2026-10-02": day]
            return .object(o)
        }
        let url = dir.appendingPathComponent("books/\(b.uuidString).json")
        let raw = try Data(contentsOf: url)
        let mac = try PlannerStore.encodeFile(try PlannerStore.decodeFile(PlannerData.self, from: raw))
        XCTAssertEqual(raw, mac, String(decoding: raw, as: UTF8.self))
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(text.contains(#"1\/2 정리"#) && text.contains(#"https:\/\/spiralday.com\/a"#), text)
        XCTAssertFalse(text.contains("dayOff") || text.contains("theme") || text.contains("carriedFrom") || text.contains(#""cat""#), text)
        // 책장에서 빠진 책은 파일을 지운다 (transform 이 nil)
        store.deleteBook(b)
        try Data(mac).write(to: url)
        try await host.updateBook(id: b.uuidString) { _ in nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// 펼친 책을 읽을 때는 저장 전 편집까지 (앱 파일과 같은 JSON)
    func testOpenBookIsReadWithUnsavedEdits() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-host-read-\(UUID().uuidString)")
        dirs.append(dir)
        let store = PlannerStore(folder: dir)
        let a = store.createBook(name: "A", start: d1, end: nil)
        store.saveNow()
        store.editDay(d1) { $0.comment = "아직 저장 전" }
        let host = PlannerSyncHost(store: store)
        guard case .ok(let v) = await host.readBook(id: a.uuidString) else { return XCTFail("읽힘") }
        let back = try PlannerStore.decodeFile(PlannerData.self, from: v.jsonData())
        XCTAssertEqual(back.days[Dates.key(d1)]?.comment, "아직 저장 전")
        let missing = await host.readBook(id: UUID().uuidString)
        XCTAssertEqual(missing, .missing)
    }
}
