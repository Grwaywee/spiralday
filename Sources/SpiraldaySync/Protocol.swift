// 서버와 주고받는 값 (Spiralday Sync 프로토콜 v1 의 JSON 본문 — 모든 클라이언트 엔진이 같다).
// id: gid · deviceId · pairingId · nonce = 16바이트 base64url (22자). token · codeHash · rid · recoveryId = 32바이트 (43자).
import Foundation

public struct Auth: Sendable, Equatable {
    public let gid: String
    public let token: String
    public init(gid: String, token: String) {
        self.gid = gid
        self.token = token
    }
}

/// 페어링 방식: QR (32바이트 비밀, 기본) · 8자 코드 (카메라가 없을 때)
public enum PairingMode: String, Sendable, Codable {
    case qr, code
}

public struct JoinedRes: Sendable, Equatable {
    public let gid: String
    public let deviceId: String
    public let token: String
}

public struct CreatePairingRes: Sendable, Equatable {
    public let pairingId: String
    /// ms
    public let expiresAt: Int
}

/// 페어링 상태 (원래 기기가 본다): pending · claimed · approved · denied · expired
public struct PairingStatusRes: Sendable, Equatable {
    public struct Device: Sendable, Equatable {
        public let id: String
        public let name: String?
        public let removed: Bool
    }

    public let pairingId: String
    public let status: String
    /// ms. claimed 이면 승인 기한
    public let expiresAt: Int
    /// claimed · approved: 들어오려는(들어온) 기기. 승인 전 이름은 "p.<플랫폼>"
    public let device: Device?
    /// claimed · approved: 새 기기가 고른 난수 (확인 숫자에 들어간다)
    public let nonce: String?
}

/// 합류 요청 응답. 감싼 키는 없다 — 원래 기기가 승인한 뒤 join 으로 받는다
public struct ClaimRes: Sendable, Equatable {
    public let gid: String
    public let pairingId: String
    public let deviceId: String
    public let token: String
    /// ms. 이때까지 원래 기기가 승인해야 한다
    public let expiresAt: Int
}

/// 새 기기가 묻는 합류 상태. approved 일 때 감싼 키가 한 번 온다
public enum JoinPollRes: Sendable, Equatable {
    case waiting(expiresAt: Int?)
    case approved(wrappedKey: String?)
    case denied
    case expired
    case other(String)
}

public enum PutRecordResult: Sendable, Equatable {
    case ok(seq: Int)
    /// 409: 서버에 있는 지금 버전 (ct 가 nil 이면 서버에 레코드가 없다)
    case conflict(seq: Int, ct: String?)
}

public struct RecordWrite: Sendable, Equatable {
    public let rid: String
    public let baseSeq: Int
    public let ct: String
    /// 되돌리기: 2분 안에 같은 기기가 다시 써도 바로 앞 버전을 이전 버전으로 꼭 남긴다
    public var keep = false

    public init(rid: String, baseSeq: Int, ct: String, keep: Bool = false) {
        self.rid = rid
        self.baseSeq = baseSeq
        self.ct = ct
        self.keep = keep
    }
}

public enum BatchResult: Sendable, Equatable {
    case ok(rid: String, seq: Int)
    case conflict(rid: String, seq: Int, ct: String?)
    /// usage · provisional: quota_exceeded 일 때 그룹 용량 · 두 번째 기기 전의 작은 용량인지
    case error(rid: String, code: String, usageLimit: Int? = nil, provisional: Bool = false)

    public var rid: String {
        switch self {
        case let .ok(rid, _), let .conflict(rid, _, _), let .error(rid, _, _, _): return rid
        }
    }
}

public struct PutRecordsRes: Sendable, Equatable {
    public let results: [BatchResult]
    public let head: Int
}

public struct Change: Sendable, Equatable {
    public let rid: String
    public let seq: Int
    public let ct: String
}

public struct ChangesRes: Sendable, Equatable {
    public let changes: [Change]
    public let head: Int
    public let more: Bool?
}

public struct HistoryVersionRes: Sendable, Equatable {
    public let seq: Int
    public let ct: String
    /// ms
    public let at: Int
    public let current: Bool
}

public struct DeviceRow: Sendable, Equatable {
    public let id: String
    public let name: String?
    /// 들어올 때의 플랫폼 (이름을 암호화한 뒤에도 남는다 — 목록 아이콘용). 예전 서버는 nil
    public var platform: String? = nil
    public let created: Int
    public let lastSeen: Int
    public let current: Bool
}

