import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 앱 안 ‘소식’ 받아 오기와 기기에 남기는 것 (Docs/InAppNews.md §4 · §6) — Mac · iPhone · iPad 공용.
//   · 요청: https://spiralday.com/news/news.json 에 GET 하나. 헤더는 User-Agent: Spiralday · Accept · Accept-Language: * 와
//     받아 둔 것이 있으면 If-None-Match · If-Modified-Since 뿐. 쿠키 · 캐시 · 인증 · Referer 없음, 넘겨주기는 따르지 않는다,
//     연결부터 다 받을 때까지 5초, 65,536 바이트를 넘으면 끊는다
//   · 응답: 200 이고 피드를 받아들일 때만 캐시를 바꾼다 (빈 items 도). 304 · 3xx · 4xx · 5xx · 시간 초과 · 연결 없음 · 큰 · 깨진 본문은
//     받아 둔 것 그대로, 조용히
//   · 저장 (기기마다 · 로컬만): UserDefaults 의 news.* 와 Caches 폴더의 news.json (받은 바이트) · news-meta.json (ETag ·
//     Last-Modified · 마지막 시도 시각). 데모 · 스냅샷 · 시험은 NewsMemoryStorage (메모리만)
// 받은 것 · 본 것을 어디로도 보내지 않는다 (통계 · 동기화와 상관없다).
// ─────────────────────────────────────────────────────────────────────────────

/// 마지막으로 받아들인 피드
public struct NewsCache: Equatable, Sendable {
    public var body: Data
    public var etag: String?
    public var lastModified: String?

    public init(body: Data, etag: String? = nil, lastModified: String? = nil) {
        self.body = body
        self.etag = etag
        self.lastModified = lastModified
    }
}

/// 한 번 받아 본 결과
public enum NewsFetchOutcome: Equatable, Sendable {
    /// 200 이고 피드를 받아들였다 → 캐시를 이것으로
    case replaced(NewsCache)
    /// 받아 둔 것 그대로 (까닭: 304 · 상태 코드 · 시간 초과 · 너무 큼 · 읽지 못함 …)
    case kept(String)
}

/// 응답 하나 (시험이 바꿔 끼울 수 있게)
public enum NewsTransportResult: Equatable, Sendable {
    case response(status: Int, headers: [String: String], body: Data)
    /// 65,536 바이트를 넘어 끊었다
    case tooBig
    /// 시간 초과 · 연결 없음 · 그 밖의 실패
    case failed(String)
}

public protocol NewsTransport: Sendable {
    func get(_ request: URLRequest) async -> NewsTransportResult
}

public enum NewsFetcher {
    /// 보낼 요청: 정해진 헤더와 (받아 둔 것이 있으면) 조건부 헤더뿐
    public static func request(url: URL = NewsRules.Request.url, cache: NewsCache?,
                               timeout: TimeInterval = NewsRules.Request.timeoutSeconds) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = NewsRules.Request.method
        req.httpShouldHandleCookies = false
        for (k, v) in NewsRules.Request.headers { req.setValue(v, forHTTPHeaderField: k) }
        if let cache {
            if let e = cache.etag, !e.isEmpty { req.setValue(e, forHTTPHeaderField: "If-None-Match") }
            if let m = cache.lastModified, !m.isEmpty { req.setValue(m, forHTTPHeaderField: "If-Modified-Since") }
        }
        return req
    }

    /// 한 번 받아 본다 (캐시를 바꿀지만 정하고, 저장은 부르는 쪽이)
    public static func fetch(url: URL = NewsRules.Request.url, cache: NewsCache?, transport: NewsTransport) async -> NewsFetchOutcome {
        outcome(await transport.get(request(url: url, cache: cache)))
    }

    /// 응답 → 캐시를 바꿀지 (공유 벡터 fetch 와 같은 규칙)
    public static func outcome(_ r: NewsTransportResult) -> NewsFetchOutcome {
        switch r {
        case .tooBig: return .kept("too big")
        case .failed(let why): return .kept(why)
        case .response(let status, let headers, let body):
            guard status == 200 else { return .kept("HTTP \(status)") }
            guard body.count <= NewsRules.Limits.maxBytes else { return .kept("too big") }
            guard NewsRules.replacesCache(status: status, body: body) else { return .kept("not accepted") }
            func header(_ name: String) -> String? {
                headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            }
            return .replaced(NewsCache(body: body, etag: header("ETag"), lastModified: header("Last-Modified")))
        }
    }

    /// 로컬 파일을 받은 것처럼 (디버그 · QA 의 바꿔 끼우기 — 출시 빌드에는 이 길이 없다)
    public static func readFile(_ url: URL) -> NewsFetchOutcome {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue
        else { return .kept("no file") }
        guard size <= NewsRules.Limits.maxBytes else { return .kept("too big") }
        guard let data = try? Data(contentsOf: url) else { return .kept("unreadable") }
        return outcome(.response(status: 200, headers: [:], body: data))
    }
}

