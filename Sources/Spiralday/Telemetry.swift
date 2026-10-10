import AppKit
import Foundation
import Security
import SpiraldayKit

/// 익명 사용 통계. 하루 한 번 앱 버전 · macOS 버전 · 칩 종류 · 언어와 무작위 설치 번호만 보낸다.
/// 플래너 기록은 보내지 않는다. 설정 → 데이터에서 끌 수 있다 (https://spiralday.com/privacy.html).
/// 운영 서버로는 우리가 내보낸 앱(Developer ID · 팀 SCQ7JJP5MN 서명)만 보낸다 — swift run · build.sh 로컬 빌드 ·
/// 애드혹 · 서명 없는 빌드 · 포크 · CI 는 보내지 않는다 (TelemetryGate). 시험은 SPIRALDAY_PING_URL 로 시험 서버에.
/// `--ping-test` 는 출시 앱이어도 운영 서버로 보내지 않는다 (시험 서버로만).
enum Telemetry {
    static let enabledKey = "telemetryEnabled"
    static let installIDKey = "telemetryInstallID"
    private static let lastDayKey = "telemetryLastPingDay"

    /// 이 실행의 서명 확인. 확실한 결과만 기억하고, 잠깐의 실패는 다음 하루 확인(pingIfDue) 때 다시 읽는다
    /// (시험이 가짜 확인으로 바꿔 끼울 수 있게 var).
    @MainActor static var signing = TelemetrySigningMemo(read: TelemetrySigning.checkSelf)

    /// 지금 어디로 보내는지 (또는 왜 보내지 않는지) — 하루 한 번 보내기가 보낼 차례일 때마다 본다
    @MainActor
    static func decision() -> TelemetryGate.Decision {
        TelemetryGate.decide(check: signing.check(), override: ProcessInfo.processInfo.environment[TelemetryGate.overrideKey])
    }

    /// `--ping-test` 가 보낼 곳: SPIRALDAY_PING_URL 의 시험 서버만 (서명과 상관없이 — 출시 앱이어도 운영 서버로는 보내지 않는다)
    static func pingTestTarget(environment: [String: String]) -> TelemetryGate.Decision {
        TelemetryGate.pingTestDecision(override: environment[TelemetryGate.overrideKey])
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
        guard d.string(forKey: lastDayKey) != today, case .send(let url) = decision(), let body = payload() else { return }
        if let t = lastAttempt, Date().timeIntervalSince(t) < 3600 { return }
        lastAttempt = Date()
        sending = true
        Task { @MainActor in
            defer { sending = false }
            guard let status = try? await send(body, to: url), (200..<300).contains(status) else { return }
            UserDefaults.standard.set(today, forKey: lastDayKey)
        }
    }

