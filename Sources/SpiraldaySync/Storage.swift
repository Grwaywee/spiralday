// 엔진의 동기화 상태 저장소 (앱 파일과 따로).
// 담는 것: 메타(노드 id · HLC · 받은 순번 head · 그룹 정보), 레코드마다 상태(필드 도장 · 지운 표시) ·
// 마지막으로 맞춘 그림자 · 서버 순번 · 보낼 것/앱에 넣을 것 표시. 오프라인 동안의 편집도 여기에 남는다 (dirty).
//
// 구현: MemorySyncStorage (테스트), FileSyncStorage (앱의 Application Support 아래 폴더 하나).
import Foundation

public struct StoredData: Sendable {
    public var meta: JSONValue?
    public var records: [(String, JSONValue)]
    public init(meta: JSONValue? = nil, records: [(String, JSONValue)] = []) {
        self.meta = meta
        self.records = records
    }
}

public struct StorageBatch: Sendable {
    public var meta: JSONValue?
    public var put: [(String, JSONValue)]
    public var del: [String]
    /// 디스크까지 꼭 내려 쓸지 (fsync). 실시간 묶음(초당 여러 번)은 false — 앱이 죽어도 남고, 전원이 꺼질 때만 잃을 수 있다
    public var durable: Bool
    public init(meta: JSONValue? = nil, put: [(String, JSONValue)] = [], del: [String] = [], durable: Bool = true) {
        self.meta = meta
        self.put = put
        self.del = del
        self.durable = durable
    }
}

public protocol SyncStorage: Sendable {
    func load() async throws -> StoredData
    /// 한 번에(가능하면 원자적으로) 적는다
    func write(_ batch: StorageBatch) async throws
    /// 모두 지운다 (그룹에서 나올 때)
    func clear() async throws
}

