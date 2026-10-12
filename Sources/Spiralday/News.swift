import AppKit
import Combine
import SwiftUI
import SpiraldayKit

// ─────────────────────────────────────────────────────────────────────────────
// 앱 안 ‘소식’ (Docs/InAppNews.md) — 사장님 결정 2026-10-11: 계정 · 푸시 없이.
//   · ‘열 때’(§5.1): 앱을 켤 때, 60분 넘게 다른 앱을 쓰다(또는 잠자다) 돌아왔을 때. 받아 오기를 시작하고 끝나거나 5초가 지나면
//     카드 차례 — 그때의 캐시로 고른다 (규칙은 SpiraldayKit NewsRules · 받기는 NewsFetcher).
//     뒤에서 켜진 앱(로그인 항목 · open -g)처럼 카드 차례에 앱이 앞에 있지 않았으면, 처음 앞으로 올 때를 ‘열 때’로 친다
//   · 카드: 종이 위가 아니라 종이 옆 여백의 작은 카드 (NewsCardController). 띄우는 순간 본 것으로 적는다 — 어떻게 닫아도 다시 뜨지 않는다
//   · 설정 › 소식: 목록과 ‘소식’ 항목의 작은 점 (종이 · 팔레트 · 설정 단추 · Dock 아이콘에는 아무것도 없다)
//   · 받기: https://spiralday.com/news/news.json 에 GET 하나 (설치 번호 · 기기 정보 · 쿼리 문자열 · 쿠키 없음), 마지막 시도 뒤
//     60분 안에는 건너뛰고, 켜 둔 동안은 24시간마다. 실패는 조용히 지나간다. 설정 › 소식의 스위치로 끈다
//   · 데모 · 스냅샷 · 시험 실행은 받지 않고 상태도 메모리에만. 디버그 빌드 · 출시 서명이 없는 빌드만 로컬 피드로 바꿔 끼울 수 있다
//     (`--news-feed <파일>` 또는 SPIRALDAY_NEWS_URL — NewsLaunch)
// ─────────────────────────────────────────────────────────────────────────────

/// 피드를 어디서 받는지
enum NewsSource: Equatable {
    /// 받지 않는다 (데모 · 스냅샷)
    case none
    case network(URL)
    /// 로컬 파일 (디버그 · QA 의 `--news-feed`)
    case file(URL)
}

/// 이 실행에서 소식을 어떻게 쓰는지 (App 이 켤 때 정한다)
struct NewsLaunch: Equatable {
    var source: NewsSource
    /// 기기에 남기는지 (아니면 메모리에만 — 데모 · QA)
    var persists: Bool
    /// ‘열 때’를 돌리는지 (카드를 띄울 수 있는지)
    var opens: Bool

    static let demo = NewsLaunch(source: .none, persists: false, opens: false)
    static let live = NewsLaunch(source: .network(NewsRules.Request.url), persists: true, opens: true)

    /// 로컬 피드로 바꿔 끼우는 환경 변수 (디버그 · 출시 서명이 없는 빌드만)
    static let overrideKey = "SPIRALDAY_NEWS_URL"
    static let feedFlag = "--news-feed"

    /// 실행 인자 · 환경 변수 · 빌드로 정한다. releaseSigned: 출시 서명(Developer ID · 팀 SCQ7JJP5MN)이 확실한지 —
    /// 그런 앱은 바꿔 끼우기를 아예 보지 않는다 (출시 빌드에는 주소를 바꾸는 길이 없다, §4)
    static func decide(args: [String], environment: [String: String], demo: Bool, releaseSigned: Bool) -> NewsLaunch {
        if !releaseSigned, let o = override(args: args, environment: environment) {
            // 바꿔 끼운 실행은 메모리에만 (이 Mac 의 소식 상태 · 캐시를 건드리지 않는다)
            return NewsLaunch(source: o, persists: false, opens: true)
        }
        return demo ? .demo : .live
    }

    /// `--news-feed <파일>` (먼저) 또는 SPIRALDAY_NEWS_URL (http · https 주소, 또는 file 경로). 알아볼 수 없으면 nil
    static func override(args: [String], environment: [String: String]) -> NewsSource? {
        if let i = args.firstIndex(of: feedFlag), i + 1 < args.count, !args[i + 1].isEmpty {
            return .file(URL(fileURLWithPath: args[i + 1]))
        }
        let raw = environment[overrideKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" { return .file(url) }
        guard scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return .network(url)
    }
}

/// 카드를 띄우는 쪽 (Mac 은 NewsCardController — 시험은 가짜로)
@MainActor
protocol NewsCardHost: AnyObject {
    /// 처음 안내 창이 떠 있는지
    var onboardingVisible: Bool { get }
    /// 앱이 앞에 있는지 (아니면 카드 차례를 건너뛰고, 앱이 앞으로 올 때 다시 — NewsCenter.cameBack)
    var appIsActive: Bool { get }
    /// 지금 카드를 띄워도 되는지 (§5.1: 플래너가 앞에 있고, 다른 창 · 시트 · 메뉴 · 둘러보기 · 동기화 연결이 없고, 글을 쓰는 중이 아님)
    func canPresentCard() -> Bool
    func presentCard(_ content: NewsCardContent)
}

/// 카드에 그릴 것 (글은 모두 글 그대로 — Text(verbatim:))
struct NewsCardContent: Equatable {
    enum Kind: Equatable { case notice, whatsNew }

