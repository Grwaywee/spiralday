// 동기화 서버 주소. 운영: https://sync.spiralday.com
//
// 정하는 순서 (앞의 것이 이긴다):
//   1. 숨은 개발용 덮어쓰기: UserDefaults "SpiraldaySyncServerURLOverride"
//      (개발 메뉴에서 setDeveloperOverride(_:) 로 · Xcode 스킴의 실행 인수 `-SpiraldaySyncServerURLOverride http://127.0.0.1:<포트>`)
//   2. 환경 변수 SPIRALDAY_SYNC_URL (테스트 · 명령줄)
//   3. 빌드 설정: Info.plist 의 "SpiraldaySyncServerURL" (xcconfig 의 SPIRALDAY_SYNC_URL 을 넣는다)
//   4. 기본값 https://sync.spiralday.com
// 주소는 https 여야 한다. http 는 개발 서버(localhost · 127.0.0.1 · ::1 · *.local · 사설망 IP)에만 쓸 수 있다.
import Foundation

public enum SyncServerConfig {
    public static let productionURL = URL(string: "https://sync.spiralday.com")!
    public static let overrideDefaultsKey = "SpiraldaySyncServerURLOverride"
    public static let environmentKey = "SPIRALDAY_SYNC_URL"
    public static let infoPlistKey = "SpiraldaySyncServerURL"

    public enum Source: String, Sendable {
        case developerOverride, environment, buildSetting, production
    }

    /// 지금 쓸 서버 주소와 어디서 왔는지
    public static func resolve(bundle: Bundle = .main, defaults: UserDefaults = .standard,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> (url: URL, source: Source) {
        if let s = defaults.string(forKey: overrideDefaultsKey), let u = validate(s) { return (u, .developerOverride) }
        if let s = environment[environmentKey], let u = validate(s) { return (u, .environment) }
        if let s = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String, let u = validate(s) { return (u, .buildSetting) }
        return (productionURL, .production)
    }

    /// 개발 메뉴: 덮어쓰기 주소를 두거나 (nil 이면) 지운다. 맞지 않는 주소면 false
    @discardableResult
    public static func setDeveloperOverride(_ s: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else {
            defaults.removeObject(forKey: overrideDefaultsKey)
            return true
        }
        guard let u = validate(s) else { return false }
        defaults.set(u.absoluteString, forKey: overrideDefaultsKey)
        return true
    }

    /// 쓸 수 있는 서버 주소인지 (https, 또는 개발 서버의 http). 경로 · 쿼리는 받지 않는다. 끝의 / 는 뗀다
    public static func validate(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty,
              c.path.isEmpty, c.query == nil, c.fragment == nil, c.user == nil, c.password == nil else { return nil }
        switch scheme {
        case "https": break
        case "http": guard isDevelopmentHost(host) else { return nil }
        default: return nil
        }
        return URL(string: s)
    }

    /// http 로 붙어도 되는 개발 서버 (이 기기 · 같은 망)
    public static func isDevelopmentHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "127.0.0.1" || h == "::1" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, h.split(separator: ".").count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])) || parts[0] == 127
    }
}
