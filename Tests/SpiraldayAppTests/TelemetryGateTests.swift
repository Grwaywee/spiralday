import Foundation
import Security
import XCTest
@testable import Spiralday

/// 익명 사용 통계를 누가 보내는가: 운영 서버로는 팀 SCQ7JJP5MN 의 Developer ID 로 서명한 출시 앱만.
/// swift run · build.sh 로컬(애드혹) · 서명 없음 · 다른 팀 · 포크 · CI 는 보내지 않고, SPIRALDAY_PING_URL 의 시험 서버로만 보낼 수 있다.
/// (보내지도, UserDefaults · ~/Library/Application Support/Spiralday 를 건드리지도 않는다)
final class TelemetryGateTests: XCTestCase {
    private let release = TelemetryGate.Signing(teamID: "SCQ7JJP5MN", developerID: true)
    private let local = "http://127.0.0.1:8787/ping"

    private func decide(_ s: TelemetryGate.Signing, _ override: String? = nil) -> TelemetryGate.Decision {
        TelemetryGate.decide(signing: s, override: override)
    }

    // MARK: 운영 서버로는 출시 앱만

    func testOnlyTheReleaseSignatureSendsToProduction() {
        XCTAssertEqual(decide(release), .send(TelemetryGate.production))
        XCTAssertEqual(TelemetryGate.production.absoluteString, "https://leanagilehungry.com/api/spiralday/ping")
    }

    func testLocalAdHocUnsignedForkAndCIBuildsDoNotSend() {
        // 애드혹 · 서명 없음 (swift run · build.sh 로컬 · CI)
        XCTAssertEqual(decide(.unsigned), .skip(.notReleaseBuild))
        // 다른 팀의 Developer ID (포크)
        XCTAssertEqual(decide(.init(teamID: "ABCDE12345", developerID: true)), .skip(.notReleaseBuild))
        // 우리 팀이지만 Developer ID 가 아니거나 서명이 맞지 않음 (Apple Development 인증서 · 서명 뒤에 고친 앱)
        XCTAssertEqual(decide(.init(teamID: "SCQ7JJP5MN", developerID: false)), .skip(.notReleaseBuild))
        // 팀 id 는 정확히 같아야 한다
        XCTAssertEqual(decide(.init(teamID: "scq7jjp5mn", developerID: true)), .skip(.notReleaseBuild))
        XCTAssertEqual(decide(.init(teamID: "SCQ7JJP5MN ", developerID: true)), .skip(.notReleaseBuild))
        XCTAssertEqual(decide(.init(teamID: nil, developerID: true)), .skip(.notReleaseBuild))
    }

    // MARK: SPIRALDAY_PING_URL (시험 서버)

    func testOverrideToATestServerWorksFromAnyBuild() {
        let url = URL(string: local)!
        XCTAssertEqual(decide(.unsigned, local), .send(url))
        XCTAssertEqual(decide(release, local), .send(url), "출시 앱도 시험할 때는 시험 서버로만")
        XCTAssertEqual(decide(.unsigned, "  \(local)\n"), .send(url))
        XCTAssertEqual(decide(.unsigned, "https://staging.example.com/ping"), .send(URL(string: "https://staging.example.com/ping")!))
    }

    func testEmptyOverrideIsNoOverride() {
        XCTAssertEqual(decide(.unsigned, ""), .skip(.notReleaseBuild))
        XCTAssertEqual(decide(.unsigned, "   "), .skip(.notReleaseBuild))
        XCTAssertEqual(decide(release, ""), .send(TelemetryGate.production))
    }

    /// 시험하려고 준 값이 틀렸으면 운영 서버로 새지 않고 아무 데도 보내지 않는다 (출시 앱이어도)
    func testUnreadableOverrideSendsNowhere() {
        for bad in ["not a url", "localhost:8787/ping", "127.0.0.1:8787", "ftp://127.0.0.1/ping",
                    "file:///tmp/ping", "http://", "https:///ping", "//127.0.0.1:8787/ping"] {
            XCTAssertEqual(decide(.unsigned, bad), .skip(.badOverride), bad)
            XCTAssertEqual(decide(release, bad), .skip(.badOverride), bad)
        }
    }

