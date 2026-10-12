import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 앱 안 ‘소식’의 규칙 (Docs/InAppNews.md) — 순수 함수. Mac · iPhone · iPad 가 함께 쓴다.
//   · 받은 바이트 → 받아들일지 (§2 · §2.1), 항목마다 걸러 내기, 앱에 넣은 노트(whats-new.json, §3) 읽기
//   · open (열 때의 카드 하나와 저장, §5.4) · list (설정 › 소식의 줄과 점, §5.5) · markListSeen
//   · 날짜 · 버전 꼴과 비교, 링크 허용 목록 (§8.2), 목록의 날짜 글 (§1.2)
// 공유 벡터: Tests/Fixtures/news-rules.json (비공개 저장소 web/tests/fixtures/news-rules.json 과 같은 바이트) —
// 참고 구현 Scripts/news-check.mjs 와 같은 답을 내야 한다 (InAppNewsTests).
//
// 언어마다 빠지기 쉬운 곳 (§8.3):
//   · 글자 수는 코드 포인트 (unicodeScalars.count) — String.count(글자 묶음)도 UTF-16 도 아니다
//   · 정규식을 쓰지 않고 바이트로 검사한다 (\d 가 다른 문자의 숫자를 맞추거나, $ 가 마지막 줄바꿈 앞에 맞는 일이 없게)
//   · JSON 은 이 파일의 작은 읽개로 읽는다: true 와 1 을 섞지 않고, 짝 없는 서로게이트 · 깊이 · BOM · UTF-8 을 직접 본다
//     (JSONSerialization 은 UTF-16 도 읽고, NSNumber 가 true 와 1 을 섞는다)
//   · 날짜는 달력 날짜 글끼리 비교한다 (시각으로 바꾸지 않는다)
// ─────────────────────────────────────────────────────────────────────────────

/// 소식 글 하나 (한국어는 꼭, 영어는 없으면 한국어로)
public struct NewsText: Equatable, Sendable {
    public let ko: String
    public let en: String?

    public init(ko: String, en: String? = nil) {
        self.ko = ko
        self.en = en
    }

    /// 앱 화면이 한국어면 ko, 아니면 en (없으면 ko)
    public func pick(_ lang: String) -> String { lang == "ko" ? ko : (en ?? ko) }
}

public enum NewsKind: String, Sendable, Equatable {
    case notice, update
}

public enum NewsImportance: String, Sendable, Equatable {
    case normal, important
}

/// 피드에서 받아들인 항목 (§2)
public struct NewsItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let date: String
    public let kind: NewsKind
    public let importance: NewsImportance
    public let title: NewsText
    public let body: NewsText
    /// 없으면 모든 플랫폼 (모르는 값도 그대로 두고, 고를 때 지금 플랫폼이 들어 있는지만 본다)
    public let platforms: [String]?
    public let minVersion: [String: String]?
    public let maxVersion: [String: String]?
    public let syncOnly: Bool
    /// 허용 목록(§8.2)을 지난 링크만 (아니면 nil)
    public let link: String?
    public let expires: String?
}

/// 앱에 넣은 ‘이번에 달라진 점’ 노트 하나 (§3)
public struct NewsNote: Equatable, Sendable {
    public let app: String
    public let date: String
    public let body: NewsText

    public init(app: String, date: String, body: NewsText) {
        self.app = app
        self.date = date
        self.body = body
    }
}

/// 받아들인 피드 (§2): 남은 항목 (파일 순서), 버린 항목, 링크만 뺀 항목
public struct NewsFeed: Equatable, Sendable {
    public struct Dropped: Equatable, Sendable {
        public let index: Int
        public let id: String?
        public let reason: String
    }

    public let items: [NewsItem]
    public let dropped: [Dropped]
    public let linkRemoved: [String]

    public static let empty = NewsFeed(items: [], dropped: [], linkRemoved: [])
}

/// 받은 바이트를 읽은 결과: 파일 전체를 받아들였는지 (아니면 받아 둔 것을 그대로 쓴다)
public enum NewsFeedParse: Equatable, Sendable {
    case accepted(NewsFeed)
    case rejected(String)

    public var feed: NewsFeed? {
        if case .accepted(let f) = self { return f }
        return nil
    }
}

