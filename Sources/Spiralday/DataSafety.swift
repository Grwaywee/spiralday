import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// 읽지 못한 저장 파일 (데이터 안전, 1.0.6 이후 핫픽스)
//
// 책 파일(books/<id>.json)이나 책장(library.json)이 있는데 읽지 못하면 (깨졌거나, 이 버전이 모르는 형식이거나,
// 읽기 권한이 없으면) PlannerStore 가
//   1) 원본은 손대지 않고 옆에 같은 내용의 복사본 "<파일>.unreadable-yyyyMMdd-HHmmss.json" 을 남기고
//      (같은 내용의 복사본이 이미 있으면 새로 만들지 않는다)
//   2) 앱이 도는 동안 그 원본에는 아무것도 쓰지 않는다 (saveNow · writeLibrary 가 건너뛴다)
//   3) 읽지 못한 책은 펼치지 않는다:
//        · 켤 때 펼치려던 책 → 다른 책 (내가 만든 책 먼저, 없으면 예시 플래너).
//          읽을 수 있는 책이 하나도 없으면 새 플래너를 한 권 만들어 편다 (적은 것이 어디에도 저장되지 않는 일이 없게).
//        · 앱을 쓰다가 그 책을 고르면 → 펼치지 않고 지금 책 그대로.
//      library.json 을 읽지 못하면 books 폴더의 읽을 수 있는 책 파일로 책장을 메모리에서만 꾸민다
//      ("되찾은 플래너 n"). 기록은 각 책 파일에 그대로 저장되고, 책 이름 · 표지 · 기간을 바꾼 것은 저장되지 않는다.
// 그리고 여기서 한국어 알림을 띄운다: 켤 때 한 번 (첫 창을 열기 전에), 앱을 쓰다가 그 책을 펼치려 할 때마다.
// `Spiralday --load-safety-test <dir>` 가 임시 폴더에서 이 흐름을 확인한다 (앱의 실제 데이터 폴더는 건드리지 않는다).
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum DataSafetyAlert {
    /// 켤 때 읽지 못한 파일이 있으면 한 번 알린다. freshBook: 읽을 수 있는 책이 없어서 새로 만들어 편 책.
    static func presentLaunchNotices(_ store: PlannerStore, freshBook: UUID?) {
        guard let text = launchText(store, freshBook: freshBook) else { return }
        show(text, files: store.launchNotices)
    }

    /// 앱을 쓰다가 읽지 못하는 책을 펼치려 했을 때
    static func presentRefused(_ note: UnreadableFile, store: PlannerStore) {
        show(refusedText(note, store: store), files: [note])
    }

    /// 켤 때 알림의 제목과 본문 (알릴 것이 없으면 nil). `--load-safety-test` 가 글도 찍어 본다.
    static func launchText(_ store: PlannerStore, freshBook: UUID?) -> (title: String, body: String)? {
        let notes = store.launchNotices
        guard !notes.isEmpty else { return nil }
        let title: String
        if notes.count == 1, let n = notes.first {
            title = n.kind == .library ? "플래너 목록 파일을 열지 못했어요" : "\(quoted(n.name, "을", "를")) 열지 못했어요"
        } else {
            title = "플래너 파일 \(notes.count)개를 열지 못했어요"
        }
        var parts = [notes.map { describe($0, folder: store.folder) }.joined(separator: "\n\n"), promise]
        if store.libraryUnreadable {
            let n = store.books.count
            parts.append(n > 0
                ? "그래서 books 폴더의 플래너 파일 \(n)개로 책장을 임시로 꾸몄어요 (이름은 ‘되찾은 플래너’). "
                    + "기록은 플래너마다 그대로 저장되지만, 이번에 플래너 이름 · 표지 · 기간을 바꾼 것은 저장되지 않아요."
                : "books 폴더에서 읽을 수 있는 플래너를 찾지 못했어요. 새로 만드는 플래너는 books 폴더에 따로 저장돼요.")
        }
        if let id = freshBook, let b = store.books.first(where: { $0.id == id }) {
            parts.append("읽을 수 있는 플래너가 없어서 새 플래너 ‘\(b.name)’\(SettingsJosa.pick(b.name, "을", "를")) 만들어 펼쳤어요. "
                         + "여기에 쓰는 것은 새 파일에 저장돼요.")
        } else if notes.contains(where: { $0.kind != .library }), let b = store.activeBook {
            parts.append("대신 ‘\(b.name)’\(SettingsJosa.pick(b.name, "을", "를")) 펼쳤어요.")
        }
        parts.append(advice)
        return (title, parts.joined(separator: "\n\n"))
    }

    static func refusedText(_ note: UnreadableFile, store: PlannerStore) -> (title: String, body: String) {
        var parts = [describe(note, folder: store.folder), promise]
        if let b = store.activeBook { parts.append("지금 펼친 ‘\(b.name)’ 그대로예요.") }
        parts.append(advice)
        return ("\(quoted(note.name, "을", "를")) 열 수 없어요", parts.joined(separator: "\n\n"))
    }

    private static let promise = "원본 파일은 손대지 않았고, 아무것도 덮어쓰지 않았어요. 앱을 쓰는 동안 그 파일에는 저장하지 않아요."
    private static let advice = "‘폴더 열기’로 파일이 있는 곳을 볼 수 있어요. 파일이 고쳐지면 다음에 열 때 그대로 열려요. "
        + "도움이 필요하면 도움말 → 버그 신고로 알려 주세요."

    private static func describe(_ n: UnreadableFile, folder: URL?) -> String {
        let what = n.kind == .library ? "플래너 목록 (library.json)" : "‘\(n.name ?? "이름 없는 플래너")’ 파일"
        var lines = ["\(what): \(n.reason)", "원본: \(relative(n.url, folder))"]
        lines.append(n.copy.map { "복사본: \(relative($0, folder))" } ?? "복사본은 만들지 못했어요 (원본은 그대로 있어요).")
        return lines.joined(separator: "\n")
    }

    /// ‘회사 플래너’를 · 이름을 모르면 플래너 파일을
    private static func quoted(_ name: String?, _ withBatchim: String, _ without: String) -> String {
        guard let name, !name.isEmpty else { return "플래너 파일\(withBatchim)" }
        return "‘\(name)’\(SettingsJosa.pick(name, withBatchim, without))"
    }

    /// 데이터 폴더 안이면 그 안의 경로로 (books/….json)
    private static func relative(_ url: URL, _ folder: URL?) -> String {
        guard let folder else { return url.path }
        let base = folder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    static func makeAlert(_ text: (title: String, body: String)) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.body
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "폴더 열기")
        return alert
    }

    private static func show(_ text: (title: String, body: String), files: [UnreadableFile]) {
        if !NSApp.isActive { NSApp.activate() }
        let alert = makeAlert(text)
        if alert.runModal() == .alertSecondButtonReturn {
            // 복사본을 (없으면 원본을) 고른 채로 Finder 를 연다
            NSWorkspace.shared.activateFileViewerSelecting(files.map { $0.copy ?? $0.url })
        }
    }
}