    /// 출시 서명이 없으면 SPIRALDAY_PING_URL 로 운영 서버를 가리켜도 보내지 않는다
    func testOverrideCannotPointAnUnsignedBuildAtProduction() {
        for prod in ["https://leanagilehungry.com/api/spiralday/ping",
                     "http://leanagilehungry.com/api/spiralday/ping",
                     "HTTPS://LeanAgileHungry.COM/api/spiralday/ping",
                     "https://leanagilehungry.com./api/spiralday/ping",
                     "https://www.leanagilehungry.com/api/spiralday/ping",
                     "https://leanagilehungry.com:443/other"] {
            XCTAssertEqual(decide(.unsigned, prod), .skip(.overrideIsProduction), prod)
            XCTAssertEqual(decide(.init(teamID: "ABCDE12345", developerID: true), prod), .skip(.overrideIsProduction), prod)
            if case .send = decide(release, prod) {} else { XCTFail("출시 앱은 운영 주소를 줘도 보낸다: \(prod)") }
        }
    }

    func testProductionHostMatchIsExact() {
        XCTAssertTrue(TelemetryGate.isProduction(URL(string: "https://leanagilehungry.com/x")!))
        XCTAssertTrue(TelemetryGate.isProduction(URL(string: "https://api.leanagilehungry.com/x")!))
        XCTAssertFalse(TelemetryGate.isProduction(URL(string: "https://notleanagilehungry.com/x")!))
        XCTAssertFalse(TelemetryGate.isProduction(URL(string: "https://leanagilehungry.com.example.org/x")!))
        XCTAssertFalse(TelemetryGate.isProduction(URL(string: "http://127.0.0.1:8787/ping")!))
    }

    func testSkipMessagesAreKorean() {
        XCTAssertTrue(TelemetryGate.Skip.notReleaseBuild.message.contains("SPIRALDAY_PING_URL"))
        XCTAssertTrue(TelemetryGate.Skip.notReleaseBuild.message.contains("SCQ7JJP5MN"))
        XCTAssertTrue(TelemetryGate.Skip.badOverride.message.contains("SPIRALDAY_PING_URL"))
        XCTAssertTrue(TelemetryGate.Skip.overrideIsProduction.message.contains("운영 서버"))
    }

    // MARK: --ping-test 는 운영 서버로 보내지 않는다 (출시 앱이어도 — Windows 와 같다)

    /// 회의적 검토 (2026-10-10, 낮음): 출시 서명 앱에서 SPIRALDAY_PING_URL 없이 --ping-test 를 돌리면 하루 한 번 보내기의 규칙을 그대로 따라
    /// 운영 서버로 보냈다 — 시험 한 번이 운영 통계에 섞였다. --ping-test 는 서명과 상관없이 운영 서버가 아닌 시험 서버로만.
    func testPingTestNeedsATestServerEvenForTheRelease() {
        for none in [nil, "", "   ", "\n"] as [String?] {
            XCTAssertEqual(TelemetryGate.pingTestDecision(override: none), .skip(.pingTestNeedsTestServer), String(describing: none))
        }
        // 하루 한 번 보내기와 다른 규칙: 출시 앱은 운영 서버로 보내지만, --ping-test 는 아니다
        XCTAssertEqual(decide(release), .send(TelemetryGate.production))
        XCTAssertNotEqual(TelemetryGate.pingTestDecision(override: nil), .send(TelemetryGate.production))
    }

    func testPingTestRefusesProductionAndUnreadableOverrides() {
        for prod in ["https://leanagilehungry.com/api/spiralday/ping",
                     "http://leanagilehungry.com/api/spiralday/ping",
                     "HTTPS://LeanAgileHungry.COM/api/spiralday/ping",
                     "https://leanagilehungry.com./api/spiralday/ping",
                     "https://www.leanagilehungry.com/api/spiralday/ping",
                     "  https://leanagilehungry.com:443/other  "] {
            XCTAssertEqual(TelemetryGate.pingTestDecision(override: prod), .skip(.pingTestNeverProduction), prod)
        }
        for bad in ["not a url", "localhost:8787/ping", "ftp://127.0.0.1/ping", "file:///tmp/ping", "http://"] {
            XCTAssertEqual(TelemetryGate.pingTestDecision(override: bad), .skip(.badOverride), bad)
        }
    }