/// 고를 때의 입력 (§5)
public struct NewsEnv: Equatable, Sendable {
    /// mac · win · ios · ipados · android
    public var platform: String
    /// CFBundleShortVersionString (버전 꼴이 아니면 버전이 걸린 것은 숨긴다)
    public var appVersion: String
    /// 기기 시간대의 오늘 YYYY-MM-DD
    public var today: String
    /// 앱 화면이 한국어면 ko, 아니면 en
    public var lang: String
    /// 이 앱에서 동기화를 켜 그룹에 들어가 있다
    public var syncOn: Bool
    /// 이번에 열면서 처음 안내를 띄운다
    public var firstRun: Bool

    public init(platform: String, appVersion: String, today: String, lang: String, syncOn: Bool, firstRun: Bool) {
        self.platform = platform
        self.appVersion = appVersion
        self.today = today
        self.lang = lang
        self.syncOn = syncOn
        self.firstRun = firstRun
    }
}

/// 기기에 남기는 것 (§6) — 로컬만, 동기화 · 통계와 상관없다
public struct NewsState: Equatable, Sendable {
    public var lastSeenAppVersion: String?
    public var since: String?
    /// 본 id, 오래된 것부터 (200개까지)
    public var seen: [String]

    public init(lastSeenAppVersion: String? = nil, since: String? = nil, seen: [String] = []) {
        self.lastSeenAppVersion = lastSeenAppVersion
        self.since = since
        self.seen = seen
    }
}

/// 열 때 띄울 카드 (‘열 때’마다 많아야 하나)
public enum NewsCard: Equatable, Sendable {
    /// 중요한 소식 (그 항목의 id)
    case notice(id: String)
    /// 이번에 달라진 점 (노트에 적힌 버전 그대로)
    case whatsNew(app: String)
}

/// 설정 › 소식의 줄 하나 (§1.2 · §5.5)
public struct NewsRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let date: String
    public let kind: NewsKind
    public let importance: NewsImportance
    public let title: String
    public let body: String
    public let link: String?
    /// 안 본 줄 (제목 앞의 작은 점)
    public let unseen: Bool
    /// 앱에 넣은 노트(이번 버전의 ‘달라진 점’)인지 — 그때의 버전
    public let app: String?

    public init(id: String, date: String, kind: NewsKind, importance: NewsImportance, title: String, body: String,
                link: String?, unseen: Bool, app: String?) {
        self.id = id
        self.date = date
        self.kind = kind
        self.importance = importance
        self.title = title
        self.body = body
        self.link = link
        self.unseen = unseen
        self.app = app
    }

    /// 같은 줄, 점만 바꿔서 (목록을 연 동안 무엇이 새것이었는지 보이게)
    public func with(unseen: Bool) -> NewsRow {
        NewsRow(id: id, date: date, kind: kind, importance: importance, title: title, body: body, link: link, unseen: unseen, app: app)
    }
}

public enum NewsRules {
    // MARK: 상수 (공유 벡터의 limits · request 와 같아야 한다)

    public enum Limits {
        public static let maxBytes = 65_536
        public static let maxItems = 50
        public static let maxDepth = 16
        public static let idMax = 64
        public static let titleMax = 80
        public static let bodyMax = 600
        public static let linkMax = 200
        public static let seenMax = 200
    }

    public enum Request {
        /// 고정 — 쿼리 문자열 · 조각 없음. 출시 빌드에는 바꾸는 길이 없다
        public static let url = URL(string: "https://spiralday.com/news/news.json")!
        public static let method = "GET"
        /// 이것뿐 (받아 둔 것이 있으면 conditional 두 개를 더한다). 쿠키 · 인증 · Referer 없음
        public static let headers: [String: String] = [
            "User-Agent": "Spiralday",
            "Accept": "application/json",
            "Accept-Language": "*",
        ]
        public static let conditional = ["If-None-Match", "If-Modified-Since"]
        public static let followRedirects = false
        public static let cookies = false
        /// 연결부터 다 받을 때까지
        public static let timeoutSeconds: TimeInterval = 5
        /// 마지막 시도 뒤 이만큼 안 지났으면 건너뛴다
        public static let minMinutesBetweenTries = 60
        /// 계속 켜 둔 동안
        public static let refreshHoursWhileOpen = 24
        /// 이만큼 넘게 뒤에 있다가 앞으로 오면 ‘열 때’
        public static let openAfterAwayMinutes = 60
    }

    public static let platforms = ["mac", "win", "ios", "ipados", "android"]

    // MARK: 날짜 · 버전 · 링크