// MARK: - QA (--load-safety-test)

/// `Spiralday --load-safety-test <dir>`: <dir>/load-safety-sim 임시 폴더를 앱의 저장 폴더처럼 써서
/// 읽지 못하는 책 · 책장 파일로 켜기 → 쓰기 → 자동 저장 → 책 바꾸기 → 다시 켜기를 흉내 내고,
/// 읽지 못한 원본이 바이트 그대로인지, 복사본이 같은 내용으로 남는지 확인한다. 앱의 실제 데이터 폴더는 건드리지 않는다.
@MainActor
enum LoadSafetyTest {
    private static var failures = 0
    private static let fm = FileManager.default
    private static let enc: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let dec: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func run(to dir: URL) async -> Int32 {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath().path.lowercased()
        let target = dir.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        for name in ["spiralday", "paperplanner"] where target == support + "/" + name || target.hasPrefix(support + "/" + name + "/") {
            print("결과 폴더를 앱의 실제 데이터 폴더(~/Library/Application Support) 안에 둘 수 없어요")
            return 2
        }
        let root = dir.appendingPathComponent("load-safety-sim", isDirectory: true)
        // 지난 실행이 남긴 이 점검의 폴더만 지운다 (권한을 막아 둔 파일이 남았을 수 있다)
        for p in fm.enumerator(atPath: root.path)?.allObjects as? [String] ?? [] {
            let path = root.appendingPathComponent(p).path
            guard (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular else { continue }
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        }
        try? fm.removeItem(at: root)
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) } catch {
            print("임시 폴더를 만들지 못했어요: \(error.localizedDescription)")
            return 1
        }
        let today = Dates.day(Date())
        alertDir = root