    func testPingTestSendsToATestServer() {
        XCTAssertEqual(TelemetryGate.pingTestDecision(override: local), .send(URL(string: local)!))
        XCTAssertEqual(TelemetryGate.pingTestDecision(override: " \(local)\n"), .send(URL(string: local)!))
        XCTAssertEqual(TelemetryGate.pingTestDecision(override: "https://staging.example.com/ping"),
                       .send(URL(string: "https://staging.example.com/ping")!))
    }

    /// Telemetry.runPingTest 가 쓰는 곳 (환경 변수에서) — 하루 한 번 보내기의 decision() 이 아니다
    func testRunPingTestReadsOnlyTheTestServer() {
        XCTAssertEqual(Telemetry.pingTestTarget(environment: [:]), .skip(.pingTestNeedsTestServer))
        XCTAssertEqual(Telemetry.pingTestTarget(environment: [TelemetryGate.overrideKey: TelemetryGate.production.absoluteString]),
                       .skip(.pingTestNeverProduction))
        XCTAssertEqual(Telemetry.pingTestTarget(environment: [TelemetryGate.overrideKey: local]), .send(URL(string: local)!))
    }

    func testPingTestMessagesAreKorean() {
        for why in [TelemetryGate.Skip.pingTestNeedsTestServer, .pingTestNeverProduction] {
            XCTAssertTrue(why.message.contains("--ping-test"), why.message)
            XCTAssertTrue(why.message.contains("SPIRALDAY_PING_URL"), why.message)
            XCTAssertTrue(why.message.contains("시험 서버"), why.message)
        }
        XCTAssertTrue(TelemetryGate.Skip.pingTestNeverProduction.message.contains("운영 서버"))
        XCTAssertTrue(TelemetryGate.Skip.signingUnreadable.message.contains("다시"))
    }

    // MARK: 서명 확인의 잠깐의 실패는 기억하지 않는다

    /// 회의적 검토 (2026-10-10, 낮음): 서명은 처음 한 번 읽어 프로세스 끝까지 썼다 (static let) — 켤 때 한 번 잠깐 실패하면
    /// 출시 앱이 앱을 끌 때까지 통계를 보내지 않았다. 확실한 결과만 기억하고, 잠깐의 실패는 다음 하루 확인 때 다시 읽는다.
    func testOnlyADefiniteResultIsJudgedDefinite() {
        let team = TelemetryGate.releaseTeamID
        // 확실: 출시 서명 · 우리 팀이지만 Developer ID 요구 조건에 맞지 않음 · 팀 없음(애드혹 · 서명 없음) · 다른 팀
        XCTAssertEqual(TelemetrySigning.judge(team: team, validity: errSecSuccess), .definite(release))
        XCTAssertEqual(TelemetrySigning.judge(team: team, validity: errSecCSReqFailed),
                       .definite(.init(teamID: team, developerID: false)))
        XCTAssertEqual(TelemetrySigning.judge(team: nil, validity: errSecIO), .definite(.unsigned))
        XCTAssertEqual(TelemetrySigning.judge(team: "", validity: errSecSuccess), .definite(.unsigned))
        for status in [errSecSuccess, errSecCSReqFailed, errSecIO, errSecCSSignatureFailed] {
            XCTAssertEqual(TelemetrySigning.judge(team: "ABCDE12345", validity: status),
                           .definite(.init(teamID: "ABCDE12345", developerID: status == errSecSuccess)), "\(status)")
        }
        // 잠깐의 실패: 우리 팀인데 확인 자체가 이번에 실패 (디스크 · Security, 업데이트가 앱 묶음을 바꾸는 중 등)
        for status in [errSecIO, errSecCSSignatureFailed, errSecCSStaticCodeNotFound, errSecCSInternalError, errSecAllocate] {
            XCTAssertEqual(TelemetrySigning.judge(team: team, validity: status), .transient(status), "\(status)")
        }
    }

    func testATransientCheckSendsNowhereButATestServer() {
        let blip = TelemetrySigning.Check.transient(errSecIO)
        XCTAssertEqual(TelemetryGate.decide(check: blip, override: nil), .skip(.signingUnreadable))
        XCTAssertEqual(TelemetryGate.decide(check: blip, override: TelemetryGate.production.absoluteString), .skip(.signingUnreadable))
        XCTAssertEqual(TelemetryGate.decide(check: blip, override: "not a url"), .skip(.badOverride))
        XCTAssertEqual(TelemetryGate.decide(check: blip, override: local), .send(URL(string: local)!))
        // 확실한 결과는 서명 규칙 그대로
        XCTAssertEqual(TelemetryGate.decide(check: .definite(release), override: nil), .send(TelemetryGate.production))
        XCTAssertEqual(TelemetryGate.decide(check: .definite(.unsigned), override: nil), .skip(.notReleaseBuild))
    }