public struct DevicesRes: Sendable, Equatable {
    public let devices: [DeviceRow]
    public let maxDevices: Int
}

public struct GroupInfo: Sendable, Equatable {
    public let gid: String
    public let created: Int
    public let head: Int
    public let deviceId: String
    public let devices: Int
    public let maxDevices: Int
    public let usageBytes: Int
    public let usageLimit: Int
    /// 두 번째 기기가 들어오기 전이라 용량이 작다 (5 MB)
    public let provisional: Bool
    public let recovery: Bool
    public let lastAccess: Int
    public let deleteAfter: Int
}

public struct GetRecoveryRes: Sendable, Equatable {
    public let gid: String
    public let wrappedKey: String
}

public struct RecoveryJoinRes: Sendable, Equatable {
    public let gid: String
    public let deviceId: String
    public let token: String
    /// 기기가 꽉 차서 뺀 기기 (가장 오래 안 쓴 것)
    public let evicted: String?
}

/// WebSocket 으로 오는 알림 (모르는 것은 무시한다)
public enum ServerPush: Sendable, Equatable {
    case head(Int)
    case devices
    /// 내 그룹의 페어링 상태가 바뀜 (claimed · approved · denied)
    case pairing(id: String, status: String)
    /// 이 기기가 그룹에서 빠졌다 (곧 4401 로 닫힌다)
    case removed
    /// 그룹이 지워졌다 (곧 4404 로 닫힌다)
    case deleted
    /// presence (live 소켓에만, docs/sync-live.md §3.1): 이 기기를 뺀 같은 그룹 기기 중 연결이 열린 기기 수 · 그중 초안을 받는 기기 수.
    /// 이것을 받은 연결만 "중계 있음" 이다
    case presence(peers: Int, live: Int)
    /// 다른 기기의 봉인한 초안 (§3.3). from 은 서버가 붙인 보낸 기기 id. 키가 문자열이 아니면 빈 글 (받는 쪽 검사가 버린다)
    case draft(draft: String, q: String, from: String)
    case unknown

    public static func parse(_ text: String) -> ServerPush {
        guard let v = try? JSONValue.parse(text), case let .object(o) = v else { return .unknown }
        if o["removed"] == .bool(true) { return .removed }
        if o["deleted"] == .bool(true) { return .deleted }
        if o.keys.contains("draft") {
            return .draft(draft: o["draft"]?.stringValue ?? "", q: o["q"]?.stringValue ?? "", from: o["from"]?.stringValue ?? "")
        }
        if o.keys.contains("peers") {
            // 모양이 틀린 presence 는 무시한다 (모르는 것과 같다)
            guard let p = o["peers"]?.safeInt, let l = o["live"]?.safeInt, p >= 0, l >= 0, l <= p else { return .unknown }
            return .presence(peers: p, live: l)
        }
        // 범위 밖 숫자로 멈추지 않게 (Int(Double) 은 넘치면 멈춘다)
        if case .number? = o["head"] { return o["head"]?.safeInt.map { .head($0) } ?? .unknown }
        if o["devices"] != nil { return .devices }
        if case let .string(p)? = o["pairing"] { return .pairing(id: p, status: JS.string(o["status"])) }
        return .unknown
    }
}

/// WebSocket 닫힘 코드
public enum WSClose {
    public static let replaced = 4000
    public static let deviceRemoved = 4401
    public static let groupDeleted = 4404
}

// MARK: - 응답 읽기

struct ResponseShapeError: Error {
    let what: String
}

extension JSONValue {
    func str(_ k: String) throws -> String {
        guard case let .string(s)? = self[k] else { throw ResponseShapeError(what: k) }
        return s
    }

    func optStr(_ k: String) -> String? { self[k]?.stringValue }

    func int(_ k: String) throws -> Int {
        guard case let .number(n)? = self[k], JS.isSafeInteger(n) else { throw ResponseShapeError(what: k) }
        return Int(n)
    }

    func optInt(_ k: String) -> Int? { self[k]?.safeInt }
}

extension JoinedRes {
    init(json j: JSONValue) throws {
        gid = try j.str("gid")
        deviceId = try j.str("deviceId")
        token = try j.str("token")
    }
}