    /// `^[0-9]{1,6}(\.[0-9]{1,6}){0,2}$` → [주, 부, 수] (빈 자리는 0). 아니면 nil
    public static func parseVersion(_ s: String) -> [Int]? {
        let parts = s.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var out: [Int] = []
        for p in parts {
            guard (1...6).contains(p.count), p.allSatisfy(isDigit) else { return nil }
            out.append(p.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) })
        }
        while out.count < 3 { out.append(0) }
        return out
    }

    /// a − b 의 부호 (−1 · 0 · 1). 둘 중 하나라도 버전 꼴이 아니면 nil
    public static func compareVersions(_ a: String, _ b: String) -> Int? {
        guard let x = parseVersion(a), let y = parseVersion(b) else { return nil }
        for i in 0..<3 where x[i] != y[i] { return x[i] < y[i] ? -1 : 1 }
        return 0
    }

    /// `YYYY-MM-DD` 이고 달력에 있는 날 (윤년 포함, 0년 없음)
    public static func isDate(_ s: String) -> Bool {
        dateParts(s) != nil
    }

    /// `^https://spiralday\.com/[A-Za-z0-9._~/-]*(#[A-Za-z0-9._~-]*)?$`, 200자 이하. URL 파서로 고쳐 읽지 않는다
    public static func isAllowedLink(_ s: String) -> Bool {
        guard s.utf16.count <= Limits.linkMax else { return false }
        let prefix = Array("https://spiralday.com/".utf8)
        let b = Array(s.utf8)
        guard b.count >= prefix.count, Array(b[0..<prefix.count]) == prefix else { return false }
        var inFragment = false
        for c in b[prefix.count...] {
            if c == UInt8(ascii: "#") {
                if inFragment { return false }
                inFragment = true
                continue
            }
            let unreserved = isAlnum(c) || c == UInt8(ascii: ".") || c == UInt8(ascii: "_") || c == UInt8(ascii: "~")
                || c == UInt8(ascii: "-")
            guard unreserved || (!inFragment && c == UInt8(ascii: "/")) else { return false }
        }
        return true
    }

    // MARK: 피드 읽기 (§2 · §2.1)

    /// 받은 바이트 → 파일 전체를 받아들이는지, 받아들이면 남는 항목
    public static func parseFeed(_ data: Data) -> NewsFeedParse {
        guard data.count <= Limits.maxBytes else { return .rejected("too big") }
        let doc: NewsJSON
        do {
            doc = try NewsJSON.parse(data)
        } catch let e as NewsJSON.Failure {
            return .rejected(e.reason)
        } catch {
            return .rejected("not JSON (UTF-8)")
        }
        guard case .object(let top) = doc else { return .rejected("not an object") }
        guard case .number(let v)? = top["version"], v == 1 else { return .rejected("version") }
        guard case .array(let raw)? = top["items"] else { return .rejected("items") }
        var items: [NewsItem] = []
        var dropped: [NewsFeed.Dropped] = []
        var linkRemoved: [String] = []
        var ids = Set<String>()
        for (index, entry) in raw.prefix(Limits.maxItems).enumerated() {
            let id: String? = { if case .object(let o) = entry, case .string(let s)? = o["id"] { return s }; return nil }()
            switch validateItem(entry) {
            case .failure(let why):
                dropped.append(.init(index: index, id: id, reason: why.reason))
            case .success(let (item, removed)):
                guard !ids.contains(item.id) else {
                    dropped.append(.init(index: index, id: item.id, reason: "duplicate id"))
                    continue
                }
                ids.insert(item.id)
                if removed { linkRemoved.append(item.id) }
                items.append(item)
            }
        }
        if raw.count > Limits.maxItems {
            dropped.append(.init(index: Limits.maxItems, id: nil, reason: "items after the first \(Limits.maxItems) are not read"))
        }
        return .accepted(NewsFeed(items: items, dropped: dropped, linkRemoved: linkRemoved))
    }

    private struct Drop: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// 한 항목 → 항목과 ‘링크만 뺐는지’, 또는 버리는 까닭
    private static func validateItem(_ entry: NewsJSON) -> Result<(NewsItem, Bool), Drop> {
        guard case .object(let o) = entry else { return .failure(Drop("not an object")) }
        guard case .string(let id)? = o["id"], isID(id) else { return .failure(Drop("id")) }
        guard !id.hasPrefix("app-") else { return .failure(Drop("id app- is reserved")) }
        guard case .string(let date)? = o["date"], isDate(date) else { return .failure(Drop("date")) }
        guard case .string(let k)? = o["kind"], let kind = NewsKind(rawValue: k) else { return .failure(Drop("kind")) }
        guard case .string(let im)? = o["importance"], let importance = NewsImportance(rawValue: im) else {
            return .failure(Drop("importance"))
        }
        guard let title = text(o["title"], max: Limits.titleMax, multiline: false) else { return .failure(Drop("title")) }
        guard let body = text(o["body"], max: Limits.bodyMax, multiline: true) else { return .failure(Drop("body")) }
        var platforms: [String]?
        if !absent(o["platforms"]) {
            guard case .array(let a)? = o["platforms"], !a.isEmpty else { return .failure(Drop("platforms")) }
            var list: [String] = []
            for p in a {
                guard case .string(let s) = p else { return .failure(Drop("platforms")) }
                list.append(s)
            }
            platforms = list
        }
        var minVersion: [String: String]?
        if !absent(o["minVersion"]) {
            guard let m = versionMap(o["minVersion"]) else { return .failure(Drop("minVersion")) }
            minVersion = m
        }
        var maxVersion: [String: String]?
        if !absent(o["maxVersion"]) {
            guard let m = versionMap(o["maxVersion"]) else { return .failure(Drop("maxVersion")) }
            maxVersion = m
        }
        var syncOnly = false
        if !absent(o["syncOnly"]) {
            guard case .bool(let b)? = o["syncOnly"] else { return .failure(Drop("syncOnly")) }
            syncOnly = b
        }
        var expires: String?
        if !absent(o["expires"]) {
            guard case .string(let e)? = o["expires"], isDate(e) else { return .failure(Drop("expires")) }
            expires = e
        }
        var link: String?
        var removed = false
        if !absent(o["link"]) {
            if case .string(let l)? = o["link"], isAllowedLink(l) { link = l } else { removed = true }
        }
        let item = NewsItem(id: id, date: date, kind: kind, importance: importance, title: title, body: body,
                            platforms: platforms, minVersion: minVersion, maxVersion: maxVersion, syncOnly: syncOnly,
                            link: link, expires: expires)
        return .success((item, removed))
    }

    // MARK: 앱에 넣은 노트 (§3)

    /// whats-new.json → 쓸 수 있는 노트들 (잘못된 것은 건너뛴다. 파일이 아예 잘못되면 빈 목록)
    public static func parseBundled(_ data: Data) -> [NewsNote] {
        guard case .object(let doc)? = try? NewsJSON.parse(data),
              case .number(let v)? = doc["version"], v == 1,
              case .array(let notes)? = doc["notes"]
        else { return [] }
        var out: [NewsNote] = []
        for n in notes {
            guard case .object(let o) = n,
                  case .string(let app)? = o["app"], parseVersion(app) != nil,
                  case .string(let date)? = o["date"], isDate(date),
                  let body = text(o["body"], max: Limits.bodyMax, multiline: true)
            else { continue }
            out.append(NewsNote(app: app, date: date, body: body))
        }
        return out
    }

    /// 지금 앱 버전과 숫자로 같은 노트 (여럿이면 처음 것). 앱 버전이 버전 꼴이 아니면 nil
    public static func note(for appVersion: String, in notes: [NewsNote]) -> NewsNote? {
        guard parseVersion(appVersion) != nil else { return nil }
        return notes.first { compareVersions($0.app, appVersion) == 0 }
    }

    /// 목록에서 노트의 id (적힌 그대로)
    public static func noteID(_ note: NewsNote) -> String { "app-\(note.app)" }

    /// 노트의 제목 (§3)
    public static func noteTitle(_ app: String) -> NewsText {
        NewsText(ko: "\(app) 에서 달라진 점", en: "What\u{2019}s new in \(app)")
    }

    // MARK: 고르기 (§5)

    /// 지금 보이는 항목인지 (§5.2)
    public static func isVisible(_ item: NewsItem, env: NewsEnv) -> Bool {
        if before(env.today, item.date) { return false }
        if let e = item.expires, before(e, env.today) { return false }
        if let p = item.platforms, !p.contains(env.platform) { return false }
        func key(_ m: [String: String]?) -> String? {
            guard let m else { return nil }
            if m[env.platform] != nil { return env.platform }
            if env.platform == "ipados", m["ios"] != nil { return "ios" }
            return nil
        }
        let minKey = key(item.minVersion)
        let maxKey = key(item.maxVersion)
        if minKey != nil || maxKey != nil {
            guard parseVersion(env.appVersion) != nil else { return false }
            if let k = minKey, let v = item.minVersion?[k], (compareVersions(env.appVersion, v) ?? -1) < 0 { return false }
            if let k = maxKey, let v = item.maxVersion?[k], (compareVersions(env.appVersion, v) ?? 1) > 0 { return false }
        }
        if item.syncOnly && !env.syncOn { return false }
        return true
    }

    /// 목록에 들어가는 한 줄 (노트 또는 피드 항목)
    private struct Entry {
        let id: String
        let date: String
        let kind: NewsKind
        let importance: NewsImportance
        let title: NewsText
        let body: NewsText
        let link: String?
        let app: String?
    }

    /// 보이는 것: 이 버전의 노트 + 걸러 낸 소식, 날짜가 늦은 것부터 (같은 날이면 노트 먼저, 그다음 파일 순서) — §5.3
    private static func ordered(_ env: NewsEnv, _ items: [NewsItem], _ notes: [NewsNote]) -> [Entry] {
        var all: [Entry] = []
        if let n = note(for: env.appVersion, in: notes) {
            all.append(Entry(id: noteID(n), date: n.date, kind: .update, importance: .normal, title: noteTitle(n.app),
                             body: n.body, link: nil, app: n.app))
        }
        for it in items where isVisible(it, env: env) {
            all.append(Entry(id: it.id, date: it.date, kind: it.kind, importance: it.importance, title: it.title,
                             body: it.body, link: it.link, app: nil))
        }
        // 안정 정렬: 날짜가 같으면 원래 순서
        return all.enumerated()
            .sorted { a, b in a.element.date == b.element.date ? a.offset < b.offset : before(b.element.date, a.element.date) }
            .map(\.element)
    }

    private static func remember(_ seen: inout [String], _ id: String) {
        if !seen.contains(id) { seen.append(id) }
        if seen.count > Limits.seenMax { seen.removeFirst(seen.count - Limits.seenMax) }
    }

    /// 한 번 ‘열 때’ (§5.4): 띄울 카드 하나(없으면 nil)와 바로 저장할 상태 (카드는 띄우는 순간 본 것)
    public static func open(env: NewsEnv, state: NewsState, items: [NewsItem], notes: [NewsNote])
        -> (card: NewsCard?, save: NewsState) {
        var seen = state.seen
        var lastSeen = state.lastSeenAppVersion
        var since = state.since
        let appOK = parseVersion(env.appVersion) != nil
        let lastOK = lastSeen.flatMap(parseVersion) != nil
        let n = note(for: env.appVersion, in: notes)
        var card: NewsCard?
        if env.firstRun {
            if appOK, !(lastOK && (compareVersions(lastSeen!, env.appVersion) ?? 0) > 0) { lastSeen = env.appVersion }
            if since == nil { since = env.today }
            if let n { remember(&seen, noteID(n)) }
        } else {
            let updated = appOK && (!lastOK || (compareVersions(lastSeen!, env.appVersion) ?? 0) < 0)
            let whatsNewDue = updated && n != nil && !seen.contains(noteID(n!))
            if let notice = ordered(env, items, notes).first(where: { $0.importance == .important && !seen.contains($0.id) }) {
                card = .notice(id: notice.id)
                remember(&seen, notice.id)
            } else if whatsNewDue, let n {
                card = .whatsNew(app: n.app)
                remember(&seen, noteID(n))
            }
            if updated {
                if case .whatsNew = card { lastSeen = env.appVersion } else if !whatsNewDue { lastSeen = env.appVersion }
            }
        }
        return (card, NewsState(lastSeenAppVersion: lastSeen, since: since, seen: seen))
    }

    /// 설정 › 소식의 목록과 ‘소식’ 항목의 점 (§5.5 — 상태를 바꾸지 않는다)
    public static func list(env: NewsEnv, state: NewsState, items: [NewsItem], notes: [NewsNote]) -> (rows: [NewsRow], dot: Bool) {
        let rows = ordered(env, items, notes).map { e in
            NewsRow(id: e.id, date: e.date, kind: e.kind, importance: e.importance,
                    title: e.title.pick(env.lang), body: e.body.pick(env.lang), link: e.link,
                    unseen: !state.seen.contains(e.id)
                        && (e.importance == .important || state.since == nil || !before(e.date, state.since!)),
                    app: e.app)
        }
        return (rows, rows.contains { $0.unseen })
    }

    /// 목록을 열었을 때: 보이는 것을 모두 본 것으로
    public static func markListSeen(env: NewsEnv, state: NewsState, items: [NewsItem], notes: [NewsNote]) -> NewsState {
        var s = state
        for e in ordered(env, items, notes) { remember(&s.seen, e.id) }
        return s
    }

    /// 받은 응답을 캐시에 넣을지 (공유 벡터 fetch): 200 이고 피드를 받아들일 때만. 나머지는 받아 둔 것 그대로
    public static func replacesCache(status: Int?, body: Data?) -> Bool {
        guard status == 200, let body else { return false }
        return parseFeed(body).feed != nil
    }

    // MARK: 보이는 글

    /// 목록 · 카드의 날짜: 올해면 ‘10월 20일’ (en Oct 20), 아니면 ‘2025년 12월 3일’ (en Dec 3, 2025).
    /// 달력 날짜 그대로 — 시각(UTC)으로 바꾸지 않는다
    public static func displayDate(_ date: String, today: String, lang: String) -> String {
        guard let (y, m, d) = dateParts(date) else { return date }
        let thisYear = dateParts(today)?.0 == y
        if lang == "ko" { return thisYear ? "\(m)월 \(d)일" : "\(y)년 \(m)월 \(d)일" }
        let mon = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][m - 1]
        return thisYear ? "\(mon) \(d)" : "\(mon) \(d), \(y)"
    }

    // MARK: 작은 도우미

    private static func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
    private static func isLower(_ c: UInt8) -> Bool { c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z") }
    private static func isAlnum(_ c: UInt8) -> Bool {
        isDigit(c) || isLower(c) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
    }

    /// `^[a-z0-9][a-z0-9-]{0,63}$`
    private static func isID(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard (1...Limits.idMax).contains(b.count), isDigit(b[0]) || isLower(b[0]) else { return false }
        return b.dropFirst().allSatisfy { isDigit($0) || isLower($0) || $0 == UInt8(ascii: "-") }
    }

    /// YYYY-MM-DD → (연, 월, 일), 달력에 없는 날이면 nil
    static func dateParts(_ s: String) -> (Int, Int, Int)? {
        let b = Array(s.utf8)
        guard b.count == 10, b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-") else { return nil }
        for i in [0, 1, 2, 3, 5, 6, 8, 9] where !isDigit(b[i]) { return nil }
        func num(_ r: Range<Int>) -> Int { b[r].reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) } }
        let y = num(0..<4), m = num(5..<7), d = num(8..<10)
        guard y >= 1, (1...12).contains(m), d >= 1 else { return nil }
        let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
        return d <= days ? (y, m, d) : nil
    }

    /// 글자 그대로 a < b (같은 꼴의 날짜라 날짜 순서와 같다)
    private static func before(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

    private static func absent(_ v: NewsJSON?) -> Bool {
        if case .null? = v { return true }
        return v == nil
    }

    /// 제목 · 본문에 넣지 못하는 글자 (§2): 제어 문자 (본문의 줄바꿈만 예외) · 방향 제어 · 줄 · 문단 구분자
    private static func allowed(_ u: Unicode.Scalar, multiline: Bool) -> Bool {
        let v = u.value
        if v == 0x0A { return multiline }
        if v <= 0x1F || (0x7F...0x9F).contains(v) { return false }
        if v == 0x200E || v == 0x200F || v == 0x2028 || v == 0x2029 { return false }
        if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) { return false }
        return true
    }

    /// {ko, en?} → 글, 또는 nil (항목을 버린다). en 이 없거나 null · "" 이면 ko 로
    private static func text(_ v: NewsJSON?, max: Int, multiline: Bool) -> NewsText? {
        guard case .object(let o)? = v else { return nil }
        func ok(_ j: NewsJSON?) -> String? {
            guard case .string(let s)? = j, !s.isEmpty, s.unicodeScalars.count <= max,
                  s.unicodeScalars.allSatisfy({ allowed($0, multiline: multiline) })
            else { return nil }
            return s
        }
        guard let ko = ok(o["ko"]) else { return nil }
        if absent(o["en"]) { return NewsText(ko: ko) }
        if case .string("")? = o["en"] { return NewsText(ko: ko) }
        guard let en = ok(o["en"]) else { return nil }
        return NewsText(ko: ko, en: en)
    }

    /// { 플랫폼: 버전 } — 모르는 키도 값은 버전이어야 한다
    private static func versionMap(_ v: NewsJSON?) -> [String: String]? {
        guard case .object(let o)? = v else { return nil }
        var out: [String: String] = [:]
        for (k, x) in o {
            guard case .string(let s) = x, parseVersion(s) != nil else { return nil }
            out[k] = s
        }
        return out
    }
}