/// URLSession 으로 받기: 일회용 세션 (쿠키 · 캐시 없음), 넘겨주기 따르지 않음, 5초, 65,536 바이트에서 끊기
public final class NewsURLSessionTransport: NSObject, NewsTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let timeout: TimeInterval
    private let maxBytes: Int
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        // URLSession 이 저절로 붙이는 언어 · 기기 정보 대신 정한 값으로 (요청의 값이 이긴다)
        c.httpAdditionalHeaders = NewsRules.Request.headers
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// 연결부터 다 받을 때까지 (앱은 5초)
    public var timeoutInterval: TimeInterval { timeout }

    public init(timeout: TimeInterval = NewsRules.Request.timeoutSeconds, maxBytes: Int = NewsRules.Limits.maxBytes) {
        self.timeout = timeout
        self.maxBytes = maxBytes
        super.init()
    }

    /// 세션은 delegate(이 객체)를 붙잡고 있으니 다 쓰면 풀어 준다 (앱은 하나를 계속 쓴다)
    public func invalidate() { session.invalidateAndCancel() }

    public func get(_ request: URLRequest) async -> NewsTransportResult {
        var req = request
        req.timeoutInterval = timeout
        let deadline = Date().addingTimeInterval(timeout)
        do {
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { return .failed("not HTTP") }
            // 200 이 아니면 본문을 읽지 않는다 (304 · 3xx · 4xx · 5xx 는 어차피 받아 둔 것 그대로)
            guard http.statusCode == 200 else {
                bytes.task.cancel()
                return .response(status: http.statusCode, headers: [:], body: Data())
            }
            if http.expectedContentLength > Int64(maxBytes) {
                bytes.task.cancel()
                return .tooBig
            }
            var body = Data()
            body.reserveCapacity(Int(min(max(http.expectedContentLength, 0), Int64(maxBytes))))
            for try await chunk in bytes {
                body.append(chunk)
                if body.count > maxBytes {
                    bytes.task.cancel()
                    return .tooBig
                }
                // 보내는 쪽이 아주 천천히 흘려도 5초에서 끊는다
                if body.count % 4096 == 0, Date() > deadline {
                    bytes.task.cancel()
                    return .failed("timeout")
                }
            }
            guard Date() <= deadline.addingTimeInterval(0.5) else { return .failed("timeout") }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let k = k as? String, let v = v as? String { headers[k] = v }
            }
            return .response(status: http.statusCode, headers: headers, body: body)
        } catch {
            let ns = error as NSError
            return .failed(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut ? "timeout" : "no connection")
        }
    }

    /// 넘겨주기는 따르지 않는다 → 3xx 응답이 그대로 돌아와 실패로 친다
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    /// 인증을 묻는 서버에는 아무것도 주지 않는다
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - 기기에 남기는 것 (§6)

/// 소식의 상태 · 스위치 · 캐시를 두는 곳
public protocol NewsStorage: AnyObject {
    var state: NewsState { get set }
    /// ‘spiralday.com 에서 소식 받기’ (기본 켬)
    var fetchEnabled: Bool { get set }
    var cache: NewsCache? { get set }
    /// 마지막으로 받아 보려 한 때 (성공 · 실패 모두)
    var lastAttempt: Date? { get set }
}