extension CreatePairingRes {
    init(json j: JSONValue) throws {
        pairingId = try j.str("pairingId")
        expiresAt = try j.int("expiresAt")
    }
}

extension PairingStatusRes {
    init(json j: JSONValue) throws {
        pairingId = try j.str("pairingId")
        status = try j.str("status")
        expiresAt = j.optInt("expiresAt") ?? 0
        if let d = j["device"], case .object = d, let id = d.optStr("id") {
            device = Device(id: id, name: d.optStr("name"), removed: d["removed"] == .bool(true))
        } else {
            device = nil
        }
        nonce = j.optStr("nonce")
    }
}

extension ClaimRes {
    init(json j: JSONValue) throws {
        gid = try j.str("gid")
        pairingId = try j.str("pairingId")
        deviceId = try j.str("deviceId")
        token = try j.str("token")
        expiresAt = try j.int("expiresAt")
    }
}

extension JoinPollRes {
    init(json j: JSONValue) throws {
        switch try j.str("status") {
        case "waiting": self = .waiting(expiresAt: j.optInt("expiresAt"))
        case "approved": self = .approved(wrappedKey: j.optStr("wrappedKey"))
        case "denied": self = .denied
        case "expired": self = .expired
        case let s: self = .other(s)
        }
    }
}

extension PutRecordsRes {
    init(json j: JSONValue) throws {
        guard case let .array(rs)? = j["results"] else { throw ResponseShapeError(what: "results") }
        results = try rs.map { r in
            let rid = try r.str("rid")
            if let e = r.optStr("error") {
                return .error(rid: rid, code: e, usageLimit: r["usage"]?.optInt("limit"), provisional: r["provisional"] == .bool(true))
            }
            if r["conflict"] == .bool(true) { return .conflict(rid: rid, seq: try r.int("seq"), ct: r.optStr("ct")) }
            return .ok(rid: rid, seq: try r.int("seq"))
        }
        head = j.optInt("head") ?? 0
    }
}

extension ChangesRes {
    init(json j: JSONValue) throws {
        guard case let .array(cs)? = j["changes"] else { throw ResponseShapeError(what: "changes") }
        changes = try cs.map { Change(rid: try $0.str("rid"), seq: try $0.int("seq"), ct: try $0.str("ct")) }
        head = try j.int("head")
        more = j["more"]?.boolValue
    }
}

extension HistoryVersionRes {
    static func list(json j: JSONValue) throws -> [HistoryVersionRes] {
        guard case let .array(vs)? = j["versions"] else { throw ResponseShapeError(what: "versions") }
        return try vs.map {
            HistoryVersionRes(seq: try $0.int("seq"), ct: try $0.str("ct"), at: $0.optInt("at") ?? 0, current: $0["current"] == .bool(true))
        }
    }
}

extension DevicesRes {
    init(json j: JSONValue) throws {
        guard case let .array(ds)? = j["devices"] else { throw ResponseShapeError(what: "devices") }
        devices = try ds.map {
            DeviceRow(id: try $0.str("id"), name: $0.optStr("name"), platform: $0.optStr("platform"), created: $0.optInt("created") ?? 0,
                      lastSeen: $0.optInt("lastSeen") ?? 0, current: $0["current"] == .bool(true))
        }
        maxDevices = j.optInt("maxDevices") ?? 10
    }
}

extension GroupInfo {
    init(json j: JSONValue) throws {
        gid = try j.str("gid")
        created = j.optInt("created") ?? 0
        head = j.optInt("head") ?? 0
        deviceId = try j.str("deviceId")
        devices = j.optInt("devices") ?? 0
        maxDevices = j.optInt("maxDevices") ?? 10
        usageBytes = j["usage"]?.optInt("bytes") ?? 0
        usageLimit = j["usage"]?.optInt("limit") ?? 0
        provisional = j["provisional"] == .bool(true)
        recovery = j["recovery"] == .bool(true)
        lastAccess = j.optInt("lastAccess") ?? 0
        deleteAfter = j.optInt("deleteAfter") ?? 0
    }
}

extension GetRecoveryRes {
    init(json j: JSONValue) throws {
        gid = try j.str("gid")
        wrappedKey = try j.str("wrappedKey")
    }
}

extension RecoveryJoinRes {
    init(json j: JSONValue) throws {
        gid = try j.str("gid")
        deviceId = try j.str("deviceId")
        token = try j.str("token")
        evicted = j.optStr("evicted")
    }
}