// MARK: - 소식 문구 (Mac · iPhone · iPad 가 같은 말을 쓴다, §1)

public enum NewsCopy {
    public static func paneTitle(_ lang: String) -> String { lang == "ko" ? "소식" : "News" }
    /// 카드 위의 작은 글자: ‘소식 · 10월 20일’
    public static func noticeCaption(date: String, today: String, lang: String) -> String {
        "\(lang == "ko" ? "소식" : "News") · \(NewsRules.displayDate(date, today: today, lang: lang))"
    }
    public static func whatsNewCaption(_ lang: String) -> String { lang == "ko" ? "이번에 달라진 점" : "What\u{2019}s new" }
    /// 이번에 달라진 점 카드의 제목: 지금 **앱 버전** (§1.1 — 노트를 `1.2` 로 적어도 앱 1.2.0 이면 ‘Spiralday 1.2.0’, Windows · Android 와 같다)
    public static func whatsNewTitle(appVersion: String) -> String { "Spiralday \(appVersion)" }
    @available(*, deprecated, renamed: "whatsNewTitle(appVersion:)", message: "노트에 적힌 버전이 아니라 앱 버전을 넘겨요 (§1.1)")
    public static func whatsNewTitle(_ app: String) -> String { whatsNewTitle(appVersion: app) }
    public static func whatsNewFootnote(_ lang: String) -> String {
        lang == "ko" ? "설정 › 소식에서 다시 볼 수 있어요." : "You can read this again in Settings \u{203A} News."
    }
    public static func learnMore(_ lang: String) -> String { lang == "ko" ? "자세히 보기" : "Learn more" }
    public static func ok(_ lang: String) -> String { lang == "ko" ? "확인" : "OK" }
    public static func kind(_ k: NewsKind, _ lang: String) -> String {
        switch k {
        case .notice: lang == "ko" ? "알림" : "Notice"
        case .update: lang == "ko" ? "업데이트" : "Update"
        }
    }
    public static func empty(_ lang: String) -> String { lang == "ko" ? "아직 소식이 없어요." : "No news yet." }
    public static func fetchToggle(_ lang: String) -> String {
        lang == "ko" ? "spiralday.com 에서 소식 받기" : "Get news from spiralday.com"
    }
    public static func fetchOnDetail(_ lang: String) -> String {
        lang == "ko" ? "앱을 열 때(켜 둔 동안은 하루 한 번) spiralday.com 의 소식 파일을 읽어 와요. 설치 번호나 기기 정보는 보내지 않아요."
            : "When you open the app (and once a day while it stays open), it reads the news file on spiralday.com. "
                + "No install ID or device information is sent."
    }
    /// 설정 › 소식의 설명 한 줄 (모든 플랫폼이 같은 말 — 카드 · 시트 · 대화상자 어느 모양에도 맞게)
    public static func paneNote(_ lang: String) -> String {
        lang == "ko" ? "업데이트한 뒤 달라진 점과 꼭 알아야 할 소식만 앱을 열 때 한 번 보여 드려요. 푸시 알림 · 배지는 없어요."
            : "Only what\u{2019}s new after an update and news you need to know show once when you open the app. "
                + "No push notifications or badges."
    }
    /// 안 본 줄 · ‘소식’ 항목의 점을 읽어 주는 말 (VoiceOver · 화면 읽기)
    public static func unseen(_ lang: String) -> String { lang == "ko" ? "새 소식" : "New" }
    public static func fetchOffDetail(_ lang: String) -> String {
        lang == "ko" ? "받아 오지 않아요. 이미 받은 소식과 이번에 달라진 점은 그대로 볼 수 있어요."
            : "News isn\u{2019}t fetched. You can still read the news you already have and what\u{2019}s new in this version."
    }
}