/// 메모리 (테스트 · 저장하지 않는 미리보기)
public actor MemorySyncStorage: SyncStorage {
    public private(set) var meta: JSONValue?
    public private(set) var records: [String: JSONValue] = [:]
    public private(set) var writes = 0

    public init() {}

    public func load() async throws -> StoredData {
        StoredData(meta: meta, records: records.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }

    public func write(_ b: StorageBatch) async throws {
        writes += 1
        if let m = b.meta { meta = m }
        for (k, v) in b.put { records[k] = v }
        for k in b.del { records[k] = nil }
    }

    public func clear() async throws {
        meta = nil
        records = [:]
    }
}

/// 폴더 하나에 둔다: state.json (전체 사본) + journal.jsonl (그 뒤의 쓰기 묶음, 한 줄에 하나).
/// 쓰기는 일지 끝에 한 줄 덧붙이고 fsync 한다 (큰 책장에서도 쓰기 한 번이 작다). 실시간 묶음(durable = false)은 fsync 하지 않는다.
/// 일지가 사본보다 커지면 사본을 새로 쓰고(임시 파일 → 이름 바꾸기) 일지를 비운다.
/// 읽을 때는 사본 뒤에 일지를 차례로 덮는다 (마지막 줄이 쓰다 끊겼으면 그 줄만 버린다).
/// 사본과 일지 줄에는 세대 번호(g)가 있어, 사본을 새로 쓴 뒤 일지를 비우기 전에 꺼져도 옛 줄을 다시 덮지 않는다.
public actor FileSyncStorage: SyncStorage {
    public let directory: URL
    private var meta: JSONValue?
    private var records: [String: JSONValue] = [:]
    private var loaded = false
    private var journalBytes = 0
    private var snapshotBytes = 0
    private var gen = 0
    private let fm = FileManager.default

    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var journalURL: URL { directory.appendingPathComponent("journal.jsonl") }

    /// - Parameter directory: 동기화 상태를 둘 폴더 (없으면 만든다). 기본값은 `FileSyncStorage.defaultDirectory()`
    public init(directory: URL) {
        self.directory = directory
    }

    /// <Application Support>/<appFolder>/SyncState.
    /// iOS: 앱 샌드박스의 Application Support (앱 그룹 컨테이너에 있는 플래너 파일과 따로 — 위젯은 이것을 읽지 않는다).
    /// macOS(샌드박스 없음): ~/Library/Application Support/Spiralday/SyncState — 앱 데이터 폴더 안의 하위 폴더라 백업 · 이동이 함께 된다.
    /// 앱 파일(library.json · books/)과는 섞이지 않는다
    public static func defaultDirectory(appFolder: String = "Spiralday") throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent(appFolder, isDirectory: true).appendingPathComponent("SyncState", isDirectory: true)
    }

    public func load() async throws -> StoredData {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        meta = nil
        records = [:]
        if let data = try? Data(contentsOf: stateURL), !data.isEmpty {
            snapshotBytes = data.count
            if let v = try? JSONValue.parse(data) {
                if let m = v["meta"], !m.isNull { meta = m }
                records = v["records"]?.objectValue ?? [:]
                gen = v.optInt("g") ?? 0
            } else {
                // 깨진 사본: 옆에 남겨 두고 빈 상태로 시작한다 (앱 파일은 그대로라 다시 맞추면 된다. 그룹 값이 이긴다)
                let aside = directory.appendingPathComponent("state.json.corrupt-\(Int(Date().timeIntervalSince1970))")
                try? fm.moveItem(at: stateURL, to: aside)
                try? fm.removeItem(at: journalURL)
                snapshotBytes = 0
                gen = 0
            }
        }
        if let data = try? Data(contentsOf: journalURL), !data.isEmpty {
            journalBytes = data.count
            var start = data.startIndex
            while start < data.endIndex {
                let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
                let line = data[start..<end]
                start = end < data.endIndex ? data.index(after: end) : end
                guard !line.isEmpty, let v = try? JSONValue.parse(Data(line)), (v.optInt("g") ?? 0) == gen else { continue }
                apply(StorageBatch(meta: v["meta"].flatMap { $0.isNull ? nil : $0 },
                                   put: (v["put"]?.objectValue ?? [:]).map { ($0.key, $0.value) },
                                   del: (v["del"]?.arrayValue ?? []).compactMap(\.stringValue)))
            }
        }
        loaded = true
        return StoredData(meta: meta, records: records.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }

    private func apply(_ b: StorageBatch) {
        if let m = b.meta { meta = m }
        for (k, v) in b.put { records[k] = v }
        for k in b.del { records[k] = nil }
    }

    public func write(_ b: StorageBatch) async throws {
        if !loaded { _ = try await load() }
        apply(b)
        var line: [String: JSONValue] = ["g": JSONValue(gen)]
        if let m = b.meta { line["meta"] = m }
        if !b.put.isEmpty {
            var o: [String: JSONValue] = [:]
            for (k, v) in b.put { o[k] = v }
            line["put"] = .object(o)
        }
        if !b.del.isEmpty { line["del"] = .array(b.del.map { .string($0) }) }
        var data = JSONValue.object(line).jsonData()
        data.append(0x0A)
        if journalBytes + data.count > max(1 << 20, snapshotBytes) {
            try compact()
            return
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: journalURL.path) {
            fm.createFile(atPath: journalURL.path, contents: nil, attributes: Self.fileAttributes)
        }
        let h = try FileHandle(forWritingTo: journalURL)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: data)
        if b.durable { try h.synchronize() }
        journalBytes += data.count
    }

    /// 지금 내용을 사본으로 새로 쓰고 일지를 비운다
    private func compact() throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let next = gen + 1
        let all: JSONValue = ["g": JSONValue(next), "meta": meta ?? .null, "records": .object(records)]
        let data = all.jsonData()
        // .atomic = 임시 파일에 쓰고 이름 바꾸기
        try data.write(to: stateURL, options: Self.writeOptions)
        gen = next
        try Data().write(to: journalURL, options: Self.writeOptions)
        snapshotBytes = data.count
        journalBytes = 0
    }

    public func clear() async throws {
        meta = nil
        records = [:]
        loaded = true
        try? fm.removeItem(at: journalURL)
        try? fm.removeItem(at: stateURL)
        snapshotBytes = 0
        journalBytes = 0
        gen = 0
    }

    /// 지금 내용을 사본 하나로 (앱이 뒤로 갈 때 불러도 된다)
    public func compactNow() throws {
        if loaded { try compact() }
    }

    #if os(iOS)
    nonisolated(unsafe) static let fileAttributes: [FileAttributeKey: Any]? = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
    nonisolated(unsafe) static let fileAttributes: [FileAttributeKey: Any]? = nil
    static let writeOptions: Data.WritingOptions = [.atomic]
    #endif
}

// MARK: - 그룹 자격 (그룹 id · 기기 id · 토큰 · 그룹 키)

public struct Credentials: Sendable, Equatable, Codable {
    public let gid: String
    public let deviceId: String
    public let token: String
    /// 그룹 키 K (base64url)
    public let key: String

    public init(gid: String, deviceId: String, token: String, key: String) {
        self.gid = gid
        self.deviceId = deviceId
        self.token = token
        self.key = key
    }

    var json: JSONValue { ["gid": .string(gid), "deviceId": .string(deviceId), "token": .string(token), "key": .string(key)] }

    init?(json v: JSONValue?) {
        guard let v, let gid = v.optStr("gid"), let d = v.optStr("deviceId"), let t = v.optStr("token"), let k = v.optStr("key") else { return nil }
        self.init(gid: gid, deviceId: d, token: t, key: k)
    }
}

/// 비밀(토큰 · 그룹 키)을 따로 두는 곳 (Keychain). 넘기지 않으면 동기화 상태 저장소의 메타에 둔다 (테스트용)
public protocol CredentialStore: Sendable {
    func get() async throws -> Credentials?
    func set(_ c: Credentials?) async throws
}

public actor MemoryCredentialStore: CredentialStore {
    private var c: Credentials?
    public init(_ c: Credentials? = nil) { self.c = c }
    public func get() async throws -> Credentials? { c }
    public func set(_ c: Credentials?) async throws { self.c = c }
}
