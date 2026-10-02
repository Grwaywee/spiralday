// 메모리 안의 가짜 Spiralday Sync 서버 (테스트 · 앱 개발용).
// 프로토콜 v1 의 경로 · JSON · 상태 코드를 따른다. URLProtocol 로 URLSession 요청을 가로채므로
// HTTPTransport 를 그대로 쓴다:
//   let server = FakeSyncServer()
//   let transport = server.transport(ip: "10.0.0.1")
import Foundation
import SpiraldaySync

public struct FakeServerLimits: Sendable {
    public var maxDevices = 10
    public var maxGroupBytes = 50 * 1024 * 1024
    /// 두 번째 기기가 들어오기 전의 그룹 용량
    public var provisionalGroupBytes = 5 * 1024 * 1024
    public var maxRecordBytes = 1024 * 1024
    public var maxActivePairings = 3
    public var historyMs = 30 * 86_400_000
    public var historyPerRecord = 100
    public var historyCoalesceMs = 2 * 60_000
    // 남용 막기 상한 (요청 제한): 운영 서버의 값은 서버 설정이라 여기에 두지 않는다. 기본은 제한 없음(0) —
    // 요청 제한을 보는 테스트가 필요한 값을 직접 넣는다 (예: codeFailPerHour = 2)
    /// IP 당 10분에 claim 시도 수 (0 = 제한 없음)
    public var claimPer10Min = 0
    /// IP 당 시간에 8자 코드 합류 실패 수 (0 = 제한 없음)
    public var codeFailPerHour = 0
    /// 서버 전체 10분에 8자 코드 합류 실패 수 (0 = 제한 없음)
    public var codeFailGlobalPer10Min = 0
    /// 합류 요청 뒤 승인 기한 (초)
    public var pairingApproveSec = 180
    /// 승인 뒤 감싼 키를 받아 갈 기한 (초). 받은 뒤 이만큼은 다시 준다
    public var pairingDeliverSec = 120
    /// 키를 받은 새 기기가 수락할 때까지 (초). 못 하면 뺀다
    public var pairingAcceptSec = 30 * 60
    public init() {}
}

/// 기기 하나의 네트워크 (끊기 · 요청 실패 흉내)
public final class FakeNet: @unchecked Sendable {
    private let lock = NSLock()
    private var _offline = false
    private var _fail: (@Sendable (String, String) -> Bool)?
    private var _dropResponse: (@Sendable (String, String) -> Bool)?
    public let id = UUID().uuidString

    public init() {}

    /// 오프라인 (요청 · WebSocket 모두 실패)
    public var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }

    /// (method, path) 가 맞으면 요청이 서버에 닿지 못한 것처럼
    public var fail: (@Sendable (String, String) -> Bool)? {
        get { lock.withLock { _fail } }
        set { lock.withLock { _fail = newValue } }
    }

    /// (method, path) 가 맞으면 서버는 처리했는데 응답만 잃은 것처럼 (한 번)
    public var dropResponse: (@Sendable (String, String) -> Bool)? {
        get { lock.withLock { _dropResponse } }
        set { lock.withLock { _dropResponse = newValue } }
    }

    func takeDrop(_ m: String, _ p: String) -> Bool {
        lock.withLock {
            guard let d = _dropResponse, d(m, p) else { return false }
            _dropResponse = nil
            return true
        }
    }

    /// 말 안 듣는 네트워크: 요청이 늦게 · 뒤섞여 · 두 번 · 아예 안 닿거나 응답만 사라진다 (씨앗을 정한 난수)
    public struct Chaos: Sendable {
        public var dropRequest = 0.0
        public var dropResponse = 0.0
        /// 서버가 같은 요청을 두 번 처리한다 (응답은 첫 번째 또는 두 번째)
        public var duplicate = 0.0
        /// 0…maxDelayMs 만큼 늦게 (그 사이 다른 요청이 앞지른다)
        public var maxDelayMs = 0
        public var seed: UInt64 = 1
        public init(dropRequest: Double = 0, dropResponse: Double = 0, duplicate: Double = 0, maxDelayMs: Int = 0, seed: UInt64 = 1) {
            self.dropRequest = dropRequest
            self.dropResponse = dropResponse
            self.duplicate = duplicate
            self.maxDelayMs = maxDelayMs
            self.seed = seed
        }
    }

    private var _chaos: Chaos?
    private var rngState: UInt64 = 0

    public var chaos: Chaos? {
        get { lock.withLock { _chaos } }
        set {
            lock.withLock {
                _chaos = newValue
                rngState = newValue?.seed ?? 0
            }
        }
    }

    /// 0..<1 난수 (SplitMix64)
    func random() -> Double {
        lock.withLock {
            rngState &+= 0x9E37_79B9_7F4A_7C15
            var z = rngState
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }
}

struct HttpErr: Error {
    let status: Int
    let code: String
    let message: String
    var extra: [String: JSONValue] = [:]
    var headers: [String: String] = [:]
}

public final class FakeSyncServer: @unchecked Sendable {
    public struct Device: Sendable {
        public let id: String
        public var name: String
        /// 들어올 때의 플랫폼 (이름을 암호화한 뒤에도 남는다)
        var platform: String?
        let tokenHash: String
        let created: Int
        var lastSeen: Int
    }

    struct Rec {
        var seq: Int
        var ct: String
        var size: Int
        var at: Int
        var writer: String
    }

    struct Hist {
        var seq: Int
        var ct: String
        var size: Int
        var at: Int
        var gone: Int
    }

    public struct Pairing: Sendable {
        public let id: String
        let codeHash: String
        public var wrappedKey: String?
        var expires: Int
        let mode: String
        public var status: String
        public var deviceId: String?
        var deviceName: String?
        var tokenHash: String?
        var nonce: String?
        var deliveredAt: Int?
        var acceptedAt: Int?
        /// 색인에 등록했는지 (같은 코드 해시가 다른 그룹에 살아 있으면 조용히 등록하지 않는다)
        var indexed = true
    }

    final class Group {
        let gid: String
        let created: Int
        var head = 0
        var bytes = 0
        var lastAccess: Int
        var recoveryId: String?
        /// 두 번째 기기가 들어온 적이 있음 → 용량 maxGroupBytes
        var paired = false
        var devices: [String: Device] = [:]
        var deviceOrder: [String] = []
        var revoked = Set<String>()
        var records: [String: Rec] = [:]
        var history: [String: [Hist]] = [:]
        var pairings: [String: Pairing] = [:]
        var sockets: [FakeSocket] = []

