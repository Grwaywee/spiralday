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