    /// `Spiralday --ping-test`: 날짜와 상관없이 한 번 보내고 결과를 찍은 뒤 끝낸다.
    /// 보내는 곳은 SPIRALDAY_PING_URL 의 시험 서버만 — 출시 앱이어도 운영 서버로는 보내지 않는다 (Windows 와 같다).
    /// 주소가 없거나 · 알아볼 수 없거나 · 운영 서버면 이유를 찍고 1 로 끝낸다.
    @MainActor
    static func runPingTest() {
        let target = pingTestTarget(environment: ProcessInfo.processInfo.environment)
        guard case .send(let url) = target else {
            if case .skip(let why) = target { print("✗ 보내지 않아요: \(why.message)") }
            fflush(stdout)
            exit(1)
        }
        guard let body = payload() else {
            print("✗ Info.plist 에 버전이 없어요 (build/Spiralday.app 으로 실행하세요)")
            exit(1)
        }
        print("POST \(url.absoluteString)")
        print(String(decoding: body, as: UTF8.self))
        Task { @MainActor in
            do {
                let status = try await send(body, to: url)
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
    private static func send(_ body: Data, to url: URL) async throws -> Int {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 기본 User-Agent 의 기기·시스템 정보 대신 앱 이름만
        req.setValue("Spiralday", forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        let (_, resp) = try await session.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }
}

// MARK: - 누가 보내는가

/// 통계를 어디로 보낼지 (또는 보내지 않을지) 정하는 순수한 규칙. 서명 · 환경 변수는 밖에서 읽어 넘긴다.
///
/// - 운영 서버(leanagilehungry.com)로는 우리가 내보낸 앱만: Apple 이 발급한 Developer ID Application 인증서로
///   팀 SCQ7JJP5MN 이 서명한 실행 (release/release.sh 의 `Developer ID Application: LeanAgileHungry Inc. (SCQ7JJP5MN)`).
/// - 그 밖의 빌드(swift run · build.sh 로컬 · 애드혹 · 서명 없음 · 다른 팀 · 포크 · CI)는 보내지 않는다.
/// - SPIRALDAY_PING_URL 로 운영 서버가 아닌 http(s) 주소를 주면 어느 빌드든 그곳으로만 보낸다 (시험용).
///   값이 있는데 알아볼 수 없으면 아무 데도 보내지 않는다 — 시험하려던 실행이 운영 서버로 새지 않게.
/// - 서명을 이번에 읽지 못했으면(잠깐의 실패) 운영 서버로 보내지 않고, 다음 확인 때 다시 읽는다 (decide(check:override:)).
/// - `--ping-test` 는 따로: 늘 시험 서버로만 (pingTestDecision).
enum TelemetryGate {
    /// 공식 출시 서명의 Apple 개발자 팀
    static let releaseTeamID = "SCQ7JJP5MN"
    /// 운영 통계 서버
    static let production = URL(string: "https://leanagilehungry.com/api/spiralday/ping")!
    /// 시험 서버 주소를 주는 환경 변수
    static let overrideKey = "SPIRALDAY_PING_URL"

    /// 실행 중인 앱의 코드 서명에서 읽은 것
    struct Signing: Equatable {
        /// 서명의 팀 id (애드혹 · 서명 없음이면 nil)
        var teamID: String?
        /// 그 팀의 Apple 발급 Developer ID Application 인증서로 서명했고 서명이 유효한지
        var developerID: Bool

        static let unsigned = Signing(teamID: nil, developerID: false)
    }

    enum Decision: Equatable {
        case send(URL)
        case skip(Skip)
    }

    enum Skip: Equatable {
        /// 출시 서명이 없는 빌드 — 운영 서버로 보내지 않는다
        case notReleaseBuild
        /// SPIRALDAY_PING_URL 이 http(s) 주소가 아니다
        case badOverride
        /// 출시 서명이 없는데 SPIRALDAY_PING_URL 이 운영 서버를 가리킨다
        case overrideIsProduction
        /// 이번에는 서명을 읽지 못했다 (잠깐의 실패) — 기억하지 않고 다음 확인 때 다시 읽는다
        case signingUnreadable
        /// --ping-test 인데 SPIRALDAY_PING_URL 이 없다
        case pingTestNeedsTestServer
        /// --ping-test 의 SPIRALDAY_PING_URL 이 운영 서버를 가리킨다 (출시 앱이어도 보내지 않는다)
        case pingTestNeverProduction

        var message: String {
            switch self {
            case .notReleaseBuild:
                return "출시 서명(Developer ID · 팀 \(TelemetryGate.releaseTeamID))이 없는 빌드라 운영 서버로 보내지 않아요. "
                    + "시험하려면 \(TelemetryGate.overrideKey)=http://127.0.0.1:8787/ping 처럼 시험 서버를 주세요."
            case .badOverride:
                return "\(TelemetryGate.overrideKey) 값이 http(s) 주소가 아니에요."
            case .overrideIsProduction:
                return "출시 서명이 없는 빌드는 \(TelemetryGate.overrideKey) 로도 운영 서버에 보내지 않아요."
            case .signingUnreadable:
                return "이번에는 앱 서명을 읽지 못해 보내지 않아요. 다음 확인 때 다시 읽어요."
            case .pingTestNeedsTestServer:
                return "--ping-test 는 시험 서버로만 보내요. "
                    + "\(TelemetryGate.overrideKey)=http://127.0.0.1:8787/ping 처럼 운영 서버가 아닌 주소를 주세요."
            case .pingTestNeverProduction:
                return "--ping-test 는 출시 앱이어도 운영 서버(\(TelemetryGate.production.host ?? ""))로 보내지 않아요. "
                    + "\(TelemetryGate.overrideKey) 에 시험 서버 주소를 주세요."
            }
        }
    }

    /// 출시 앱인지: 팀 SCQ7JJP5MN 의 Developer ID 서명
    static func isRelease(_ s: Signing) -> Bool {
        s.developerID && s.teamID == releaseTeamID
    }

    /// 주소가 운영 서버(leanagilehungry.com 과 그 하위 이름)인지
    static func isProduction(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        while host.hasSuffix(".") { host.removeLast() }
        let prod = production.host!.lowercased()
        return host == prod || host.hasSuffix("." + prod)
    }

    static func decide(signing: Signing, override: String?) -> Decision {
        let raw = trimmed(override)
        guard !raw.isEmpty else {
            return isRelease(signing) ? .send(production) : .skip(.notReleaseBuild)
        }
        guard let url = overrideURL(raw) else { return .skip(.badOverride) }
        if isProduction(url), !isRelease(signing) { return .skip(.overrideIsProduction) }
        return .send(url)
    }

    /// 서명 확인 결과로: 확실하면 위의 규칙 그대로. 잠깐 실패했으면 운영 서버로는 보내지 않는다 (출시 앱인지 모르므로) —
    /// 시험 서버 주소는 서명과 상관없으니 그대로, 알아볼 수 없는 값이면 아무 데도.
    static func decide(check: TelemetrySigning.Check, override: String?) -> Decision {
        switch check {
        case .definite(let signing):
            return decide(signing: signing, override: override)
        case .transient:
            switch decide(signing: .unsigned, override: override) {
            case .skip(.notReleaseBuild), .skip(.overrideIsProduction): return .skip(.signingUnreadable)
            case let other: return other
            }
        }
    }

    /// `--ping-test` 가 보낼 곳: 운영 서버가 아닌 SPIRALDAY_PING_URL 만. 서명과 상관없다 — 출시 앱이어도 운영 서버로는 보내지 않아,
    /// 시험 한 번이 운영 통계에 섞이지 않는다 (Windows 의 --ping-test 와 같다).
    static func pingTestDecision(override: String?) -> Decision {
        let raw = trimmed(override)
        guard !raw.isEmpty else { return .skip(.pingTestNeedsTestServer) }
        guard let url = overrideURL(raw) else { return .skip(.badOverride) }
        return isProduction(url) ? .skip(.pingTestNeverProduction) : .send(url)
    }

    private static func trimmed(_ override: String?) -> String {
        override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// SPIRALDAY_PING_URL 값 → http(s) 주소 (알아볼 수 없으면 nil)
    private static func overrideURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}

/// 서명 확인을 프로세스 동안 기억하는 곳 — 확실한 결과만 기억한다 (출시 서명이거나, 확실히 아님: 애드혹 · 서명 없음 · 다른 팀 ·
/// Developer ID 요구 조건에 맞지 않음). 잠깐의 실패(Security · 디스크, 업데이트가 앱 묶음을 바꾸는 중 등)는 기억하지 않아
/// 다음 확인 때 다시 읽는다. 예전에는 처음 읽은 것을 프로세스 끝까지 써서(static let), 켤 때 한 번 실패하면 출시 앱이
/// 앱을 끌 때까지 통계를 보내지 않았다.
final class TelemetrySigningMemo {
    private let read: () -> TelemetrySigning.Check
    /// 기억한 확실한 결과
    private(set) var known: TelemetryGate.Signing?

    init(read: @escaping () -> TelemetrySigning.Check) {
        self.read = read
    }

    func check() -> TelemetrySigning.Check {
        if let known { return .definite(known) }
        let c = read()
        if case .definite(let s) = c { known = s }
        return c
    }
}

/// 실행 중인 이 프로세스의 코드 서명 읽기 (Security framework, 화면 없이)
enum TelemetrySigning {
    /// 서명 확인 한 번의 결과
    enum Check: Equatable {
        /// 확실한 결과 — 프로세스 동안 기억해도 된다
        case definite(TelemetryGate.Signing)
        /// 이번에는 확인하지 못했다 (그 OSStatus) — 기억하지 않고 다음에 다시
        case transient(OSStatus)

        var signing: TelemetryGate.Signing? {
            if case .definite(let s) = self { return s }
            return nil
        }
    }

    /// 팀 SCQ7JJP5MN 의 Developer ID Application 서명이라는 요구 조건 (Apple 이 정한 Developer ID 요구 조건에 팀을 더한 것)
    static func developerIDRequirement(team: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// SecCodeCopySelf → 실행 중인 앱의 디스크 위 서명 → check(of:)
    static func checkSelf() -> Check {
        var code: SecCode?
        var staticCode: SecStaticCode?
        let copied = SecCodeCopySelf(SecCSFlags(), &code)
        guard copied == errSecSuccess, let code else { return .transient(failure(copied)) }
        let found = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
        guard found == errSecSuccess, let staticCode else { return .transient(failure(found)) }
        return check(of: staticCode)
    }

    /// 실행 중인 앱의 서명 (확인하지 못했으면 서명 없음으로 본다 — 시험용)
    static func readSelf() -> TelemetryGate.Signing { checkSelf().signing ?? .unsigned }

    /// 디스크의 앱 · 실행 파일 (시험용: 실행하지 않고 서명만 읽는다 — 실행 중인 앱과 같은 check(of:))
    static func read(at url: URL) -> TelemetryGate.Signing {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode
        else { return .unsigned }
        return check(of: staticCode).signing ?? .unsigned
    }

    /// 서명 정보(SecCodeCopySigningInformation)의 팀 id, 그리고 그 팀의 Developer ID 요구 조건을 만족하는지.
    /// 요구 조건은 서명(코드 디렉터리) · 인증서 체인만 확인하고, 실행 파일의 페이지와 번들의 다른 파일(글꼴 · 그림)은
    /// 해시하지 않는다 — 실행 중인 프로세스의 페이지는 커널이 이미 서명과 맞춰 본다 (출시 앱에서 1ms 안팎, 실행 파일까지 해시하면 20ms).
    private static func check(of staticCode: SecStaticCode) -> Check {
        var info: CFDictionary?
        let read = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        if read == errSecCSUnsigned { return .definite(.unsigned) }
        guard read == errSecSuccess, let dict = info as? [String: Any] else { return .transient(failure(read)) }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        guard let team, !team.isEmpty else { return judge(team: nil, validity: errSecSuccess) }
        guard let req = requirement(team: team) else {
            // 팀 id 꼴(영문 대문자 · 숫자 10자)이 아니면 우리 팀일 수 없다. 우리 팀의 요구 조건을 이번에 만들지 못한 것은 다음에 다시
            return judge(team: team, validity: team == TelemetryGate.releaseTeamID ? errSecCSInternalError : errSecCSReqFailed)
        }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        return judge(team: team, validity: SecStaticCodeCheckValidity(staticCode, flags, req))
    }

    /// 팀 id 와 그 팀의 Developer ID 요구 조건 확인(SecStaticCodeCheckValidity)의 결과 → 확실한지, 잠깐의 실패인지.
    /// - 팀 없음(애드혹 · 서명 없음) · 다른 팀: 확실히 우리 출시 앱이 아니다 (확인이 무엇을 돌려줬든)
    /// - 우리 팀: 맞으면(errSecSuccess) 출시 앱, 요구 조건에 맞지 않으면(errSecCSReqFailed — Apple Development 등) 확실히 아님,
    ///   그 밖의 실패(디스크 · 서명 읽기 · Security 내부, 업데이트가 앱 묶음을 바꾸는 중 등)는 잠깐의 실패로 본다
    static func judge(team: String?, validity: OSStatus) -> Check {
        guard let team, !team.isEmpty else { return .definite(.unsigned) }
        switch validity {
        case errSecSuccess:
            return .definite(.init(teamID: team, developerID: true))
        case errSecCSReqFailed:
            return .definite(.init(teamID: team, developerID: false))
        default:
            return team == TelemetryGate.releaseTeamID ? .transient(validity) : .definite(.init(teamID: team, developerID: false))
        }
    }

    /// 실패라고 했는데 상태가 errSecSuccess 인 경우(값이 비어 온 것)도 실패 코드로
    private static func failure(_ status: OSStatus) -> OSStatus {
        status == errSecSuccess ? errSecCSInternalError : status
    }

    private static func requirement(team: String) -> SecRequirement? {
        // 팀 id 는 영문 대문자 · 숫자 10자 — 요구 조건 글에 다른 것이 섞이지 않게
        guard team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { return nil }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(developerIDRequirement(team: team) as CFString, SecCSFlags(), &req) == errSecSuccess
        else { return nil }
        return req
    }
}
