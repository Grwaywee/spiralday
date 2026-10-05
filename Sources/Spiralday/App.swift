import SwiftUI
import AppKit
import Sparkle
import SpiraldayKit
import SpiraldaySync

@main
struct SpiraldayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 창은 AppDelegate 가 직접 만든다 (창 = 종이, 비율 고정, 옆 팔레트)
        Settings { EmptyView() }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("업데이트 확인…") { delegate.checkForUpdates() }
                }
                CommandGroup(replacing: .appSettings) {
                    // 둘러보는 중에는 설정에서 책을 바꾸지 못하게 (돌아갈 책이 어긋난다)
                    Button("설정…") {
                        guard !TourController.shared.isRunning else { NSSound.beep(); return }
                        SettingsWindowController.shared.show(store: delegate.store, state: delegate.state)
                    }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .help) {
                    Button("플래너 둘러보기") { TourController.shared.start(.full) }
                    Button("튜토리얼 모음…") {
                        guard !TourController.shared.isRunning else { NSSound.beep(); return }
                        SettingsWindowController.shared.showTutorials(store: delegate.store, state: delegate.state)
                    }
                    Divider()
                    Button("Spiralday 웹사이트") { Links.open(Links.website) }
                    Button("버그 신고 · 기능 제안…") { Links.open(Links.feedback) }
                    Divider()
                    Button("GitHub (오픈소스)") { Links.open(Links.github) }
                    Button("GitHub에서 ⭐ 주기") { Links.open(Links.github) }
                    Button("개인정보 처리방침") { Links.open(Links.privacy) }
                    Button("린에자일헝그리") { Links.open(Links.company) }
                }
                // 플래너 둘러보기 중에는 넘기기 · 쪽 바꾸기가 쉰다 (둘러보기가 장을 옮긴다)
                CommandMenu("플래너") {
                    Button("주간 보기") { planner { $0.switchKind(.weekly) } }.keyboardShortcut("1", modifiers: .command)
                    Button("일간 보기") { planner { $0.switchKind(.daily) } }.keyboardShortcut("2", modifiers: .command)
                    Button("홈 (통계)") { planner { $0.switchKind(.home) } }.keyboardShortcut("0", modifiers: .command)
                    Button("팔레트 접기 / 펼치기") { planner { _ in PaletteModel.shared.togglePinned() } }
                        .keyboardShortcut("\\", modifiers: .command)

                    Divider()
                    Button("이전 장") { planner { $0.flip(.backward) } }.keyboardShortcut("[", modifiers: .command)
                    Button("다음 장") { planner { $0.flip(.forward) } }.keyboardShortcut("]", modifiers: .command)
                    Button("오늘") { planner { $0.goToday() } }.keyboardShortcut("t", modifiers: .command)
                    Divider()
                    Button("PDF로 내보내기…") {
                        planner { _ in PDFExportWindowController.shared.show(store: delegate.store, state: delegate.state) }
                    }
                    .keyboardShortcut("p", modifiers: .command)
                    // 동기화: 지금 맞추기 · 이 날(주)의 이전 버전 · 동기화 설정. 꺼져 있어도 세 항목이 보이고, 켜기 전에는
                    // 앞의 둘은 흐리다 (1.0.7 과 달라지는 화면: 이 메뉴 · 설정 창의 ‘동기화’ — 종이 · 팔레트 · PDF 는 그대로)
                    SyncMenuItems(sync: delegate.sync, store: delegate.store, state: delegate.state,
                                  blocked: { TourController.shared.isRunning })
                }
            }
    }
}

