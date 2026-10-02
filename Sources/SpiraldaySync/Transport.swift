// 서버와 말하는 부분. 엔진은 SyncTransport 만 안다 (테스트는 가짜 서버를 꽂는다).
// HTTPTransport: URLSession + URLSessionWebSocketTask (프로토콜 v1 의 HTTP 경로 · 인증 · WebSocket 알림).
import Foundation

/// 서버가 오류로 답함 ({"error": {"code", "message"}})
public struct SyncHTTPError: Error, CustomStringConvertible, Sendable {
    public let status: Int
    public let code: String
    public let message: String
    /// 429 의 Retry-After (초)
    public let retryAfter: Double?
    public let body: JSONValue?

    public init(status: Int, code: String, message: String, retryAfter: Double? = nil, body: JSONValue? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
        self.body = body
    }

    public var description: String { "HTTP \(status) \(code): \(message)" }
}

/// 서버에 닿지 못함 (오프라인 · 시간 초과 · DNS …)
public struct NetworkError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct SocketHandlers: Sendable {
    public var onOpen: @Sendable () -> Void
    public var onMessage: @Sendable (ServerPush) -> Void
    public var onClose: @Sendable (_ code: Int, _ reason: String) -> Void

    public init(onOpen: @escaping @Sendable () -> Void = {}, onMessage: @escaping @Sendable (ServerPush) -> Void,
                onClose: @escaping @Sendable (Int, String) -> Void) {
        self.onOpen = onOpen
        self.onMessage = onMessage
        self.onClose = onClose
    }
}

public protocol SocketHandle: Sendable {
    /// "ping" (연결 유지) · "head" (지금 head 를 묻는다)
    func send(_ text: String)
    /// 봉인한 초안 하나 (docs/sync-live.md §3.2 — {"draft","q"}). 보내지 못했으면 false (닫힘 · 보내기 대기가 Draft 의
    /// bufferLimit 을 넘음) → 엔진은 그 조각을 다음 틱에 다음 조각과 합쳐 다시 보낸다
    func sendDraft(_ draft: String, q: String) -> Bool
    func close()
}

extension SocketHandle {
    /// 초안을 모르는 연결 (예전 구현): 보내지 않는다
    public func sendDraft(_ draft: String, q: String) -> Bool { false }
}

/// WebSocket 하위 프로토콜 (docs/sync-protocol.md §4 · sync-live.md §2). 서버가 고르는 값은 늘 spiralday.v1
public enum WSProtocol {
    public static let v1 = "spiralday.v1"
    /// 실시간 쓰기 기능 협상: 이 값을 아는 서버는 이 연결을 live 소켓으로 받는다 (presence · 초안 중계). 옛 서버는 무시한다
    public static let live = "spiralday.live.1"
    /// 보내기 대기가 이보다 많으면 초안을 보내지 않는다 (느린 망에서 옛 초안을 쌓지 않게)
    public static let draftBufferLimit = 64 * 1024
}

public protocol SyncTransport: Sendable {
    func createGroup(deviceName: String) async throws -> JoinedRes
    func groupInfo(_ a: Auth) async throws -> GroupInfo
    func deleteGroup(_ a: Auth) async throws

    func createPairing(_ a: Auth, codeHash: String, wrappedKey: String, expiresIn: Int?, mode: PairingMode) async throws -> CreatePairingRes
    func pairingStatus(_ a: Auth, pairingId: String) async throws -> PairingStatusRes
    /// 원래 기기: 취소 · 거절
    func cancelPairing(_ a: Auth, pairingId: String) async throws
    /// 원래 기기: 확인 숫자가 같다 → 승인
    func approvePairing(_ a: Auth, pairingId: String, deviceId: String) async throws
    /// 새 기기: 합류 요청 (감싼 키는 오지 않는다)
    func claimPairing(codeHash: String, deviceName: String, mode: PairingMode, nonce: String) async throws -> ClaimRes
    /// 새 기기 (claim 의 토큰): 승인을 묻는다 → approved 면 감싼 키 (한 번만)
    func pollJoin(_ a: Auth, pairingId: String) async throws -> JoinPollRes
    /// 새 기기 (claim 의 토큰): 요청을 거둔다 (승인된 뒤면 그룹에서 빠진다)
    func withdrawJoin(_ a: Auth, pairingId: String) async throws

