import AppKit
import SwiftUI
import SpiraldayKit

// ─────────────────────────────────────────────────────────────────────────────
// `Spiralday --news-qa <폴더>`: 앱 안 소식의 화면을 라이트 · 다크로 PNG 로 찍고 끝낸다 (메모리에서만 — 받지 않고, 설정 값 ·
// 캐시 폴더 · 데이터 폴더를 건드리지 않는다).
//   card-notice-*.png · card-whatsnew-*.png · card-long-*.png   카드 (중요한 소식 · 이번에 달라진 점 · 긴 본문은 카드 안에서 스크롤)
//   pane-*.png · pane-empty-*.png · pane-off-*.png              설정 › 소식 (줄 · 안 본 점 · 펼친 줄 · 빈 목록 · 스위치 끔)
//   sidebar-*.png                                              설정 창 옆 목록의 ‘소식’ 점
//   place-<팔레트 자리>-<쪽>.png · place-full-screen.png         종이 · 스프링 · 팔레트 옆 카드 자리 (실제 창과 같은 자리 계산)
// 글은 모두 시험용이다 (실제 공지가 아니다).
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum NewsQA {
    /// 스냅샷의 오늘 (날짜 글이 날마다 바뀌지 않게)
    static let today = Dates.parse("2026-10-21")!

    /// 시험용 피드 (Docs/InAppNews.md §2 의 모양)
    static let sampleFeed = Data("""
    {"version":1,"items":[
     {"id":"2026-10-20-sync-check","date":"2026-10-20","kind":"notice","importance":"important",
      "title":{"ko":"25일 새벽, 동기화를 잠깐 쉬어요","en":"Sync takes a short break early on the 25th"},
      "body":{"ko":"새벽 2시부터 30분쯤 서버를 손봐요.\\n그동안 쓴 것은 기기에 남아 있다가, 끝나면 저절로 맞춰져요.","en":"We’ll be servicing the server for about 30 minutes from 2 a.m."},
      "link":"https://spiralday.com/privacy.html","expires":"2026-10-25"},
     {"id":"2026-10-16-guide","date":"2026-10-16","kind":"update","importance":"normal",
      "title":{"ko":"spiralday.com 에 쓰는 법을 새로 적었어요"},
      "body":{"ko":"형광펜으로 분류하는 법과 PDF 로 뽑는 법을 사진과 함께 적었어요."},"link":"https://spiralday.com/"},
     {"id":"2025-12-03-hello","date":"2025-12-03","kind":"notice","importance":"normal",
      "title":{"ko":"Spiralday 소식은 여기에 모아 둬요"},
      "body":{"ko":"알림은 띄우지 않아요. 꼭 알아야 할 것만 앱을 열 때 한 번 보여 드려요."}}
    ]}
    """.utf8)

    static func run(to dir: URL) async -> Int32 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var count = 0
        var failures = 0
        func done(_ ok: Bool, _ name: String) {
            if ok { count += 1 } else { failures += 1; print("✗ \(name)") }
        }
        let notes = NewsCenter.bundledNotes().isEmpty ? [sampleNote] : NewsCenter.bundledNotes()
        let version = notes.first?.app ?? "1.1.1"
        let center = qaCenter(notes: notes, version: version, seen: [])
        // 카드
        let notice = center.content(.notice(id: "2026-10-20-sync-check"))!
        let whatsNew = center.content(.whatsNew(app: version))!
        let long = NewsCardContent(kind: .notice, id: "long", caption: notice.caption, title: "긴 소식은 카드 안에서 스크롤해요",
                                   body: (1...14).map { "\($0). 시험용 줄이에요. 카드 높이를 넘으면 본문만 스크롤하고 단추는 늘 보여요." }
                                       .joined(separator: "\n"), link: nil, footnote: nil)
        for dark in [false, true] {
            let s = dark ? "dark" : "light"
            for (name, c) in [("card-notice", notice), ("card-whatsnew", whatsNew), ("card-long", long)] {
                let file = dir.appendingPathComponent("\(name)-\(s).png")
                let view = NewsCardView(content: c, snapshot: true).padding(24)
                done(await capture(view, size: fitting(view), dark: dark, background: false, to: file), file.lastPathComponent)
            }
        }
        // 설정 › 소식: 안 본 점 (소식 둘 · 이번 버전의 노트) · 펼친 줄
        for dark in [false, true] {
            let s = dark ? "dark" : "light"
            let c = qaCenter(notes: notes, version: version, seen: [])
            c.paneShown()
            let pane = NewsSettingsPane(center: c, initiallyOpen: ["2026-10-20-sync-check"], snapshot: true).formStyle(.grouped)
            done(await capture(pane, size: CGSize(width: 530, height: 720), dark: dark, background: true,
                               to: dir.appendingPathComponent("pane-\(s).png")), "pane-\(s)")
            let empty = NewsCenter()
            empty.configure(.demo, notes: [], appVersion: version, syncOn: { false }, storage: NewsMemoryStorage())
            empty.now = { today }
            empty.load(state: NewsState(), cache: nil)
            let emptyPane = NewsSettingsPane(center: empty, snapshot: true).formStyle(.grouped)
            done(await capture(emptyPane, size: CGSize(width: 530, height: 460), dark: dark, background: true,
                               to: dir.appendingPathComponent("pane-empty-\(s).png")), "pane-empty-\(s)")
            let off = qaCenter(notes: notes, version: version, seen: ["2026-10-20-sync-check", "2026-10-16-guide", "app-\(version)"])
            off.setFetchEnabled(false)
            let offPane = NewsSettingsPane(center: off, snapshot: true).formStyle(.grouped)
            done(await capture(offPane, size: CGSize(width: 530, height: 600), dark: dark, background: true,
                               to: dir.appendingPathComponent("pane-off-\(s).png")), "pane-off-\(s)")
            // 옆 목록: 안 본 소식이 있을 때 ‘소식’ 끝의 점
            let dotCenter = qaCenter(notes: notes, version: version, seen: [])
            let sidebar = VStack(alignment: .leading, spacing: 6) {
                ForEach([SettingsPane.tutorials, .news, .data]) { p in
                    HStack(spacing: 9) {
                        SettingsIconTile(symbol: p.symbol, tint: p.tint, size: 22)
                        Text(p.title)
                        if p == .news {
                            Spacer(minLength: 4)
                            NewsSidebarDot(center: dotCenter)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
            }
            .frame(width: 190, alignment: .leading)
            .padding(.vertical, 10)
            done(await capture(sidebar, size: CGSize(width: 190, height: 130), dark: dark, background: true,
                               to: dir.appendingPathComponent("sidebar-\(s).png")), "sidebar-\(s)")
        }
        // 카드 자리: 팔레트 네 자리 × 일간 · 주간, 그리고 창이 화면을 꽉 채운 경우
        let store = PlannerStore(inMemory: true)
        store.fillSample(around: today)
        store.useDemoBook(start: Dates.add(days: -42, to: Dates.weekStart(today)))
        for edge in PaletteEdge.allCases {
            for kind in [PageKind.daily, .weekly] {
                let name = "place-\(edge.rawValue)-\(kind.rawValue).png"
                if let img = placement(edge: edge, kind: kind, card: notice, store: store, fullScreen: false) {
                    Snapshotter.write(img, dir.appendingPathComponent(name))
                    done(true, name)
                } else { done(false, name) }
            }
        }
        if let img = placement(edge: .right, kind: .daily, card: notice, store: store, fullScreen: true) {
            Snapshotter.write(img, dir.appendingPathComponent("place-full-screen.png"))
            done(true, "place-full-screen")
        } else { done(false, "place-full-screen") }
        print("✓ \(count)장 → \(dir.path)")
        return failures == 0 ? 0 : 1
    }

    static let sampleNote = NewsNote(app: "1.1.1", date: "2026-10-10",
                                     body: NewsText(ko: "- 시험용 달라진 점 하나\n- 시험용 달라진 점 둘", en: "- Test change one\n- Test change two"))

    /// 메모리에만 있는 소식 (시험용 피드를 받아 둔 것으로)
    static func qaCenter(notes: [NewsNote], version: String, seen: [String]) -> NewsCenter {
        let c = NewsCenter()
        c.configure(.demo, notes: notes, appVersion: version, syncOn: { true }, storage: NewsMemoryStorage())
        c.now = { today }
        c.load(state: NewsState(lastSeenAppVersion: version, since: nil, seen: seen), cache: NewsCache(body: sampleFeed))
        return c
    }

    private static func fitting<V: View>(_ view: V) -> CGSize {
        let h = NSHostingView(rootView: view)
        return h.fittingSize
    }

    /// 종이 + 스프링 + 팔레트 + 카드를 실제 창과 같은 자리 계산으로 한 장에 (PaletteTest.scene 과 같은 방법)
    static func placement(edge: PaletteEdge, kind: PageKind, card: NewsCardContent, store: PlannerStore, fullScreen: Bool) -> CGImage? {
        let state = AppState(kind: kind, today: today)
        state.store = store
        let pageSize = kind == .daily ? CGSize(width: 560, height: 877) : CGSize(width: 1270, height: 811)
        guard let page = PageSnapshotter(store: store, state: state).image(kind: kind, index: state.index, size: pageSize, scale: 2)
        else { return nil }
        let pageRect = NSRect(origin: .zero, size: pageSize)
        let big = pageRect.insetBy(dx: -4000, dy: -4000)
        // 꽉 찬 화면: 종이 + 팔레트가 화면 전체
        let paletteSize = PaletteController.measure(edge, store: store, state: state, snapshot: true)
        let vis = fullScreen ? pageRect.insetBy(dx: -(paletteSize.width + 30), dy: -20) : big
        let placed = PalettePlacement.place(paletteSize, page: pageRect, visible: vis, preferred: edge, kind: kind)
        let model = PaletteModel(testEdge: edge, open: true)
        model.side = placed.side
        let cardSize = NSHostingView(rootView: NewsCardView(content: card, snapshot: true).padding(NewsCardPlacement.margin)).fittingSize
        let spot = NewsCardPlacement.place(cardSize, page: pageRect, palette: placed.frame, paletteSide: placed.side, kind: kind,
                                           visible: vis)
        let u = pageSize.width / kind.design.width
        let out = (RingWindowController.outside * u).rounded(.up)
        let ins = (RingWindowController.inside * u).rounded(.up)
        let ring = kind.edge == .leading
            ? NSRect(x: -out, y: 0, width: out + ins, height: pageSize.height)
            : NSRect(x: 0, y: pageSize.height - ins, width: pageSize.width, height: out + ins)
        let rings = RingModel()
        rings.kind = kind
        rings.u = u
        rings.outside = out
        var bounds = pageRect.union(placed.frame).union(ring).union(spot.frame).insetBy(dx: -28, dy: -28)
        if fullScreen { bounds = vis }
        func origin(_ r: NSRect) -> CGSize { CGSize(width: r.minX - bounds.minX, height: bounds.maxY - r.maxY) }
        let content = ZStack(alignment: .topLeading) {
            Color(white: fullScreen ? 0.3 : 0.85)
            Image(decorative: page, scale: 2)
                .resizable()
                .frame(width: pageSize.width, height: pageSize.height)
                .offset(origin(pageRect))
            RingStrip(model: rings)
                .frame(width: ring.width, height: ring.height)
                .offset(origin(ring))
            PaletteView(model: model)
                .frame(width: placed.frame.width, height: placed.frame.height)
                .offset(origin(placed.frame))
            NewsCardView(content: card, snapshot: true)
                .padding(NewsCardPlacement.margin)
                .frame(width: spot.frame.width, height: spot.frame.height)
                .offset(origin(spot.frame))
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .environment(\.isSnapshot, true)
        .environment(\.colorScheme, .light)
        .environmentObject(store)
        .environmentObject(state)
        let r = ImageRenderer(content: content)
        r.scale = 1
        return r.cgImage
    }

    /// 화면 밖 창에 그려 PNG 로 (Form 은 ImageRenderer 로 그려지지 않는다 — SyncQA 와 같은 방법)
    private static func capture<V: View>(_ view: V, size: CGSize, dark: Bool, background: Bool, to url: URL) async -> Bool {
        let root = view.frame(width: size.width, height: size.height)
            .background(background ? Color(nsColor: .windowBackgroundColor) : Color(white: dark ? 0.32 : 0.86))
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.setContentSize(size)
        w.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        defer { w.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url) } catch { return false }
        return true
    }
}
