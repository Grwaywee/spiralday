import AppKit
import Foundation
import Security
import SpiraldayKit

/// 익명 사용 통계. 하루 한 번 앱 버전 · macOS 버전 · 칩 종류 · 언어와 무작위 설치 번호만 보낸다.
/// 플래너 기록은 보내지 않는다. 설정 → 데이터에서 끌 수 있다 (https://spiralday.com/privacy.html).
/// 운영 서버로는 우리가 내보낸 앱(Developer ID · 팀 SCQ7JJP5MN 서명)만 보낸다 — swift run · build.sh 로컬 빌드 ·
/// 애드혹 · 서명 없는 빌드 · 포크 · CI 는 보내지 않는다 (TelemetryGate). 시험은 SPIRALDAY_PING_URL 로 시험 서버에.
enum Telemetry {
    static let enabledKey = "telemetryEnabled"
    static let installIDKey = "telemetryInstallID"
    private static let lastDayKey = "telemetryLastPingDay"

    /// 이 실행이 어디로 보내는지 (또는 왜 보내지 않는지). 서명은 처음 한 번만 읽는다.
    static let decision: TelemetryGate.Decision = TelemetryGate.decide(
        signing: TelemetrySigning.current,
        override: ProcessInfo.processInfo.environment[TelemetryGate.overrideKey])

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
        guard d.string(forKey: lastDayKey) != today, case .send(let url) = decision, let body = payload() else { return }
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
    /// 보내는 곳은 하루 한 번 보내기와 같은 규칙 (출시 앱이 아니면 SPIRALDAY_PING_URL 의 시험 서버로만).
    @MainActor
    static func runPingTest() {
        guard case .send(let url) = decision else {
            if case .skip(let why) = decision { print("✗ 보내지 않아요: \(why.message)") }
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

        var message: String {
            switch self {
            case .notReleaseBuild:
                return "출시 서명(Developer ID · 팀 \(TelemetryGate.releaseTeamID))이 없는 빌드라 운영 서버로 보내지 않아요. "
                    + "시험하려면 \(TelemetryGate.overrideKey)=http://127.0.0.1:8787/ping 처럼 시험 서버를 주세요."
            case .badOverride:
                return "\(TelemetryGate.overrideKey) 값이 http(s) 주소가 아니에요."
            case .overrideIsProduction:
                return "출시 서명이 없는 빌드는 \(TelemetryGate.overrideKey) 로도 운영 서버에 보내지 않아요."
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
        let raw = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            return isRelease(signing) ? .send(production) : .skip(.notReleaseBuild)
        }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return .skip(.badOverride) }
        if isProduction(url), !isRelease(signing) { return .skip(.overrideIsProduction) }
        return .send(url)
    }
}

/// 실행 중인 이 프로세스의 코드 서명 읽기 (Security framework, 화면 없이 · 한 번만)
enum TelemetrySigning {
    /// 처음 쓸 때 한 번 읽어 둔다
    static let current: TelemetryGate.Signing = readSelf()

    /// 팀 SCQ7JJP5MN 의 Developer ID Application 서명이라는 요구 조건 (Apple 이 정한 Developer ID 요구 조건에 팀을 더한 것)
    static func developerIDRequirement(team: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// SecCodeCopySelf → 실행 중인 앱의 디스크 위 서명 → signing(of:)
    static func readSelf() -> TelemetryGate.Signing {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode
        else { return .unsigned }
        return signing(of: staticCode)
    }

    /// 디스크의 앱 · 실행 파일 (시험용: 실행하지 않고 서명만 읽는다 — 실행 중인 앱과 같은 signing(of:))
    static func read(at url: URL) -> TelemetryGate.Signing {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode
        else { return .unsigned }
        return signing(of: staticCode)
    }

    /// 서명 정보(SecCodeCopySigningInformation)의 팀 id, 그리고 그 팀의 Developer ID 요구 조건을 만족하는지.
    /// 요구 조건은 서명(코드 디렉터리) · 인증서 체인만 확인하고, 실행 파일의 페이지와 번들의 다른 파일(글꼴 · 그림)은
    /// 해시하지 않는다 — 실행 중인 프로세스의 페이지는 커널이 이미 서명과 맞춰 본다 (출시 앱에서 1ms 안팎, 실행 파일까지 해시하면 20ms).
    private static func signing(of staticCode: SecStaticCode) -> TelemetryGate.Signing {
        guard let team = teamID(of: staticCode) else { return .unsigned }
        guard let req = requirement(team: team) else { return .init(teamID: team, developerID: false) }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        return .init(teamID: team, developerID: SecStaticCodeCheckValidity(staticCode, flags, req) == errSecSuccess)
    }

    private static func teamID(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
        else { return nil }
        return team
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
