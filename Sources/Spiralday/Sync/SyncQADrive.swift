#if DEBUG
import AppKit
import Combine
import SwiftUI
import SpiraldayKit
import SpiraldaySync

// ─────────────────────────────────────────────────────────────────────────────
// 디버그 빌드만: 여러 기기 동기화 검증(여러 기기를 한꺼번에 모는 바깥 스크립트)이 이 Mac 앱을 몰 수 있게 하는 통로.
//
//   Spiralday --sync-drive <폴더> [--sync-drive-keychain com.spiralday.mac.sync.qa.<이름>]
//
// 따로 된 것만 쓴다:
//   · 플래너 파일    <폴더>/data (앱의 데이터 폴더 ~/Library/Application Support/Spiralday 는 거절)
//   · 동기화 비밀    로그인 키체인의 테스트용 서비스 이름 (com.spiralday.mac.sync.qa. 로 시작해야 한다 — 앱의 com.spiralday.sync 는 거절)
//   · 동기화 설정 값 <폴더>/sync-defaults.plist (앱의 설정 파일이 아니라 — 껐다 켜도 그룹이 남게)
//   · 창            화면 밖에 둔다 (앱을 앞으로 가져오지 않는다 — 쓰던 사람의 화면 · 포커스를 건드리지 않는다)
// 통계 · 업데이트 확인 · ⭐ 부탁 · 처음 안내 · 둘러보기는 켜지 않는다.
//
// <폴더>/in/<이름>.json ({"op": "...", ...}) 을 이름 순서로 하나씩 읽어, 화면이 부르는 것과 같은 저장소 · AppState ·
// SyncController 함수로 실행하고 <폴더>/out/<이름>.json ({"ok": true, "result": ...} 또는 {"ok": false, "error": "..."}) 을 남긴다.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum SyncQADriveLaunch {
    static let keychainPrefix = "com.spiralday.mac.sync.qa."

    struct Config {
        let dir: URL
        let dataDir: URL
        let keychainService: String
    }

    /// 실행 인수에서 (없으면 nil — 보통 실행). 맞지 않으면 까닭을 찍고 끝낸다
    static func config(_ args: [String]) -> Config? {
        guard let i = args.firstIndex(of: "--sync-drive") else { return nil }
        guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else {
            print("사용법: Spiralday --sync-drive <폴더> [--sync-drive-keychain \(keychainPrefix)<이름>]")
            exit(2)
        }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true).standardizedFileURL
        let data = dir.appendingPathComponent("data", isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let real = data.resolvingSymlinksInPath().path.lowercased() + "/"
        for name in ["Spiralday", "PaperPlanner"] {
            let app = support.appendingPathComponent(name, isDirectory: true).resolvingSymlinksInPath().path.lowercased() + "/"
            if real.hasPrefix(app) || app.hasPrefix(real) {
                print("앱의 데이터 폴더(~/Library/Application Support/\(name))는 쓸 수 없어요")
                exit(2)
            }
        }
        var service = keychainPrefix + UUID().uuidString
        if let k = args.firstIndex(of: "--sync-drive-keychain") {
            guard k + 1 < args.count, args[k + 1].hasPrefix(keychainPrefix), args[k + 1].count > keychainPrefix.count else {
                print("--sync-drive-keychain 은 \(keychainPrefix) 로 시작해야 해요")
                exit(2)
            }
            service = args[k + 1]
        }
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        return Config(dir: dir, dataDir: data, keychainService: service)
    }

    /// 이 실행의 동기화 컨트롤러: 테스트용 키체인 이름 · 폴더 안의 설정 값 · 폴더 안의 SyncState
    static func controller(store: PlannerStore, config: Config) -> SyncController {
        let defaults = SyncFileDefaults(config.dir.appendingPathComponent("sync-defaults.plist"))
        guard let env = SyncController.Environment.live(store: store, keychainService: config.keychainService, defaults: defaults) else {
            print("저장 폴더가 없어요")
            exit(2)
        }
        return SyncController(store: store, env: env)
    }
}

