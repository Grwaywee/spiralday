import SwiftUI
import AppKit

@main
struct PaperPlannerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 창은 AppDelegate 가 직접 만든다 (창 = 종이, 비율 고정, 옆 팔레트)
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("설정…") { SettingsWindowController.shared.show(store: delegate.store, state: delegate.state) }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(replacing: .newItem) {}
                CommandMenu("플래너") {
                    Button("주간 보기") { delegate.state.switchKind(.weekly) }.keyboardShortcut("1", modifiers: .command)
                    Button("일간 보기") { delegate.state.switchKind(.daily) }.keyboardShortcut("2", modifiers: .command)
                    Button("홈 (통계)") { delegate.state.switchKind(.home) }.keyboardShortcut("0", modifiers: .command)

                    Divider()
                    Button("이전 장") { delegate.state.flip(.backward) }.keyboardShortcut("[", modifiers: .command)
                    Button("다음 장") { delegate.state.flip(.forward) }.keyboardShortcut("]", modifiers: .command)
                    Button("오늘") { delegate.state.goToday() }.keyboardShortcut("t", modifiers: .command)
                    Divider()
                    Button("PDF로 내보내기…") { PDFExportWindowController.shared.show(store: delegate.store, state: delegate.state) }
                        .keyboardShortcut("p", modifiers: .command)
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: PlannerStore
    let state: AppState
    private var windowController: MainWindowController?

    private static let args = CommandLine.arguments

    override init() {
        if Self.args.contains("--demo") || Self.args.contains("--snapshot") || Self.args.contains("--pdf-test") {
            // 개발/스크린샷용: 실제 데이터 파일을 건드리지 않는다
            store = PlannerStore(inMemory: true)
            store.fillSample(around: Date())
            store.useDemoBook(start: Dates.add(days: -42, to: Dates.weekStart(Date())))
        } else {
            store = PlannerStore()
        }
        state = AppState(kind: Self.args.contains("--weekly") ? .weekly
                            : Self.args.contains("--home") ? .home : store.data.prefs.lastKind)
        super.init()
        state.store = store
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                    exit(0)
                }
            }
            return
        }
        let demo = Self.args.contains("--demo")
        if !demo && (store.books.isEmpty || OnboardingController.needsOnboarding) || Self.args.contains("--onboarding") {
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
        wc.show()
        state.installMonitors()
        if Self.args.contains("--settings") { SettingsWindowController.shared.show(store: store, state: state) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Snapshot CLI

/// `PaperPlanner --snapshot <dir>` renders PNGs used for visual QA and the README:
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

    static func write(_ img: CGImage, _ url: URL) {
        let rep = NSBitmapImageRep(cgImage: img)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }
}
