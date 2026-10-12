import AppKit
import XCTest
@testable import SpiraldayKit
@testable import Spiralday

/// 팝오버 창처럼 클래스 이름에 Popover 가 든 창 (SwiftUI .popover 의 _NSPopoverWindow)
final class FakePopoverWindow: NSWindow {}

/// Mac 의 앱 안 소식 (Docs/InAppNews.md): ‘열 때’ · 카드 차례 · 처음 설치 · 받아 오기 실패 · 60분 규칙 · 설정 › 소식의 점 ·
/// 카드 자리 (종이 · 팔레트를 가리지 않음) · 바꿔 끼우기는 출시 서명 앱에서 안 됨. 메모리 저장소 · 가짜 받기 · 화면 밖 창으로만.
@MainActor
final class InAppNewsMacTests: XCTestCase {
    // MARK: 가짜

    final class FakeHost: NewsCardHost {
        var onboardingVisible = false
        var allowed = true
        var active = true
        var presented: [NewsCardContent] = []
        var appIsActive: Bool { active }
        func canPresentCard() -> Bool { allowed }
        func presentCard(_ content: NewsCardContent) { presented.append(content) }
    }

    final class FakeTransport: NewsTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [URLRequest] = []
        var result: NewsTransportResult
        var delay: TimeInterval = 0

        init(_ result: NewsTransportResult) { self.result = result }

        var calls: [URLRequest] { lock.withLock { _calls } }