/// --sync-drive 의 플래너 창: 앱의 플래너 창과 같은 종이(RootView)를 화면 밖의 테두리 없는 창에 둔다.
/// (제목 막대가 있는 창은 AppKit · 앱이 화면 안으로 끌어온다.) 앱을 앞으로 가져오지 않고, 글 칸 · 필드 편집기 · 되돌리기는
/// 앱의 플래너 창과 같다 (SyncController.editedFieldReplaced 가 보는 NSWindow 의 undoManager)
final class SyncQADriveWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    @MainActor
    static func make(store: PlannerStore, state: AppState) -> NSWindow {
        let size = CGSize(width: 640, height: 640 * PageKind.daily.design.height / PageKind.daily.design.width)
        let w = SyncQADriveWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = NSHostingView(rootView: RootView().environmentObject(store).environmentObject(state))
        w.orderFrontRegardless()
        w.makeKey()
        state.curl.backingScale = w.backingScaleFactor
        return w
    }
}

/// 파일 하나에 두는 설정 값 (--sync-drive: 껐다 켜도 그룹 주소가 남게, 앱의 설정 파일과 섞지 않게)
final class SyncFileDefaults: UserDefaults {
    private let url: URL
    private var values: [String: Any]

    init(_ url: URL) {
        self.url = url
        values = (NSDictionary(contentsOf: url) as? [String: Any]) ?? [:]
        super.init(suiteName: nil)!
    }

    private func write() { (values as NSDictionary).write(to: url, atomically: true) }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value; write() }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value; write() }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil; write() }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
}

@MainActor
final class SyncQADrive {
    private static var current: SyncQADrive?

    private let dir: URL
    private let inbox: URL
    private let outbox: URL
    private let store: PlannerStore
    private let state: AppState
    private let sync: SyncController
    private let keychainService: String
    private let window: () -> NSWindow?
    /// watchStart 로 지켜보는 날의 변화 (받은 때 · 그날의 값)
    private var watch: AnyCancellable?
    private var watched: [[String: Any]] = []

    static func start(_ config: SyncQADriveLaunch.Config, store: PlannerStore, state: AppState, sync: SyncController,
                      window: @escaping () -> NSWindow?) {
        let d = SyncQADrive(config, store: store, state: state, sync: sync, window: window)
        current = d
        d.loop()
    }