/// 메모리에만 (데모 · 스냅샷 · 시험 · QA 의 바꿔 끼우기 — 설정 파일 · 캐시 폴더에 아무것도 남기지 않는다)
public final class NewsMemoryStorage: NewsStorage {
    public var state: NewsState
    public var fetchEnabled: Bool
    public var cache: NewsCache?
    public var lastAttempt: Date?

    public init(state: NewsState = NewsState(), fetchEnabled: Bool = true, cache: NewsCache? = nil, lastAttempt: Date? = nil) {
        self.state = state
        self.fetchEnabled = fetchEnabled
        self.cache = cache
        self.lastAttempt = lastAttempt
    }
}

/// UserDefaults (news. 접두) 와 Caches 폴더의 news.json · news-meta.json
public final class NewsDefaultsStorage: NewsStorage {
    public enum Key {
        public static let lastSeenAppVersion = "news.lastSeenAppVersion"
        public static let since = "news.since"
        public static let seen = "news.seen"
        public static let fetchEnabled = "news.fetchEnabled"
    }

    private let defaults: UserDefaults
    private let folder: URL
    private var bodyURL: URL { folder.appendingPathComponent("news.json") }
    private var metaURL: URL { folder.appendingPathComponent("news-meta.json") }

    private struct Meta: Codable {
        var etag: String?
        var lastModified: String?
        var lastAttempt: Date?
    }

    /// folder: 이 앱의 캐시 폴더 (지워지면 다시 받으면 된다)
    public init(defaults: UserDefaults = .standard, cacheFolder folder: URL) {
        self.defaults = defaults
        self.folder = folder
    }

    /// Caches/<묶음 id>/ (묶음 id 가 없으면 Caches/Spiralday/)
    public static func defaultCacheFolder(bundleID: String? = Bundle.main.bundleIdentifier) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(bundleID ?? "Spiralday", isDirectory: true)
    }

    public var state: NewsState {
        get {
            let last = defaults.string(forKey: Key.lastSeenAppVersion)
            let since = defaults.string(forKey: Key.since).flatMap { NewsRules.isDate($0) ? $0 : nil }
            var seen = (defaults.array(forKey: Key.seen) ?? []).compactMap { $0 as? String }
            if seen.count > NewsRules.Limits.seenMax { seen.removeFirst(seen.count - NewsRules.Limits.seenMax) }
            return NewsState(lastSeenAppVersion: last, since: since, seen: seen)
        }
        set {
            if let v = newValue.lastSeenAppVersion { defaults.set(v, forKey: Key.lastSeenAppVersion) } else {
                defaults.removeObject(forKey: Key.lastSeenAppVersion)
            }
            if let v = newValue.since { defaults.set(v, forKey: Key.since) } else { defaults.removeObject(forKey: Key.since) }
            defaults.set(newValue.seen, forKey: Key.seen)
        }
    }

    public var fetchEnabled: Bool {
        get { defaults.object(forKey: Key.fetchEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.fetchEnabled) }
    }

    private var meta: Meta {
        get { (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) } ?? Meta() }
        set {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(newValue) { try? d.write(to: metaURL, options: .atomic) }
        }
    }

    public var cache: NewsCache? {
        get {
            // 받은 바이트가 없으면 (캐시 폴더가 지워졌으면) 조건부 헤더도 보내지 않는다
            guard let body = try? Data(contentsOf: bodyURL), body.count <= NewsRules.Limits.maxBytes else { return nil }
            let m = meta
            return NewsCache(body: body, etag: m.etag, lastModified: m.lastModified)
        }
        set {
            var m = meta
            if let c = newValue {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? c.body.write(to: bodyURL, options: .atomic)
                m.etag = c.etag
                m.lastModified = c.lastModified
            } else {
                try? FileManager.default.removeItem(at: bodyURL)
                m.etag = nil
                m.lastModified = nil
            }
            meta = m
        }
    }

    public var lastAttempt: Date? {
        get { meta.lastAttempt }
        set {
            var m = meta
            m.lastAttempt = newValue
            meta = m
        }
    }
}