        init(gid: String, created: Int) {
            self.gid = gid
            self.created = created
            lastAccess = created
        }
    }

    public struct LogEntry: Sendable {
        public let method: String
        public let path: String
        public let body: JSONValue?
        public let status: Int
    }

    private let lock = NSRecursiveLock()
    var groups: [String: Group] = [:]
    var pairingIndex: [String: (gid: String, pairingId: String, expires: Int, mode: String)] = [:]
    var recovery: [String: (gid: String, wrappedKey: String, authHash: String)] = [:]
    public let limits: FakeServerLimits
    private var _batch = true
    private var _conflicts = 0
    private var _log: [LogEntry] = []
    private var claimHits: [String: [Int]] = [:]
    private var codeFails: [String: [Int]] = [:]
    private var globalCodeFails: [Int] = []
    private let nowFn: @Sendable () -> Int
    public let host: String

    public init(limits: FakeServerLimits = FakeServerLimits(), now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
        self.limits = limits
        nowFn = now
        host = "fake-\(UUID().uuidString.lowercased()).sync.test"
        FakeURLProtocol.register(self)
    }

    deinit { FakeURLProtocol.unregister(host) }

    func now() -> Int { nowFn() }

    /// records/batch 를 받는지 (false 면 404 → 엔진은 하나씩 보낸다)
    public var batch: Bool {
        get { lock.withLock { _batch } }
        set { lock.withLock { _batch = newValue } }
    }

    /// baseSeq 가 맞지 않아 거절한 쓰기 수
    public var conflicts: Int { lock.withLock { _conflicts } }

    /// 요청 기록 (테스트에서 서버가 본 것을 검사)
    public var log: [LogEntry] { lock.withLock { _log } }

    public var groupCount: Int { lock.withLock { groups.count } }

    /// 서버가 가진 것 모두를 글로 (평문이 새지 않는지 볼 때)
    public func dump() -> String {
        lock.withLock {
            var out = _log.map { "\($0.method) \($0.path) \($0.body?.canonical ?? "")" }.joined(separator: "\n")
            for g in groups.values {
                for d in g.devices.values { out += "\n" + d.name }
                for r in g.records.values { out += "\n" + r.ct }
            }
            return out
        }
    }

    /// 그룹의 기기 이름들 (서버에 있는 그대로)
    public func deviceNames(gid: String) -> [String] {
        lock.withLock { groups[gid].map { g in g.deviceOrder.compactMap { g.devices[$0]?.name } } ?? [] }
    }

    public func deviceCount(gid: String) -> Int { lock.withLock { groups[gid]?.devices.count ?? 0 } }

    public func pairings(gid: String) -> [Pairing] { lock.withLock { groups[gid].map { Array($0.pairings.values) } ?? [] } }

    /// 서버의 기기 이름을 바꿔치기한다 (악의적인 서버 흉내)
    public func swapDeviceNames(gid: String) {
        lock.withLock {
            guard let g = groups[gid], g.deviceOrder.count >= 2 else { return }
            let a = g.deviceOrder[0], b = g.deviceOrder[1]
            let na = g.devices[a]!.name
            g.devices[a]!.name = g.devices[b]!.name
            g.devices[b]!.name = na
        }
    }

    /// 레코드 암호문 (rid → ct)
    public func recordCiphertext(gid: String, rid: String) -> (seq: Int, ct: String)? {
        lock.withLock { groups[gid]?.records[rid].map { ($0.seq, $0.ct) } }
    }

    /// 백업에서 되돌린 것처럼: 레코드를 모두 잃고 head 가 0
    public func rollback(gid: String) {
        lock.withLock {
            guard let g = groups[gid] else { return }
            g.records = [:]
            g.head = 0
        }
    }

    public func head(gid: String) -> Int { lock.withLock { groups[gid]?.head ?? 0 } }

    // MARK: - 전송

