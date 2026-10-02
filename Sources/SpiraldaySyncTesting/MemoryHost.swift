// 메모리 안의 앱 (테스트용 SyncHost). 책장 + 책 내용을 들고, 앱이 하듯 통째로 바꾼다.
import Foundation
import SpiraldaySync

public final class MemoryHost: SyncHost, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var _library: JSONValue
    private var _books: [String: JSONValue] = [:]
    private var _libraryUnreadable = false
    private var _unreadable = Set<String>()
    private var _applied = 0
    private var _settings: JSONValue?
    private var _openBook: String?
    private var _liveApplied = 0
    private var _liveReads = 0

    public init(library: JSONValue = ["books": [], "sampleSeeded": false], sharedSettings: JSONValue? = nil) {
        _library = library
        _settings = sharedSettings
    }

    public var library: JSONValue {
        get { lock.withLock { _library } }
        set { lock.withLock { _library = newValue } }
    }

    public var books: [String: JSONValue] {
        get { lock.withLock { _books } }
        set { lock.withLock { _books = newValue } }
    }

    public func book(_ id: String) -> JSONValue? { lock.withLock { _books[id.uppercased()] } }

    public func setBook(_ id: String, _ v: JSONValue?) { lock.withLock { _books[id.uppercased()] = v } }

    /// 읽을 수 없는 척 (깨진 파일 흉내)
    public var libraryUnreadable: Bool {
        get { lock.withLock { _libraryUnreadable } }
        set { lock.withLock { _libraryUnreadable = newValue } }
    }

    public func setUnreadable(_ id: String, _ on: Bool) {
        lock.withLock {
            if on { _unreadable.insert(id.uppercased()) } else { _unreadable.remove(id.uppercased()) }
        }
    }

    /// updateBook/updateLibrary 가 불린 횟수
    public var applied: Int { lock.withLock { _applied } }

    /// 앱에서 열린 책 (실시간 읽기 readLive · 넣기 applyLive 를 받는 책). nil 이면 받지 않는다 → 엔진은 readBook · updateBook 으로
    public var openBook: String? {
        get { lock.withLock { _openBook } }
        set { lock.withLock { _openBook = newValue?.uppercased() } }
    }

    /// applyLive 로 넣은 횟수
    public var liveApplied: Int { lock.withLock { _liveApplied } }

    /// readLive 로 읽은 횟수
    public var liveReads: Int { lock.withLock { _liveReads } }

    public var sharedSettings: JSONValue? {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }

    public var supportsSharedSettings: Bool { lock.withLock { _settings != nil } }

    public func readLibrary() async -> JSONValue? {
        lock.withLock { _libraryUnreadable ? nil : _library }
    }

    public func readBook(id: String) async -> BookRead {
        lock.withLock {
            let k = id.uppercased()
            if _unreadable.contains(k) { return .unreadable }
            return _books[k].map { .ok($0) } ?? .missing
        }
    }

    public func updateBook(id: String, _ transform: @Sendable (JSONValue?) -> JSONValue?) async throws {
        lock.withLock {
            let k = id.uppercased()
            // 읽을 수 없는 파일은 건드리지 않는다 (진짜 앱과 같게)
            if _unreadable.contains(k) { return }
            let next = transform(_books[k])
            _applied += 1
            _books[k] = next
        }
    }

    public func updateLibrary(_ transform: @Sendable (JSONValue) -> JSONValue) async throws {
        lock.withLock {
            _library = transform(_library)
            _applied += 1
            // 펼친 책이 지워졌으면 다른 책을 편다 (사용자가 만든 책 먼저, 없으면 예시 플래너)
            if case let .string(active)? = _library["activeID"],
               !Records.books(_library).contains(where: { $0["id"]?.stringValue == active }),
               case var .object(o) = _library {
                let bs = Records.books(_library)
                let next = bs.first { $0["isSample"] != .bool(true) } ?? bs.first
                o["activeID"] = next?["id"] ?? .null
                if o["activeID"] == .null { o["activeID"] = nil }
                _library = .object(o)
            }
        }
    }

    public func readLive(bookId: String, keys: [String]) async -> [String: JSONValue]? {
        lock.withLock {
            let k = bookId.uppercased()
            guard _openBook == k, let data = _books[k] else { return nil }
            _liveReads += 1
            var out: [String: JSONValue] = [:]
            for key in keys { out[key] = Self.recordValue(data, key) ?? .null }
            return out
        }
    }

    public func applyLive(bookId: String, keys: [String], _ transform: @Sendable ([String: JSONValue]) -> [String: JSONValue]) async -> Bool {
        lock.withLock {
            let k = bookId.uppercased()
            guard _openBook == k, var data = _books[k] else { return false }
            var cur: [String: JSONValue] = [:]
            for key in keys { cur[key] = Self.recordValue(data, key) ?? .null }
            let next = transform(cur)
            for key in keys {
                guard let pk = RecordKeys.parse(key), let v = next[key] else { continue }
                let value: JSONValue? = v.isNull ? nil : v
                switch pk.kind {
                case .day: data = Records.withDay(data, pk.date!, value)
                case .week: data = Records.withWeek(data, pk.date!, value)
                case .prefs:
                    if case var .object(o) = data, let value {
                        o["prefs"] = value
                        data = .object(o)
                    }
                default: break
                }
            }
            _books[k] = data
            _liveApplied += 1
            return true
        }
    }

    /// 책 JSON 에서 레코드 하나의 값 (하루 · 한 주 · 설정)
    static func recordValue(_ data: JSONValue, _ key: String) -> JSONValue? {
        guard let pk = RecordKeys.parse(key) else { return nil }
        switch pk.kind {
        case .day: return data["days"]?[pk.date!]
        case .week: return data["weeks"]?[pk.date!]
        case .prefs: return data["prefs"]
        default: return nil
        }
    }

    public func readSharedSettings() async -> JSONValue? { lock.withLock { _settings } }

    public func updateSharedSettings(_ transform: @Sendable (JSONValue) -> JSONValue) async throws {
        lock.withLock { _settings = transform(_settings ?? .object([:])) }
    }

    /// 앱에서 책 내용을 고친 것처럼
    public func edit(_ id: String, _ f: (JSONValue) -> JSONValue) {
        lock.withLock {
            let k = id.uppercased()
            guard let cur = _books[k] else { preconditionFailure("책이 없음 \(k)") }
            _books[k] = f(cur)
        }
    }

    /// 책장을 고친 것처럼
    public func editLibrary(_ f: (JSONValue) -> JSONValue) {
        lock.withLock { _library = f(_library) }
    }
}