extension SpiraldayApp {
    /// 플래너 메뉴 항목: 둘러보는 중이면 아무것도 하지 않는다
    @MainActor
    private func planner(_ f: (AppState) -> Void) {
        guard !TourController.shared.isRunning else { return }
        f(delegate.state)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: PlannerStore
    let state: AppState
    /// Spiralday Sync (기본은 꺼짐 — 켜기 전까지 키체인 · 네트워크를 건드리지 않는다)
    let sync: SyncController
    private var windowController: MainWindowController?
    /// 원격 업데이트 (Sparkle). 데모·스냅샷 같은 개발 실행에서는 켜지 않는다.
    private var updater: SPUStandardUpdaterController?
    /// 켤 때 읽을 수 있는 책이 하나도 없어서 새로 만들어 편 책 (알림에 적는다 → DataSafety.swift)
    private var launchFreshBook: UUID?
    #if DEBUG
    /// --sync-drive: 여러 기기 동기화 검증이 모는 실행 (디버그 빌드만 — Sync/SyncQADrive.swift)
    private var drive: SyncQADriveLaunch.Config?
    #endif

    var canCheckForUpdates: Bool { updater != nil }

    func checkForUpdates() { updater?.checkForUpdates(nil) }

    private static let args = CommandLine.arguments

    /// 예전 이름(Paper Planner, personal.paperplanner) 시절의 설정을 한 번 옮겨 온다
    private static func migrateDefaults() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromPaperPlanner"), let old = UserDefaults(suiteName: "personal.paperplanner") else { return }
        for (k, v) in old.dictionaryRepresentation()
        where k == "onboardingDone" || k.hasPrefix("contentSize.") || k == "settingsPane" {
            d.set(v, forKey: k)
        }
        d.set(true, forKey: "migratedFromPaperPlanner")
    }

    override init() {
        #if DEBUG
        // 여러 기기 동기화 검증: 따로 된 폴더 · 테스트용 키체인 이름 · 폴더 안의 설정 값만 쓴다 (앱의 데이터 · 설정을 건드리지 않는다)
        if let cfg = SyncQADriveLaunch.config(Self.args) {
            drive = cfg
            store = PlannerStore(folder: cfg.dataDir)
            state = AppState(kind: .daily)
            sync = SyncQADriveLaunch.controller(store: store, config: cfg)
            super.init()
            state.store = store
            SyncController.shared = sync
            return
        }
        #endif
        Self.migrateDefaults()
        if Self.args.contains("--demo") || Self.args.contains("--snapshot") || Self.args.contains("--pdf-test")
            || Self.args.contains("--ping-test") || Self.args.contains("--dday-migrate-test") || Self.args.contains("--icon")
            || Self.args.contains("--sample-book-test") || Self.args.contains("--tour-test")
            || Self.args.contains("--palette-test") || Self.args.contains("--load-safety-test") || Self.args.contains("--sync-qa") {
            // 개발/스크린샷용: 실제 데이터 파일을 건드리지 않는다
            store = PlannerStore(inMemory: true)
            store.fillSample(around: Date())
            store.useDemoBook(start: Dates.add(days: -42, to: Dates.weekStart(Date())))
        } else {
            store = PlannerStore()
            // 책장을 읽고 옮기기까지 끝난 뒤, 설치 후 처음 한 번만 예시 플래너를 꽂아 둔다 (펼치지는 않는다)
            store.seedSampleBookIfNeeded()
            // 펼치려던 책 파일을 모두 읽지 못했으면 (원본은 그대로 두고) 새 플래너를 펴서 적는 것이 저장되게 한다
            launchFreshBook = store.openFreshBookIfNothingReadable()
        }
        state = AppState(kind: Self.args.contains("--weekly") ? .weekly
                            : Self.args.contains("--home") ? .home : store.data.prefs.lastKind)
        // 동기화는 파일에 저장하는 실행에서만 (데모 · 스냅샷은 메모리 저장소라 꺼짐으로만 보인다)
        let st = store
        sync = SyncController.Environment.live(store: st).map { SyncController(store: st, env: $0) }
            ?? SyncController.unavailable(store: st)
        super.init()
        state.store = store
        SyncController.shared = sync
    }

    #if DEBUG
    func applicationWillFinishLaunching(_ notification: Notification) {
        // --sync-drive: Dock · ⌘Tab 에 나오지 않고 앞으로 오지 않는다 (쓰던 사람의 포커스를 가져가지 않게)
        if drive != nil { NSApp.setActivationPolicy(.accessory) }
    }