    /// 이 서버로 가는 HTTPTransport (ip: 요청 제한을 셀 IP, net: 끊기 흉내)
    public func transport(ip: String = "10.0.0.1", net: FakeNet = FakeNet()) -> HTTPTransport {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeURLProtocol.self]
        FakeURLProtocol.registerNet(net)
        let server = self
        return HTTPTransport(
            baseURL: URL(string: "https://\(host)")!,
            session: URLSession(configuration: c),
            extraHeaders: ["X-Fake-IP": ip, "X-Fake-Net": net.id],
            timeout: 10,
            webSocket: { req, h in server.openSocket(req, handlers: h, net: net) })
    }

    // MARK: - HTTP

    public struct Response {
        public let status: Int
        public let headers: [String: String]
        public let body: Data
    }

    func json(_ status: Int, _ body: JSONValue, _ headers: [String: String] = [:]) -> Response {
        var h = headers
        h["Content-Type"] = "application/json; charset=utf-8"
        return Response(status: status, headers: h, body: body.jsonData())
    }

    /// 요청 하나 처리 (진짜 서버처럼 JSON 으로 답한다)
    public func handle(method: String, url: URL, headers: [String: String], body: Data?) -> Response {
        lock.lock()
        defer { lock.unlock() }
        var parsed: JSONValue?
        var status = 500
        let path = url.path
        defer { _log.append(LogEntry(method: method, path: path, body: parsed, status: status)) }
        do {
            if let body, !body.isEmpty, method != "GET", method != "DELETE" {
                guard let v = try? JSONValue.parse(body) else { throw HttpErr(status: 400, code: "invalid_json", message: "JSON 을 읽을 수 없습니다.") }
                guard case .object = v else { throw HttpErr(status: 400, code: "invalid_json", message: "JSON 객체여야 합니다.") }
                parsed = v
            }
            let res = try route(method, url, headers, parsed?.objectValue ?? [:])
            status = res.status
            return res
        } catch let e as HttpErr {
            status = e.status
            var error: [String: JSONValue] = ["code": .string(e.code), "message": .string(e.message)]
            var top: [String: JSONValue] = [:]
            for (k, v) in e.extra {
                if k == "retryAfter" { error["retryAfter"] = v } else { top[k] = v }
            }
            top["error"] = .object(error)
            return json(e.status, .object(top), e.headers)
        } catch {
            status = 500
            return json(500, ["error": ["code": "internal", "message": .string("\(error)")]])
        }
    }

    // MARK: 도우미

    func sha(_ s: String) -> String { Base64URL.encode(SyncCrypto.sha256(Array(s.utf8))) }
    func randomId() -> String { Base64URL.encode(SyncCrypto.randomBytes(16)) }
    func randomToken() -> String { Base64URL.encode(SyncCrypto.randomBytes(32)) }

    static func isId22(_ s: String) -> Bool { s.utf8.count == 22 && s.utf8.allSatisfy(isB64) }
    static func isKey43(_ s: String) -> Bool { s.utf8.count == 43 && s.utf8.allSatisfy(isB64) }
    static func isB64(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
    }

    func deviceByToken(_ g: Group, _ token: String) -> Device? {
        let th = sha(token)
        return g.devices.values.first { $0.tokenHash == th }
    }

    func group(_ gid: String?) throws -> Group {
        guard let gid, Self.isId22(gid), let g = groups[gid] else { throw HttpErr(status: 404, code: "group_not_found", message: "동기화 그룹이 없습니다.") }
        return g
    }

    func bearer(_ headers: [String: String]) -> String? {
        let h = headers.first { $0.key.lowercased() == "authorization" }?.value ?? ""
        guard h.lowercased().hasPrefix("bearer ") else { return nil }
        let t = h.dropFirst(7).trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.contains(" ") ? nil : t
    }

    private var brokenTokens = Set<String>()
    /// 테스트: 그 그룹의 모든 토큰을 알아보지 못하는 척 (서버 사고 — 401 unauthorized, device_removed 아님)
    public func setTokensBroken(gid: String, _ on: Bool) {
        lock.withLock {
            if on { brokenTokens.insert(gid) } else { brokenTokens.remove(gid) }
        }
    }

    func quota(_ g: Group) -> Int { g.paired ? limits.maxGroupBytes : min(limits.provisionalGroupBytes, limits.maxGroupBytes) }

    func auth(_ g: Group, _ headers: [String: String], accept: Bool = true) throws -> Device {
        guard let token = bearer(headers), Self.isKey43(token) else {
            throw HttpErr(status: 401, code: "unauthorized", message: "기기 토큰이 없거나 형식이 맞지 않습니다.")
        }
        if brokenTokens.contains(g.gid) { throw HttpErr(status: 401, code: "unauthorized", message: "기기 토큰이 맞지 않습니다.") }
        guard var dev = deviceByToken(g, token) else {
            if g.revoked.contains(sha(token)) { throw HttpErr(status: 401, code: "device_removed", message: "이 기기는 동기화 그룹에서 제거되었습니다.") }
            throw HttpErr(status: 401, code: "unauthorized", message: "기기 토큰이 맞지 않습니다.")
        }
        dev.lastSeen = now()
        g.devices[dev.id] = dev
        g.lastAccess = now()
        if accept {
            // 페어링으로 막 들어온 기기의 첫 그룹 요청 (기기 목록 말고) = 수락
            for (id, var p) in g.pairings where p.status == "approved" && p.deviceId == dev.id && p.acceptedAt == nil {
                p.acceptedAt = now()
                p.wrappedKey = nil
                g.pairings[id] = p
            }
        }
        return dev
    }

    func str(_ o: [String: JSONValue], _ k: String, _ min: Int, _ max: Int, _ check: ((String) -> Bool)? = nil) throws -> String {
        guard case let .string(v)? = o[k] else { throw HttpErr(status: 400, code: "invalid_field", message: "\(k): 문자열이어야 합니다", extra: ["field": .string(k)]) }
        let n = v.utf16.count
        if n < min || n > max || !(check?(v) ?? true) {
            throw HttpErr(status: 400, code: "invalid_field", message: "\(k): 형식이 맞지 않습니다", extra: ["field": .string(k)])
        }
        return v
    }

    static let platforms: Set<String> = ["Mac", "Windows", "iPhone", "iPad", "Android", "Web"]
    static func isPlatformName(_ v: String) -> Bool { v.hasPrefix("p.") && platforms.contains(String(v.dropFirst(2))) }

    /// 처음 들어오는 기기 이름: "p.<플랫폼>" 목록만
    func platformName(_ o: [String: JSONValue], _ k: String = "deviceName") throws -> String {
        let v = try str(o, k, 1, 256)
        guard Self.isPlatformName(v) else { throw HttpErr(status: 400, code: "invalid_field", message: "\(k): \"p.<플랫폼>\" 이어야 합니다", extra: ["field": .string(k)]) }
        return v
    }

    /// 이름 바꾸기: 암호화한 이름("e1.…") 또는 플랫폼 이름
    func name(_ o: [String: JSONValue], _ k: String = "deviceName") throws -> String {
        let v = try str(o, k, 1, 256)
        let encrypted = v.hasPrefix("e1.") && v.utf8.count > 3 && v.utf8.dropFirst(3).allSatisfy(Self.isB64)
        guard encrypted || Self.isPlatformName(v) else {
            throw HttpErr(status: 400, code: "invalid_field", message: "\(k): \"e1.<암호문>\" 이나 \"p.<플랫폼>\" 이어야 합니다", extra: ["field": .string(k)])
        }
        return v
    }

    func wrapped(_ o: [String: JSONValue]) throws -> String {
        let v = try str(o, "wrappedKey", 16, 1024) { $0.utf8.allSatisfy(Self.isB64) }
        guard Base64URL.decode(v) != nil else { throw HttpErr(status: 400, code: "invalid_field", message: "wrappedKey: base64url 이어야 합니다") }
        return v
    }

    func mode(_ o: [String: JSONValue]) throws -> String {
        guard case let .string(v)? = o["mode"], v == "qr" || v == "code" else {
            throw HttpErr(status: 400, code: "invalid_field", message: "mode: qr · code 중 하나여야 합니다", extra: ["field": "mode"])
        }
        return v
    }

    func broadcast(_ g: Group, _ msg: JSONValue) {
        let s = msg.canonical
        for sock in g.sockets { sock.serverSend(s) }
    }

    func revoke(_ g: Group, _ deviceId: String) throws {
        guard let d = g.devices[deviceId] else { throw HttpErr(status: 404, code: "device_not_found", message: "그런 기기가 없습니다.") }
        g.devices[deviceId] = nil
        g.deviceOrder.removeAll { $0 == deviceId }
        g.revoked.insert(d.tokenHash)
        for s in g.sockets where s.deviceId == deviceId {
            s.serverSend(#"{"removed":true}"#)
            s.serverClose(4401, "device_removed")
        }
        g.sockets.removeAll { $0.deviceId == deviceId }
        broadcast(g, ["devices": true])
    }

    func destroy(_ g: Group) {
        for s in g.sockets {
            s.serverSend(#"{"deleted":true}"#)
            s.serverClose(4404, "group_deleted")
        }
        g.sockets = []
        for p in g.pairings.values { unindex(p) }
        if let r = g.recoveryId { recovery[r] = nil }
        groups[g.gid] = nil
    }

    func gcHistory(_ g: Group) {
        let n = now()
        for (rid, list) in g.history {
            let keep = list.filter { $0.gone > n - limits.historyMs }
            for h in list where !(h.gone > n - limits.historyMs) { g.bytes -= h.size }
            g.history[rid] = keep.isEmpty ? nil : keep
        }
    }

    func addDevice(_ g: Group, id: String, name: String, tokenHash: String) {
        let n = now()
        g.devices[id] = Device(id: id, name: name, platform: name.hasPrefix("p.") ? String(name.dropFirst(2)) : nil, tokenHash: tokenHash, created: n, lastSeen: n)
        g.deviceOrder.append(id)
    }

    // MARK: 경로

    func route(_ m: String, _ url: URL, _ headers: [String: String], _ body: [String: JSONValue]) throws -> Response {
        let seg = url.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard seg.first == "v1" else { throw HttpErr(status: 404, code: "not_found", message: "없는 경로입니다.") }
        func at(_ i: Int) -> String? { i < seg.count ? seg[i] : nil }
        let a = at(1), b = at(2), c = at(3), d = at(4), e = at(5)

        if a == "groups", seg.count == 2, m == "POST" {
            let nm = try platformName(body)
            let gid = randomId(), token = randomToken(), deviceId = randomId()
            let g = Group(gid: gid, created: now())
            addDevice(g, id: deviceId, name: nm, tokenHash: sha(token))
            groups[gid] = g
            return json(201, ["gid": .string(gid), "deviceId": .string(deviceId), "token": .string(token)])
        }

        if a == "pairings", b == "claim", seg.count == 3, m == "POST" {
            if body["code"] != nil {
                throw HttpErr(status: 400, code: "invalid_field", message: "code: 코드 원문은 서버로 보내지 않습니다. codeHash 를 보내세요", extra: ["field": "code"])
            }
            let codeHash = try str(body, "codeHash", 43, 43, Self.isKey43)
            let nm = try platformName(body)
            let md = try mode(body)
            let nonce = try str(body, "nonce", 22, 22, Self.isId22)
            let ip = headers["X-Fake-IP"] ?? "local"
            try limitClaim(ip)
            if md == "code" { try reserveCodeAttempt(ip) }
            let notFound = HttpErr(status: 404, code: "pairing_not_found", message: "코드가 맞지 않거나 만료되었습니다.")
            guard let ref = pairingIndex[codeHash], ref.expires > now(), ref.mode == md else { throw notFound }
            let g = groups[ref.gid]
            if let g { sweep(g) }
            guard let g, var p = g.pairings[ref.pairingId], p.status == "pending", p.expires > now(), p.wrappedKey != nil, p.indexed else { throw notFound }
            if g.devices.count >= limits.maxDevices {
                if md == "code" { refundCodeAttempt(ip) }
                throw HttpErr(status: 409, code: "device_limit", message: "기기는 \(limits.maxDevices)대까지 연결할 수 있습니다.")
            }
            if md == "code" { refundCodeAttempt(ip) }
            let token = randomToken(), deviceId = randomId()
            p.status = "claimed"
            p.deviceId = deviceId
            p.deviceName = nm
            p.tokenHash = sha(token)
            p.nonce = nonce
            p.expires = max(p.expires, now() + limits.pairingApproveSec * 1000)
            g.pairings[p.id] = p
            pairingIndex[codeHash] = nil
            broadcast(g, ["pairing": .string(p.id), "status": "claimed"])
            return json(200, ["gid": .string(g.gid), "pairingId": .string(p.id), "deviceId": .string(deviceId), "token": .string(token), "expiresAt": JSONValue(p.expires)])
        }

        if a == "recovery", let b {
            guard Self.isKey43(b) else { throw HttpErr(status: 404, code: "recovery_not_found", message: "복구 정보가 없습니다.") }
            if seg.count == 3, m == "PUT" {
                let gid = try str(body, "gid", 22, 22, Self.isId22)
                let wk = try wrapped(body)
                let authHash = try str(body, "authHash", 43, 43, Self.isKey43)
                let g = try group(gid)
                _ = try auth(g, headers)
                if let cur = recovery[b], cur.gid != gid {
                    throw HttpErr(status: 409, code: "recovery_in_use", message: "이 복구 id 는 다른 그룹이 쓰고 있습니다.")
                }
                recovery[b] = (gid, wk, authHash)
                let old = g.recoveryId
                g.recoveryId = b
                if let old, old != b { recovery[old] = nil }
                return json(200, ["recoveryId": .string(b), "replaced": .bool(old != nil && old != b)])
            }
            if seg.count == 3, m == "GET" {
                // 그룹의 지금 복구 id 일 때만 (새로 만든 뒤의 옛 코드는 통하지 않는다)
                guard let v = recovery[b], groups[v.gid]?.recoveryId == b else {
                    throw HttpErr(status: 404, code: "recovery_not_found", message: "복구 정보가 없습니다. 복구 코드를 다시 확인하세요.")
                }
                return json(200, ["gid": .string(v.gid), "wrappedKey": .string(v.wrappedKey)])
            }
            if seg.count == 4, c == "join", m == "POST" {
                let authV = try str(body, "auth", 43, 43, Self.isKey43)
                let nm = try platformName(body)
                let ah = Base64URL.encode(SyncCrypto.sha256(Base64URL.decode(authV) ?? []))
                guard let v = recovery[b], v.authHash == ah else { throw HttpErr(status: 403, code: "forbidden", message: "복구 증명이 맞지 않습니다.") }
                let g = try group(v.gid)
                guard g.recoveryId == b else { throw HttpErr(status: 403, code: "forbidden", message: "복구 증명이 맞지 않습니다.") }
                var evicted: String?
                if g.devices.count >= limits.maxDevices {
                    evicted = g.devices.values.sorted { ($0.lastSeen, $0.created) < ($1.lastSeen, $1.created) }.first!.id
                    try revoke(g, evicted!)
                }
                let token = randomToken(), deviceId = randomId()
                addDevice(g, id: deviceId, name: nm, tokenHash: sha(token))
                g.lastAccess = now()
                if g.devices.count >= 2 { g.paired = true }
                broadcast(g, ["devices": true])
                return json(200, ["gid": .string(g.gid), "deviceId": .string(deviceId), "token": .string(token), "evicted": evicted.map { .string($0) } ?? .null])
            }
            throw HttpErr(status: 405, code: "method_not_allowed", message: "이 경로에서 쓸 수 없는 메서드입니다.")
        }

        if a == "groups", seg.count >= 3 {
            let g = try group(b)
            sweep(g)
            // 새 기기 (claim 의 토큰): 승인 전에는 기기가 아니므로 기기 인증 전에
            if c == "pairings", seg.count == 6, let d, e == "join" { return try join(g, d, m, headers) }
            // 기기 목록은 새 기기가 수락 전에 부른다 → 수락으로 치지 않는다
            let dev = try auth(g, headers, accept: !(c == "devices" && seg.count == 4 && m == "GET"))
            if seg.count == 3 {
                if m == "GET" {
                    return json(200, [
                        "gid": .string(g.gid), "created": JSONValue(g.created), "head": JSONValue(g.head), "deviceId": .string(dev.id),
                        "devices": JSONValue(g.devices.count), "maxDevices": JSONValue(limits.maxDevices),
                        "usage": ["bytes": JSONValue(g.bytes), "limit": JSONValue(quota(g))], "provisional": .bool(!g.paired),
                        "recovery": .bool(g.recoveryId != nil), "lastAccess": JSONValue(g.lastAccess), "deleteAfter": JSONValue(g.lastAccess + 396 * 86_400_000),
                    ])
                }
                if m == "DELETE" {
                    destroy(g)
                    return json(200, ["deleted": true])
                }
            }
            if c == "records", seg.count == 4, m == "POST" { return try putRecord(g, dev, body) }
            if c == "records", seg.count == 5, d == "batch", m == "POST" {
                guard _batch else { throw HttpErr(status: 404, code: "not_found", message: "없는 경로입니다.") }
                guard case let .array(list)? = body["writes"], (1...100).contains(list.count) else {
                    throw HttpErr(status: 400, code: "invalid_field", message: "writes: 1..100 개의 배열이어야 합니다", extra: ["field": "writes"])
                }
                var seen = Set<String>()
                for w in list {
                    let rid = try str(w.objectValue ?? [:], "rid", 43, 43, Self.isKey43)
                    if !seen.insert(rid).inserted { throw HttpErr(status: 400, code: "invalid_field", message: "writes: 같은 rid 를 두 번 쓸 수 없습니다") }
                }
                var results: [JSONValue] = []
                var full = false
                for w in list {
                    let rid = w["rid"]!
                    if full {
                        results.append(["rid": rid, "error": "quota_exceeded"])
                        continue
                    }
                    do {
                        switch try writeOne(g, dev, w.objectValue ?? [:], notify: false) {
                        case let .ok(seq): results.append(["rid": rid, "seq": JSONValue(seq)])
                        case let .conflict(seq, ct): results.append(["rid": rid, "conflict": true, "seq": JSONValue(seq), "ct": ct.map { .string($0) } ?? .null])
                        }
                    } catch let err as HttpErr where err.code == "quota_exceeded" {
                        full = true
                        var item: [String: JSONValue] = ["rid": rid, "error": "quota_exceeded"]
                        for (k, v) in err.extra { item[k] = v }
                        results.append(.object(item))
                    }
                }
                broadcast(g, ["head": JSONValue(g.head)])
                return json(200, ["results": .array(results), "head": JSONValue(g.head)])
            }
            if c == "records", seg.count == 6, e == "history", m == "GET" {
                guard let d, Self.isKey43(d) else { throw HttpErr(status: 400, code: "invalid_field", message: "rid: 형식이 맞지 않습니다") }
                gcHistory(g)
                var versions: [JSONValue] = []
                if let cur = g.records[d] {
                    versions.append(["seq": JSONValue(cur.seq), "ct": .string(cur.ct), "at": JSONValue(cur.at), "current": true])
                }
                for h in (g.history[d] ?? []).sorted(by: { $0.seq > $1.seq }) {
                    versions.append(["seq": JSONValue(h.seq), "ct": .string(h.ct), "at": JSONValue(h.at)])
                }
                return json(200, ["versions": .array(versions), "truncated": false])
            }
            if c == "changes", seg.count == 4, m == "GET" {
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let since = Int(q.first { $0.name == "since" }?.value ?? "0") ?? -1
                let limit = min(1000, max(1, Int(q.first { $0.name == "limit" }?.value ?? "500") ?? 500))
                guard since >= 0 else { throw HttpErr(status: 400, code: "invalid_field", message: "since: 0 이상의 정수여야 합니다") }
                let changes = g.records.filter { $0.value.seq > since }.sorted { $0.value.seq < $1.value.seq }.prefix(limit)
                let last = changes.last?.value.seq ?? g.head
                return json(200, [
                    "changes": .array(changes.map { ["rid": .string($0.key), "seq": JSONValue($0.value.seq), "ct": .string($0.value.ct)] }),
                    "head": JSONValue(g.head), "more": .bool(!changes.isEmpty && last < g.head),
                ])
            }
            if c == "devices", seg.count == 4, m == "GET" {
                let list = g.deviceOrder.compactMap { g.devices[$0] }.sorted { $0.created < $1.created }
                return json(200, [
                    "devices": .array(list.map { ["id": .string($0.id), "name": .string($0.name), "platform": $0.platform.map { .string($0) } ?? .null, "created": JSONValue($0.created), "lastSeen": JSONValue($0.lastSeen), "current": .bool($0.id == dev.id)] }),
                    "maxDevices": JSONValue(limits.maxDevices),
                ])
            }
            if c == "devices", seg.count == 5, let d {
                let id = d == "me" ? dev.id : d
                if m == "DELETE" {
                    try revoke(g, id)
                    return json(200, ["removed": true, "id": .string(id)])
                }
                if m == "PATCH" {
                    let nm = try name(body, "name")
                    guard g.devices[id] != nil else { throw HttpErr(status: 404, code: "device_not_found", message: "그런 기기가 없습니다.") }
                    g.devices[id]!.name = nm
                    if nm.hasPrefix("p.") { g.devices[id]!.platform = String(nm.dropFirst(2)) }
                    broadcast(g, ["devices": true])
                    return json(200, ["id": .string(id), "name": .string(nm)])
                }
            }
            if c == "pairings", seg.count == 4, m == "POST" {
                let codeHash = try str(body, "codeHash", 43, 43, Self.isKey43)
                let wk = try wrapped(body)
                var ttl = 600
                if let v = body["expiresIn"] {
                    guard let n = v.safeInt, (60...600).contains(n) else { throw HttpErr(status: 400, code: "invalid_field", message: "expiresIn: 60..600 범위여야 합니다") }
                    ttl = n
                }
                let md = try mode(body)
                let n = now()
                let active = g.pairings.values.filter { ($0.status == "pending" || $0.status == "claimed") && $0.expires > n }.count
                if active >= limits.maxActivePairings { throw HttpErr(status: 409, code: "pairing_limit", message: "열린 페어링이 너무 많습니다.") }
                if g.devices.count >= limits.maxDevices { throw HttpErr(status: 409, code: "device_limit", message: "기기는 \(limits.maxDevices)대까지 연결할 수 있습니다.") }
                // 같은 해시가 다른 그룹에 살아 있으면 조용히 등록하지 않는다 (409 로 드러내지 않는다)
                let indexed = !(pairingIndex[codeHash].map { $0.expires > n } ?? false)
                let id = randomId()
                let expires = n + ttl * 1000
                var p = Pairing(id: id, codeHash: codeHash, wrappedKey: wk, expires: expires, mode: md, status: "pending")
                p.indexed = indexed
                g.pairings[id] = p
                if indexed { pairingIndex[codeHash] = (g.gid, id, expires, md) }
                return json(201, ["pairingId": .string(id), "expiresAt": JSONValue(expires)])
            }
            if c == "pairings", seg.count >= 5, let d {
                guard var p = g.pairings[d] else { throw HttpErr(status: 404, code: "pairing_not_found", message: "페어링이 없습니다.") }
                let gone = HttpErr(status: 404, code: "pairing_not_found", message: "승인할 합류 요청이 없습니다.")
                if seg.count == 6, e == "approve", m == "POST" {
                    let deviceId = try str(body, "deviceId", 22, 22, Self.isId22)
                    if p.deviceId != deviceId { throw gone }
                    if p.status == "approved" { return json(200, ["pairingId": .string(p.id), "status": "approved", "deviceId": .string(deviceId)]) }
                    guard p.status == "claimed", p.expires > now(), p.wrappedKey != nil, let th = p.tokenHash else { throw gone }
                    if g.devices.count >= limits.maxDevices { throw HttpErr(status: 409, code: "device_limit", message: "기기는 \(limits.maxDevices)대까지 연결할 수 있습니다.") }
                    addDevice(g, id: deviceId, name: p.deviceName ?? "p.Web", tokenHash: th)
                    g.paired = true
                    p.status = "approved"
                    p.expires = max(p.expires, now() + limits.pairingDeliverSec * 1000)
                    g.pairings[p.id] = p
                    broadcast(g, ["pairing": .string(p.id), "status": "approved"])
                    broadcast(g, ["devices": true])
                    return json(200, ["pairingId": .string(p.id), "status": "approved", "deviceId": .string(deviceId)])
                }
                guard seg.count == 5 else { throw HttpErr(status: 404, code: "not_found", message: "없는 경로입니다.") }
                if m == "GET" {
                    let open = p.status == "pending" || p.status == "claimed"
                    let st = open && p.expires <= now() ? "expired" : p.status
                    var out: [String: JSONValue] = ["pairingId": .string(p.id), "status": .string(st), "expiresAt": JSONValue(p.expires)]
                    if st == "claimed" || st == "approved", let did = p.deviceId {
                        if st == "claimed" {
                            out["device"] = ["id": .string(did), "name": p.deviceName.map { .string($0) } ?? .null]
                        } else if let dv = g.devices[did] {
                            out["device"] = ["id": .string(dv.id), "name": .string(dv.name), "created": JSONValue(dv.created)]
                        } else {
                            out["device"] = ["id": .string(did), "name": .null, "removed": true]
                        }
                        out["nonce"] = p.nonce.map { .string($0) } ?? .null
                    }
                    return json(200, .object(out))
                }
                if m == "DELETE" {
                    if p.status == "pending" || (p.status == "approved" && p.acceptedAt != nil) {
                        g.pairings[p.id] = nil
                        unindex(p)
                    } else if p.status != "denied" {
                        deny(g, &p)
                        g.pairings[p.id] = p
                    }
                    return json(200, ["deleted": true])
                }
            }
        }
        throw HttpErr(status: 404, code: "not_found", message: "없는 경로입니다.")
    }

    /// 이 페어링이 등록한 색인 항목만 지운다 (같은 해시의 남의 항목은 그대로)
    func unindex(_ p: Pairing) {
        if pairingIndex[p.codeHash]?.pairingId == p.id { pairingIndex[p.codeHash] = nil }
    }

    /// 만료된 페어링 정리 (진짜 서버의 알람). 승인됐는데 키를 받아 가지 않았거나 수락하지 않은 기기는 뺀다
    func sweep(_ g: Group) {
        let n = now()
        for (id, var p) in g.pairings where p.wrappedKey != nil && (p.deliveredAt.map { $0 <= n - limits.pairingDeliverSec * 1000 } ?? false) {
            p.wrappedKey = nil
            g.pairings[id] = p
        }
        for p in g.pairings.values where p.expires <= n {
            if p.status == "approved", p.acceptedAt == nil, let did = p.deviceId, g.devices[did] != nil { try? revoke(g, did) }
            g.pairings[p.id] = nil
            if p.status == "pending" { unindex(p) }
        }
    }

    func deny(_ g: Group, _ p: inout Pairing) {
        if p.status == "approved", let did = p.deviceId, g.devices[did] != nil { try? revoke(g, did) }
        p.status = "denied"
        p.wrappedKey = nil
        broadcast(g, ["pairing": .string(p.id), "status": "denied"])
    }

    /// 새 기기: POST = 승인을 묻기 (approved 면 감싼 키 한 번) · DELETE = 거두기
    func join(_ g: Group, _ pairingId: String, _ m: String, _ headers: [String: String]) throws -> Response {
        guard let token = bearer(headers), Self.isKey43(token) else {
            throw HttpErr(status: 401, code: "unauthorized", message: "합류 요청 토큰이 없거나 형식이 맞지 않습니다.")
        }
        guard var p = g.pairings[pairingId], let th = p.tokenHash, th == sha(token) else {
            throw HttpErr(status: 404, code: "pairing_not_found", message: "합류 요청이 없습니다.")
        }
        if m == "DELETE" {
            if p.status == "claimed" || p.status == "approved" {
                deny(g, &p)
                g.pairings[p.id] = p
            }
            return json(200, ["deleted": true])
        }
        guard m == "POST" else { throw HttpErr(status: 405, code: "method_not_allowed", message: "이 경로에서 쓸 수 없는 메서드입니다.") }
        if p.status == "denied" { return json(200, ["status": "denied"]) }
        if p.status == "claimed" {
            return json(200, p.expires <= now() ? ["status": "expired"] : ["status": "waiting", "expiresAt": JSONValue(p.expires)])
        }
        let n = now()
        let redelivery = p.deliveredAt.map { n - $0 < limits.pairingDeliverSec * 1000 } ?? false
        if p.status == "approved", let wk = p.wrappedKey, let did = p.deviceId, p.acceptedAt == nil, p.deliveredAt == nil || redelivery {
            if g.devices[did] == nil {
                deny(g, &p)
                g.pairings[p.id] = p
                return json(200, ["status": "denied"])
            }
            if p.deliveredAt == nil {
                p.deliveredAt = n
                p.expires = n + limits.pairingAcceptSec * 1000
                g.pairings[p.id] = p
            }
            return json(200, ["status": "approved", "wrappedKey": .string(wk)])
        }
        throw HttpErr(status: 404, code: "pairing_not_found", message: "합류 요청이 없습니다. 이미 받았거나 만료되었습니다.")
    }

    /// 8자 코드 합류: 실패로 미리 센다 (IP · 전체). 넘었으면 429 — 코드를 찾아보지도 않는다
    func reserveCodeAttempt(_ ip: String) throws {
        let n = now()
        var mine = (codeFails[ip] ?? []).filter { $0 > n - 3_600_000 }
        var all = globalCodeFails.filter { $0 > n - 600_000 }
        globalCodeFails = all
        func over(_ lim: Int, _ list: [Int], _ window: Int) -> Int {
            lim > 0 && list.count >= lim ? max(1, Int((Double(list[0] + window - n) / 1000).rounded(.up))) : 0
        }
        var ra = over(limits.codeFailPerHour, mine, 3_600_000)
        // 전체 상한이면 code_join_paused (이 사람이 틀린 것이 아니다)
        let code = ra > 0 ? "rate_limited" : "code_join_paused"
        if ra == 0 { ra = over(limits.codeFailGlobalPer10Min, all, 600_000) }
        if ra > 0 {
            throw HttpErr(status: 429, code: code, message: "코드로 연결하려는 시도가 너무 많습니다. 잠시 뒤에 다시 하거나 QR 코드로 연결하세요.",
                          extra: ["retryAfter": JSONValue(ra)], headers: ["Retry-After": String(ra)])
        }
        mine.append(n)
        all.append(n)
        codeFails[ip] = mine
        globalCodeFails = all
    }

    func refundCodeAttempt(_ ip: String) {
        _ = codeFails[ip]?.popLast()
        _ = globalCodeFails.popLast()
    }

    func limitClaim(_ ip: String) throws {
        guard limits.claimPer10Min > 0 else { return }
        let n = now()
        var hits = (claimHits[ip] ?? []).filter { $0 > n - 600_000 }
        if hits.count >= limits.claimPer10Min {
            let ra = max(1, Int((Double(hits[0] + 600_000 - n) / 1000).rounded(.up)))
            throw HttpErr(status: 429, code: "rate_limited", message: "요청이 너무 많습니다.", extra: ["retryAfter": JSONValue(ra)], headers: ["Retry-After": String(ra)])
        }
        hits.append(n)
        claimHits[ip] = hits
    }

    enum WriteResult {
        case ok(Int)
        case conflict(Int, String?)
    }

    func putRecord(_ g: Group, _ dev: Device, _ body: [String: JSONValue]) throws -> Response {
        switch try writeOne(g, dev, body, notify: true) {
        case let .conflict(seq, ct):
            throw HttpErr(status: 409, code: "conflict", message: "다른 기기가 먼저 바꿨습니다. 받은 버전과 합친 뒤 다시 보내세요.",
                          extra: ["seq": JSONValue(seq), "ct": ct.map { .string($0) } ?? .null])
        case let .ok(seq):
            return json(200, ["seq": JSONValue(seq)])
        }
    }

    func writeOne(_ g: Group, _ dev: Device, _ body: [String: JSONValue], notify: Bool) throws -> WriteResult {
        let rid = try str(body, "rid", 43, 43, Self.isKey43)
        guard let baseSeq = body["baseSeq"]?.safeInt, baseSeq >= 0 else { throw HttpErr(status: 400, code: "invalid_field", message: "baseSeq: 정수여야 합니다") }
        guard case let .string(ctStr)? = body["ct"] else { throw HttpErr(status: 400, code: "invalid_field", message: "ct: 문자열이어야 합니다") }
        guard let bytes = Base64URL.decode(ctStr) else { throw HttpErr(status: 400, code: "invalid_field", message: "ct: base64url 이어야 합니다") }
        if bytes.count > limits.maxRecordBytes { throw HttpErr(status: 413, code: "record_too_large", message: "레코드가 너무 큽니다.") }
        if bytes.count < 41 { throw HttpErr(status: 400, code: "invalid_field", message: "ct: 암호문이 너무 짧습니다") }
        let cur = g.records[rid]
        let curSeq = cur?.seq ?? 0
        if baseSeq != curSeq {
            _conflicts += 1
            return .conflict(curSeq, cur?.ct)
        }
        let n = now()
        // keep: 되돌리기 — 2분 안이라도 지금 버전을 이전 버전으로 남긴다
        let keep = body["keep"] == .bool(true)
        let coalesce = !keep && cur != nil && cur!.writer == dev.id && n - cur!.at < limits.historyCoalesceMs
        let delta = bytes.count - (coalesce ? cur!.size : 0)
        let limit = quota(g)
        if g.bytes + delta > limit {
            var extra: [String: JSONValue] = ["usage": ["bytes": JSONValue(g.bytes), "limit": JSONValue(limit)]]
            if !g.paired { extra["provisional"] = true }
            throw HttpErr(status: 413, code: "quota_exceeded", message: "그룹 저장 용량을 넘었습니다.", extra: extra)
        }
        if let cur, !coalesce {
            var list = g.history[rid] ?? []
            list.append(Hist(seq: cur.seq, ct: cur.ct, size: cur.size, at: cur.at, gone: n))
            while list.count > limits.historyPerRecord { g.bytes -= list.removeFirst().size }
            g.history[rid] = list
        }
        let seq = g.head + 1
        g.records[rid] = Rec(seq: seq, ct: ctStr, size: bytes.count, at: n, writer: dev.id)
        g.head = seq
        g.bytes += delta
        if notify { broadcast(g, ["head": JSONValue(seq)]) }
        return .ok(seq)
    }

    // MARK: - WebSocket

    func openSocket(_ req: URLRequest, handlers: SocketHandlers, net: FakeNet) -> SocketHandle {
        let sock = FakeSocket(handlers: handlers)
        let token = bearer(req.allHTTPHeaderFields ?? [:])
        let path = req.url?.path ?? ""
        sock.queue.async { [weak self] in
            guard let self else { return }
            if net.offline {
                sock.serverClose(1006, "offline")
                return
            }
            self.lock.withLock {
                let parts = path.split(separator: "/").map(String.init)
                guard parts.count == 4, parts[0] == "v1", parts[1] == "groups", parts[3] == "ws", let g = self.groups[parts[2]],
                      let token, let dev = self.deviceByToken(g, token) else {
                    // 진짜 서버는 업그레이드하지 않고 401/404 JSON 을 준다 → 클라이언트에는 1006 으로 보인다
                    sock.serverClose(1006, "upgrade_failed")
                    return
                }
                sock.deviceId = dev.id
                sock.server = self
                g.sockets.append(sock)
                sock.group = g
                sock.serverOpen()
                sock.serverSend(#"{"head":\#(g.head)}"#)
            }
        }
        return sock
    }

    func socketClosed(_ s: FakeSocket) {
        lock.withLock { s.group?.sockets.removeAll { $0 === s } }
    }

    func headOf(_ g: Group) -> Int { lock.withLock { g.head } }

    /// 열린 WebSocket 을 모두 네트워크 오류로 끊는다 (기기가 오프라인이 된 것처럼)
    public func dropSockets() {
        lock.withLock {
            for g in groups.values {
                for s in g.sockets { s.serverClose(1006, "dropped") }
                g.sockets = []
            }
        }
    }
}

/// 가짜 WebSocket (서버 쪽 조작 함수가 붙어 있다). 알림은 순서대로 따로 줄에서 전한다
final class FakeSocket: SocketHandle, @unchecked Sendable {
    let queue = DispatchQueue(label: "fake-socket")
    let handlers: SocketHandlers
    private let lock = NSLock()
    private var state = 0 // 0 연결 중 · 1 열림 · 3 닫힘
    var deviceId: String?
    weak var server: FakeSyncServer?
    var group: FakeSyncServer.Group?

    init(handlers: SocketHandlers) { self.handlers = handlers }

    func send(_ text: String) {
        guard lock.withLock({ state == 1 }) else { return }
        if text == "ping" { serverSend("pong") }
        if text == "head", let g = group, let s = server { serverSend(#"{"head":\#(s.headOf(g))}"#) }
    }

    func close() {
        let was = lock.withLock { () -> Int in
            let w = state
            state = 3
            return w
        }
        if was >= 2 { return }
        server?.socketClosed(self)
        // 우리가 닫은 것은 알리지 않는다 (HTTPTransport 의 WebSocket 과 같게)
    }

    func serverOpen() {
        lock.withLock { state = 1 }
        queue.async { self.handlers.onOpen() }
    }

    func serverSend(_ data: String) {
        guard lock.withLock({ state == 1 }) else { return }
        queue.async {
            guard self.lock.withLock({ self.state == 1 }) else { return }
            if data == "pong" { return }
            self.handlers.onMessage(ServerPush.parse(data))
        }
    }

    /// 서버가 끊는다 (4401 기기 제거 · 4404 그룹 삭제 · 1006 네트워크)
    func serverClose(_ code: Int, _ reason: String) {
        let was = lock.withLock { () -> Int in
            let w = state
            state = 3
            return w
        }
        if was >= 2 { return }
        queue.async { self.handlers.onClose(code, reason) }
    }
}

// MARK: - URLProtocol

/// URLSession 요청을 가짜 서버로 보낸다 (호스트 이름으로 서버를 찾는다)
final class FakeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var servers: [String: Weak] = [:]
    nonisolated(unsafe) private static var nets: [String: WeakNet] = [:]
    private static let lock = NSLock()

    struct Weak { weak var server: FakeSyncServer? }
    struct WeakNet { weak var net: FakeNet? }

    static func register(_ s: FakeSyncServer) { lock.withLock { servers[s.host] = Weak(server: s) } }
    static func unregister(_ host: String) { lock.withLock { servers[host] = nil } }
    static func registerNet(_ n: FakeNet) { lock.withLock { nets[n.id] = WeakNet(net: n) } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".sync.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        guard let url = req.url, let host = url.host,
              let server = Self.lock.withLock({ Self.servers[host]?.server }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let headers = req.allHTTPHeaderFields ?? [:]
        let net = headers["X-Fake-Net"].flatMap { id in Self.lock.withLock { Self.nets[id]?.net } }
        let method = req.httpMethod ?? "GET"
        if let net, net.offline || (net.fail?(method, url.path) ?? false) {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if let net, let chaos = net.chaos {
            if net.random() < chaos.dropRequest {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            let body = Self.bodyOf(req)
            let delay = chaos.maxDelayMs > 0 ? Int(net.random() * Double(chaos.maxDelayMs)) : 0
            let dup = net.random() < chaos.duplicate
            let late = net.random() < 0.5
            let dropRes = net.random() < chaos.dropResponse
            // URLProtocol 의 client 는 startLoading 을 부른 스레드에서 불러야 한다
            nonisolated(unsafe) let thread = Thread.current
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delay)) { [self] in
                var res = server.handle(method: method, url: url, headers: headers, body: body)
                if dup {
                    let again = server.handle(method: method, url: url, headers: headers, body: body)
                    if late { res = again }
                }
                let box = Outcome(res: dropRes ? nil : res, url: url)
                perform(#selector(finish(_:)), on: thread, with: box, waitUntilDone: false, modes: [RunLoop.Mode.default.rawValue, RunLoop.Mode.common.rawValue])
            }
            return
        }
        let body = Self.bodyOf(req)
        let res = server.handle(method: method, url: url, headers: headers, body: body)
        if let net, net.takeDrop(method, url.path) {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        deliver(res, url)
    }

    final class Outcome: NSObject, @unchecked Sendable {
        let res: FakeSyncServer.Response?
        let url: URL
        init(res: FakeSyncServer.Response?, url: URL) {
            self.res = res
            self.url = url
        }
    }

    @objc private func finish(_ o: Outcome) {
        guard let res = o.res else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        deliver(res, o.url)
    }

    private func deliver(_ res: FakeSyncServer.Response, _ url: URL) {
        let http = HTTPURLResponse(url: url, statusCode: res.status, httpVersion: "HTTP/1.1", headerFields: res.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: res.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func bodyOf(_ req: URLRequest) -> Data? {
        var body = req.httpBody
        if body == nil, let stream = req.httpBodyStream {
            stream.open()
            var d = Data()
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                d.append(buf, count: n)
            }
            stream.close()
            body = d
        }
        return body
    }

    override func stopLoading() {}
}