    func putRecord(_ a: Auth, _ w: RecordWrite) async throws -> PutRecordResult
    /// 여러 레코드 한 번에. 서버가 모르면(404 not_found · 405) nil → 하나씩 보낸다
    func putRecords(_ a: Auth, _ writes: [RecordWrite]) async throws -> PutRecordsRes?
    func changes(_ a: Auth, since: Int, limit: Int) async throws -> ChangesRes
    func history(_ a: Auth, rid: String) async throws -> [HistoryVersionRes]

    func devices(_ a: Auth) async throws -> DevicesRes
    /// deviceId 에 "me" 를 쓸 수 있다
    func renameDevice(_ a: Auth, deviceId: String, name: String) async throws
    func removeDevice(_ a: Auth, deviceId: String) async throws

    func putRecovery(_ a: Auth, recoveryId: String, gid: String, wrappedKey: String, authHash: String) async throws
    func getRecovery(recoveryId: String) async throws -> GetRecoveryRes
    func joinByRecovery(recoveryId: String, auth: String, deviceName: String) async throws -> RecoveryJoinRes

    func openSocket(_ a: Auth, handlers: SocketHandlers) -> SocketHandle
    /// live = 실시간 초안 · presence 를 받는 연결로 (하위 프로토콜에 spiralday.live.1 을 더한다)
    func openSocket(_ a: Auth, handlers: SocketHandlers, live: Bool) -> SocketHandle
}

extension SyncTransport {
    /// 실시간을 모르는 전송 (예전 구현): 보통 연결
    public func openSocket(_ a: Auth, handlers: SocketHandlers, live: Bool) -> SocketHandle { openSocket(a, handlers: handlers) }
}

// MARK: - HTTP

/// WebSocket 하나를 여는 것 (테스트에서 바꿔 끼운다). request 에 주소 · 인증 헤더가 들어 있다
public typealias WebSocketFactory = @Sendable (_ request: URLRequest, _ handlers: SocketHandlers) -> SocketHandle

public final class HTTPTransport: SyncTransport {
    public let baseURL: URL
    private let session: URLSession
    private let extraHeaders: [String: String]
    private let timeout: TimeInterval
    private let webSocket: WebSocketFactory