    /// --sync-drive: 플래너 종이(RootView)를 화면 밖 창에 열고 동기화를 켠 뒤 통로를 연다 (통계 · 업데이트 · 처음 안내 · 둘러보기 없이)
    private func startDrive(_ cfg: SyncQADriveLaunch.Config) {
        Fonts.register()
        let window = SyncQADriveWindow.make(store: store, state: state)
        sync.plannerWindow = { window }
        state.plannerWindow = window
        state.installMonitors()
        let sy = sync, st = state
        Task { @MainActor in await sy.start(state: st) }
        SyncQADrive.start(cfg, store: store, state: state, sync: sync) { window }
        Fonts.activate { Task { @MainActor in st.fontsReady = true } }
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let drive {
            startDrive(drive)
            return
        }
        #endif
        // 통계 전송 확인용: 창 없이 한 번 보내고 결과를 찍은 뒤 끝낸다
        if Self.args.contains("--ping-test") {
            Telemetry.runPingTest()
            return
        }
        // D-day 옮기기 확인용: 주어진 책 파일을 복사해 옮겨 보고 요약을 찍은 뒤 끝낸다 (실제 데이터는 건드리지 않는다)
        if let i = Self.args.firstIndex(of: "--dday-migrate-test") {
            guard i + 2 < Self.args.count else {
                print("사용법: Spiralday --dday-migrate-test <옛 책 json> <결과 json>")
                exit(2)
            }
            exit(DDayMigrateTest.run(input: URL(fileURLWithPath: Self.args[i + 1]),
                                     output: URL(fileURLWithPath: Self.args[i + 2])))
        }
        // 데이터 안전 확인용: 임시 폴더에서 깨진 책 · 책장 파일로 켜기 → 저장 → 다시 켜기를 흉내 내 원본이 그대로인지 본다
        if let i = Self.args.firstIndex(of: "--load-safety-test") {
            guard i + 1 < Self.args.count else {
                print("사용법: Spiralday --load-safety-test <결과 폴더>")
                exit(2)
            }
            let dir = URL(fileURLWithPath: Self.args[i + 1])
            Task { @MainActor in exit(await LoadSafetyTest.run(to: dir)) }
            return
        }
        // 손글씨 폰트는 어떤 창보다 먼저 등록한다
        Fonts.register()
        if let i = Self.args.firstIndex(of: "--icon"), i + 1 < Self.args.count {
            let out = URL(fileURLWithPath: Self.args[i + 1])
            let variant = i + 2 < Self.args.count ? Int(Self.args[i + 2]) ?? 0 : 0
            Fonts.activate {
                Task { @MainActor in
                    let r = ImageRenderer(content: AppIconArt(variant: variant))
                    r.scale = 1
                    if let img = r.cgImage { Snapshotter.write(img, out) }
                    exit(0)
                }
            }
            return
        }
        // 설정 → 동기화의 모든 상태를 라이트 · 다크로 PNG 로 찍고 끝낸다 (메모리에서만 · 서버 · 키체인 없이)
        if let i = Self.args.firstIndex(of: "--sync-qa") {
            guard i + 1 < Self.args.count else {
                print("사용법: Spiralday --sync-qa <결과 폴더> [상태 …]")
                exit(2)
            }
            let dir = URL(fileURLWithPath: Self.args[i + 1])
            let only = Array(Self.args[(i + 2)...].filter { !$0.hasPrefix("-") })
            let st = store
            Fonts.activate {
                Task { @MainActor in exit(await SyncQA.run(to: dir, store: st, only: only)) }
            }
            return
        }
        if let i = Self.args.firstIndex(of: "--pdf-test"), i + 1 < Self.args.count {
            let dir = URL(fileURLWithPath: Self.args[i + 1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let st = store, sa = state
            Fonts.activate {
                Task { @MainActor in
                    let store = st, state = sa
                    let ws = Dates.weekStart(Date())
                    for layout in PDFLayout.allCases {
                        try? await PDFExporter.export(layout, from: ws, to: Dates.add(days: 6, to: ws), cutGuides: true,
                                                      store: store, state: state,
                                                      to: dir.appendingPathComponent("\(layout.rawValue).pdf")) { _ in }
                    }
                    exit(0)
                }
            }
            return
        }
        if let i = Self.args.firstIndex(of: "--snapshot"), i + 1 < Self.args.count {
            let dir = URL(fileURLWithPath: Self.args[i + 1])
            Fonts.activate {
                Task { @MainActor in
                    Snapshotter.run(to: dir)
                    Snapshotter.onboarding(to: dir)
                    FrontMatterSnapshot.run(to: dir)
                    exit(0)
                }
            }
            return
        }
        // 예시 플래너 확인용: 오늘 기준으로 만들어 JSON 과 모든 장을 PNG 로 찍고 끝낸다 (메모리에서만)
        if let i = Self.args.firstIndex(of: "--sample-book-test") {
            guard i + 1 < Self.args.count else {
                print("사용법: Spiralday --sample-book-test <결과 폴더>")
                exit(2)
            }
            let dir = URL(fileURLWithPath: Self.args[i + 1])
            Fonts.activate {
                Task { @MainActor in exit(await SampleBookTest.run(to: dir)) }
            }
            return
        }
        // 플래너 둘러보기 확인용: 메모리에만 만든 예시 플래너로 모든 단계를 PNG 로 찍고 단계 목록을 찍은 뒤 끝낸다
        if let i = Self.args.firstIndex(of: "--tour-test") {
            guard i + 1 < Self.args.count else {
                print("사용법: Spiralday --tour-test <결과 폴더>")
                exit(2)
            }
            let dir = URL(fileURLWithPath: Self.args[i + 1])
            Fonts.activate {
                Task { @MainActor in exit(TourTest.run(to: dir)) }
            }
            return
        }
        // 팔레트 확인용: 네 자리 × 펼침 · 접힘을 종이 옆에 그려 PNG 로 남기고 끝낸다 (메모리에서만)
        if let i = Self.args.firstIndex(of: "--palette-test") {
            guard i + 1 < Self.args.count else {
                print("사용법: Spiralday --palette-test <결과 폴더>")
                exit(2)
            }
            let dir = URL(fileURLWithPath: Self.args[i + 1])
            let st = store
            Fonts.activate {
                Task { @MainActor in exit(PaletteTest.run(to: dir, store: st)) }
            }
            return
        }
        let demo = Self.args.contains("--demo")
        // 읽지 못한 책 · 책장 파일: 어떤 창보다 먼저 한 번 알린다 (원본은 그대로 두고 복사본을 남겼다).
        // 앱을 쓰다가 그 책을 펼치려 하면 펼치지 않고 그때마다 알린다.
        DataSafetyAlert.presentLaunchNotices(store, freshBook: launchFreshBook)
        let safetyStore = store
        store.onUnreadableBook = { [weak safetyStore] note in
            Task { @MainActor in
                guard let safetyStore else { return }
                DataSafetyAlert.presentRefused(note, store: safetyStore)
            }
        }
        // .app 으로 실행될 때만 (Info.plist 에 SUFeedURL 이 있을 때) 업데이트를 확인한다
        if !demo, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            sync.onCheckForUpdates = { [weak self] in self?.checkForUpdates() }
        }
        // Spiralday Sync: 이 설치가 그룹에 들어 있을 때만 키체인을 읽고 엔진을 띄운다 (기본은 꺼짐). 데모에서는 쓰지 않는다
        if demo {
            sync.startUnavailable(state: state)
        } else {
            let sy = sync, st = state
            Task { @MainActor in await sy.start(state: st) }
        }
        // 익명 사용 통계 (하루 한 번, 설정에서 끌 수 있다). 데모에서는 보내지 않는다.
        if !demo { Telemetry.start() }
        // GitHub ⭐ 부탁 (서로 다른 날로 7일째에 한 번만). 데모에서는 날짜를 세지 않고, --star-prompt 는 바로 띄워 본다.
        let mainWindow: @MainActor () -> NSWindow? = { [weak self] in self?.windowController?.window }
        if Self.args.contains("--star-prompt") {
            StarPrompt.force(window: mainWindow)
        } else if !demo {
            StarPrompt.start(store: store, window: mainWindow)
        }
        // 예시 플래너만 있으면 아직 처음이다: 튜토리얼에서 내 플래너를 만든다
        if !demo && (store.userBooks.isEmpty || OnboardingController.needsOnboarding) || Self.args.contains("--onboarding") {
            OnboardingController.shared.show(store: store, state: state) { [weak self] in self?.openPlanner() }
        } else {
            openPlanner()
        }
        let st = state
        Fonts.activate { Task { @MainActor in st.fontsReady = true } }
    }

    /// 플래너(책)가 준비된 뒤 본 창을 연다
    private func openPlanner() {
        guard windowController == nil else { windowController?.show(); return }
        let wc = MainWindowController(store: store, state: state)
        windowController = wc
        // 실시간 쓰기(동기화를 켰을 때만): 조합 중인 글자 · "다른 기기에서 쓰는 중" 은 이 창의 글 칸에서
        sync.plannerWindow = { [weak wc] in wc?.window }
        wc.show()
        state.installMonitors()
        TourController.shared.attach(store: store, state: state, window: wc.window)
        if Self.args.contains("--settings") { SettingsWindowController.shared.show(store: store, state: state) }
        // 플래너 둘러보기: 처음 한 번만 저절로 (새 사용자는 처음 안내를 마친 뒤, 기존 사용자는 1.0.5 를 처음 켰을 때).
        // --tour 는 데모에서도 바로 띄워 본다.
        if Self.args.contains("--tour") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { TourController.shared.start(.full) }
        } else if !Self.args.contains("--demo") && !Self.args.contains("--settings") {
            TourController.shared.startFirstTimeIfNeeded()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 끝내기 전: 동기화를 켰으면 저장하고 남은 편집을 올린다 (오래 기다리지 않는다 — 못 올린 것은 다음에 켤 때 올린다)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard sync.inGroup, sync.hasEngine else { return .terminateNow }
        sync.prepareToQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

// MARK: - Snapshot CLI

/// `Spiralday --snapshot <dir>` renders PNGs used for visual QA and the README:
///   daily_blank.png / daily.png     1277 × 2000 px (same pixel grid as the template)
///   weekly_blank.png / weekly.png   2000 × 1277 px
///   curl_daily_NN.png / curl_weekly_NN.png   page-turn frames (half size)
@MainActor
enum Snapshotter {
    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sample = PlannerStore(inMemory: true)
        sample.fillSample(around: Date())
        let blank = PlannerStore(inMemory: true)

        for kind in [PageKind.daily, .weekly, .home] {
            let state = AppState(kind: kind)
            // 샘플 데이터는 이번 주 화요일에 가장 많다
            if kind == .daily { state.dayIndex = Dates.daysBetween(state.baseDay, Dates.add(days: 1, to: state.baseWeek)) }
            let size = kind.design
            for (name, store) in [("\(kind.rawValue)_blank", blank), (kind.rawValue, sample)] {
                let snap = PageSnapshotter(store: store, state: state)
                if let img = snap.image(kind: kind, index: state.index, size: size, scale: 1) {
                    write(img, dir.appendingPathComponent("\(name).png"))
                }
            }
            guard kind.flips else { continue }
            // 넘김 프레임 (절반 크기)
            let half = CGSize(width: size.width / 2, height: size.height / 2)
            let snap = PageSnapshotter(store: sample, state: state)
            if let cur = snap.image(kind: kind, index: state.index, size: half, scale: 1),
               let next = snap.image(kind: kind, index: state.index + 1, size: half, scale: 1) {
                let frames = CurlController.renderTurnFrames(PageBitmaps(current: cur, neighbor: next),
                                                             direction: .forward, edge: kind.edge,
                                                             pageSize: half, scale: 1, frameCount: 12)
                for (i, f) in frames.enumerated() {
                    write(f, dir.appendingPathComponent(String(format: "curl_%@_%02d.png", kind.rawValue, i)))
                }
            }
        }
    }

    /// 튜토리얼 첫 장 (README 이미지). 처음 켠 사람처럼 빈 서재로 그린다
    static func onboarding(to dir: URL) {
        let fresh = PlannerStore(inMemory: true)
        let r = ImageRenderer(content: OnboardingView(model: OnboardingModel(store: fresh)).environmentObject(fresh))
        r.scale = 2
        if let img = r.cgImage { write(img, dir.appendingPathComponent("onboarding.png")) }
    }

    static func write(_ img: CGImage, _ url: URL) {
        let rep = NSBitmapImageRep(cgImage: img)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }
}

// MARK: - D-day migrate CLI

/// `Spiralday --dday-migrate-test <in.json> <out.json>`
/// 책 파일을 <out> 으로 복사한 뒤, 앱이 책을 열 때와 똑같은 코드(PlannerStore.openBookFile)로
/// 백업(<out>.before-per-day-dday.json) → D-day 옮기기 → 저장을 해 보고 요약을 찍는다. <in> 은 읽기만 한다.
/// <in> 과 <out> 이 같은 파일이거나, <out> 이 앱의 실제 데이터 폴더 안이면 아무것도 하지 않고 끝낸다.
@MainActor
enum DDayMigrateTest {
    static func run(input: URL, output: URL) -> Int32 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: input.path) else { print("입력 파일이 없어요: \(input.path)"); return 1 }
        let inPath = real(input), outPath = real(output)
        guard inPath != outPath else {
            print("입력과 결과는 다른 파일이어야 해요 (입력 파일은 읽기만 해요)")
            return 2
        }
        let support = real(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        for name in ["Spiralday", "PaperPlanner"] where outPath.hasPrefix(support + "/" + name.lowercased() + "/") {
            print("결과 파일을 앱의 실제 데이터 폴더(~/Library/Application Support/\(name)) 안에 둘 수 없어요")
            return 2
        }
        // 결과 쪽 파일과 지난번 실행이 남긴 결과 쪽 백업은 이 명령이 만든 것이라 지우고 새로 만든다
        try? fm.removeItem(at: output)
        try? fm.removeItem(at: PlannerStore.ddayBackupURL(output))
        do { try fm.copyItem(at: input, to: output) } catch { print("복사 실패: \(error.localizedDescription)"); return 1 }
        let today = Date()
        guard let (data, migration) = PlannerStore.openBookFile(output, book: nil, today: today) else {
            print("책 파일로 읽지 못했어요: \(input.path)")
            return 1
        }
        print("입력: \(input.path)")
        print("결과: \(output.path)")
        if let m = migration {
            print("옮김: 예 (ddaysPerDay false → true)")
            print("백업: \(m.backup?.path ?? "-") (\(m.backupCreated ? "새로 만듦" : "이미 있어서 그대로 둠"))")
            print("저장한 D-day (목록): \(m.library)개")
            for d in data.prefs.ddays { print("  · \(line(d, today))") }
            print("D-day 를 붙인 날: \(m.stampedDays.count)일 \(m.stampedDays)")
        } else {
            print("옮김: 아니오 (이미 날마다 D-day 인 파일 — 바꾼 것 없음)")
            print("저장한 D-day (목록): \(data.prefs.ddays.count)개")
        }
        let tk = Dates.key(today)
        let todays = data.days[tk]?.ddays ?? []
        print("오늘(\(tk)) D-day: \(todays.isEmpty ? "없음" : "\(todays.count)개")")
        for d in todays { print("  · \(line(d, today))") }
        let withDDay = data.days.filter { !$0.value.ddays.isEmpty }.count
        let recorded = data.days.values.filter(\.hasRecord).count
        let tasks = data.days.values.reduce(0) { $0 + $1.tasks.count }
        print("날 기록: \(data.days.count)개 (기록한 날 \(recorded) · D-day 붙은 날 \(withDDay)) · 할 일 \(tasks)개 · 주간 \(data.weeks.count)개")
        // 저장한 결과를 다시 읽어 본다
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let raw = try? Data(contentsOf: output), let again = try? dec.decode(PlannerData.self, from: raw) else {
            print("다시 읽기: 실패")
            return 1
        }
        print("다시 읽기: 성공 (날 \(again.days.count)개 · ddaysPerDay \(again.prefs.ddaysPerDay))")
        return 0
    }

    /// 심볼릭 링크를 풀고 정리한 경로 (아직 없는 파일이면 있는 부모 폴더까지만 풀린다).
    /// macOS 기본 디스크는 대소문자를 가리지 않으므로 소문자로 비교한다.
    private static func real(_ url: URL) -> String {
        let u = url.standardizedFileURL
        let dir = u.deletingLastPathComponent().resolvingSymlinksInPath()
        return dir.appendingPathComponent(u.lastPathComponent).resolvingSymlinksInPath().path.lowercased()
    }

    private static func line(_ d: DDay, _ today: Date) -> String {
        let src = d.source.map { " ← \($0.uuidString.prefix(8))" } ?? ""
        return "\(d.title.isEmpty ? "(제목 없음)" : d.title) \(Dates.key(d.date)) \(d.count(from: today)) [id \(d.id.uuidString.prefix(8))\(src)]"
    }
}