    func testTheMemoRereadsAfterATransientFailureAndKeepsADefiniteResult() {
        var answers: [TelemetrySigning.Check] = [.transient(errSecIO), .transient(errSecCSSignatureFailed), .definite(release)]
        var reads = 0
        let memo = TelemetrySigningMemo { reads += 1; return answers.removeFirst() }
        XCTAssertEqual(memo.check(), .transient(errSecIO))
        XCTAssertNil(memo.known, "잠깐의 실패는 기억하지 않는다")
        XCTAssertEqual(memo.check(), .transient(errSecCSSignatureFailed), "다음 확인 때 다시 읽는다")
        XCTAssertEqual(memo.check(), .definite(release))
        XCTAssertEqual(memo.known, release)
        XCTAssertEqual(memo.check(), .definite(release))
        XCTAssertEqual(reads, 3, "확실한 결과를 얻은 뒤에는 다시 읽지 않는다")

        // 확실히 우리 출시 앱이 아니면 (애드혹 · 다른 팀) 한 번 읽고 끝
        var adHocReads = 0
        let adHoc = TelemetrySigningMemo { adHocReads += 1; return .definite(.unsigned) }
        for _ in 0..<5 { XCTAssertEqual(adHoc.check(), .definite(.unsigned)) }
        XCTAssertEqual(adHocReads, 1)
    }

    /// 하루 한 번 보내기가 쓰는 Telemetry.decision() 도 그 기억을 쓴다: 처음 확인이 잠깐 실패해도 다음 확인에서 출시 앱이면 운영 서버로
    @MainActor
    func testTheDailyDecisionRetriesAfterATransientFailure() throws {
        guard ProcessInfo.processInfo.environment[TelemetryGate.overrideKey] == nil else {
            throw XCTSkip("\(TelemetryGate.overrideKey) 가 있는 환경")
        }
        let saved = Telemetry.signing
        defer { Telemetry.signing = saved }
        var answers: [TelemetrySigning.Check] = [.transient(errSecIO), .definite(release)]
        Telemetry.signing = TelemetrySigningMemo { answers.removeFirst() }
        XCTAssertEqual(Telemetry.decision(), .skip(.signingUnreadable), "잠깐 실패한 확인에서는 보내지 않는다")
        XCTAssertEqual(Telemetry.decision(), .send(TelemetryGate.production), "다음 확인에서 다시 읽는다")
        XCTAssertEqual(Telemetry.decision(), .send(TelemetryGate.production))
        XCTAssertTrue(answers.isEmpty)
    }

    // MARK: 진짜 서명 읽기 (Security framework)