    /// - Parameters:
    ///   - baseURL: 예: https://sync.spiralday.com (SyncServerConfig.resolve() 참고)
    ///   - session: 바꿔 끼울 URLSession (기본: 쿠키 · 캐시 없는 ephemeral)
    ///   - extraHeaders: 모든 요청에 붙일 헤더 (개발 · 테스트)
    ///   - timeout: 요청 시간 제한 (초)
    ///   - webSocket: WebSocket 만들기 (기본: URLSessionWebSocketTask)
    public init(baseURL: URL, session: URLSession? = nil, extraHeaders: [String: String] = [:], timeout: TimeInterval = 30,
                webSocket: WebSocketFactory? = nil) {
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        self.baseURL = URL(string: s)!
        self.session = session ?? {
            let c = URLSessionConfiguration.ephemeral
            c.httpCookieStorage = nil
            c.urlCache = nil
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            c.timeoutIntervalForRequest = timeout
            c.waitsForConnectivity = false
            return URLSession(configuration: c)
        }()
        self.extraHeaders = extraHeaders
        self.timeout = timeout
        self.webSocket = webSocket ?? { req, h in URLSessionSocket.open(request: req, handlers: h) }
    }

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? s
    }

    private func g(_ a: Auth) -> String { "/v1/groups/\(Self.enc(a.gid))" }

    struct Reply {
        let status: Int
        let json: JSONValue?
    }

    private func call(_ method: String, _ path: String, body: JSONValue? = nil, token: String? = nil, allow409: Bool = false) async throws -> Reply {
        guard let url = URL(string: baseURL.absoluteString + path) else { throw NetworkError("주소가 틀림: \(path)") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.jsonData()
        }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let res: URLResponse
        do {
            (data, res) = try await session.data(for: req)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw NetworkError("서버에 닿지 못함: \(error.localizedDescription)")
        }
        guard let http = res as? HTTPURLResponse else { throw NetworkError("HTTP 응답이 아님") }
        let json = data.isEmpty ? nil : try? JSONValue.parse(data)
        if (200..<300).contains(http.statusCode) || (allow409 && http.statusCode == 409) {
            return Reply(status: http.statusCode, json: json)
        }
        let err = json?["error"]
        let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? err?["retryAfter"]?.numberValue
        throw SyncHTTPError(status: http.statusCode, code: err?.optStr("code") ?? "http_\(http.statusCode)",
                            message: err?.optStr("message") ?? "HTTP \(http.statusCode)", retryAfter: ra, body: json)
    }

    /// 응답 본문을 모양에 맞게 읽는다 (틀리면 서버 오류로)
    private func read<T>(_ r: Reply, _ f: (JSONValue) throws -> T) throws -> T {
        do {
            guard let j = r.json else { throw ResponseShapeError(what: "본문") }
            return try f(j)
        } catch let e as ResponseShapeError {
            throw SyncHTTPError(status: 502, code: "invalid_response", message: "서버 응답 모양이 틀림 (\(e.what))", body: r.json)
        }
    }

    public func createGroup(deviceName: String) async throws -> JoinedRes {
        try read(try await call("POST", "/v1/groups", body: ["deviceName": .string(deviceName)]), JoinedRes.init(json:))
    }

    public func groupInfo(_ a: Auth) async throws -> GroupInfo {
        try read(try await call("GET", g(a), token: a.token), GroupInfo.init(json:))
    }

    public func deleteGroup(_ a: Auth) async throws {
        _ = try await call("DELETE", g(a), token: a.token)
    }

    public func createPairing(_ a: Auth, codeHash: String, wrappedKey: String, expiresIn: Int?, mode: PairingMode) async throws -> CreatePairingRes {
        var body: [String: JSONValue] = ["codeHash": .string(codeHash), "wrappedKey": .string(wrappedKey), "mode": .string(mode.rawValue)]
        if let expiresIn { body["expiresIn"] = JSONValue(expiresIn) }
        return try read(try await call("POST", g(a) + "/pairings", body: .object(body), token: a.token), CreatePairingRes.init(json:))
    }

    public func pairingStatus(_ a: Auth, pairingId: String) async throws -> PairingStatusRes {
        try read(try await call("GET", g(a) + "/pairings/\(Self.enc(pairingId))", token: a.token), PairingStatusRes.init(json:))
    }

    public func cancelPairing(_ a: Auth, pairingId: String) async throws {
        _ = try await call("DELETE", g(a) + "/pairings/\(Self.enc(pairingId))", token: a.token)
    }

    public func approvePairing(_ a: Auth, pairingId: String, deviceId: String) async throws {
        _ = try await call("POST", g(a) + "/pairings/\(Self.enc(pairingId))/approve", body: ["deviceId": .string(deviceId)], token: a.token)
    }

    public func claimPairing(codeHash: String, deviceName: String, mode: PairingMode, nonce: String) async throws -> ClaimRes {
        let body: JSONValue = ["codeHash": .string(codeHash), "deviceName": .string(deviceName), "mode": .string(mode.rawValue), "nonce": .string(nonce)]
        return try read(try await call("POST", "/v1/pairings/claim", body: body), ClaimRes.init(json:))
    }

    public func pollJoin(_ a: Auth, pairingId: String) async throws -> JoinPollRes {
        try read(try await call("POST", g(a) + "/pairings/\(Self.enc(pairingId))/join", token: a.token), JoinPollRes.init(json:))
    }

    public func withdrawJoin(_ a: Auth, pairingId: String) async throws {
        _ = try await call("DELETE", g(a) + "/pairings/\(Self.enc(pairingId))/join", token: a.token)
    }

    public func putRecord(_ a: Auth, _ w: RecordWrite) async throws -> PutRecordResult {
        let r = try await call("POST", g(a) + "/records", body: Self.writeBody(w), token: a.token, allow409: true)
        if r.status == 409 {
            // 서버는 seq · ct 를 맨 위에 둔다 (오류 객체 안에 둔 서버도 받아 준다)
            let j = r.json ?? .object([:])
            let inner = j["error"] ?? .object([:])
            guard let seq = j.optInt("seq") ?? inner.optInt("seq") else {
                throw SyncHTTPError(status: 409, code: "conflict", message: "409 응답에 seq 가 없음", body: j)
            }
            return .conflict(seq: seq, ct: j.optStr("ct") ?? inner.optStr("ct"))
        }
        return .ok(seq: try read(r) { try $0.int("seq") })
    }

    public func putRecords(_ a: Auth, _ writes: [RecordWrite]) async throws -> PutRecordsRes? {
        let body: JSONValue = ["writes": .array(writes.map(Self.writeBody))]
        do {
            return try read(try await call("POST", g(a) + "/records/batch", body: body, token: a.token), PutRecordsRes.init(json:))
        } catch let e as SyncHTTPError where e.status == 405 || (e.status == 404 && e.code == "not_found") {
            return nil
        }
    }

    static func writeBody(_ w: RecordWrite) -> JSONValue {
        var o: [String: JSONValue] = ["rid": .string(w.rid), "baseSeq": JSONValue(w.baseSeq), "ct": .string(w.ct)]
        if w.keep { o["keep"] = true }
        return .object(o)
    }

    public func changes(_ a: Auth, since: Int, limit: Int) async throws -> ChangesRes {
        try read(try await call("GET", g(a) + "/changes?since=\(since)&limit=\(limit)", token: a.token), ChangesRes.init(json:))
    }

    public func history(_ a: Auth, rid: String) async throws -> [HistoryVersionRes] {
        try read(try await call("GET", g(a) + "/records/\(Self.enc(rid))/history", token: a.token), HistoryVersionRes.list(json:))
    }

    public func devices(_ a: Auth) async throws -> DevicesRes {
        try read(try await call("GET", g(a) + "/devices", token: a.token), DevicesRes.init(json:))
    }

    public func renameDevice(_ a: Auth, deviceId: String, name: String) async throws {
        _ = try await call("PATCH", g(a) + "/devices/\(Self.enc(deviceId))", body: ["name": .string(name)], token: a.token)
    }

    public func removeDevice(_ a: Auth, deviceId: String) async throws {
        _ = try await call("DELETE", g(a) + "/devices/\(Self.enc(deviceId))", token: a.token)
    }

    public func putRecovery(_ a: Auth, recoveryId: String, gid: String, wrappedKey: String, authHash: String) async throws {
        let body: JSONValue = ["gid": .string(gid), "wrappedKey": .string(wrappedKey), "authHash": .string(authHash)]
        _ = try await call("PUT", "/v1/recovery/\(Self.enc(recoveryId))", body: body, token: a.token)
    }

    public func getRecovery(recoveryId: String) async throws -> GetRecoveryRes {
        try read(try await call("GET", "/v1/recovery/\(Self.enc(recoveryId))"), GetRecoveryRes.init(json:))
    }

    public func joinByRecovery(recoveryId: String, auth: String, deviceName: String) async throws -> RecoveryJoinRes {
        let body: JSONValue = ["auth": .string(auth), "deviceName": .string(deviceName)]
        return try read(try await call("POST", "/v1/recovery/\(Self.enc(recoveryId))/join", body: body), RecoveryJoinRes.init(json:))
    }

    /// WebSocket: 네이티브는 Authorization: Bearer 헤더로. 토큰은 주소에 넣지 않는다
    public func openSocket(_ a: Auth, handlers: SocketHandlers) -> SocketHandle {
        openSocket(a, handlers: handlers, live: false)
    }

    /// live: 하위 프로토콜 목록 "spiralday.v1, spiralday.live.1" 을 함께 보낸다 (docs/sync-live.md §2). 새 서버는 spiralday.v1 을 골라
    /// 돌려주고 {"head"} 다음에 {"peers"} 를 보낸다. 옛 서버는 Bearer 연결에 하위 프로토콜을 돌려주지 않지만 연결은 그대로 열린다
    /// ({"peers"} 가 오지 않음 = 중계 없음)
    public func openSocket(_ a: Auth, handlers: SocketHandlers, live: Bool) -> SocketHandle {
        var s = baseURL.absoluteString
        if s.hasPrefix("https") { s = "wss" + s.dropFirst(5) } else if s.hasPrefix("http") { s = "ws" + s.dropFirst(4) }
        var req = URLRequest(url: URL(string: s + g(a) + "/ws")!, timeoutInterval: timeout)
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("Bearer \(a.token)", forHTTPHeaderField: "Authorization")
        if live { req.setValue("\(WSProtocol.v1), \(WSProtocol.live)", forHTTPHeaderField: "Sec-WebSocket-Protocol") }
        return webSocket(req, handlers)
    }
}

