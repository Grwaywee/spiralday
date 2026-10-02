import XCTest
import Combine
import SpiraldayKit

/// → 미룸 id (UUIDv5) · 저장 알림 · 밖에서 넣기 (applyLibrary · applyActiveData · 펼치지 않은 책 파일) · 되돌리기 기록 옮기기
@MainActor
final class ExternalChangesTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func tempFolder() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("spiralday-kit-ext-\(UUID().uuidString)")
        dirs.append(d)
        return d
    }

    private func bookFile(_ dir: URL, _ id: UUID) -> URL { dir.appendingPathComponent("books/\(id.uuidString).json") }

    private func readBook(_ dir: URL, _ id: UUID) throws -> PlannerData {
        try PlannerStore.decodeFile(PlannerData.self, from: Data(contentsOf: bookFile(dir, id)))
    }

    private let d1 = Dates.parse("2026-10-01")!
    private var d2: Date { Dates.add(days: 1, to: d1) }
    private var d3: Date { Dates.add(days: 2, to: d1) }

    // MARK: UUIDv5 · carryTaskId

    func testCarryTaskIdMatchesReferenceVectors() {
        // 고정 값 — 같은 규칙을 쓰는 모든 앱이 같은 값을 내야 한다 (Python uuid.uuid5 와 같다)
        XCTAssertEqual(PlanTask.carryTaskId(UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!).uuidString,
                       "0D594A5F-8FD8-50CA-803B-6260FFD0478F")
        XCTAssertEqual(PlanTask.carryTaskId(UUID(uuidString: "3f2504e0-4f89-11d3-9a0c-0305e82c3301")!).uuidString,
                       "0D594A5F-8FD8-50CA-803B-6260FFD0478F")
        let a = PlanTask.carryTaskId(UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!)
        XCTAssertEqual(a.uuidString, "F0D88FE3-AC08-5FA8-B047-DA3B2BA83191")
        // 사본을 또 넘기면 carryTaskId(사본 id) (Python uuid.uuid5 와 같은 값)
        XCTAssertEqual(PlanTask.carryTaskId(a).uuidString, "D46C7DA0-E4AA-5FE8-8C55-C72547CDEB34")
        XCTAssertNotEqual(PlanTask.carryTaskId(a), a)
        XCTAssertEqual(PlanTask.carryTaskId(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!).uuidString,
                       "694BECAA-9DE7-5819-BF69-7E2CC7DDE5B1")
        // RFC 9562: DNS 이름공간 + "www.example.com"
        XCTAssertEqual(UUID(v5Namespace: UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!, name: "www.example.com").uuidString,
                       "2ED6657D-E927-568B-95E1-2665A8AEA6A2")
        // 이름은 UTF-8
        XCTAssertEqual(UUID(v5Namespace: UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!, name: "미룸 ✓").uuidString,
                       "AA2EA8A8-D10A-543B-8DEA-CF95198821E9")
        // 버전 5 · RFC 변형
        for _ in 0..<50 {
            let s = PlanTask.carryTaskId(UUID()).uuidString
            XCTAssertEqual(Array(s)[14], "5", s)
            XCTAssertTrue("89AB".contains(Array(s)[19]), s)
        }
    }

    func testCarryForwardUsesDeterministicId() throws {
        let orig = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        func store() -> PlannerStore {
            let s = PlannerStore(inMemory: true)
            s.editDay(d1) { $0.tasks = [PlanTask(id: orig, text: "견적서 비교", cat: 3, row: 0)] }
            return s
        }
        let mac = store()
        mac.setMark(d1, orig, .moved)
        let copy = try XCTUnwrap(mac.carriedCopy(of: orig, from: d1))
        XCTAssertEqual(copy.id.uuidString, "0D594A5F-8FD8-50CA-803B-6260FFD0478F")
        XCTAssertEqual(copy.carriedFrom, orig)
        XCTAssertEqual(copy.text, "견적서 비교")
        XCTAssertEqual(copy.cat, 3)
        XCTAssertEqual(copy.mark, .none)

        // 두 곳에서 따로 넘겨도 같은 사본
        let pad = store()
        pad.setMark(d1, orig, .moved)
        XCTAssertEqual(pad.day(d2).tasks.map(\.id), mac.day(d2).tasks.map(\.id))

        // → 를 떼면 손대지 않은 사본은 거두고, 다시 → 하면 같은 id
        mac.setMark(d1, orig, .done)
        XCTAssertTrue(mac.day(d2).tasks.isEmpty)
        mac.setMark(d1, orig, .moved)
        XCTAssertEqual(mac.day(d2).tasks.map(\.id), [copy.id])

        // 사본을 또 넘기면 사본 id 에서 이어진다
        mac.setMark(d2, copy.id, .moved)
        XCTAssertEqual(mac.carriedCopy(of: copy.id, from: d2)?.id, PlanTask.carryTaskId(copy.id))

        // 고친 사본은 → 를 뗐다 붙여도 둘이 되지 않는다
        mac.taskText(d2, id: copy.id).wrappedValue = "견적서 비교 (고침)"
        mac.setMark(d1, orig, .none)
        mac.setMark(d1, orig, .moved)
        XCTAssertEqual(mac.day(d2).tasks.map(\.id), [copy.id])
    }

    func testCarryFallsBackToFreshIdWhenTaken() {
        let orig = UUID()
        let s = PlannerStore(inMemory: true)
        s.editDay(d1) { $0.tasks = [PlanTask(id: orig, text: "a", row: 0)] }
        // 다음 날에 그 id 가 이미 있다 (다른 할 일로)
        s.editDay(d2) { $0.tasks = [PlanTask(id: PlanTask.carryTaskId(orig), text: "다른 할 일", row: 0)] }
        s.setMark(d1, orig, .moved)
        let ids = s.day(d2).tasks.map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertEqual(s.carriedCopy(of: orig, from: d1)?.text, "a")
        XCTAssertNotEqual(s.carriedCopy(of: orig, from: d1)?.id, PlanTask.carryTaskId(orig))
    }

    // MARK: 저장 알림

    func testOnSavedAndOnDeletedReportWhatWasWritten() throws {
        let dir = tempFolder()
        let store = PlannerStore(folder: dir)
        XCTAssertTrue(store.libraryCreated)
        var saved: [(UUID?, Bool)] = []
        var deleted: [UUID] = []
        store.onSaved = { saved.append(($0, $1)) }
        store.onDeleted = { deleted.append($0) }

        let a = store.createBook(name: "A", start: d1, end: nil)
        XCTAssertEqual(saved.last?.0, a)
        XCTAssertEqual(saved.last?.1, true)

        saved = []
        store.editDay(d1) { $0.comment = "안녕" }
        XCTAssertTrue(saved.isEmpty, "저장 예약만으로는 알리지 않는다 (쓴 뒤에 알린다)")
        store.saveNow()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.0, a)
        XCTAssertEqual(saved.first?.1, true)
        XCTAssertEqual(try readBook(dir, a).days[Dates.key(d1)]?.comment, "안녕")

        saved = []
        store.updateBook(a) { $0.name = "A2" }
        XCTAssertEqual(saved.count, 1)
        XCTAssertNil(saved.first?.0)
        XCTAssertEqual(saved.first?.1, true)

        let b = store.createBook(name: "B", start: d1, end: nil)
        saved = []
        store.activate(a)
        XCTAssertTrue(saved.contains { $0.0 == b }, "펼친 책을 바꾸기 전에 지금 책을 저장한다")
        XCTAssertTrue(saved.contains { $0.0 == nil && $0.1 })

        saved = []
        store.deleteBook(b)
        XCTAssertEqual(deleted, [b])
        XCTAssertEqual(saved.count, 1)
        XCTAssertNil(saved.first?.0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookFile(dir, b).path))

        // 같은 폴더를 다시 열면 책장은 있던 것
        XCTAssertFalse(PlannerStore(folder: dir).libraryCreated)
        XCTAssertFalse(PlannerStore(inMemory: true).libraryCreated)
    }

    // MARK: applyActiveData

    func testApplyActiveDataReplacesSavesAndSkipsSameContent() throws {
        let dir = tempFolder()
        let store = PlannerStore(folder: dir)
        let a = store.createBook(name: "A", start: d1, end: nil)
        store.editDay(d1) { $0.comment = "mine" }
        store.editPrefs { $0.lastKind = .weekly }
        var saved: [(UUID?, Bool)] = []
        store.onSaved = { saved.append(($0, $1)) }

        var merged = store.data
        merged.days[Dates.key(d2)] = { var r = DayRecord(); r.comment = "from elsewhere"; r.tasks = [PlanTask(text: "줄 없는 할 일")]; return r }()
        merged.prefs.lastKind = .daily        // 기기마다 따로: 이 기기의 것을 둔다
        let v0 = store.version
        var flags: [Bool] = []
        let watch = store.$data.dropFirst().sink { _ in flags.append(store.isApplyingExternalChange) }
        defer { watch.cancel() }

        let r = store.applyActiveData(merged)
        XCTAssertTrue(r.changed)
        XCTAssertEqual(flags, [true], "$data 를 보는 쪽은 밖에서 온 변경인 것을 안다")
        XCTAssertFalse(store.isApplyingExternalChange)
        XCTAssertGreaterThan(store.version, v0)
        XCTAssertEqual(store.data.days[Dates.key(d2)]?.comment, "from elsewhere")
        XCTAssertEqual(store.data.days[Dates.key(d2)]?.tasks.first?.row, 0, "줄 없는 할 일에 줄을 매긴다")
        XCTAssertEqual(store.data.prefs.lastKind, .weekly)
        // 바로 저장 · 알림
        XCTAssertEqual(try readBook(dir, a).days[Dates.key(d2)]?.comment, "from elsewhere")
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.0, a)

        // 같은 내용이면 아무것도 하지 않는다
        saved = []
        flags = []
        let v1 = store.version
        XCTAssertFalse(store.applyActiveData(store.data).changed)
        XCTAssertEqual(store.version, v1)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(flags.isEmpty)
    }

    func testApplyActiveDataKeepsTheFieldBeingWritten() throws {
        let store = PlannerStore(inMemory: true)
        store.useBook(BookInfo(name: "A", start: d1), data: PlannerData())
        let task = store.addTask(d1, row: 0)
        store.taskText(d1, id: task).wrappedValue = "쓰는 중인 글"
        let other = store.addTask(d1, row: 1)
        store.taskText(d1, id: other).wrappedValue = "다른 할 일"

        // 다른 곳에서: 쓰는 할 일의 글과 다른 할 일의 글을 바꿨다
        var merged = store.data
        let k = Dates.key(d1)
        let ti = try XCTUnwrap(merged.days[k]?.tasks.firstIndex { $0.id == task })
        let oi = try XCTUnwrap(merged.days[k]?.tasks.firstIndex { $0.id == other })
        merged.days[k]!.tasks[ti].text = "다른 기기의 글"
        merged.days[k]!.tasks[oi].text = "다른 할 일 (고침)"
        merged.days[k]!.comment = "코멘트"
        let r = store.applyActiveData(merged, keepingEditOf: AppState.taskKey(d1, task))
        XCTAssertTrue(r.changed)
        XCTAssertTrue(r.keptEdit)
        XCTAssertFalse(r.editedItemRemoved)
        XCTAssertEqual(store.day(d1).tasks.first { $0.id == task }?.text, "쓰는 중인 글")
        XCTAssertEqual(store.day(d1).tasks.first { $0.id == other }?.text, "다른 할 일 (고침)")
        XCTAssertEqual(store.day(d1).comment, "코멘트")

        // 쓰는 칸만 달랐으면: 내용은 그대로지만 그 칸이 다시 비교되도록 저장하고 알린다
        let dir = tempFolder()
        let filed = PlannerStore(folder: dir)
        _ = filed.createBook(name: "B", start: d1, end: nil)
        filed.dayField(d1, \.comment).wrappedValue = "쓰는 중"
        filed.saveNow()
        var notified = 0
        filed.onSaved = { _, _ in notified += 1 }
        var onlyEdited = filed.data
        onlyEdited.days[k]?.comment = "다른 기기의 글"
        let v = filed.version
        let r3 = filed.applyActiveData(onlyEdited, keepingEditOf: "c|\(k)")
        XCTAssertFalse(r3.changed)
        XCTAssertTrue(r3.keptEdit)
        XCTAssertEqual(filed.version, v)
        XCTAssertEqual(notified, 1)
        XCTAssertEqual(filed.day(d1).comment, "쓰는 중")

        // 쓰던 할 일이 다른 곳에서 지워졌다: 되살리지 않고 알린다
        var gone = store.data
        gone.days[k]!.tasks.removeAll { $0.id == task }
        let r2 = store.applyActiveData(gone, keepingEditOf: AppState.taskKey(d1, task))
        XCTAssertTrue(r2.editedItemRemoved)
        XCTAssertFalse(r2.keptEdit)
        XCTAssertNil(store.day(d1).tasks.first { $0.id == task })
    }

    func testKeepingEditedFieldCoversEveryInlineField() {
        let k = "2026-10-01"
        var mine = PlannerData()
        var day = DayRecord()
        day.comment = "내 코멘트"
        day.memos = ["", "내 메모", "", "넷째 줄"]
        day.memoTags = ["태그", "", ""]
        let note = TimeNote(kind: .text, start: 3, end: 5, text: "내 메모칸")
        day.notes = [note]
        mine.days[k] = day
        mine.weeks["2026-09-28"] = WeekRecord(goal: "내 목표", review: "r", stars: 2)
        mine.prefs.motto = "내 다짐"

        var merged = PlannerData()
        var other = DayRecord()
        other.comment = "남의 코멘트"
        other.notes = [TimeNote(id: note.id, kind: .text, start: 3, end: 5, text: "남의 메모칸")]
        merged.days[k] = other
        merged.weeks["2026-09-28"] = WeekRecord(goal: "남의 목표", review: "남의 돌아보기", stars: 5)
        merged.prefs.motto = "남의 다짐"

        func keep(_ key: String) -> (data: PlannerData, kept: Bool, removed: Bool) {
            PlannerData.keepingEditedField(key, mine: mine, merged: merged)
        }
        XCTAssertEqual(keep("c|\(k)").data.days[k]?.comment, "내 코멘트")
        XCTAssertEqual(keep("c|\(k)").data.days[k]?.notes.first?.text, "남의 메모칸", "다른 칸은 합친 값")
        XCTAssertEqual(keep("m|\(k)|1").data.days[k]?.memos[1], "내 메모")
        XCTAssertEqual(keep("m|\(k)|3").data.days[k]?.memos[3], "넷째 줄", "넘친 메모 줄도")
        XCTAssertEqual(keep("mt|\(k)|0").data.days[k]?.memoTags[0], "태그")
        XCTAssertEqual(keep("tn|\(k)|\(note.id.uuidString)").data.days[k]?.notes.first?.text, "내 메모칸")
        XCTAssertEqual(keep("wg|2026-09-28").data.weeks["2026-09-28"], WeekRecord(goal: "내 목표", review: "남의 돌아보기", stars: 5))
        XCTAssertEqual(keep(FrontPage.mottoKey).data.prefs.motto, "내 다짐")
        XCTAssertTrue(keep(FrontPage.mottoKey).kept)
        // 같은 값 · 모르는 키 · 잘못된 키는 그대로
        XCTAssertFalse(PlannerData.keepingEditedField("c|\(k)", mine: merged, merged: merged).kept)
        XCTAssertEqual(keep("x|\(k)").data, merged)
        XCTAssertEqual(keep("c|not-a-day").data, merged)
        XCTAssertEqual(keep("m|\(k)|99").data, merged)
        // 지운 날에 쓰는 중이면 그날을 다시 만든다 (글이 사라지지 않게)
        var empty = merged
        empty.days[k] = nil
        XCTAssertEqual(PlannerData.keepingEditedField("c|\(k)", mine: mine, merged: empty).data.days[k]?.comment, "내 코멘트")
    }

    // MARK: applyLibrary

    func testApplyLibraryAddsUpdatesAndKeepsTheOpenBook() throws {
        let dir = tempFolder()
        let store = PlannerStore(folder: dir)
        let a = store.createBook(name: "A", start: d1, end: nil)
        var saved: [(UUID?, Bool)] = []
        store.onSaved = { saved.append(($0, $1)) }

        var lib = store.library
        let incoming = BookInfo(name: "다른 기기의 책", start: d1)
        lib.books.append(incoming)
        lib.books[0].name = "A (고침)"
        lib.activeID = incoming.id          // 펼친 책은 이 기기의 것: 보지 않는다
        lib.sampleSeeded = false
        let r = store.applyLibrary(lib)
        XCTAssertTrue(r.changed)
        XCTAssertNil(r.closedBook)
        XCTAssertEqual(store.library.activeID, a)
        XCTAssertEqual(store.books.map(\.name), ["A (고침)", "다른 기기의 책"])
        XCTAssertEqual(saved.count, 1)
        XCTAssertNil(saved.first?.0)
        let onDisk = try PlannerStore.decodeFile(Library.self, from: Data(contentsOf: dir.appendingPathComponent("library.json")))
        XCTAssertEqual(onDisk.books.map(\.id), [a, incoming.id])
        XCTAssertEqual(onDisk.activeID, a)

        // 같은 책장이면 아무것도 하지 않는다 · 같은 id 가 둘이면 앞의 것만
        saved = []
        XCTAssertFalse(store.applyLibrary(store.library).changed)
        XCTAssertTrue(saved.isEmpty)
        var dup = store.library
        dup.books.append(dup.books[0])
        XCTAssertFalse(store.applyLibrary(dup).changed)
    }

    func testApplyLibraryClosesARemovedOpenBookWithoutWritingIt() async throws {
        let dir = tempFolder()
        let store = PlannerStore(folder: dir)
        let a = store.createBook(name: "A", start: d1, end: nil)
        let b = store.createBook(name: "B", start: d1, end: nil)
        store.editDay(d1) { $0.comment = "B 에 쓰는 중" }     // 저장 예약만 된 편집
        XCTAssertEqual(store.library.activeID, b)

        var lib = store.library
        lib.books.removeAll { $0.id == b }
        let r = store.applyLibrary(lib)
        XCTAssertEqual(r.closedBook, b)
        XCTAssertEqual(r.openedBook, a)
        XCTAssertEqual(store.library.activeID, a)
        XCTAssertEqual(store.day(d1).comment, "", "A 의 내용이 펼쳐진다")
        // 빠진 책의 편집은 그 파일에 쓰지 않는다 (예약한 저장도 버렸다)
        let exp = expectation(description: "저장 예약 시간이 지남")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 3)
        XCTAssertNotEqual(try readBook(dir, b).days[Dates.key(d1)]?.comment, "B 에 쓰는 중")

        // 그 뒤 파일 지우기: 책장에서 빠졌으므로 지울 수 있다
        try store.removeBookFile(b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookFile(dir, b).path))
    }

    func testApplyLibraryOpensTheFirstUserBookWhenNothingIsOpen() {
        let dir = tempFolder()
        let store = PlannerStore(folder: dir)
        store.seedSampleBookIfNeeded(today: d1)          // 처음 켬: 예시 플래너만, 펼친 책 없음
        XCTAssertNil(store.library.activeID)
        XCTAssertTrue(store.library.sampleSeeded)
        var lib = store.library
        let joined = BookInfo(name: "내 플래너", start: d1, created: d1)
        lib.books.insert(joined, at: 0)
        lib.sampleSeeded = false
        let r = store.applyLibrary(lib)
        XCTAssertEqual(r.openedBook, joined.id)
        XCTAssertEqual(store.library.activeID, joined.id)
        XCTAssertTrue(store.library.sampleSeeded, "예시 플래너를 꽂았다는 표시는 지우지 않는다")
    }

    func testApplyLibraryDoesNothingWhileLibraryIsUnreadable() throws {
        let dir = tempFolder()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("books"), withIntermediateDirectories: true)
        let libURL = dir.appendingPathComponent("library.json")
        let broken = Data("{ not json".utf8)
        try broken.write(to: libURL)
        let store = PlannerStore(folder: dir)
        XCTAssertTrue(store.libraryUnreadable)
        var lib = store.library
        lib.books.append(BookInfo(name: "X", start: d1))
        XCTAssertFalse(store.applyLibrary(lib).changed)
        XCTAssertEqual(try Data(contentsOf: libURL), broken, "읽지 못한 library.json 은 그대로")
    }

    // MARK: 펼치지 않은 책 파일

    func testRawBookFilesForBooksThatAreNotOpen() throws {
        let dir = tempFolder()
        let store = PlannerStore(folder: dir)
        let a = store.createBook(name: "A", start: d1, end: nil)
        store.editDay(d1) { $0.comment = "A 의 코멘트" }
        let b = store.createBook(name: "B", start: d1, end: nil)     // A 를 저장하고 B 를 편다
        let fresh = UUID()

        // 읽기
        XCTAssertEqual(store.readBookRaw(fresh), .missing)
        guard case let .data(raw) = store.readBookRaw(a) else { return XCTFail("A 를 읽어야 한다") }
        XCTAssertEqual(try PlannerStore.decodeFile(PlannerData.self, from: raw).days[Dates.key(d1)]?.comment, "A 의 코멘트")
        store.editDay(d2) { $0.comment = "B 저장 전" }
        guard case let .data(open) = store.readBookRaw(b) else { return XCTFail() }
        XCTAssertEqual(try PlannerStore.decodeFile(PlannerData.self, from: open).days[Dates.key(d2)]?.comment, "B 저장 전",
                       "펼친 책은 지금 내용")

        // 쓰기 (알리지 않는다)
        var saved = 0
        store.onSaved = { _, _ in saved += 1 }
        var next = try PlannerStore.decodeFile(PlannerData.self, from: raw)
        next.days[Dates.key(d3)] = { var r = DayRecord(); r.comment = "밖에서"; return r }()
        try store.writeBookRaw(a, PlannerStore.encodeFile(next))
        try store.writeBookRaw(fresh, PlannerStore.encodeFile(next))       // 책장에 아직 없는 책도
        XCTAssertEqual(saved, 0)
        XCTAssertEqual(try readBook(dir, a).days[Dates.key(d3)]?.comment, "밖에서")
        XCTAssertThrowsError(try store.writeBookRaw(b, PlannerStore.encodeFile(next))) { XCTAssertEqual($0 as? BookFileError, .bookIsOpen) }
        XCTAssertThrowsError(try store.writeBookRaw(a, Data("{\"days\": 3}".utf8))) {
            guard case .invalidContent? = $0 as? BookFileError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try readBook(dir, a).days[Dates.key(d3)]?.comment, "밖에서", "읽을 수 없는 내용은 쓰지 않는다")

        // 펼치면 쓴 내용
        store.activate(a)
        XCTAssertEqual(store.day(d3).comment, "밖에서")
        store.activate(b)
        saved = 0

        // 지우기: 펼친 책 · 책장에 있는 책은 거절, 뺀 책 · 없는 파일은 된다
        XCTAssertThrowsError(try store.removeBookFile(b)) { XCTAssertEqual($0 as? BookFileError, .bookIsOpen) }
        XCTAssertThrowsError(try store.removeBookFile(a)) { XCTAssertEqual($0 as? BookFileError, .bookIsListed) }
        try store.removeBookFile(fresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookFile(dir, fresh).path))
        try store.removeBookFile(UUID())
        XCTAssertEqual(saved, 0)
    }

    func testUnreadableBookFilesAreNeverWrittenOrRemoved() throws {
        let dir = tempFolder()
        let store = PlannerStore(folder: dir)
        _ = store.createBook(name: "A", start: d1, end: nil)
        // 책장에 없는(다른 곳에서 지운) 책 하나와 책장에 있는 책 하나가 깨졌다
        let loose = UUID()
        let listed = store.createBook(name: "B", start: d1, end: nil)
        _ = store.createBook(name: "C", start: d1, end: nil)
        let broken = Data("{\"days\": {\"2026-10-01\": 42}}".utf8)
        try broken.write(to: bookFile(dir, loose))
        try broken.write(to: bookFile(dir, listed))
        let good = try PlannerStore.encodeFile(PlannerData())

        // 쓰기 · 지우기 전에 지금 파일을 본다 (먼저 읽지 않았어도)
        XCTAssertThrowsError(try store.writeBookRaw(listed, good)) { XCTAssertEqual($0 as? BookFileError, .unreadable) }
        XCTAssertNotNil(store.unreadableBooks[listed])
        XCTAssertNotNil(store.unreadableBooks[listed]?.copy, "원본을 그대로 복사해 둔다")
        XCTAssertThrowsError(try store.removeBookFile(loose)) { XCTAssertEqual($0 as? BookFileError, .unreadable) }
        XCTAssertEqual(store.readBookRaw(loose), .unreadable)
        XCTAssertEqual(store.readBookRaw(listed), .unreadable)
        XCTAssertThrowsError(try store.writeBookRaw(loose, good))
        XCTAssertEqual(try Data(contentsOf: bookFile(dir, loose)), broken)
        XCTAssertEqual(try Data(contentsOf: bookFile(dir, listed)), broken)
        // 앱도 그 책을 펼치지 않는다
        XCTAssertFalse(store.activate(listed))
    }

    // MARK: 되돌리기 기록 옮기기

    func testRebasedCarriesAnExternalChangeIntoAnOlderVersion() {
        let k1 = "2026-10-01", k2 = "2026-10-02", k3 = "2026-10-03"
        // 되돌리기 단계(snapshot): 사용자가 k1 에 할 일을 쓰기 전
        var snapshot = PlannerData()
        var s1 = DayRecord()
        s1.comment = "옛 코멘트"
        snapshot.days[k1] = s1
        snapshot.prefs.defaultTheme = 1
        // 지금(base): 사용자가 k1 에 할 일을 썼다
        var base = snapshot
        base.days[k1]!.tasks = [PlanTask(text: "내가 쓴 할 일", row: 0)]
        base.days[k2] = { var r = DayRecord(); r.comment = "지울 날"; return r }()
        // 밖에서 온 변경(theirs): k1 의 코멘트를 고치고, k2 를 지우고, k3 를 만들고, 형광펜을 바꿨다
        var theirs = base
        theirs.days[k1]!.comment = "다른 기기의 코멘트"
        theirs.days[k2] = nil
        theirs.days[k3] = { var r = DayRecord(); r.slots[0] = 2; return r }()
        theirs.prefs.categories[0].name = "딥워크"
        theirs.weeks["2026-09-28"] = WeekRecord(goal: "목표")

        let undone = snapshot.rebased(from: base, to: theirs)
        // 사용자의 편집(할 일)은 되돌리고, 밖에서 온 변경은 모두 남는다
        XCTAssertEqual(undone.days[k1]?.tasks, [])
        XCTAssertEqual(undone.days[k1]?.comment, "다른 기기의 코멘트")
        XCTAssertNil(undone.days[k2])
        XCTAssertEqual(undone.days[k3]?.slots[0], 2)
        XCTAssertEqual(undone.prefs.categories[0].name, "딥워크")
        XCTAssertEqual(undone.prefs.defaultTheme, 1)
        XCTAssertEqual(undone.weeks["2026-09-28"]?.goal, "목표")
        // 바뀐 것이 없으면 그대로
        XCTAssertEqual(snapshot.rebased(from: base, to: base), snapshot)
    }
}