        func get(_ request: URLRequest) async -> NewsTransportResult {
            lock.withLock { _calls.append(request) }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            return lock.withLock { result }
        }
    }

    static let important = """
    {"version":1,"items":[{"id":"2026-10-20-sync-check","date":"2026-10-20","kind":"notice","importance":"important",
     "title":{"ko":"25일 새벽, 동기화를 잠깐 쉬어요"},"body":{"ko":"**굵게** <b>글</b> 그대로"},
     "link":"https://spiralday.com/privacy.html","expires":"2026-10-25"},
     {"id":"2026-10-19-normal","date":"2026-10-19","kind":"update","importance":"normal","title":{"ko":"보통 소식"},"body":{"ko":"본문"}}]}
    """
    static let note = NewsNote(app: "1.2.0", date: "2026-10-16", body: NewsText(ko: "- 달라진 점", en: "- Changed"))
    static let today = Dates.parse("2026-10-20")!.addingTimeInterval(10 * 3600)

    private func center(state: NewsState = NewsState(), cache: Data? = nil, transport: FakeTransport? = nil,
                        launch: NewsLaunch = NewsLaunch(source: .network(NewsRules.Request.url), persists: false, opens: true),
                        host: FakeHost) -> (NewsCenter, NewsMemoryStorage) {
        let storage = NewsMemoryStorage(state: state, cache: cache.map { NewsCache(body: $0) })
        let c = NewsCenter()
        c.configure(launch, notes: [Self.note], appVersion: "1.2.0", syncOn: { false }, storage: storage, transport: transport)
        c.now = { Self.today }
        c.cardWait = 0.3
        c.launchSettle = 0
        c.host = host
        return (c, storage)
    }

    private static func ok(_ json: String) -> NewsTransportResult {
        .response(status: 200, headers: ["ETag": "\"e1\""], body: Data(json.utf8))
    }

    // MARK: 처음 설치 · 업데이트

    /// 새로 설치 (처음 안내): 카드 없이 이 버전 · 오늘 · 이번 노트를 적는다. 중요한 소식은 그다음 ‘열 때’ 한 번
    func testAFreshInstallShowsNoCardAndRemembersTheVersion() async {
        let host = FakeHost()
        host.onboardingVisible = true
        let t = FakeTransport(Self.ok(Self.important))
        let (c, storage) = center(transport: t, host: host)
        await c.start(firstRun: true, watch: false)?.value
        XCTAssertEqual(host.presented, [], "처음 안내 중에는 카드가 없다")
        XCTAssertEqual(storage.state, NewsState(lastSeenAppVersion: "1.2.0", since: "2026-10-20", seen: ["app-1.2.0"]))
        // 처음 안내를 마치고 다음 ‘열 때’: 아직 걸려 있는 중요한 소식이 한 번
        host.onboardingVisible = false
        storage.lastAttempt = nil
        await c.opened(launch: false)?.value
        XCTAssertEqual(host.presented.map(\.id), ["2026-10-20-sync-check"])
        XCTAssertEqual(host.presented.first?.body, "**굵게** <b>글</b> 그대로", "HTML · 마크다운을 풀지 않는다")
        XCTAssertEqual(host.presented.first?.link?.absoluteString, "https://spiralday.com/privacy.html")
        XCTAssertEqual(host.presented.first?.caption, "소식 · 10월 20일")
        await c.opened(launch: false)?.value
        XCTAssertEqual(host.presented.count, 1, "닫으면 다시 뜨지 않는다")
    }

    /// 업데이트 뒤 처음 열 때: 이번에 달라진 점 한 번 (오프라인이어도 — 앱에 넣은 노트)
    func testWhatsNewShowsOnceAfterAnUpdateEvenOffline() async {
        let host = FakeHost()
        let t = FakeTransport(.failed("no connection"))
        let (c, storage) = center(state: NewsState(lastSeenAppVersion: "1.1.1"), transport: t, host: host)
        await c.start(firstRun: false, watch: false)?.value
        XCTAssertEqual(host.presented.map(\.kind), [.whatsNew])
        XCTAssertEqual(host.presented.first?.title, "Spiralday 1.2.0")
        XCTAssertEqual(host.presented.first?.footnote, "설정 › 소식에서 다시 볼 수 있어요.")
        XCTAssertEqual(storage.state.lastSeenAppVersion, "1.2.0")
        XCTAssertNil(storage.cache, "실패는 캐시를 바꾸지 않는다")
        storage.lastAttempt = nil
        await c.opened(launch: false)?.value
        XCTAssertEqual(host.presented.count, 1)
    }

    /// 열 때 카드는 하나 (§5.1): 카드를 띄운 실행에서는 카드를 닫은 뒤에도 GitHub ⭐ 제안을 다음 실행으로 미룬다
    func testACardShownThisRunHoldsTheStarPromptUntilTheNextLaunch() async {
        let host = FakeHost()
        let (c, _) = center(state: NewsState(lastSeenAppVersion: "1.1.1"), transport: FakeTransport(.failed("x")), host: host)
        XCTAssertFalse(c.cardShownThisRun)
        XCTAssertNil(c.launchTurn)
        let turn = c.start(firstRun: false, watch: false)
        XCTAssertNotNil(c.launchTurn, "StarPrompt 는 켤 때의 카드 차례가 끝나기를 기다린다")
        await turn?.value
        XCTAssertEqual(host.presented.map(\.kind), [.whatsNew])
        XCTAssertTrue(c.cardShownThisRun, "카드를 닫은 뒤에도 이번 실행에서는 그대로")
        XCTAssertTrue(StarPrompt.yieldsToNews(cardShownThisRun: c.cardShownThisRun, cardShowing: false), "닫은 뒤에도 묻지 않는다")
        XCTAssertTrue(StarPrompt.yieldsToNews(cardShownThisRun: false, cardShowing: true))
        XCTAssertFalse(StarPrompt.yieldsToNews(cardShownThisRun: false, cardShowing: false))

        // 카드가 없던 실행 (볼 것이 없음 · 차례를 건너뜀) 은 그대로 물어도 된다
        let quiet = FakeHost()
        let (q, _) = center(state: NewsState(lastSeenAppVersion: "1.2.0", seen: ["app-1.2.0"]), transport: FakeTransport(.failed("x")),
                            host: quiet)
        await q.start(firstRun: false, watch: false)?.value
        XCTAssertEqual(quiet.presented, [])
        XCTAssertFalse(q.cardShownThisRun)
        let skipped = FakeHost()
        skipped.allowed = false
        let (s, _) = center(state: NewsState(lastSeenAppVersion: "1.1.1"), transport: FakeTransport(.failed("x")), host: skipped)
        await s.start(firstRun: false, watch: false)?.value
        XCTAssertFalse(s.cardShownThisRun)
    }

    /// 카드를 띄울 수 없는 차례 (다른 창 · 글 쓰는 중 …) 는 아무것도 적지 않고 다음 ‘열 때’ 다시
    func testASkippedTurnSavesNothing() async {
        let host = FakeHost()
        host.allowed = false
        let (c, storage) = center(state: NewsState(lastSeenAppVersion: "1.1.1"), transport: FakeTransport(.failed("x")), host: host)
        await c.start(firstRun: false, watch: false)?.value
        XCTAssertEqual(host.presented, [])
        XCTAssertEqual(storage.state, NewsState(lastSeenAppVersion: "1.1.1"))
        host.allowed = true
        storage.lastAttempt = nil
        await c.opened(launch: false)?.value
        XCTAssertEqual(host.presented.map(\.kind), [.whatsNew])
    }

    // MARK: 받아 오기

    /// 실패 · 304 는 받아 둔 것 그대로 — 목록은 캐시로 보인다
    func testAFailedFetchKeepsTheCache() async {
        let host = FakeHost()
        let cached = Data(Self.important.utf8)
        let t = FakeTransport(.response(status: 503, headers: [:], body: Data()))
        let (c, storage) = center(state: NewsState(lastSeenAppVersion: "1.2.0", seen: ["app-1.2.0", "2026-10-20-sync-check"]),
                                  cache: cached, transport: t, host: host)
        await c.start(firstRun: false, watch: false)?.value
        XCTAssertEqual(t.calls.count, 1)
        XCTAssertEqual(storage.cache?.body, cached)
        XCTAssertEqual(c.rows.map(\.id), ["2026-10-20-sync-check", "2026-10-19-normal", "app-1.2.0"])
        XCTAssertEqual(host.presented, [])
    }

    /// 마지막 시도 뒤 60분 안에는 받지 않는다 · 스위치를 끄면 받지 않는다 · 시계가 뒤로 가면 다시 받는다
    func testTriesAreSpacedAndTheSwitchStopsThem() async {
        let host = FakeHost()
        let t = FakeTransport(Self.ok(Self.important))
        var clock = Self.today
        let (c, storage) = center(state: NewsState(lastSeenAppVersion: "1.2.0"), transport: t, host: host)
        c.now = { clock }
        await c.start(firstRun: false, watch: false)?.value
        XCTAssertEqual(t.calls.count, 1)
        XCTAssertEqual(storage.cache?.etag, "\"e1\"")
        clock = Self.today.addingTimeInterval(59 * 60)
        await c.opened(launch: false)?.value
        XCTAssertEqual(t.calls.count, 1, "59분 뒤")
        clock = Self.today.addingTimeInterval(61 * 60)
        await c.opened(launch: false)?.value
        XCTAssertEqual(t.calls.count, 2, "61분 뒤")
        XCTAssertEqual(t.calls.last?.value(forHTTPHeaderField: "If-None-Match"), "\"e1\"", "받아 둔 것이 있으면 조건부로")
        c.setFetchEnabled(false)
        clock = Self.today.addingTimeInterval(5 * 3600)
        await c.opened(launch: false)?.value
        XCTAssertEqual(t.calls.count, 2, "스위치를 끄면 받지 않는다")
        XCTAssertFalse(storage.fetchEnabled)
        c.setFetchEnabled(true)
        await c.opened(launch: false)?.value
        XCTAssertEqual(t.calls.count, 3)
        clock = Self.today.addingTimeInterval(-3 * 3600)
        await c.opened(launch: false)?.value
        XCTAssertEqual(t.calls.count, 4, "앞날의 기록(시계를 되돌림)은 지난 것으로")
    }

    /// 받기가 늦어도 카드 차례는 기다리지 않는다 (그때의 캐시로) — 받은 것은 목록에만, 카드는 다음 ‘열 때’
    func testTheCardTurnDoesNotWaitForASlowFetch() async throws {
        let host = FakeHost()
        let t = FakeTransport(Self.ok(Self.important))
        t.delay = 1.0
        let (c, storage) = center(state: NewsState(lastSeenAppVersion: "1.2.0", seen: ["app-1.2.0"]), transport: t, host: host)
        let started = Date()
        await c.start(firstRun: false, watch: false)?.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9, "cardWait(0.3초) 뒤에 차례")
        XCTAssertEqual(host.presented, [], "아직 받지 못했다")
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertNotNil(storage.cache, "받기는 끝까지 가서 캐시를 바꾼다")
        XCTAssertTrue(c.dot, "목록 · 점만 바뀐다")
        XCTAssertEqual(host.presented, [])
        storage.lastAttempt = nil
        t.delay = 0
        await c.opened(launch: false)?.value
        XCTAssertEqual(host.presented.map(\.id), ["2026-10-20-sync-check"])
    }

    /// 60분 넘게 뒤에 있다가 돌아오면 ‘열 때’ (그보다 짧으면 아님)
    func testComingBackAfterAnHourIsAnOpen() async {
        let host = FakeHost()
        var clock = Self.today
        let (c, _) = center(state: NewsState(lastSeenAppVersion: "1.1.1"), transport: FakeTransport(.failed("x")), host: host)
        c.now = { clock }
        c.wentAway()
        clock = Self.today.addingTimeInterval(30 * 60)
        XCTAssertNil(c.cameBack())
        c.wentAway()
        clock = clock.addingTimeInterval(61 * 60)
        await c.cameBack()?.value
        XCTAssertEqual(host.presented.map(\.kind), [.whatsNew])
    }

    /// 뒤에서 켜진 앱 (로그인 항목 · open -g): 켤 때의 카드 차례는 앞에 있지 않아 건너뛰고 아무것도 적지 않는다.
    /// 한 번도 앞에 온 적이 없어 ‘뒤로 간 때’가 비어 있어도, 처음 앞으로 올 때가 ‘열 때’다 (얼마 만이든)
    func testABackgroundLaunchOpensWhenTheAppFirstComesForward() async {
        for minutes in [61.0, 2.0] {
            let host = FakeHost()
            host.active = false
            var clock = Self.today
            let (c, storage) = center(state: NewsState(lastSeenAppVersion: "1.1.1"), transport: FakeTransport(.failed("x")), host: host)
            c.now = { clock }
            await c.start(firstRun: false, watch: false)?.value
            XCTAssertEqual(host.presented, [], "\(minutes)분: 앞에 있지 않으면 카드가 없다")
            XCTAssertEqual(storage.state, NewsState(lastSeenAppVersion: "1.1.1"), "\(minutes)분: 아무것도 적지 않는다")
            XCTAssertTrue(c.openWhenActive)
            clock = Self.today.addingTimeInterval(minutes * 60)
            host.active = true
            await c.cameBack()?.value
            XCTAssertEqual(host.presented.map(\.kind), [.whatsNew], "\(minutes)분 뒤 처음 앞으로: 이번에 달라진 점")
            XCTAssertFalse(c.openWhenActive)
            // 그 뒤로는 다시 60분 규칙
            c.wentAway()
            clock = clock.addingTimeInterval(5 * 60)
            XCTAssertNil(c.cameBack())
        }
    }

    /// 이번에 달라진 점 카드의 제목은 앱 버전 (§1.1): 노트를 ‘1.2’ 로 적어도 앱 1.2.0 이면 ‘Spiralday 1.2.0’ — Windows · Android 와 같다.
    /// 목록의 줄 제목은 노트에 적힌 그대로 (§3)
    func testTheWhatsNewTitleIsTheAppVersion() async {
        let host = FakeHost()
        let storage = NewsMemoryStorage(state: NewsState(lastSeenAppVersion: "1.1.1"))
        let c = NewsCenter()
        c.configure(NewsLaunch(source: .none, persists: false, opens: true),
                    notes: [NewsNote(app: "1.2", date: "2026-10-16", body: NewsText(ko: "- 달라진 점", en: "- Changed"))],
                    appVersion: "1.2.0", syncOn: { false }, storage: storage)
        c.now = { Self.today }
        c.cardWait = 0.3
        c.launchSettle = 0
        c.host = host
        await c.start(firstRun: false, watch: false)?.value
        XCTAssertEqual(host.presented.map(\.title), ["Spiralday 1.2.0"])
        XCTAssertEqual(host.presented.first?.id, "app-1.2")
        XCTAssertEqual(c.rows.map(\.title), ["1.2 에서 달라진 점"])
    }

    /// 데모: 받지 않고 카드도 없다 (목록은 노트로)
    func testTheDemoNeitherFetchesNorShowsCards() async {
        let host = FakeHost()
        let t = FakeTransport(Self.ok(Self.important))
        let (c, _) = center(state: NewsState(lastSeenAppVersion: "1.1.1"), transport: t, launch: .demo, host: host)
        XCTAssertNil(c.start(firstRun: false, watch: false))
        XCTAssertNil(c.fetchIfDue())
        XCTAssertEqual(t.calls.count, 0)
        XCTAssertEqual(host.presented, [])
        XCTAssertEqual(c.rows.map(\.id), ["app-1.2.0"])
    }

    // MARK: 설정 › 소식

    /// 목록을 열면: 이번에 보이는 점은 그대로, ‘소식’ 항목의 점은 바로 사라지고, 다음에 열면 줄의 점도 없다
    func testOpeningTheListClearsTheDotButKeepsWhatWasNew() {
        let host = FakeHost()
        let (c, storage) = center(state: NewsState(lastSeenAppVersion: "1.2.0", seen: []), cache: Data(Self.important.utf8), host: host)
        XCTAssertTrue(c.dot)
        c.paneShown()
        XCTAssertFalse(c.dot)
        XCTAssertEqual(c.paneUnseen, ["2026-10-20-sync-check", "2026-10-19-normal", "app-1.2.0"])
        XCTAssertEqual(Set(storage.state.seen), ["2026-10-20-sync-check", "2026-10-19-normal", "app-1.2.0"])
        c.paneShown()
        XCTAssertEqual(c.paneUnseen.count, 3, "다시 불러도 같다")
        c.paneHidden()
        c.paneShown()
        XCTAssertEqual(c.paneUnseen, [], "다음에 열면 점이 없다")
    }

    /// 설정 › 소식의 날짜 칸: 작년의 두 자리 월 · 일(‘2025년 12월 31일’)도 한 줄에 — 펼친 본문은 날짜 · 종류 칸 다음에서 시작
    func testTheDateColumnFitsTheLongestDate() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        for d in ["2025-12-31", "2025-11-28", "2026-10-20"] {
            let s = NewsRules.displayDate(d, today: "2026-10-21", lang: "ko")
            let w = NSAttributedString(string: s, attributes: [.font: font]).size().width
            XCTAssertLessThanOrEqual(w, NewsRowView.dateWidth, "\(s) (\(w)pt)")
        }
        XCTAssertGreaterThan(NewsRowView.dateWidth, 92, "예전 92pt 로는 ‘2025년 12월 31일’이 꺾였다")
        XCTAssertEqual(NewsRowView.bodyIndent, NewsRowView.dateWidth + NewsRowView.columnSpacing + NewsRowView.kindWidth)
    }

    /// 설정 › 소식의 말: 모든 플랫폼이 같은 문장 (Kit NewsCopy — Windows · Android 의 NEWS_COPY 와 같게)
    func testTheNewsPaneWordsAreTheSharedOnes() {
        XCTAssertEqual(NewsCopy.unseen("ko"), "새 소식")
        XCTAssertFalse(NewsCopy.paneNote("ko").contains("종이"), "Mac 에만 맞는 말(종이 옆)은 쓰지 않는다")
        XCTAssertTrue(NewsCopy.paneNote("ko").contains("달라진 점"), "업데이트 뒤의 달라진 점도 카드로 뜬다")
        XCTAssertTrue(NewsCopy.fetchOnDetail("ko").contains("하루 한 번"), "켜 둔 동안 하루 한 번 받는다는 것도")
    }

    /// 설정 › 소식의 이름 · 부제 · 아이콘과 도움말 메뉴는 Kit NewsCopy 의 것 (공유 벡터 copy · icon 과 같다 — InAppNewsTests 가 본다)
    func testTheNewsPaneUsesTheSharedCopyAndIcon() {
        XCTAssertEqual(SettingsPane.news.title, "소식")
        XCTAssertEqual(SettingsPane.news.title, NewsCopy.paneTitle("ko"))
        XCTAssertEqual(SettingsPane.news.subtitle, NewsCopy.paneSubtitle("ko"))
        XCTAssertEqual(SettingsPane.news.symbol, "newspaper.fill")
        XCTAssertEqual(SettingsPane.news.tint.hexString, "C2783A")
        XCTAssertEqual(NewsCopy.menu("ko"), "소식\u{2026}")
    }

    // MARK: 바꿔 끼우기

    func testOverridesAreOnlyForBuildsWithoutTheReleaseSignature() {
        let env = ["SPIRALDAY_NEWS_URL": "http://127.0.0.1:8765/news.json"]
        XCTAssertEqual(NewsLaunch.decide(args: [], environment: env, demo: false, releaseSigned: true), .live, "출시 앱은 보지 않는다")
        XCTAssertEqual(NewsLaunch.decide(args: ["--demo"], environment: env, demo: true, releaseSigned: true), .demo)
        let o = NewsLaunch.decide(args: ["--demo"], environment: env, demo: true, releaseSigned: false)
        XCTAssertEqual(o, NewsLaunch(source: .network(URL(string: "http://127.0.0.1:8765/news.json")!), persists: false, opens: true),
                       "바꿔 끼운 실행은 메모리에만")
        XCTAssertEqual(NewsLaunch.decide(args: ["--news-feed", "/tmp/f.json"], environment: env, demo: false, releaseSigned: false).source,
                       .file(URL(fileURLWithPath: "/tmp/f.json")), "--news-feed 가 먼저")
        XCTAssertEqual(NewsLaunch.decide(args: [], environment: ["SPIRALDAY_NEWS_URL": "javascript:alert(1)"], demo: false,
                                         releaseSigned: false), .live)
        XCTAssertEqual(NewsLaunch.decide(args: [], environment: [:], demo: true, releaseSigned: false), .demo)
        XCTAssertEqual(NewsLaunch.live.source, .network(URL(string: "https://spiralday.com/news/news.json")!))
        XCTAssertTrue(NewsLaunch.live.persists)
    }

    /// build.sh 가 노트를 .app 에 넣는다
    func testTheBuildBundlesTheNotes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains(#"cp Docs/release-notes/whats-new.json "$APP/Contents/Resources/whats-new.json""#))
        // .app 이 아닌 실행(시험)에는 노트가 없다 — 그래도 멈추지 않는다
        XCTAssertEqual(NewsCenter.bundledNotes(Bundle(for: Self.self)), [])
    }

    // MARK: 카드 자리

    private let screen = NSRect(x: 0, y: 70, width: 1728, height: 1012)

    func testTheCardSitsBesideThePaperAndNeverOnThePalette() {
        let card = CGSize(width: NewsCardPlacement.width, height: 190)
        for kind in [PageKind.daily, .weekly] {
            let page = kind == .daily ? NSRect(x: 620, y: 150, width: 520, height: 815) : NSRect(x: 330, y: 300, width: 1000, height: 640)
            for edge in PaletteEdge.allCases {
                let pal = PalettePlacement.place(edge.isVertical ? CGSize(width: 104, height: 760) : CGSize(width: 760, height: 104),
                                                 page: page, visible: screen, preferred: edge, kind: kind)
                let r = NewsCardPlacement.place(card, page: page, palette: pal.frame, paletteSide: pal.side, kind: kind, visible: screen)
                XCTAssertNotEqual(r.spot, .overPaper, "\(kind) \(edge)")
                XCTAssertTrue(r.frame.intersection(page).isEmpty, "\(kind) \(edge): 종이를 가리지 않는다 \(r.frame)")
                XCTAssertFalse(r.frame.intersects(pal.frame), "\(kind) \(edge): 팔레트를 가리지 않는다")
                XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(r.frame), "\(kind) \(edge): 화면 안")
                // 스프링이 튀어나온 쪽이면 스프링도 가리지 않는다
                if case .side(let s) = r.spot, s == PaletteEdge.ringSide(kind) {
                    let ring = PalettePlacement.ringClearance(s, kind: kind, pageWidth: page.width)
                    XCTAssertTrue(r.frame.intersection(page.insetBy(dx: -ring, dy: -ring)).isEmpty, "\(kind) \(edge): 스프링")
                }
            }
        }
        // 팔레트가 오른쪽이면 먼저 반대쪽(왼쪽)
        XCTAssertEqual(NewsCardPlacement.order(.right).first, .left)
        XCTAssertEqual(NewsCardPlacement.order(.right).last, .right)
    }

    /// 창이 화면을 꽉 채우면 (자리가 없으면) 종이 아래 가운데에 — 화면 안
    func testWithNoRoomTheCardGoesToThePaperBottom() {
        let card = CGSize(width: NewsCardPlacement.width, height: 190)
        let vis = NSRect(x: 0, y: 0, width: 1024, height: 640)
        let page = NSRect(x: 40, y: 8, width: 860, height: 624)
        let r = NewsCardPlacement.place(card, page: page, palette: NSRect(x: 914, y: 40, width: 104, height: 560), paletteSide: .right,
                                        kind: .weekly, visible: vis)
        XCTAssertEqual(r.spot, .overPaper)
        XCTAssertTrue(vis.contains(r.frame))
        XCTAssertEqual(r.frame.midX, page.midX, accuracy: 1)
    }

    // MARK: 카드 창

    /// 화면 밖의 창 (시험이 화면에 창을 띄우거나 쓰던 앱의 키를 빼앗지 않게). 제목 막대가 있어도 화면 안으로 끌려오지 않는다
    final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// 화면 밖 플래너 창과 그 둘레의 가짜 화면 (카드 자리를 잡는 곳)
    private func offscreenPlanner() -> (NSWindow, NSRect) {
        let planner = OffscreenWindow(contentRect: NSRect(x: -12_000, y: 200, width: 400, height: 500), styleMask: [.titled],
                                      backing: .buffered, defer: false)
        planner.isReleasedWhenClosed = false
        planner.orderFrontRegardless()
        return (planner, planner.frame.insetBy(dx: -600, dy: -200))
    }

    private static let card = NewsCardContent(kind: .notice, id: "n", caption: "소식 · 10월 20일", title: "제목", body: "본문",
                                              link: URL(string: "https://spiralday.com/"), footnote: nil)

    /// 진짜 카드 창: 플래너 창의 child · 종이 옆 · VoiceOver 이름 · Esc 로 닫힘. 화면 밖 창 · 열쇠 창이 되지 않게 (시험만)
    func testTheCardPanelOpensBesideThePlannerAndClosesWithEscape() async throws {
        let (planner, vis) = offscreenPlanner()
        defer { planner.orderOut(nil) }
        let state = AppState(kind: .daily)
        let cards = NewsCardController()
        cards.takesKey = false
        cards.visibleFrameOverride = vis
        cards.attach(planner: planner, state: state, sync: nil)
        cards.presentCard(Self.card)
        let panel = try XCTUnwrap(cards.panelForTests)
        defer { panel.orderOut(nil) }
        XCTAssertTrue(cards.isShowing)
        XCTAssertTrue(panel.parent === planner)
        XCTAssertFalse(panel.isKeyWindow, "시험에서는 열쇠 창이 되지 않는다")
        XCTAssertEqual(panel.accessibilityLabel(), "소식")
        XCTAssertEqual(panel.frame.width, NewsCardPlacement.width + 2 * NewsCardPlacement.margin, "카드 크기를 잰다 (0 × 0 이 아니다)")
        XCTAssertGreaterThan(panel.frame.height, 120)
        XCTAssertTrue(panel.frame.intersection(planner.frame).isEmpty, "자리가 있으면 종이를 가리지 않는다 \(panel.frame)")
        XCTAssertTrue(vis.contains(panel.frame), "화면 안")
        panel.cancelOperation(nil)
        XCTAssertFalse(cards.isShowing, "Esc 로 바로 닫힌 것으로")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(planner.childWindows?.first { $0 is NewsCardPanel }, "살짝 사라진 뒤 창에서 떨어진다")
        XCTAssertFalse(panel.isVisible)
    }

    /// 카드가 열쇠 창일 때 플래너 단축키(← → · T W D H · 1–7 …): 카드의 키도 플래너 단축키로 보고, 처리하면 카드를 닫는다.
    /// Return · Esc · Tab · 스페이스는 카드 몫 (플래너 창에서 온 단축키는 카드를 닫지 않는다)
    func testAPlannerShortcutTypedOnTheCardWorksAndClosesIt() throws {
        let (planner, vis) = offscreenPlanner()
        defer { planner.orderOut(nil) }
        let store = PlannerStore(inMemory: true)
        let state = AppState(kind: .daily)
        state.store = store
        state.plannerWindow = planner
        state.isPlannerPanel = MainWindowController.isPlannerPanel
        let cards = NewsCardController()
        cards.takesKey = false
        cards.visibleFrameOverride = vis
        cards.attach(planner: planner, state: state, sync: nil)
        cards.presentCard(Self.card)
        let panel = try XCTUnwrap(cards.panelForTests)
        defer { panel.orderOut(nil) }
        XCTAssertEqual(state.inputWindow(panel), .plannerPanel, "카드는 플래너에 딸린 패널")
        func key(_ code: UInt16, _ chars: String, in w: NSWindow) -> Bool {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            return state.handleKey(e)
        }
        // 카드 몫의 키: 플래너가 먹지 않고 카드도 그대로
        XCTAssertFalse(key(36, "\r", in: panel), "Return")
        XCTAssertFalse(key(48, "\t", in: panel), "Tab")
        XCTAssertFalse(key(49, " ", in: panel), "스페이스")
        XCTAssertFalse(key(53, "\u{1b}", in: panel), "Esc 는 카드로 (cancelOperation)")
        XCTAssertTrue(cards.isShowing)
        // 플래너 창에서 누른 단축키는 카드를 닫지 않는다
        let pen = store.categories[1].id
        XCTAssertTrue(key(19, "2", in: planner))
        XCTAssertTrue(cards.isShowing)
        state.pickTool(AppState.eraser)
        // 카드에서 누른 단축키: 플래너가 처리하고 카드는 닫힌다
        XCTAssertTrue(key(19, "2", in: panel), "카드가 열쇠 창이어도 1–7 펜")
        XCTAssertEqual(state.tool, pen)
        XCTAssertFalse(cards.isShowing, "단축키를 누르면 카드는 닫힌다")
    }

    /// §5.1 의 조건: 플래너가 앞에 · 다른 창 없음 · 글 쓰는 중 아님 · 둘러보기 · 동기화 연결 · 메뉴 · 팝오버 아님
    func testCardsWaitWhileTheUserIsBusy() {
        let (planner, _) = offscreenPlanner()
        defer { planner.orderOut(nil) }
        let state = AppState(kind: .daily)
        func may(key: NSWindow? = planner, windows: [NSWindow] = [], tour: Bool = false, sync: Bool = false, tracking: Bool = false) -> Bool {
            NewsCardController.mayPresent(planner: planner, windows: [planner] + windows, keyWindow: key, state: state,
                                          tourRunning: tour, syncFlow: sync, tracking: tracking)
        }
        XCTAssertTrue(may())
        XCTAssertFalse(may(key: nil), "다른 앱 · 다른 창이 앞에")
        XCTAssertFalse(may(tour: true), "둘러보기")
        XCTAssertFalse(may(sync: true), "동기화 연결")
        XCTAssertFalse(may(tracking: true), "메뉴 · 칠하는 중")
        state.editingKey = "comment"
        XCTAssertFalse(may(), "글을 쓰는 중")
        state.editingKey = nil
        let settings = OffscreenWindow(contentRect: NSRect(x: -11_000, y: 200, width: 300, height: 300), styleMask: [.titled],
                                       backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        defer { settings.orderOut(nil) }
        settings.orderFrontRegardless()
        XCTAssertFalse(may(windows: [settings]), "설정 · PDF 같은 다른 창")
        settings.orderOut(nil)
        XCTAssertTrue(may(windows: [settings]))
        // 팝오버 (D-day 등): 띄운 플래너 창의 자식 창이어도 막는다
        let popover = FakePopoverWindow(contentRect: NSRect(x: -11_800, y: 300, width: 200, height: 120), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        popover.isReleasedWhenClosed = false
        defer { popover.orderOut(nil) }
        planner.addChildWindow(popover, ordered: .above)
        defer { planner.removeChildWindow(popover) }
        popover.orderFrontRegardless()
        XCTAssertTrue(popover.parent === planner)
        XCTAssertTrue(popover.className.contains("Popover"))
        XCTAssertFalse(may(windows: [popover]), "플래너 자식 팝오버")
        popover.orderOut(nil)
        XCTAssertTrue(may(windows: [popover]))
    }
}