// MARK: - URLSessionWebSocketTask

/// WebSocket 하나 (세션 하나). 닫힘은 한 번만 알린다. 우리가 닫은 것은 알리지 않는다
final class URLSessionSocket: NSObject, SocketHandle, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let handlers: SocketHandlers

    private init(handlers: SocketHandlers) {
        self.handlers = handlers
    }

    static func open(request: URLRequest, handlers: SocketHandlers) -> URLSessionSocket {
        let s = URLSessionSocket(handlers: handlers)
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCache = nil
        let session = URLSession(configuration: c, delegate: s, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        s.lock.withLock {
            s.session = session
            s.task = task
        }
        task.resume()
        s.receive()
        return s
    }

    private func receive() {
        guard let task = lock.withLock({ closed ? nil : self.task }) else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(.string(text)):
                if text != "pong" { self.handlers.onMessage(ServerPush.parse(text)) }
                self.receive()
            case .success:
                self.receive()
            case .failure:
                let code = task.closeCode.rawValue
                self.finish(code: code == 0 ? 1006 : code, reason: task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            }
        }
    }

    private func finish(code: Int, reason: String) {
        let already = lock.withLock {
            let was = closed
            closed = true
            return was
        }
        if already { return }
        handlers.onClose(code, reason)
        lock.withLock { session }?.invalidateAndCancel()
    }

    func send(_ text: String) {
        guard let task = lock.withLock({ closed ? nil : self.task }) else { return }
        task.send(.string(text)) { _ in }
    }

    /// 아직 보내지 못한 글자 (URLSessionWebSocketTask 에는 bufferedAmount 가 없어 직접 센다)
    private var buffered = 0

    func sendDraft(_ draft: String, q: String) -> Bool {
        let frame = JSONValue.object(["draft": .string(draft), "q": .string(q)]).canonical
        let n = frame.utf8.count
        let task: URLSessionWebSocketTask? = lock.withLock {
            if closed || buffered + n > WSProtocol.draftBufferLimit { return nil }
            buffered += n
            return self.task
        }
        guard let task else { return false }
        task.send(.string(frame)) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.buffered -= n }
        }
        return true
    }

    func close() {
        let (t, s) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            if closed { return (nil, nil) }
            closed = true
            return (task, session)
        }
        t?.cancel(with: .normalClosure, reason: "bye".data(using: .utf8))
        s?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        if lock.withLock({ closed }) { return }
        handlers.onOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(code: closeCode.rawValue == 0 ? 1006 : closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 업그레이드 거절 (401 등) · 네트워크 → 1006
        let code = (task as? URLSessionWebSocketTask)?.closeCode.rawValue ?? 0
        finish(code: code == 0 ? 1006 : code, reason: error?.localizedDescription ?? "")
    }
}