    let kind: Kind
    let id: String
    /// 위 작은 글자 (‘소식 · 10월 20일’ · ‘이번에 달라진 점’)
    let caption: String
    let title: String
    let body: String
    /// 허용 목록을 지난 링크 (자세히 보기)
    let link: URL?
    /// 아래 작은 글자 (이번에 달라진 점: ‘설정 › 소식에서 다시 볼 수 있어요.’)
    let footnote: String?
}

@MainActor
final class NewsCenter: ObservableObject {
    static let shared = NewsCenter()

    /// 설정 › 소식의 줄 (점은 paneUnseen 으로)
    @Published private(set) var rows: [NewsRow] = []
    /// 설정 창 옆 목록의 ‘소식’ 항목의 점
    @Published private(set) var dot = false
    /// ‘spiralday.com 에서 소식 받기’
    @Published private(set) var fetchEnabled = true
    /// 목록을 연 동안 점을 그대로 보이는 줄 (무엇이 새것인지 보이게 — 저장은 이미 본 것으로)
    @Published private(set) var paneUnseen: Set<String> = []

    let platform = "mac"
    /// Mac 은 지금 화면이 한국어뿐이라 늘 ko (§5)
    let lang = "ko"
    private(set) var launch = NewsLaunch.demo
    private(set) var storage: NewsStorage = NewsMemoryStorage()
    private var transport: NewsTransport?
    private(set) var items: [NewsItem] = []
    private(set) var notes: [NewsNote] = []
    var appVersion = ""
    var syncOn: () -> Bool = { false }
    var now: () -> Date = { Date() }
    weak var host: NewsCardHost?
    /// 카드 차례가 받아 오기를 기다리는 최대 시간 (§5.6 — 5초)
    var cardWait: TimeInterval = NewsRules.Request.timeoutSeconds
    /// 켤 때 창이 자리 잡도록 카드 차례 전에 기다리는 시간
    var launchSettle: TimeInterval = 1.5

    /// 이번 실행을 처음 안내로 시작했는지 (새로 설치) — 첫 카드 차례는 open(firstRun: true) 의 저장만
    private var firstRunLaunch = false
    private var firstRunSaved = false
    private var fetchTask: Task<Void, Never>?
    private var paneOpen = false
    private var awaySince: Date?
    /// 카드 차례에 앱이 앞에 있지 않아 건너뛰었다 (뒤에서 켜짐 · 켜자마자 다른 앱으로) — 앱이 앞으로 오면 바로 ‘열 때’
    private(set) var openWhenActive = false
    /// 이번 실행에서 카드를 띄웠다 (§5.1 열 때 카드는 하나 — 카드를 닫은 뒤에도 GitHub ⭐ 제안은 다음 실행으로)
    private(set) var cardShownThisRun = false
    /// 켤 때의 ‘열 때’ (받아 오기를 5초까지 기다린 뒤의 카드 차례) — GitHub ⭐ 제안은 이것이 끝난 뒤에 정한다
    private(set) var launchTurn: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?

    init() {}

    // MARK: 켤 때

    /// App 이 켤 때 한 번 (창을 열기 전). notes: 앱에 넣은 whats-new.json
    func configure(_ launch: NewsLaunch, notes: [NewsNote], appVersion: String, syncOn: @escaping () -> Bool,
                   storage: NewsStorage? = nil, transport: NewsTransport? = nil) {
        self.launch = launch
        self.notes = notes
        self.appVersion = appVersion
        self.syncOn = syncOn
        self.storage = storage ?? (launch.persists
            ? NewsDefaultsStorage(defaults: .standard, cacheFolder: NewsDefaultsStorage.defaultCacheFolder())
            : NewsMemoryStorage())
        if case .network = launch.source { self.transport = transport ?? NewsURLSessionTransport() } else { self.transport = transport }
        fetchEnabled = self.storage.fetchEnabled
        reloadItems()
        refreshList()
    }

