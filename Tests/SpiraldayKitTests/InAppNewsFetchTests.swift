import Foundation
import Network
import XCTest
@testable import SpiraldayKit

/// 소식 받아 오기 (Docs/InAppNews.md §4) 를 진짜 URLSession 으로 — 이 Mac 안(127.0.0.1)의 작은 HTTP 서버에 보내
/// 줄에 실린 요청 그대로를 본다: 헤더는 정한 것뿐 · 쿠키 없음 · 넘겨주기 안 따름 · 64 KB 에서 끊음 · 시간 초과 · 실패는 조용히 그대로.
final class InAppNewsFetchTests: XCTestCase {
    private var server: LoopbackHTTPServer!

    override func setUp() async throws {
        server = try LoopbackHTTPServer()
        try await server.start()
    }

    override func tearDown() async throws {
        server.stop()
    }

    private func url(_ path: String = "/news/news.json") -> URL { URL(string: "http://127.0.0.1:\(server.port)\(path)")! }

    private static let feed = Data(#"{"version":1,"items":[{"id":"a","date":"2026-10-01","kind":"notice","importance":"normal","title":{"ko":"제목"},"body":{"ko":"본문"}}]}"#.utf8)

    func testTheRequestCarriesOnlyTheAgreedHeaders() async throws {
        server.reply = { _ in .ok(Self.feed, extra: ["ETag": "\"v1\"", "Last-Modified": "Tue, 20 Oct 2026 01:00:00 GMT",
                                                      "Set-Cookie": "track=1; Path=/"]) }
        let t = NewsURLSessionTransport()
        defer { t.invalidate() }
        let first = await NewsFetcher.fetch(url: url(), cache: nil, transport: t)
        guard case .replaced(let cache) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(cache.body, Self.feed)
        XCTAssertEqual(cache.etag, "\"v1\"")
        XCTAssertEqual(cache.lastModified, "Tue, 20 Oct 2026 01:00:00 GMT")
        // 두 번째: 조건부 헤더, 그리고 서버가 준 쿠키를 돌려보내지 않는다
        server.reply = { _ in .status(304) }
        let second = await NewsFetcher.fetch(url: url(), cache: cache, transport: t)
        XCTAssertEqual(second, .kept("HTTP 304"))

        let reqs = server.requests
        XCTAssertEqual(reqs.count, 2)
        for (i, r) in reqs.enumerated() {
            XCTAssertEqual(r.line, "GET /news/news.json HTTP/1.1", "쿼리 문자열 · 조각 없음")
            XCTAssertEqual(r.header("user-agent"), "Spiralday", "기기 · 시스템 정보 없이")
            XCTAssertEqual(r.header("accept"), "application/json")
            XCTAssertEqual(r.header("accept-language"), "*")
            XCTAssertNil(r.header("cookie"))
            XCTAssertNil(r.header("referer"))
            XCTAssertNil(r.header("authorization"))
            // URLSession 이 저절로 붙이는 연결 헤더 말고는 정한 것뿐
            let allowed: Set<String> = ["host", "user-agent", "accept", "accept-language", "accept-encoding", "connection",
                                        "if-none-match", "if-modified-since", "priority"]
            XCTAssertEqual(Set(r.headers.map { $0.0 }).subtracting(allowed), [], "요청 \(i + 1): \(r.headers)")
            XCTAssertTrue(r.body.isEmpty)
        }
        XCTAssertNil(reqs[0].header("if-none-match"))
        XCTAssertEqual(reqs[1].header("if-none-match"), "\"v1\"")
        XCTAssertEqual(reqs[1].header("if-modified-since"), "Tue, 20 Oct 2026 01:00:00 GMT")
    }

    func testRedirectsAreNotFollowed() async throws {
        server.reply = { r in r.line.contains("/elsewhere") ? .ok(Self.feed) : .status(302, extra: ["Location": "/elsewhere"]) }
        let t = NewsURLSessionTransport()
        defer { t.invalidate() }
        let r = await NewsFetcher.fetch(url: url(), cache: nil, transport: t)
        XCTAssertEqual(r, .kept("HTTP 302"))
        XCTAssertEqual(server.requests.map(\.line), ["GET /news/news.json HTTP/1.1"], "넘겨준 곳으로 가지 않는다")
    }

    func testErrorStatusesAndBrokenBodiesKeepTheCache() async throws {
        let t = NewsURLSessionTransport()
        defer { t.invalidate() }
        for status in [404, 500, 503] {
            server.reply = { _ in .status(status) }
            let r = await NewsFetcher.fetch(url: url(), cache: nil, transport: t)
            XCTAssertEqual(r, .kept("HTTP \(status)"))
        }
        server.reply = { _ in .ok(Data("<!DOCTYPE html><title>오류</title>".utf8)) }
        let html = await NewsFetcher.fetch(url: url(), cache: nil, transport: t)
        XCTAssertEqual(html, .kept("not accepted"))
        server.reply = { _ in .ok(Data(#"{"version":2,"items":[]}"#.utf8)) }
        let v2 = await NewsFetcher.fetch(url: url(), cache: nil, transport: t)
        XCTAssertEqual(v2, .kept("not accepted"))
    }

    func testBodiesOver64KBAreCutOff() async throws {
        let big = Data(#"{"version":1,"items":[]}"#.utf8) + Data(repeating: 0x20, count: NewsRules.Limits.maxBytes)
        let t = NewsURLSessionTransport()
        defer { t.invalidate() }
        // 길이를 알려 주면 받기 전에, 알려 주지 않아도 (연결을 닫을 때까지 흘리면) 65,536 바이트를 넘는 순간 끊는다
        server.reply = { _ in .ok(big) }
        let a = await NewsFetcher.fetch(url: url(), cache: nil, transport: t)
        XCTAssertEqual(a, .kept("too big"))
        server.reply = { _ in .ok(big, contentLength: false) }
        let b = await NewsFetcher.fetch(url: url(), cache: nil, transport: t)
        XCTAssertEqual(b, .kept("too big"))
        // 딱 65,536 바이트는 받는다
        let exact = Data(#"{"version":1,"items":[]}"#.utf8)
        server.reply = { _ in .ok(exact + Data(repeating: 0x20, count: NewsRules.Limits.maxBytes - exact.count), contentLength: false) }
        let c = await NewsFetcher.fetch(url: url(), cache: nil, transport: t)
        guard case .replaced = c else { return XCTFail("\(c)") }
    }

    func testATimeoutIsSilentAndBounded() async throws {
        server.reply = { _ in .hang }
        let t = NewsURLSessionTransport(timeout: 0.6)
        defer { t.invalidate() }
        let start = Date()
        let r = await NewsFetcher.fetch(url: url(), cache: nil, transport: t)
        XCTAssertEqual(r, .kept("timeout"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(NewsURLSessionTransport().timeoutInterval, 5, "앱은 5초")
    }

    func testNoServerIsSilent() async throws {
        let port = server.port
        server.stop()
        let t = NewsURLSessionTransport(timeout: 2)
        defer { t.invalidate() }
        let r = await NewsFetcher.fetch(url: URL(string: "http://127.0.0.1:\(port)/news/news.json")!, cache: nil, transport: t)
        guard case .kept = r else { return XCTFail("\(r)") }
    }

    func testALocalFileIsReadLikeA200() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spiralday-news-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = dir.appendingPathComponent("ok.json")
        try Self.feed.write(to: ok)
        guard case .replaced(let c) = NewsFetcher.readFile(ok) else { return XCTFail() }
        XCTAssertEqual(c.body, Self.feed)
        let big = dir.appendingPathComponent("big.json")
        try Data(repeating: 0x20, count: NewsRules.Limits.maxBytes + 1).write(to: big)
        XCTAssertEqual(NewsFetcher.readFile(big), .kept("too big"))
        XCTAssertEqual(NewsFetcher.readFile(dir.appendingPathComponent("none.json")), .kept("no file"))
    }
}

// MARK: - 127.0.0.1 의 작은 HTTP/1.1 서버 (시험용)

final class LoopbackHTTPServer: @unchecked Sendable {
    struct Request {
        let line: String
        let headers: [(String, String)]
        let body: Data

        func header(_ name: String) -> String? { headers.first { $0.0 == name.lowercased() }?.1 }
    }

    enum Reply {
        case response(status: Int, headers: [String: String], body: Data, contentLength: Bool)
        /// 아무것도 보내지 않고 붙잡고 있는다
        case hang

        static func ok(_ body: Data, extra: [String: String] = [:], contentLength: Bool = true) -> Reply {
            .response(status: 200, headers: extra.merging(["Content-Type": "application/json"]) { a, _ in a }, body: body,
                      contentLength: contentLength)
        }

        static func status(_ code: Int, extra: [String: String] = [:]) -> Reply {
            .response(status: code, headers: extra, body: Data(), contentLength: true)
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "spiralday.news.test.server")
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _reply: (Request) -> Reply = { _ in .status(404) }
    private var held: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var requests: [Request] { lock.withLock { _requests } }
    var reply: (Request) -> Reply {
        get { lock.withLock { _reply } }
        set { lock.withLock { _reply = newValue } }
    }

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard once.take() else { return }
                    self?.port = self?.listener.port?.rawValue ?? 0
                    c.resume()
                case .failed(let e):
                    guard once.take() else { return }
                    c.resume(throwing: e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { held.forEach { $0.cancel() }; held = [] }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, Data())
    }

    private func read(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let headers = head.dropFirst().compactMap { line -> (String, String)? in
                    guard let i = line.firstIndex(of: ":") else { return nil }
                    return (line[..<i].lowercased(), line[line.index(after: i)...].trimmingCharacters(in: .whitespaces))
                }
                let req = Request(line: head.first ?? "", headers: headers, body: Data(buf[end.upperBound...]))
                self.lock.withLock { self._requests.append(req) }
                self.respond(conn, self.reply(req))
            } else if !done, error == nil {
                self.read(conn, buf)
            } else {
                conn.cancel()
            }
        }
    }

    private func respond(_ conn: NWConnection, _ reply: Reply) {
        switch reply {
        case .hang:
            lock.withLock { held.append(conn) }
        case .response(let status, let headers, let body, let contentLength):
            var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Status")\r\n"
            for (k, v) in headers { head += "\(k): \(v)\r\n" }
            if contentLength { head += "Content-Length: \(body.count)\r\n" }
            head += "Connection: close\r\n\r\n"
            conn.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

/// 한 번만 true 를 돌려준다 (서버가 준비됐다는 알림을 한 번만 넘기게)
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func take() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