    func testTheRequirementCompiles() {
        var req: SecRequirement?
        let text = TelemetrySigning.developerIDRequirement(team: TelemetryGate.releaseTeamID)
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, SecCSFlags(), &req), errSecSuccess, text)
        XCTAssertNotNil(req)
    }

    /// 시험을 돌리는 이 프로세스는 출시 앱이 아니다 — 시험 실행이 운영 통계로 가지 않는다
    @MainActor
    func testThisTestProcessIsNotARelease() {
        XCTAssertFalse(TelemetryGate.isRelease(TelemetrySigning.readSelf()))
        guard case .definite(let s) = TelemetrySigning.checkSelf() else {
            return XCTFail("이 시험 프로세스의 서명은 확실하게 읽혀야 한다 (잠깐의 실패가 아니다)")
        }
        XCTAssertFalse(TelemetryGate.isRelease(s))
        XCTAssertEqual(TelemetryGate.decide(signing: s, override: nil), .skip(.notReleaseBuild))
        if ProcessInfo.processInfo.environment[TelemetryGate.overrideKey] == nil {
            XCTAssertEqual(Telemetry.decision(), .skip(.notReleaseBuild))
        }
    }

    /// build.sh 가 서명 인증서 없이 만드는 애드혹 서명은 팀이 없어 보내지 않는다
    func testAdHocSignatureIsNotARelease() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("adhoc-true")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: exe)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "-s", "-", exe.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("codesign 으로 애드혹 서명을 하지 못함") }
        let s = TelemetrySigning.read(at: exe)
        XCTAssertNil(s.teamID)
        XCTAssertFalse(TelemetryGate.isRelease(s))
    }

    /// 이 Mac 에 공식 출시 앱이 깔려 있으면 (실행하지 않고 서명만 읽어) 출시 앱으로 알아보는지 본다.
    /// 깔린 Spiralday.app 은 건드리지 않는 것이 규칙이라 (읽기만 해도) 평소 swift test 에서는 돌지 않는다 —
    /// SPIRALDAY_READ_INSTALLED=1 을 줄 때만 (회의적 검토 2026-10-10)
    func testTheInstalledReleaseIsRecognized() throws {
        guard ProcessInfo.processInfo.environment["SPIRALDAY_READ_INSTALLED"] == "1" else {
            throw XCTSkip("SPIRALDAY_READ_INSTALLED=1 일 때만 /Applications/Spiralday.app 의 서명을 읽는다")
        }
        let app = URL(fileURLWithPath: "/Applications/Spiralday.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("/Applications/Spiralday.app 없음") }
        let s = TelemetrySigning.read(at: app)
        guard s.teamID == TelemetryGate.releaseTeamID else { throw XCTSkip("공식 서명이 아닌 Spiralday.app") }
        XCTAssertTrue(s.developerID, "팀 \(TelemetryGate.releaseTeamID) 의 Developer ID 요구 조건을 만족해야 한다")
        XCTAssertTrue(TelemetryGate.isRelease(s))
    }

    /// 다른 팀의 진짜 Developer ID 앱 (포크가 자기 인증서로 서명한 것과 같다) — Developer ID 이지만 보내지 않는다.
    /// 이 Mac 에 깔린 앱의 서명만 읽는다 (실행하지 않는다).
    func testAnotherTeamsDeveloperIDAppIsNotARelease() throws {
        let candidates = ["Google Chrome", "Docker", "Slack", "Figma", "zoom.us", "Obsidian", "Microsoft Edge", "Firefox", "Visual Studio Code"]
        let found = candidates.lazy
            .map { URL(fileURLWithPath: "/Applications/\($0).app") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ($0, TelemetrySigning.read(at: $0)) }
            .first { $0.1.developerID && $0.1.teamID != nil && $0.1.teamID != TelemetryGate.releaseTeamID }
        guard let (app, s) = found else { throw XCTSkip("다른 팀의 Developer ID 앱이 /Applications 에 없음") }
        XCTAssertFalse(TelemetryGate.isRelease(s), app.path)
        XCTAssertEqual(TelemetryGate.decide(signing: s, override: nil), .skip(.notReleaseBuild), app.path)
        // 요구 조건 자체도 우리 팀만 받는다
        var code: SecStaticCode?
        var req: SecRequirement?
        XCTAssertEqual(SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &code), errSecSuccess)
        XCTAssertEqual(SecRequirementCreateWithString(
            TelemetrySigning.developerIDRequirement(team: TelemetryGate.releaseTeamID) as CFString, SecCSFlags(), &req), errSecSuccess)
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        XCTAssertNotEqual(SecStaticCodeCheckValidity(try XCTUnwrap(code), flags, try XCTUnwrap(req)), errSecSuccess, app.path)
    }

    /// Mac App Store 서명 (팀 id 는 있지만 Developer ID 가 아니다) — Apple Development 처럼 Developer ID 로 알아보지 않는다
    func testAMacAppStoreSignatureIsNotDeveloperID() throws {
        let candidates = ["KakaoTalk", "Numbers", "Keynote", "Pages", "Final Cut Pro", "Logic Pro", "Motion", "TestFlight"]
        let found = candidates.lazy
            .map { URL(fileURLWithPath: "/Applications/\($0).app") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ($0, TelemetrySigning.read(at: $0)) }
            .first { $0.1.teamID != nil && !$0.1.developerID }
        guard let (app, s) = found else { throw XCTSkip("팀 id 가 있는 Mac App Store 앱이 /Applications 에 없음") }
        XCTAssertFalse(TelemetryGate.isRelease(s), app.path)
    }
}
