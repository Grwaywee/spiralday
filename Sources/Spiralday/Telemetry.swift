import AppKit
import Foundation

/// 익명 사용 통계. 하루 한 번 앱 버전 · macOS 버전 · 칩 종류 · 언어와 무작위 설치 번호만 보낸다.
/// 플래너 기록은 보내지 않는다. 설정 → 데이터에서 끌 수 있다 (https://spiralday.com/privacy.html).
enum Telemetry {
    static let enabledKey = "telemetryEnabled"
    static let installIDKey = "telemetryInstallID"
    private static let lastDayKey = "telemetryLastPingDay"

    /// 받는 곳 (테스트할 때는 환경 변수 SPIRALDAY_PING_URL 로 바꾼다)
    static var endpoint: URL {
        if let s = ProcessInfo.processInfo.environment["SPIRALDAY_PING_URL"], let u = URL(string: s) { return u }
        return URL(string: "https://leanagilehungry.com/api/spiralday/ping")!
    }

    @MainActor private static var observer: NSObjectProtocol?
    @MainActor private static var sending = false
    /// 실패한 뒤에는 앱으로 돌아올 때마다 다시 보내지 않고 한 시간 쉰다
    @MainActor private static var lastAttempt: Date?

    /// 앱을 켤 때 한 번. 오늘 아직 안 보냈으면 보내고, 앱으로 돌아올 때마다 날짜가 바뀌었는지 다시 본다.
    @MainActor
    static func start() {
        UserDefaults.standard.register(defaults: [enabledKey: true])
        _ = installID
        pingIfDue()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { pingIfDue() }
        }
    }

    /// 설치 번호: 처음 한 번 만드는 무작위 UUID (기기 정보에서 만들지 않는다)
    @MainActor
    static var installID: String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: installIDKey), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString.lowercased()
        d.set(id, forKey: installIDKey)
        return id
    }

    /// 켜져 있고 오늘(이 Mac 의 날짜) 아직 안 보냈으면 한 번 보낸다. 2xx 를 받았을 때만 보낸 날로 적는다.
    @MainActor
    private static func pingIfDue() {
        let d = UserDefaults.standard
        guard d.bool(forKey: enabledKey), !sending else { return }
        let today = Dates.key(Date())
        guard d.string(forKey: lastDayKey) != today, let body = payload() else { return }
        if let t = lastAttempt, Date().timeIntervalSince(t) < 3600 { return }
        lastAttempt = Date()
        sending = true
        Task { @MainActor in
            defer { sending = false }
            guard let status = try? await send(body), (200..<300).contains(status) else { return }
            UserDefaults.standard.set(today, forKey: lastDayKey)
        }
    }

    /// `Spiralday --ping-test`: 날짜와 상관없이 한 번 보내고 결과를 찍은 뒤 끝낸다
    @MainActor
    static func runPingTest() {
        guard let body = payload() else {
            print("✗ Info.plist 에 버전이 없어요 (build/Spiralday.app 으로 실행하세요)")
            exit(1)
        }
        print("POST \(endpoint.absoluteString)")
        print(String(decoding: body, as: UTF8.self))
        Task { @MainActor in
            do {
                let status = try await send(body)
                print("HTTP \(status)")
                fflush(stdout)
                exit((200..<300).contains(status) ? 0 : 1)
            } catch {
                print("✗ \(error.localizedDescription)")
                fflush(stdout)
                exit(1)
            }
        }
    }

    // MARK: 보내는 내용

    private struct Payload: Encodable {
        let id: String
        let v: String
        let b: Int
        let os: String
        let arch: String
        let lang: String
    }

    /// 보낼 JSON. 번들로 실행하지 않아 버전을 모르면 nil (보내지 않는다).
    @MainActor
    private static func payload() -> Data? {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String,
              v.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              let b = (info?["CFBundleVersion"] as? String).flatMap(Int.init), (1...100_000).contains(b)
        else { return nil }
        let p = Payload(id: installID, v: v, b: b, os: osVersion, arch: arch, lang: language)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        return try? enc.encode(p)
    }

    /// "15.6.1"
    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// 칩 종류. Rosetta 로 돌아도 Apple Silicon 이면 arm64.
    private static var arch: String {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 && v == 1 ? "arm64" : "x86_64"
    }

    /// 첫 번째 선호 언어의 언어 코드 ("ko", "en", "ja" …)
    private static var language: String {
        guard let first = Locale.preferredLanguages.first,
              let code = Locale(identifier: first).language.languageCode?.identifier.lowercased(),
              code.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil
        else { return "ko" }
        return code
    }

    // MARK: 전송

    /// 쿠키 · 캐시 없는 일회용 세션, 10초 제한
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 10
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// 한 번 보내고 HTTP 상태 코드를 돌려준다
    private static func send(_ body: Data) async throws -> Int {
        var req = URLRequest(url: endpoint, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 기본 User-Agent 의 기기·시스템 정보 대신 앱 이름만
        req.setValue("Spiralday", forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        let (_, resp) = try await session.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }
}