        await corruptActiveBook(root.appendingPathComponent("1-corrupt-active-book"), today: today)
        onlyBookCorrupt(root.appendingPathComponent("2-only-book-corrupt"), today: today)
        unreadablePermission(root.appendingPathComponent("3-no-read-permission"), today: today)
        corruptLibrary(root.appendingPathComponent("4-corrupt-library"), today: today)
        healthy(root.appendingPathComponent("5-healthy"), today: today)

        print(failures == 0 ? "모든 확인 통과" : "확인 실패 \(failures)개")
        print("결과: \(root.path)")
        return failures == 0 ? 0 : 1
    }

    // MARK: 경우들

    /// 1) 펼쳐 둔 책 파일이 깨졌고 다른 책이 있다
    private static func corruptActiveBook(_ dir: URL, today: Date) async {
        print("── 1) 펼쳐 둔 책이 깨짐 · 다른 책 있음")
        let a = BookInfo(name: "회사 플래너", start: Dates.add(days: -30, to: today), cover: 1)
        let b = BookInfo(name: "개인 플래너", start: Dates.add(days: -30, to: today), cover: 3)
        let aURL = bookURL(dir, a.id), bURL = bookURL(dir, b.id)
        let corrupt = corrupted(record(today, "회사 기록"))
        setUp(dir, Library(books: [a, b], activeID: a.id, sampleSeeded: true), books: [a.id: corrupt, b.id: valid(record(today, "개인 기록"))])

        let s = launch(dir, today: today)
        var refused: [UnreadableFile] = []
        s.onUnreadableBook = { refused.append($0) }
        check("켠 뒤: 깨진 책 파일이 바이트 그대로", bytes(aURL) == corrupt)
        let copies = PlannerStore.unreadableCopies(of: aURL)
        check("켠 뒤: 복사본 하나가 원본과 같은 바이트로 남았다 (\(copies.first?.lastPathComponent ?? "없음"))",
              copies.count == 1 && bytes(copies[0]) == corrupt)
        check("복사본 이름은 <파일>.unreadable-yyyyMMdd-HHmmss.json",
              copies.first.map { $0.lastPathComponent.range(of: #"^[0-9A-F-]{36}\.json\.unreadable-\d{8}-\d{6}\.json$"#, options: .regularExpression) != nil } ?? false)
        check("켠 뒤: 깨진 책 대신 ‘개인 플래너’가 펼쳐지고 그 기록이 보인다",
              s.activeBook?.id == b.id && s.day(today).comment == "개인 기록")
        check("켤 때 알림 한 건 (깨진 책 · 복사본 경로)",
              s.launchNotices.count == 1 && s.launchNotices.first?.kind == .book(a.id) && s.launchNotices.first?.copy == copies.first)
        if let t = DataSafetyAlert.launchText(s, freshBook: nil) { printAlert(t) }

        // 쓰기 → 0.6초 뒤 자동 저장 (scheduleSave)
        s.editDay(today) { $0.comment = "켠 뒤에 쓴 글" }
        try? await Task.sleep(for: .milliseconds(1200))
        check("자동 저장 뒤: 깨진 책 파일이 바이트 그대로", bytes(aURL) == corrupt)
        check("자동 저장 뒤: 쓴 글은 ‘개인 플래너’ 파일에 저장됐다", readBook(bURL)?.days[Dates.key(today)]?.comment == "켠 뒤에 쓴 글")

        // 깨진 책을 펼치려 하면: 펼치지 않고 알린다
        check("깨진 책 펼치기는 거절 · 지금 책 그대로 · 알림 한 번",
              !s.activate(a.id) && s.activeBook?.id == b.id && refused.count == 1 && refused.first?.kind == .book(a.id))
        if let n = refused.first { printAlert(DataSafetyAlert.refusedText(n, store: s)) }
        s.saveNow()   // 끝낼 때 저장 (willTerminate 와 같은 일)
        check("끝낼 때 저장 뒤: 깨진 책 파일이 바이트 그대로", bytes(aURL) == corrupt)
        check("책장(library.json)에 깨진 책이 그대로 있다",
              readLibrary(dir)?.books.contains { $0.id == a.id && $0.name == a.name } == true)

        // 다시 켜기
        let s2 = launch(dir, today: today)
        s2.onUnreadableBook = { refused.append($0) }
        check("다시 켜기: 마지막에 펼친 ‘개인 플래너’가 펼쳐지고 알림 없음", s2.activeBook?.id == b.id && s2.launchNotices.isEmpty)
        check("다시 켜서 깨진 책을 또 펼치려 해도 거절 · 원본 그대로 · 복사본은 늘지 않는다",
              !s2.activate(a.id) && bytes(aURL) == corrupt && PlannerStore.unreadableCopies(of: aURL).count == 1)
        // 펼친 책을 지우면 남은 책 가운데 읽을 수 있는 것만 편다 (여기서는 없음 → 아무 책도 펼치지 않는다)
        check("지우기 확인 문구의 ‘다음에 펼칠 책’에 깨진 책이 나오지 않는다", s2.fallbackBook(excluding: b.id) == nil)
        s2.deleteBook(b.id)
        s2.saveNow()
        check("펼친 책을 지워도 깨진 책으로 넘어가지 않고, 원본은 바이트 그대로",
              s2.activeBook == nil && bytes(aURL) == corrupt)
        // 사용자가 깨진 책을 직접 지우면 원본은 지워지고 복사본은 남는다
        s2.deleteBook(a.id)
        check("깨진 책을 지우면 원본만 지워지고 복사본은 남는다",
              !fm.fileExists(atPath: aURL.path) && PlannerStore.unreadableCopies(of: aURL).count == 1
                && bytes(PlannerStore.unreadableCopies(of: aURL)[0]) == corrupt)
    }

    /// 2) 책이 한 권뿐인데 그 파일이 깨졌다 → 새 플래너를 만들어 편다
    private static func onlyBookCorrupt(_ dir: URL, today: Date) {
        print("── 2) 한 권뿐인 책이 깨짐")
        let a = BookInfo(name: "내 플래너", start: Dates.add(days: -10, to: today))
        let aURL = bookURL(dir, a.id)
        let corrupt = Data("{\"days\":{\"\(Dates.key(today))\":{\"comment\":\"끊긴".utf8)
        setUp(dir, Library(books: [a], activeID: a.id, sampleSeeded: true), books: [a.id: corrupt])

        let s = launch(dir, today: today)
        let fresh = s.activeBook
        check("읽을 수 있는 책이 없어서 ‘새 플래너’를 만들어 편다",
              fresh?.name == "새 플래너" && fresh?.id != a.id && s.books.count == 2)
        if let t = DataSafetyAlert.launchText(s, freshBook: fresh?.id) { printAlert(t) }
        s.editDay(today) { $0.comment = "새 플래너에 쓴 글" }
        s.saveNow()
        check("저장 뒤: 깨진 책 파일이 바이트 그대로 · 복사본도 같은 바이트",
              bytes(aURL) == corrupt && PlannerStore.unreadableCopies(of: aURL).map(bytes) == [corrupt])
        check("쓴 글은 새 플래너 파일에 저장됐다",
              fresh.flatMap { readBook(bookURL(dir, $0.id)) }?.days[Dates.key(today)]?.comment == "새 플래너에 쓴 글")
        let s2 = launch(dir, today: today)
        check("다시 켜기: 새 플래너가 펼쳐지고 새로 만들지 않는다 · 원본 그대로",
              s2.activeBook?.id == fresh?.id && s2.books.count == 2 && bytes(aURL) == corrupt)
    }

    /// 3) 읽기 권한이 없는 책 파일 (원자적 쓰기는 이름 바꾸기라서 예전 코드는 이런 파일도 덮어썼다)
    private static func unreadablePermission(_ dir: URL, today: Date) {
        print("── 3) 읽기 권한이 없는 책 파일")
        let a = BookInfo(name: "잠긴 플래너", start: Dates.add(days: -10, to: today))
        let b = BookInfo(name: "다른 플래너", start: Dates.add(days: -10, to: today))
        let aURL = bookURL(dir, a.id)
        let original = valid(record(today, "잠긴 기록"))
        setUp(dir, Library(books: [a, b], activeID: a.id, sampleSeeded: true), books: [a.id: original, b.id: valid(PlannerData())])
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: aURL.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: aURL.path) }
        guard (try? Data(contentsOf: aURL)) == nil else {
            print("  (건너뜀: 이 계정은 권한을 막아도 읽을 수 있어요)")
            return
        }
        let s = launch(dir, today: today)
        check("켠 뒤: 읽지 못한 책 대신 ‘다른 플래너’가 펼쳐진다", s.activeBook?.id == b.id && s.launchNotices.count == 1)
        if let t = DataSafetyAlert.launchText(s, freshBook: nil) { printAlert(t) }
        s.editDay(today) { $0.comment = "다른 플래너에 쓴 글" }
        s.saveNow()
        check("잠긴 책 펼치기는 거절", !s.activate(a.id) && s.activeBook?.id == b.id)
        s.saveNow()
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: aURL.path)
        check("저장 뒤: 잠긴 책 파일이 바이트 그대로", bytes(aURL) == original)
        check("권한이 풀리면 다시 펼칠 수 있고 기록이 그대로", s.activate(a.id) && s.day(today).comment == "잠긴 기록")
    }

    /// 4) library.json 이 깨졌다 → 책 파일로 책장을 메모리에서만 꾸미고 library.json 은 그대로 둔다
    private static func corruptLibrary(_ dir: URL, today: Date) {
        print("── 4) library.json 이 깨짐")
        let bID = UUID(), cID = UUID()
        let first = Dates.add(days: -12, to: today)
        var bData = record(today, "책장 없이 남은 기록")
        bData.days[Dates.key(first)] = DayRecord()
        bData.days[Dates.key(first)]?.comment = "첫 기록"
        let cCorrupt = corrupted(record(today, "깨진 책"))
        let junk = Data("{\"activeID\":\"\(bID.uuidString)\",\"books\":[{\"cover\":1,\"id\":".utf8)
        setUp(dir, nil, books: [bID: valid(bData), cID: cCorrupt])
        let libURL = dir.appendingPathComponent("library.json")
        try? junk.write(to: libURL)
        // 한 권짜리 예전 파일도 있으면: library.json 이 없는 것으로 보고 옮기면 안 된다
        let legacy = dir.appendingPathComponent("planner.json")
        try? valid(record(today, "예전 파일")).write(to: legacy)

        let s = launch(dir, today: today)
        let copies = PlannerStore.unreadableCopies(of: libURL)
        check("켠 뒤: library.json 이 바이트 그대로 · 복사본 하나가 같은 바이트",
              bytes(libURL) == junk && copies.count == 1 && bytes(copies[0]) == junk)
        check("켤 때 알림: 플래너 목록", s.launchNotices.map(\.kind) == [.library] && s.libraryUnreadable)
        check("책장을 책 파일로 꾸몄다: 읽을 수 있는 책 한 권 ‘되찾은 플래너’ (시작일 = 첫 기록 날) 이 펼쳐진다",
              s.books.map(\.id) == [bID] && s.activeBook?.name == "되찾은 플래너" && s.activeBook?.start == first
                && s.day(today).comment == "책장 없이 남은 기록")
        check("예시 플래너를 꽂지 않고, 예전 파일(planner.json)도 옮기지 않는다",
              !s.hasSampleBook && fm.fileExists(atPath: legacy.path))
        if let t = DataSafetyAlert.launchText(s, freshBook: nil) { printAlert(t) }

        s.editDay(today) { $0.comment = "고쳐 쓴 글" }
        let made = s.createBook(name: "새 책", start: today, end: nil)
        s.updateBook(made) { $0.name = "이름 바꾼 책" }
        s.editDay(today) { $0.comment = "새 책에 쓴 글" }
        _ = s.activate(bID)
        s.saveNow()
        check("책 만들기 · 이름 바꾸기 · 책 바꾸기 · 저장 뒤에도 library.json 이 바이트 그대로", bytes(libURL) == junk)
        check("깨진 책 파일(books 폴더)도 바이트 그대로", bytes(bookURL(dir, cID)) == cCorrupt)
        check("기록은 책 파일마다 저장됐다",
              readBook(bookURL(dir, bID))?.days[Dates.key(today)]?.comment == "고쳐 쓴 글"
                && readBook(bookURL(dir, made))?.days[Dates.key(today)]?.comment == "새 책에 쓴 글")

        let s2 = launch(dir, today: today)
        check("다시 켜기: library.json 그대로 · 복사본은 늘지 않는다 · 두 책 모두 책장에 (같은 id)",
              bytes(libURL) == junk && PlannerStore.unreadableCopies(of: libURL).count == 1
                && Set(s2.books.map(\.id)) == [bID, made] && s2.launchNotices.map(\.kind) == [.library])
    }

    /// 5) 멀쩡한 책 · 아직 파일이 없는 새 책: 예전과 똑같이 (알림 · 복사본 없음)
    private static func healthy(_ dir: URL, today: Date) {
        print("── 5) 멀쩡한 책장")
        let a = BookInfo(name: "멀쩡한 플래너", start: Dates.add(days: -10, to: today))
        let m = BookInfo(name: "아직 저장 전", start: today)
        setUp(dir, Library(books: [a, m], activeID: a.id, sampleSeeded: true), books: [a.id: valid(record(today, "멀쩡한 기록"))])
        let s = launch(dir, today: today)
        check("알림 없음 · 기록이 보인다", s.launchNotices.isEmpty && s.unreadableBooks.isEmpty && s.day(today).comment == "멀쩡한 기록")
        check("파일이 아직 없는 책은 빈 책으로 펼쳐진다", s.activate(m.id) && s.data.days.isEmpty)
        s.editDay(today) { $0.comment = "새 책 첫 글" }
        check("다시 원래 책으로", s.activate(a.id) && s.day(today).comment == "멀쩡한 기록")
        s.saveNow()
        let leftovers = (fm.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []).filter { $0.contains(".unreadable-") || $0.hasSuffix(".tmp") }
        check("복사본 · 임시 파일이 생기지 않는다", leftovers.isEmpty)
        check("새 책 파일이 만들어지고 읽힌다", readBook(bookURL(dir, m.id))?.days[Dates.key(today)]?.comment == "새 책 첫 글")
    }

    // MARK: 도우미

    /// 앱이 켤 때 하는 일과 같은 차례 (AppDelegate.init)
    private static func launch(_ dir: URL, today: Date) -> PlannerStore {
        let s = PlannerStore(folder: dir)
        s.seedSampleBookIfNeeded(today: today)
        s.openFreshBookIfNothingReadable(today: today)
        return s
    }

    private static func setUp(_ dir: URL, _ library: Library?, books: [UUID: Data]) {
        try? fm.createDirectory(at: dir.appendingPathComponent("books"), withIntermediateDirectories: true)
        if let library, let raw = try? enc.encode(library) { try? raw.write(to: dir.appendingPathComponent("library.json")) }
        for (id, raw) in books { try? raw.write(to: bookURL(dir, id)) }
    }

    private static func bookURL(_ dir: URL, _ id: UUID) -> URL { dir.appendingPathComponent("books/\(id.uuidString).json") }

    private static func record(_ day: Date, _ comment: String) -> PlannerData {
        var d = PlannerData()
        d.prefs.ddaysPerDay = true
        var r = DayRecord()
        r.comment = comment
        r.tasks = [PlanTask(text: "할 일", mark: .done, cat: 0, row: 0)]
        d.days[Dates.key(day)] = r
        return d
    }

    private static func valid(_ d: PlannerData) -> Data { (try? enc.encode(d)) ?? Data() }

    /// 앞 절반만 남긴 책 파일 (중간에 끊긴 JSON)
    private static func corrupted(_ d: PlannerData) -> Data {
        let raw = valid(d)
        return raw.prefix(raw.count / 2)
    }

    private static func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }
    private static func readBook(_ url: URL) -> PlannerData? { bytes(url).flatMap { try? dec.decode(PlannerData.self, from: $0) } }
    private static func readLibrary(_ dir: URL) -> Library? {
        bytes(dir.appendingPathComponent("library.json")).flatMap { try? dec.decode(Library.self, from: $0) }
    }

    /// 알림 글을 찍고, 실제 알림 창을 띄우지 않고 그려서 <결과>/alert-N.png 로 남긴다 (모양 확인용)
    private static func printAlert(_ t: (title: String, body: String)) {
        print("  [알림] \(t.title)")
        for line in t.body.split(separator: "\n", omittingEmptySubsequences: false) { print("  │ \(line)") }
        guard let out = alertDir else { return }
        alertCount += 1
        let alert = DataSafetyAlert.makeAlert(t)
        alert.layout()
        guard let view = alert.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("alert-\(alertCount).png"))
    }
    private static var alertDir: URL?
    private static var alertCount = 0

    private static func check(_ what: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("\(ok ? "✓" : "✗ 실패") \(what)")
    }
}