    /// 앱을 켜고 본 창(또는 처음 안내)을 연 뒤. firstRun: 처음 안내를 띄웠다 (새로 설치)
    @discardableResult
    func start(firstRun: Bool, watch: Bool = true) -> Task<Void, Never>? {
        firstRunLaunch = firstRun
        guard launch.opens else { return nil }
        if watch { watchActivity() }
        launchTurn = opened(launch: true)
        return launchTurn
    }

    /// 앱에 넣은 노트 (Contents/Resources/whats-new.json — build.sh 가 Docs/release-notes/whats-new.json 을 넣는다)
    static func bundledNotes(_ bundle: Bundle = .main) -> [NewsNote] {
        guard let url = bundle.url(forResource: "whats-new", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [] }
        return NewsRules.parseBundled(data)
    }

    static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    // MARK: ‘열 때’ (§5.1)

    private func watchActivity() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentAway() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.cameBack() }
        })
        // 앱을 앞에 둔 채 Mac 이 잠들었다 깬 것도 ‘뒤에 있었던’ 것으로 친다
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentAway() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if NSApp.isActive { _ = self?.cameBack() } }
        })
        // 켜 둔 동안: 한 시간마다 마지막 시도가 24시간 넘었는지 본다 (목록 · 점만 바뀌고 카드는 다음 ‘열 때’)
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWhileOpen() }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func wentAway() {
        if awaySince == nil { awaySince = now() }
    }

    @discardableResult
    func cameBack() -> Task<Void, Never>? {
        let since = awaySince
        awaySince = nil
        // 앞에 없어 건너뛴 카드 차례가 있으면 (뒤에서 켜진 앱이 처음 앞으로 옴) 얼마 만이든 ‘열 때’
        if openWhenActive {
            openWhenActive = false
            return opened(launch: false)
        }
        guard let since, now().timeIntervalSince(since) > TimeInterval(NewsRules.Request.openAfterAwayMinutes * 60) else { return nil }
        return opened(launch: false)
    }

    /// 한 번 ‘열 때’: ① 받아 오기를 시작 ② 끝나거나 5초가 지나면 ③ 카드 차례 (켤 때는 창이 자리 잡도록 1.5초는 기다린다)
    @discardableResult
    func opened(launch isLaunch: Bool) -> Task<Void, Never>? {
        guard launch.opens else { return nil }
        let started = Date()
        let task = fetchIfDue()
        return Task { @MainActor in
            if let task { await Self.wait(for: task, seconds: self.cardWait) }
            if isLaunch {
                let left = self.launchSettle - Date().timeIntervalSince(started)
                if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            }
            self.cardTurn()
        }
    }

    /// 받아 오기를 seconds 초까지만 기다린다 (받아 오기는 그 뒤에도 끝까지 가서 목록을 바꾼다).
    /// 작업 묶음(TaskGroup)은 끝나지 않은 자식(받기)을 기다리므로 쓰지 않고, 먼저 끝난 쪽이 한 번만 깨운다
    private static func wait(for task: Task<Void, Never>, seconds: TimeInterval) async {
        final class Once { var done = false }
        let once = Once()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await task.value
                if !once.done { once.done = true; c.resume() }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if !once.done { once.done = true; c.resume() }
            }
        }
    }

    /// 카드 차례 (§5.1 · §5.4)
    func cardTurn() {
        guard launch.opens else { return }
        reloadItems()
        let onboarding = host?.onboardingVisible ?? false
        // 처음 안내를 띄우는 중이면 (새로 설치) 저장만 하고 카드는 없다 — 다시 보는 처음 안내는 ‘다른 창’으로 친다
        if firstRunLaunch && (onboarding || !firstRunSaved) {
            storage.state = NewsRules.open(env: env(firstRun: true), state: storage.state, items: items, notes: notes).save
            firstRunSaved = true
            refreshList()
            return
        }
        guard !onboarding, let host else { return }
        // 앱이 앞에 있지 않다 (뒤에서 켜짐 등): 아무것도 적지 않고, 앞으로 올 때 다시
        guard host.appIsActive else { openWhenActive = true; return }
        guard host.canPresentCard() else { return }
        openWhenActive = false
        let r = NewsRules.open(env: env(firstRun: false), state: storage.state, items: items, notes: notes)
        storage.state = r.save
        refreshList()
        if let card = r.card, let content = content(card) {
            cardShownThisRun = true
            host.presentCard(content)
        }
    }

    /// 켜 둔 동안 24시간마다 (카드 없이)
    func refreshWhileOpen() {
        guard launch.opens, storage.fetchEnabled else { return }
        if let last = storage.lastAttempt, now().timeIntervalSince(last) < TimeInterval(NewsRules.Request.refreshHoursWhileOpen * 3600),
           now() >= last { return }
        _ = fetchIfDue()
    }

    // MARK: 받아 오기 (§4)

    /// 받을 차례면 시작한다 (마지막 시도 뒤 60분이 안 지났거나 · 스위치가 꺼졌거나 · 받는 중이면 nil 또는 그 일)
    @discardableResult
    func fetchIfDue() -> Task<Void, Never>? {
        if let fetchTask { return fetchTask }
        guard storage.fetchEnabled else { return nil }
        let source = launch.source
        guard source != .none else { return nil }
        let t = now()
        if let last = storage.lastAttempt {
            let since = t.timeIntervalSince(last)
            // 시계가 뒤로 간 것(앞날의 기록)은 한 시간 넘게 지난 것으로 친다
            if since >= 0, since < TimeInterval(NewsRules.Request.minMinutesBetweenTries * 60) { return nil }
        }
        storage.lastAttempt = t
        let cache = storage.cache
        let transport = self.transport
        let task = Task { @MainActor in
            let outcome: NewsFetchOutcome
            switch source {
            case .none: outcome = .kept("off")
            case .file(let url): outcome = NewsFetcher.readFile(url)
            case .network(let url):
                if let transport { outcome = await NewsFetcher.fetch(url: url, cache: cache, transport: transport) } else { outcome = .kept("off") }
            }
            if case .replaced(let c) = outcome {
                self.storage.cache = c
                self.reloadItems()
                self.refreshList()
            }
            self.fetchTask = nil
        }
        fetchTask = task
        return task
    }

    // MARK: 목록 · 점 (§5.5)

    func env(firstRun: Bool) -> NewsEnv {
        NewsEnv(platform: platform, appVersion: appVersion, today: Dates.key(now()), lang: lang, syncOn: syncOn(), firstRun: firstRun)
    }

    private func reloadItems() {
        items = storage.cache.flatMap { NewsRules.parseFeed($0.body).feed?.items } ?? []
    }

    /// 목록 · 점을 다시. 목록이 열려 있으면 보이는 줄을 모두 본 것으로 적는다 (그 동안 점은 그대로 보인다)
    func refreshList() {
        let e = env(firstRun: false)
        let l = NewsRules.list(env: e, state: storage.state, items: items, notes: notes)
        rows = l.rows
        if paneOpen {
            paneUnseen.formUnion(l.rows.filter(\.unseen).map(\.id))
            if l.dot { storage.state = NewsRules.markListSeen(env: e, state: storage.state, items: items, notes: notes) }
            dot = false
        } else {
            dot = l.dot
        }
    }

    /// 설정 › 소식을 열었다 (여러 번 불러도 같다)
    func paneShown() {
        guard !paneOpen else { refreshList(); return }
        paneOpen = true
        paneUnseen = []
        reloadItems()
        refreshList()
    }

    /// 설정 › 소식을 떠났다 (다른 항목 · 창 닫기) — 다음에 열면 줄의 점도 없다
    func paneHidden() {
        guard paneOpen else { return }
        paneOpen = false
        paneUnseen = []
        refreshList()
    }

    func setFetchEnabled(_ on: Bool) {
        storage.fetchEnabled = on
        fetchEnabled = on
        if on { fetchIfDue() }
    }

    // MARK: 카드

    func content(_ card: NewsCard) -> NewsCardContent? {
        let today = Dates.key(now())
        switch card {
        case .notice(let id):
            guard let it = items.first(where: { $0.id == id }) else { return nil }
            return NewsCardContent(kind: .notice, id: id, caption: NewsCopy.noticeCaption(date: it.date, today: today, lang: lang),
                                   title: it.title.pick(lang), body: it.body.pick(lang),
                                   link: it.link.flatMap { NewsRules.isAllowedLink($0) ? URL(string: $0) : nil }, footnote: nil)
        case .whatsNew(let app):
            guard let n = notes.first(where: { $0.app == app }) else { return nil }
            // 제목은 앱 버전 (§1.1 — 노트를 ‘1.2’ 로 적어도 ‘Spiralday 1.2.0’)
            return NewsCardContent(kind: .whatsNew, id: NewsRules.noteID(n), caption: NewsCopy.whatsNewCaption(lang),
                                   title: NewsCopy.whatsNewTitle(appVersion: appVersion), body: n.body.pick(lang), link: nil,
                                   footnote: NewsCopy.whatsNewFootnote(lang))
        }
    }

    /// 링크는 시스템 브라우저로 — 열기 바로 앞에서 허용 목록을 한 번 더 (§8.2)
    static func openLink(_ url: URL) {
        guard NewsRules.isAllowedLink(url.absoluteString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: 시험 · QA

    /// 상태를 바꿔 넣는다 (QA 스냅샷 · 시험 — 메모리 저장소에서만)
    func load(state: NewsState, cache: NewsCache?) {
        storage.state = state
        storage.cache = cache
        reloadItems()
        refreshList()
    }
}
