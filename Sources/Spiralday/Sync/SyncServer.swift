import Foundation
import SpiraldaySync

// ─────────────────────────────────────────────────────────────────────────────
// 동기화 서버 주소 (먼저 맞는 것):
//   1. 그룹에 들어 있으면 들어간 때의 서버 (빌드가 바뀌어도 그룹은 옮겨 가지 않는다 — Windows · iOS 앱과 같은 규칙)
//   2. (디버그 빌드만) 숨은 개발용 덮어쓰기: UserDefaults "SpiraldaySyncServerURLOverride"
//      — 설정 → 동기화의 개발자 설정, 또는 실행 인수 `-SpiraldaySyncServerURLOverride http://127.0.0.1:<포트>`
//   3. (디버그 빌드만) 환경 변수 SPIRALDAY_SYNC_URL
//   4. 빌드 설정: Info.plist 의 SpiraldaySyncServerURL
//   5. https://sync.spiralday.com
// 출시 빌드(build.sh 는 -c release)는 2 · 3 을 보지 않고 https 만 받는다 (사용자 Mac 에서 다른 서버로 옮겨 갈 길이 없다).
// ─────────────────────────────────────────────────────────────────────────────

struct SyncServerChoice: Equatable {
    enum Source: String { case group, developerOverride, environment, build, production }

    let url: URL
    let source: Source
    /// 쓰지 못한 주소 (개발자 설정에 보인다)
    var ignored: String?
}

enum SyncServer {
    static var overrideKey: String { SyncServerConfig.overrideDefaultsKey }

    /// 덮어쓰기 · http 개발 서버를 받는 빌드인지 (디버그만)
    static var allowsOverride: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// 쓸 수 있는 주소인지: 디버그 빌드는 https 와 개발 서버의 http, 출시 빌드는 https 만
    static func validate(_ s: String, allowInsecure: Bool) -> URL? {
        guard let u = SyncServerConfig.validate(s) else { return nil }
        return allowInsecure || u.scheme?.lowercased() == "https" ? u : nil
    }

    static func choose(groupURL: String?, defaults: UserDefaults = .standard, bundle: Bundle = .main,
                       environment: [String: String] = ProcessInfo.processInfo.environment,
                       allowOverride: Bool = SyncServer.allowsOverride) -> SyncServerChoice {
        var ignored: String?
        if let g = groupURL, !g.isEmpty {
            if let u = validate(g, allowInsecure: allowOverride) { return SyncServerChoice(url: u, source: .group) }
            ignored = g
        }
        if allowOverride {
            if let s = defaults.string(forKey: overrideKey), !s.isEmpty {
                if let u = validate(s, allowInsecure: true) { return SyncServerChoice(url: u, source: .developerOverride, ignored: ignored) }
                ignored = ignored ?? s
            }
            if let s = environment[SyncServerConfig.environmentKey], !s.isEmpty {
                if let u = validate(s, allowInsecure: true) { return SyncServerChoice(url: u, source: .environment, ignored: ignored) }
                ignored = ignored ?? s
            }
        }
        if let s = bundle.object(forInfoDictionaryKey: SyncServerConfig.infoPlistKey) as? String,
           let u = validate(s, allowInsecure: allowOverride) {
            return SyncServerChoice(url: u, source: .build, ignored: ignored)
        }
        return SyncServerChoice(url: SyncServerConfig.productionURL, source: .production, ignored: ignored)
    }

    /// 개발자 설정에서 덮어쓰기를 두거나 지운다. 맞지 않는 주소면 false
    @discardableResult
    static func setOverride(_ s: String?, defaults: UserDefaults = .standard) -> Bool {
        guard allowsOverride else { return false }
        return SyncServerConfig.setDeveloperOverride(s, defaults: defaults)
    }

    /// 화면에 보일 주소 ("sync.spiralday.com")
    static func display(_ url: URL) -> String {
        var s = url.absoluteString
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        return s
    }
}
