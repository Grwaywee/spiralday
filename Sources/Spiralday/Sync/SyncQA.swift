import AppKit
import Security
import SwiftUI
import SpiraldayKit
import SpiraldaySync

// ─────────────────────────────────────────────────────────────────────────────
// `Spiralday --sync-qa <폴더> [상태 …]`: 설정 → 동기화의 모든 상태를 라이트 · 다크로 PNG 로 찍고 끝낸다.
//   <상태>-light.png · <상태>-dark.png  (설정 창 그대로 — 화면 밖 창에 그려 cacheDisplay)
//   palette-<상태>.png                   팔레트의 설정 단추 귀퉁이 표시
//   notice-<light|dark>.png              플래너 위의 안내
// 메모리 저장소 · 메모리 열쇠 · 따로 된 UserDefaults 묶음만 쓴다 (서버 · 키체인 · 앱의 설정 값 · 데이터 폴더를 건드리지 않는다).
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum SyncQA {
    static let states = [
        "off", "off-demo", "creds", "problem", "moved",
        "start", "join-input", "join-code", "join-link", "join-error", "restore-input", "restore-typo", "restore-ok", "restore-merge",
        "recovery-working", "recovery-show", "recovery-rotate", "recovery-check", "recovery-failed",
        "pair-opening", "pair-qr", "pair-code", "pair-request", "pair-wrong", "pair-approving", "pair-approved", "pair-denied",
        "pair-withdrawn", "pair-expired", "pair-error",
        "join-waiting", "join-approved", "join-accepting", "join-done", "join-denied", "join-expired", "join-expired-after", "join-failed",
        "restore-done", "restore-evicted",
        "idle", "syncing", "offline", "error", "quota", "warnings", "other-server", "removed", "gone",
        "history",
    ]

    static let paletteStates = ["off", "idle", "syncing", "offline", "warn", "error"]

    static func run(to dir: URL, store: PlannerStore, only: [String]) async -> Int32 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 이 실행의 동기화 설정 값은 메모리에만 (앱의 설정 파일 · ~/Library/Preferences 에 아무것도 남기지 않는다)
        let defaults = SyncMemoryDefaults()
        let wanted = only.isEmpty ? states : states.filter { only.contains($0) }
        var count = 0
        var failures = 0
        for name in wanted {
            for dark in [false, true] {
                let state = AppState(kind: .daily)
                state.store = store
                state.fontsReady = true
                let sync = controller(store: store, defaults: defaults)
                present(name, sync: sync, store: store)
                let file = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                let ok: Bool
                if name == "history" {
                    let view = SyncHistorySheet(initial: SyncHistoryRequest(book: store.userBooks.first?.id ?? UUID(), kind: .day, date: Date()))
                        .environmentObject(sync).environmentObject(store).environmentObject(state)
                    ok = await capture(view, size: CGSize(width: 540, height: 560), dark: dark, titled: false, to: file)
                } else {
                    // 설정 창의 오른쪽 칸 (설정 창을 가장 좁게 줄였을 때의 폭 · 사이드바는 그려지지 않아 빼고)
                    let view = SyncSettingsPane()
                        .formStyle(.grouped)
                        .environmentObject(store).environmentObject(state).environmentObject(sync)
                    ok = await capture(view, size: CGSize(width: 530, height: height(name)), dark: dark, titled: false, to: file)
                }
                await sync.dispose()
                if ok { count += 1 } else { failures += 1; print("✗ \(file.lastPathComponent)") }
            }
        }
        if only.isEmpty || only.contains("palette") {
            for name in paletteStates {
                let sync = controller(store: store, defaults: defaults)
                switch name {
                case "off": sync.qaPresent(status: nil, inGroup: false, flow: nil)
                case "idle": sync.qaPresent(status: idle, inGroup: true, flow: nil)
                case "syncing": sync.qaPresent(status: SyncViewStatus(state: .syncing, pending: 2, lastSyncAt: ms - 120_000, live: true), inGroup: true, flow: nil)
                case "offline": sync.qaPresent(status: SyncViewStatus(state: .offline, pending: 3, lastSyncAt: ms - 7_200_000), inGroup: true, flow: nil)
                case "warn": sync.qaPresent(status: idle, inGroup: true, flow: nil, recoveryPending: true)
                default: sync.qaPresent(status: SyncViewStatus(state: .removed, lastSyncAt: ms - 86_400_000), inGroup: true, flow: nil)
                }
                let pen = store.categories.first?.id ?? 0
                if let (img, _) = PaletteTest.scene(edge: .right, kind: .daily, open: true, tool: pen, store: store) {
                    Snapshotter.write(img, dir.appendingPathComponent("palette-\(name).png"))
                    count += 1
                } else {
                    failures += 1
                }
                await sync.dispose()
            }
            SyncIndicator.shared.gear = nil
        }
        if only.isEmpty || only.contains("notice") {
            SyncIndicator.shared.notice = SyncNotice(text: SyncText.closedBookNotice)
            for dark in [false, true] {
                let view = ZStack(alignment: .top) {
                    Ink.paper
                    SyncNoticeOverlay()
                }
                .frame(width: 640, height: 200)
                let file = dir.appendingPathComponent("notice-\(dark ? "dark" : "light").png")
                if await capture(view, size: CGSize(width: 640, height: 200), dark: dark, titled: false, to: file) { count += 1 } else { failures += 1 }
            }
            SyncIndicator.shared.notice = nil
        }
        print("✓ \(count)장 → \(dir.path)")
        return failures == 0 ? 0 : 1
    }

    /// 상태마다 창 높이 (내용이 잘리지 않게)
    private static func height(_ name: String) -> CGFloat {
        switch name {
        case "idle", "syncing", "offline", "error", "quota": 1080
        case "warnings": 1420
        case "off", "off-demo", "creds", "pair-qr", "pair-code": 800
        default: 660
        }
    }

    private static var ms: Int { Int(Date().timeIntervalSince1970 * 1000) }
    private static var idle: SyncViewStatus { SyncViewStatus(state: .idle, pending: 0, lastSyncAt: ms - 120_000, live: true) }

    /// 서버 · 키체인 없는 컨트롤러 (엔진을 만들려 하면 실패한다)
    private static func controller(store: PlannerStore, defaults: UserDefaults) -> SyncController {
        let env = SyncController.Environment(
            suggestedName: "서재 Mac", credentials: MemoryCredentialStore(), defaults: defaults,
            makeEngine: { _, _, _ in throw SyncEngineError(.offline, "QA") },
            backupRoot: FileManager.default.temporaryDirectory.appendingPathComponent("spiralday-sync-qa-backups", isDirectory: true),
            watchesSystem: false)
        return SyncController(store: store, env: env)
    }

    static func present(_ name: String, sync: SyncController, store: PlannerStore) {
        let now = Date()
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let code = "7KQ2M-H4XWD-9PZ3A-RT6YC-M1EB8"
        let deviceName = "서재 Mac"
        sync.qaDevices = [
            SyncDeviceRow(id: "d1", name: deviceName, platform: .mac, created: ms - 40 * 86_400_000, lastSeen: ms, current: true),
            SyncDeviceRow(id: "d2", name: "작은 iPad", platform: .iPad, created: ms - 60 * 86_400_000, lastSeen: ms - 300_000, current: false),
            SyncDeviceRow(id: "d3", name: "회사 PC", platform: .windows, created: ms - 20 * 86_400_000, lastSeen: ms - 26 * 3_600_000, current: false),
            SyncDeviceRow(id: "d4", name: nil, platform: .iPhone, created: ms - 60_000, lastSeen: ms - 60_000, current: false),
        ]
        let task: (String, Int) -> JSONValue = { t, m in ["id": .string(UUID().uuidString), "text": .string(t), "mark": .number(Double(m))] }
        let day: JSONValue = ["tasks": .array([task("견적서 비교", 1), task("운동 30분", 2), task("책 3장 읽기", 0)]),
                              "slots": .array((0..<144).map { $0 >= 20 && $0 < 33 ? 1 : -1 }),
                              "comment": "생각보다 일찍 끝냈다", "memos": ["", "", ""], "memoTags": ["", "", ""]]
        let earlier: JSONValue = ["tasks": .array([task("견적서 비교", 0)]), "slots": .array((0..<144).map { _ in -1 }),
                                  "comment": "", "memos": ["", "", ""], "memoTags": ["", "", ""]]
        sync.qaHistory = SyncText.versionRows(week: false, [
            (seq: 31, at: ms - 90_000, current: true, value: day),
            (seq: 27, at: ms - 3 * 3_600_000, current: false, value: earlier),
            (seq: 12, at: ms - 26 * 3_600_000, current: false, value: nil),
        ])
        let groupDevices = [SyncGroupDeviceName(name: "작은 iPad", platform: .iPad), SyncGroupDeviceName(name: "회사 PC", platform: .windows)]
        let books = store.userBooks.map(\.name)
        let idle = SyncViewStatus(state: .idle, pending: 0, lastSyncAt: ms - 120_000, live: true)
        func on(_ s: SyncViewStatus = idle, flow: SyncFlow? = nil, warnings: [SyncWarningItem] = [], pending: Bool = false, problem: String? = nil) {
            sync.qaPresent(status: s, inGroup: true, flow: flow, warnings: warnings, recoveryPending: pending, deviceName: deviceName, startProblem: problem)
        }
        func off(_ local: SyncLocalStep? = nil, flow: SyncFlow? = nil, input: [String: String] = [:]) {
            sync.qaInput = input
            sync.qaPresent(status: nil, inGroup: false, flow: flow, local: local, deviceName: deviceName)
        }
        let request = SyncRequestInfo(platform: .iPhone, deadline: now.addingTimeInterval(178), triesLeft: 3)
        let snap = SyncBackupSnapshot(folder: URL(fileURLWithPath: "/tmp"), date: now, files: [])
        switch name {
        case "off": off()
        case "off-demo": sync.qaPresent(status: nil, inGroup: false, flow: nil, deviceName: deviceName, available: false)
        case "creds": sync.qaPresent(status: nil, inGroup: false, flow: nil, deviceName: deviceName, credsUnreadable: true)
        case "problem":
            sync.qaPresent(status: nil, inGroup: false, flow: nil, deviceName: deviceName,
                           startProblem: SyncText.errorText(KeychainError(status: errSecAuthFailed), .launch))
        case "moved": sync.qaPresent(status: nil, inGroup: false, flow: nil, deviceName: deviceName, moved: true)
        case "start": off(.start)
        case "join-input": off(.join)
        case "join-code": off(.join, input: ["code": "K7QDM2X"])
        case "join-link": off(.join, input: ["link": "SPIRALDAY-PAIR:1:Zm9yLXNjcmVlbnNob3RzLW9ubHktbm90LWEtcmVhbC1rZXk"])
        case "join-error": off(.join, input: ["code": "K7QDM2XH", "error": SyncText.errorText(code: .rateLimited, fallback: nil, .join, retryAfter: 600)])
        case "restore-input": off(.restore)
        case "restore-typo": off(.restore, input: ["restore": "7KQ2M-H4XWD-9PZ3A-RT6YC-M1EB"])
        case "restore-ok": off(.restore, input: ["restore": Codes.formatRecoveryCode(Codes.newRecoveryCode())])
        case "restore-merge": off(.restore, input: ["restore": Codes.formatRecoveryCode(Codes.newRecoveryCode()), "merge": "1"])
        case "recovery-working": on(flow: .recovery(reason: .create, stage: .working))
        case "recovery-show": on(flow: .recovery(reason: .create, stage: .show(code: code)), pending: true)
        case "recovery-rotate": on(flow: .recovery(reason: .rotate, stage: .show(code: code)), pending: true)
        case "recovery-check":
            sync.qaInput = ["checking": "1"]
            on(flow: .recovery(reason: .create, stage: .show(code: code)), pending: true)
        case "recovery-failed": on(flow: .recovery(reason: .rotate, stage: .failed(SyncText.errorText(code: .offline, fallback: nil))))
        case "pair-opening": on(flow: .pair(mode: .qr, stage: .opening))
        case "pair-qr":
            on(flow: .pair(mode: .qr, stage: .waiting(qrText: "SPIRALDAY-PAIR:1:Zm9yLXNjcmVlbnNob3RzLW9ubHktbm90LWEtcmVhbC1rZXk", code: nil,
                                                       deadline: now.addingTimeInterval(581))))
        case "pair-code": on(flow: .pair(mode: .code, stage: .waiting(qrText: nil, code: "K7QD-M2XH", deadline: now.addingTimeInterval(543))))
        case "pair-request":
            sync.qaInput = ["digits": "83"]
            on(flow: .pair(mode: .qr, stage: .request(request)))
        case "pair-wrong":
            var r = request
            r.wrong = true
            r.triesLeft = 2
            on(flow: .pair(mode: .qr, stage: .request(r)))
        case "pair-approving":
            sync.qaInput = ["digits": "8301"]
            on(flow: .pair(mode: .qr, stage: .approving(request)))
        case "pair-approved": on(flow: .pair(mode: .qr, stage: .approved(platform: .iPhone)))
        case "pair-denied": on(flow: .pair(mode: .qr, stage: .denied))
        case "pair-withdrawn": on(flow: .pair(mode: .qr, stage: .withdrawn))
        case "pair-expired": on(flow: .pair(mode: .code, stage: .expired(wasRequest: false)))
        case "pair-error": on(flow: .pair(mode: .qr, stage: .error(SyncText.errorText(code: .pairingLimit, fallback: nil, .pair))))
        case "join-waiting": off(flow: .join(stage: .waiting(digits: "8301", deadline: now.addingTimeInterval(176)), localBooks: books))
        case "join-approved": off(flow: .join(stage: .approved(devices: groupDevices, deadline: now.addingTimeInterval(1795)), localBooks: books))
        case "join-accepting": off(flow: .join(stage: .accepting(devices: groupDevices, deadline: now.addingTimeInterval(1795)), localBooks: books))
        case "join-done": on(flow: .join(stage: .done(backup: snap), localBooks: books))
        case "join-denied": off(flow: .join(stage: .denied, localBooks: books))
        case "join-expired": off(flow: .join(stage: .expired(afterApproval: false), localBooks: books))
        case "join-expired-after": off(flow: .join(stage: .expired(afterApproval: true), localBooks: books))
        case "join-failed": off(flow: .join(stage: .error(SyncText.errorText(code: .invalidCode, fallback: nil, .join)), localBooks: books))
        case "restore-done": on(flow: .restore(evicted: false, backup: snap))
        case "restore-evicted": on(flow: .restore(evicted: true, backup: nil))
        case "idle", "history": on()
        case "syncing": on(SyncViewStatus(state: .syncing, pending: 2, lastSyncAt: ms - 120_000, live: true))
        case "offline": on(SyncViewStatus(state: .offline, pending: 3, lastSyncAt: ms - 2 * 3_600_000))
        case "error": on(SyncViewStatus(state: .error, pending: 1, lastSyncAt: ms - 600_000, error: "동기화 서버에 잠깐 문제가 있어요."))
        case "quota": on(SyncViewStatus(state: .quota, pending: 4, lastSyncAt: ms - 86_400_000, error: "동기화 저장 공간(50MB)이 가득 찼어요."))
        case "warnings":
            on(warnings: [SyncWarningItem(id: "w1", warning: .massDeleteBooks, bookName: nil, at: now),
                          SyncWarningItem(id: "w2", warning: .bookDeletedElsewhere, bookName: "2025 다이어리", at: now),
                          SyncWarningItem(id: "w3", warning: .updateRequired, bookName: nil, at: now)],
               pending: true)
            sync.onCheckForUpdates = {}
        case "other-server":
            sync.qaPresent(status: nil, inGroup: true, flow: nil, deviceName: deviceName,
                           startProblem: "이 Mac 의 동기화 그룹은 다른 서버(http://127.0.0.1:9000)에 있어요.")
        case "removed": on(SyncViewStatus(state: .removed, lastSyncAt: ms - 86_400_000))
        case "gone": on(SyncViewStatus(state: .groupGone, lastSyncAt: ms - 3 * 86_400_000))
        default: off()
        }
    }

    /// 화면 밖 창에 그려 PNG 로 (Form 은 ImageRenderer 로 그려지지 않는다)
    private static func capture<V: View>(_ view: V, size: CGSize, dark: Bool, titled: Bool, to url: URL) async -> Bool {
        // 창 바탕 (설정 창 · 시트처럼) 위에
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let style: NSWindow.StyleMask = titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let w = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                         styleMask: style, backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.setContentSize(size)
        w.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        let target: NSView = host
        defer { w.orderOut(nil) }
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return false }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url) } catch { return false }
        return true
    }
}

/// 메모리에만 두는 UserDefaults (QA · 테스트: 쓴 값이 설정 파일로 가지 않는다). 동기화 설정이 쓰는 것만 덮는다
final class SyncMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
}