// MARK: - 작은 JSON 읽개

/// 소식 피드 · 노트만 읽는 엄격한 JSON 읽개 (RFC 8259). 받아들이지 않는 것 (§2.1):
/// 65,536 바이트 초과는 parseFeed 가 먼저 본다 · 맨 앞 BOM 하나는 뗀다 · UTF-8 이 아님 · 짝 없는 서로게이트 (escape 로 적은 것도) ·
/// 16단계보다 깊은 객체 · 배열. 같은 키가 둘이면 뒤의 것 (JS JSON.parse 와 같다) — 덮어써진 앞 값도 글을 읽으며 모두 보므로
/// 그 안의 짝 없는 서로게이트 · 깊이도 파일을 거절한다 (§2.1 ‘어디에든’, 공유 벡터 ‘a key written twice …’).
enum NewsJSON: Equatable {
    case object([String: NewsJSON])
    case array([NewsJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    struct Failure: Error {
        let reason: String
    }

    static func parse(_ data: Data) throws -> NewsJSON {
        var bytes = [UInt8](data)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { bytes.removeFirst(3) }
        // UTF-8 이 아니면 (서로게이트를 UTF-8 로 적은 것 · 잘린 글자 포함) 바꿔 읽은 글이 원래 바이트와 다르다
        guard Array(String(decoding: bytes, as: UTF8.self).utf8) == bytes else { throw Failure(reason: "not JSON (UTF-8)") }
        var r = Reader(b: bytes)
        r.space()
        let v = try r.value(depth: 0)
        r.space()
        guard r.i == bytes.count else { throw Failure(reason: "not JSON (UTF-8)") }
        return v
    }

    private struct Reader {
        let b: [UInt8]
        var i = 0

        init(b: [UInt8]) { self.b = b }

        func fail(_ reason: String = "not JSON (UTF-8)") -> Failure { Failure(reason: reason) }

        mutating func space() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }

        /// depth: 이 값을 담은 객체 · 배열의 단계 (맨 위 값은 0, 맨 위 객체가 1단계)
        mutating func value(depth: Int) throws -> NewsJSON {
            guard i < b.count else { throw fail() }
            switch b[i] {
            case UInt8(ascii: "{"):
                guard depth + 1 <= NewsRules.Limits.maxDepth else { throw fail("too deep or lone surrogate") }
                i += 1
                var o: [String: NewsJSON] = [:]
                space()
                if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                while true {
                    space()
                    guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail() }
                    let k = try string()
                    space()
                    guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail() }
                    i += 1
                    space()
                    o[k] = try value(depth: depth + 1)
                    space()
                    guard i < b.count else { throw fail() }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                    throw fail()
                }
            case UInt8(ascii: "["):
                guard depth + 1 <= NewsRules.Limits.maxDepth else { throw fail("too deep or lone surrogate") }
                i += 1
                var a: [NewsJSON] = []
                space()
                if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                while true {
                    space()
                    a.append(try value(depth: depth + 1))
                    space()
                    guard i < b.count else { throw fail() }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                    throw fail()
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try literal("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null")
                return .null
            default:
                return .number(try number())
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= b.count, Array(b[i..<(i + w.count)]) == w else { throw fail() }
            i += w.count
        }

        /// -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
        mutating func number() throws -> Double {
            let start = i
            func digit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
            if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
            guard i < b.count, digit(b[i]) else { throw fail() }
            if b[i] == 0x30 { i += 1 } else { while i < b.count, digit(b[i]) { i += 1 } }
            if i < b.count, b[i] == UInt8(ascii: ".") {
                i += 1
                guard i < b.count, digit(b[i]) else { throw fail() }
                while i < b.count, digit(b[i]) { i += 1 }
            }
            if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
                i += 1
                if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
                guard i < b.count, digit(b[i]) else { throw fail() }
                while i < b.count, digit(b[i]) { i += 1 }
            }
            guard let d = Double(String(decoding: b[start..<i], as: UTF8.self)) else { throw fail() }
            return d
        }

        /// 따옴표로 시작하는 글 (escape 를 풀고, 짝 없는 서로게이트는 받지 않는다)
        mutating func string() throws -> String {
            i += 1
            var out: [UInt8] = []
            while true {
                guard i < b.count else { throw fail() }
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c < 0x20 { throw fail() }
                if c != UInt8(ascii: "\\") {
                    out.append(c)
                    i += 1
                    continue
                }
                i += 1
                guard i < b.count else { throw fail() }
                let e = b[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var u = try hex4()
                    if (0xD800...0xDBFF).contains(u) {
                        // 높은 서로게이트 다음에는 꼭 \uDC00–\uDFFF
                        guard i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") else {
                            throw fail("too deep or lone surrogate")
                        }
                        i += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw fail("too deep or lone surrogate") }
                        u = 0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(u) {
                        throw fail("too deep or lone surrogate")
                    }
                    guard let scalar = Unicode.Scalar(u) else { throw fail() }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw fail()
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count else { throw fail() }
            var v: UInt32 = 0
            for c in b[i..<(i + 4)] {
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                default: throw fail()
                }
                v = v * 16 + d
            }
            i += 4
            return v
        }
    }
}