    private init(_ config: SyncQADriveLaunch.Config, store: PlannerStore, state: AppState, sync: SyncController,
                 window: @escaping () -> NSWindow?) {
        dir = config.dir
        inbox = config.dir.appendingPathComponent("in", isDirectory: true)
        outbox = config.dir.appendingPathComponent("out", isDirectory: true)
        self.store = store
        self.state = state
        self.sync = sync
        self.keychainService = config.keychainService
        self.window = window
        for u in [inbox, outbox] { try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
        let hello: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier), "at": Date().timeIntervalSince1970,
                                    "keychainService": config.keychainService, "folder": config.dataDir.path]
        if let d = try? JSONSerialization.data(withJSONObject: hello) { try? d.write(to: dir.appendingPathComponent("hello.json"), options: .atomic) }
    }

    private func loop() {
        Task { @MainActor in
            while true {
                await tick()
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func tick() async {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: inbox.path) else { return }
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let src = inbox.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: src),
                  let cmd = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            try? fm.removeItem(at: src)
            var reply: [String: Any]
            do {
                reply = ["ok": true, "result": try await run(cmd["op"] as? String ?? "", cmd) ?? NSNull()]
            } catch {
                reply = ["ok": false, "error": "\(error)"]
            }
            let out = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data(#"{"ok":false,"error":"encode"}"#.utf8)
            try? out.write(to: outbox.appendingPathComponent(name), options: .atomic)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = s }
    }

    /// 글 칸의 필드 편집기 (쓰는 칸에 포커스가 있을 때)
    private var fieldEditor: NSTextView? { window()?.firstResponder as? NSTextView }

    /// 메뉴의 되돌리기(⌘Z)를 누를 수 있는지: 응답자 사슬의 되돌리기 기록 (글 칸이면 필드 편집기의 것, 아니면 창의 것)
    private var canUndo: Bool {
        (window()?.firstResponder?.undoManager ?? window()?.undoManager)?.canUndo ?? false
    }

    // MARK: 명령

    private func run(_ op: String, _ a: [String: Any]) async throws -> Any? {
        func str(_ k: String) throws -> String {
            guard let s = a[k] as? String else { throw Failure("\(k) 가 없어요") }
            return s
        }
        func int(_ k: String) throws -> Int {
            guard let n = a[k] as? Int else { throw Failure("\(k) 가 없어요") }
            return n
        }
        func day(_ k: String = "day") throws -> Date {
            guard let d = Dates.parse(try str(k)) else { throw Failure("날짜가 아니에요: \(k)") }
            return d
        }
        func uuid(_ k: String) throws -> UUID {
            guard let u = UUID(uuidString: try str(k)) else { throw Failure("UUID 가 아니에요: \(k)") }
            return u
        }

        switch op {
        case "ping":
            return "pong"
        case "state":
            return await snapshot()

        // ── 책장
        case "bookCreate":
            let start = Dates.add(days: (a["startOffset"] as? Int) ?? -30, to: Dates.day(Date()))
            return store.createBook(name: try str("name"), start: start, end: nil).uuidString
        case "bookActivate":
            guard store.activate(try uuid("id")) else { throw Failure("펼치지 못했어요") }
            return nil
        case "bookRename":
            store.updateBook(try uuid("id")) { $0.name = (a["name"] as? String) ?? $0.name }
            return nil
        case "bookDelete":
            store.deleteBook(try uuid("id"))
            return nil

        // ── 하루 (펼친 책)
        case "addTask":
            let d = try day()
            let r = store.day(d)
            let row = (a["row"] as? Int) ?? r.freeTaskRow(after: r.lastTaskLine { _ in true } ?? -1)
            let id = store.addTask(d, row: row, cat: a["cat"] as? Int)
            store.taskText(d, id: id).wrappedValue = try str("text")
            return id.uuidString
        case "setTaskText":
            store.taskText(try day(), id: try uuid("id")).wrappedValue = try str("text")
            return nil
        case "mark":
            guard let m = Mark(rawValue: try int("mark")) else { throw Failure("표시가 아니에요") }
            store.setMark(try day(), try uuid("id"), m)
            return nil
        case "deleteTask":
            store.delete(try day(), try uuid("id"))
            return nil
        case "paint":
            let row = try int("row"), from = try int("from"), to = try int("to"), cat = try int("cat")
            store.editDay(try day()) { r in
                for c in from...to { r.slots[row * 6 + c] = cat }
            }
            return nil
        case "memo":
            store.memo(try day(), try int("i")).wrappedValue = try str("text")
            return nil
        case "memoTag":
            store.memoTag(try day(), try int("i")).wrappedValue = try str("text")
            return nil
        case "comment":
            store.dayField(try day(), \.comment).wrappedValue = try str("text")
            return nil
        case "ddayAdd":
            guard let date = Dates.parse(try str("date")) else { throw Failure("date") }
            return store.addDDay(title: try str("title"), date: date, to: try day())?.uuidString
        case "catAdd":
            return store.addCategory(name: try str("name"), hex: (a["hex"] as? String) ?? "B9E4A8")
        case "catRename":
            store.updateCategory(try int("id")) { $0.name = (a["name"] as? String) ?? $0.name }
            return nil

        // ── 플래너 창의 글 칸 (화면 밖 창 — 사람이 칸을 눌러 쓰고 ⌘Z 를 누르는 것과 같은 길)
        case "editBegin":
            // 그 날을 펴고 칸을 누른다 → SwiftUI 글 칸이 필드 편집기로 포커스를 받을 때까지
            if let d = a["day"] as? String, let date = Dates.parse(d), state.kind == .daily {
                state.openDay(date)
            }
            state.editingKey = try str("key")
            for _ in 0..<40 where fieldEditor == nil {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return ["focused": fieldEditor != nil, "text": fieldEditor?.string ?? NSNull()]
        case "type":
            // 키보드로 친 것처럼 (키 이벤트 → 필드 편집기 — 되돌리기 기록이 남는다). how: "insert" 는 입력기가 넣는 것처럼 insertText
            guard let tv = fieldEditor else { throw Failure("쓰는 칸에 포커스가 없어요") }
            let how = a["how"] as? String ?? "key"
            if how == "insert" {
                tv.insertText(try str("text"), replacementRange: tv.selectedRange())
            } else {
                for ch in try str("text") {
                    let s = String(ch)
                    guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window()?.windowNumber ?? 0, context: nil, characters: s,
                                                   charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0) else { continue }
                    tv.interpretKeyEvents([e])
                }
            }
            return ["text": tv.string, "at": Self.ms()]
        case "compose":
            // 입력기의 조합 한 단계 (marked text — 한글 ㅎ → 하 → 한). 조합을 끝내는 것은 commit
            guard let tv = fieldEditor else { throw Failure("쓰는 칸에 포커스가 없어요") }
            let t = try str("text")
            tv.setMarkedText(t, selectedRange: NSRange(location: (t as NSString).length, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
            return ["text": tv.string, "marked": tv.hasMarkedText(), "at": Self.ms()]
        case "commit":
            guard let tv = fieldEditor else { throw Failure("쓰는 칸에 포커스가 없어요") }
            tv.insertText(try str("text"), replacementRange: NSRange(location: NSNotFound, length: 0))
            return ["text": tv.string, "marked": tv.hasMarkedText(), "at": Self.ms()]
        case "paintDrag":
            // 일간 타임테이블을 끌어 칠하기 (SlotPainter 의 끌기 걸음과 같은 계산). row 줄의 from 칸 → to 칸, 칸마다 stepMs
            return try await paintDrag(row: try int("row"), from: try int("from"), to: try int("to"),
                                       stepMs: (a["stepMs"] as? Int) ?? 80, tool: a["cat"] as? Int)
        case "watchStart":
            // 그 날이 바뀔 때마다 (받은 초안 · 레코드 · 내 편집) 받은 때와 값을 적는다 — 지연을 재려고
            let k = Dates.key(try day())
            watched = []
            var last = store.data.days[k]
            watch = store.$data.sink { [weak self] d in
                let r = d.days[k]
                guard r != last else { return }
                last = r
                self?.watched.append(Self.dayJSON(r, at: Self.ms()))
            }
            return nil
        case "watchStop":
            watch = nil
            defer { watched = [] }
            return watched
        case "day":
            return Self.dayJSON(store.data.days[Dates.key(try day())], at: Self.ms())
        case "liveState":
            let live = sync.live
            var o: [String: Any] = [:]
            if let p = live?.presence {
                o["presence"] = ["relay": p.relay, "peers": p.peers, "live": p.live] as [String: Any]
            } else {
                o["presence"] = NSNull()
            }
            o["applied"] = live?.appliedCount ?? 0
            o["edits"] = live?.editsSent ?? 0
            o["composedEdits"] = live?.composedEdits ?? 0
            o["hint"] = live?.hints.shown ?? NSNull()
            if let p = live?.hints.visiblePanel {
                o["hintPanel"] = ["x": p.frame.minX, "y": p.frame.minY, "w": p.frame.width, "h": p.frame.height,
                                  "canBecomeKey": p.canBecomeKey] as [String: Any]
            } else {
                o["hintPanel"] = NSNull()
            }
            o["plannerIsKey"] = window()?.isKeyWindow ?? false
            if let c = await sync.liveCountersForQA() {
                o["counters"] = ["sent": c.sent, "received": c.received, "dropped": c.dropped, "deferred": c.deferred,
                                 "adopted": c.adopted, "tooLarge": c.tooLarge] as [String: Any]
            } else {
                o["counters"] = NSNull()
            }
            o["settleHooked"] = store.settleBeforeCleanup != nil
            o["saveHooked"] = store.beforeScheduledSave != nil
            return o
        case "snapshot":
            // 화면 밖 플래너 창 + 그 위의 알림 패널을 PNG 로 (사람이 보는 모습 그대로)
            return try snapshot(to: URL(fileURLWithPath: try str("path")))
        case "undo":
            // ⌘Z: 플래너 창의 되돌리기 (기록이 없으면 아무 일도 하지 않는다 — 메뉴의 되돌리기가 흐려진 것과 같다)
            // 메뉴의 되돌리기(⌘Z)처럼 undo: 를 지금 응답자부터 보낸다 (응답자 사슬에서 처음 받는 쪽이 자기 되돌리기 기록으로)
            let before = fieldEditor?.string
            let could = canUndo
            let handled = could && (window()?.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) ?? false)
            return ["didUndo": handled, "canUndo": could, "before": before as Any, "text": fieldEditor?.string as Any]
        case "editEnd":
            state.endEditing()
            window()?.makeFirstResponder(nil)
            return nil

        case "save":
            store.saveNow()
            return nil

        // ── 동기화 (설정 → 동기화 의 단추와 같은 함수)
        case "create":
            return result(await sync.create(deviceName: try str("deviceName")))
        case "recoveryConfirm":
            sync.recoveryConfirmed()
            return nil
        case "recoveryRotate":
            return result(await sync.makeRecovery(.rotate))
        case "pairStart":
            await sync.pairStart(a["mode"] as? String == "code" ? .code : .qr)
            return flowJSON()
        case "pairApprove":
            return result(await sync.pairApprove(digits: try str("digits")))
        case "pairDeny":
            await sync.pairDeny()
            return nil
        case "joinStart":
            return result(await sync.joinStart(try str("code"), deviceName: try str("deviceName")))
        case "joinAccept":
            return result(await sync.joinAccept())
        case "restore":
            return result(await sync.restore(code: try str("code"), deviceName: try str("deviceName")))
        case "flowClose":
            await sync.endFlow()
            return nil
        case "syncNow":
            await sync.syncNow()
            return nil
        case "devices":
            let r = try await sync.listDevices()
            return r.devices.map { d -> [String: Any] in
                ["id": d.id, "name": d.name ?? NSNull(), "platform": d.platform?.rawValue ?? NSNull(), "current": d.current]
            }
        case "renameDevice":
            return result(await sync.renameDevice(try str("name")))
        case "removeDevice":
            return result(await sync.removeDevice(try str("id")))
        case "leave":
            return result(await sync.leave())
        case "wipe":
            return result(await sync.wipe())
        case "forget":
            return result(await sync.forget())
        case "history":
            let rows = try await sync.history(book: try uuid("book"), kind: a["kind"] as? String == "week" ? .week : .day, date: try day("date"))
            return rows.map { ["seq": $0.seq, "current": $0.current, "summary": $0.summary] as [String: Any] }
        case "keychainItem":
            // 테스트용 서비스 이름에 항목이 남았는지 (값은 읽지 않는다)
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            return ["count": status == errSecSuccess ? ((out as? [Any])?.count ?? 1) : 0, "status": Int(status)]
        case "quit":
            // 끝내기 (⌘Q 와 같이: 저장하고 남은 편집을 올린 뒤)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            return nil
        default:
            throw Failure("모르는 명령: \(op)")
        }
    }

    static func ms() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    static func dayJSON(_ r: DayRecord?, at: Int) -> [String: Any] {
        let r = r ?? DayRecord()
        var painted: [String: Int] = [:]
        for (i, v) in r.slots.enumerated() where v >= 0 { painted[String(i)] = v }
        return ["at": at, "comment": r.comment, "tasks": r.tasks.map { ["id": $0.id.uuidString, "text": $0.text] },
                "memos": r.memos, "slots": painted]
    }

    /// 일간 타임테이블을 끌어 칠하는 걸음을 그대로 (SlotPainter.drag 와 같은 계산: 끌기 시작의 칸을 적어 두고, 칸이 바뀔 때마다
    /// 지금 저장소의 칸 위에 이번 범위만 칠해 editDay). 화면 밖 창에는 마우스 이벤트를 보낼 수 없어 끌기 걸음만 같은 길로 부른다
    private func paintDrag(row: Int, from: Int, to: Int, stepMs: Int, tool: Int?) async throws -> [String: Any] {
        guard state.kind == .daily, state.front == nil else { throw Failure("일간 페이지가 아니에요") }
        state.endEditing()
        if let tool { state.tool = tool }
        let date = state.currentDate
        let start = row * 6 + from
        let before = store.day(date).slots
        // 같은 색을 다시 칠하면 지우개 (SlotPainter 와 같다)
        let paint = (state.tool < 0 || before[start] == state.tool) ? -1 : state.tool
        var painted: ClosedRange<Int>?
        var steps: [[String: Any]] = []
        let dir = to >= from ? 1 : -1
        var c = from
        while true {
            let s = row * 6 + c
            let range = min(start, s)...max(start, s)
            let current = store.day(date).slots
            let next = DayRecord.repainted(current, before: before, previous: painted, range: range, value: paint)
            painted = range
            if next != current { store.editDay(date) { $0.slots = next } }
            steps.append(["cell": s, "at": Self.ms()])
            if c == to { break }
            try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
            c += dir
        }
        return ["steps": steps, "slots": Self.dayJSON(store.data.days[Dates.key(date)], at: Self.ms())["slots"] ?? [:]]
    }

    private func snapshot(to url: URL) throws -> [String: Any] {
        guard let w = window(), let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure("창이 없어요")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let size = view.bounds.size
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        var hint: [String: Any]? = nil
        if let p = sync.live?.hints.visiblePanel, let pv = p.contentView, let prep = pv.bitmapImageRepForCachingDisplay(in: pv.bounds) {
            pv.cacheDisplay(in: pv.bounds, to: prep)
            // 패널의 화면 자리 → 창 안 자리
            let r = w.convertFromScreen(p.frame)
            let out = NSImage(size: size)
            out.lockFocus()
            rep.draw(in: NSRect(origin: .zero, size: size))
            prep.draw(in: r)
            out.unlockFocus()
            hint = ["x": r.minX, "y": size.height - r.maxY, "w": r.width, "h": r.height]
            guard let tiff = out.tiffRepresentation, let b = NSBitmapImageRep(data: tiff), let png = b.representation(using: .png, properties: [:]) else {
                throw Failure("PNG")
            }
            try png.write(to: url)
        } else {
            guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure("PNG") }
            try png.write(to: url)
        }
        return ["path": url.path, "hint": hint ?? NSNull()]
    }

    private func result(_ r: SyncActionResult) -> [String: Any] {
        ["ok": r.ok, "message": r.message ?? NSNull(), "code": r.code.map { "\($0)" } ?? NSNull(), "flow": flowJSON()]
    }

    /// 지금 흐름 (화면이 그리는 것)
    private func flowJSON() -> Any {
        guard let f = sync.flow else { return NSNull() }
        func plat(_ p: SyncPlatform?) -> Any { p?.rawValue ?? NSNull() }
        switch f {
        case .recovery(let reason, let stage):
            var o: [String: Any] = ["kind": "recovery", "reason": reason == .create ? "create" : "rotate"]
            switch stage {
            case .working: o["stage"] = "working"
            case .show(let code): o["stage"] = "show"; o["code"] = code
            case .failed(let m): o["stage"] = "failed"; o["message"] = m
            }
            return o
        case .pair(let mode, let stage):
            var o: [String: Any] = ["kind": "pair", "mode": mode == .code ? "code" : "qr"]
            switch stage {
            case .opening: o["stage"] = "opening"
            case .waiting(let qr, let code, _): o["stage"] = "waiting"; o["qrText"] = qr ?? NSNull(); o["code"] = code ?? NSNull()
            case .request(let i): o["stage"] = "request"; o["platform"] = plat(i.platform); o["triesLeft"] = i.triesLeft; o["wrong"] = i.wrong
            case .approving(let i): o["stage"] = "approving"; o["platform"] = plat(i.platform)
            case .approved(let p): o["stage"] = "approved"; o["platform"] = plat(p)
            case .denied: o["stage"] = "denied"
            case .withdrawn: o["stage"] = "withdrawn"
            case .expired(let r): o["stage"] = "expired"; o["wasRequest"] = r
            case .error(let m): o["stage"] = "error"; o["message"] = m
            }
            return o
        case .join(let stage, _):
            var o: [String: Any] = ["kind": "join"]
            switch stage {
            case .waiting(let digits, _): o["stage"] = "waiting"; o["digits"] = digits
            case .approved(let devices, _): o["stage"] = "approved"; o["devices"] = devices.map { $0.name ?? "" }
            case .accepting: o["stage"] = "accepting"
            case .done: o["stage"] = "done"
            case .denied: o["stage"] = "denied"
            case .expired(let after): o["stage"] = "expired"; o["afterApproval"] = after
            case .error(let m): o["stage"] = "error"; o["message"] = m
            }
            return o
        case .restore(let evicted, _):
            return ["kind": "restore", "evicted": evicted]
        }
    }

    private func snapshot() async -> [String: Any] {
        let s = sync.status
        let line = SyncText.statusLine(state: s?.state, pending: s?.pending ?? 0, lastSyncAt: s?.lastSyncAt, error: s?.error, live: s?.live ?? false)
        var status: [String: Any] = [:]
        if let s {
            status = ["state": s.state.rawValue, "pending": s.pending, "lastSyncAt": s.lastSyncAt ?? NSNull(),
                      "error": s.error ?? NSNull(), "live": s.live]
        }
        let gear = SyncIndicator.shared.gear
        return [
            "inGroup": sync.inGroup,
            "ready": sync.ready,
            "status": status,
            "statusTitle": line.title,
            "statusDetail": line.detail,
            "startProblem": sync.startProblem ?? NSNull(),
            "flow": flowJSON(),
            "notice": SyncIndicator.shared.notice?.text ?? NSNull(),
            "gear": gear.map { ["attention": $0.attention, "spoken": $0.spoken, "tone": "\($0.tone)"] as [String: Any] } ?? NSNull(),
            "warnings": sync.warnings.map { "\($0.warning)" + ($0.bookName.map { " \($0)" } ?? "") },
            "recoveryPending": sync.recoveryPending,
            "activeID": store.library.activeID?.uuidString ?? NSNull(),
            "books": store.library.books.map { ["id": $0.id.uuidString, "name": $0.name, "isSample": $0.isSample] },
            "folder": store.folder?.path ?? NSNull(),
            "editingKey": state.editingKey ?? NSNull(),
            "focused": fieldEditor != nil,
            "fieldText": fieldEditor?.string ?? NSNull(),
            "canUndo": canUndo,
            "windowCanUndo": window()?.undoManager?.canUndo ?? false,
            "kind": state.kind.rawValue,
            "keychainService": keychainService,
            "today": Dates.key(Dates.day(Date())),
        ]
    }
}
#endif
