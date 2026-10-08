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

    // MARK: 진짜 서명 읽기 (Security framework)

    func testTheRequirementCompiles() {
        var req: SecRequirement?
        let text = TelemetrySigning.developerIDRequirement(team: TelemetryGate.releaseTeamID)
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, SecCSFlags(), &req), errSecSuccess, text)
        XCTAssertNotNil(req)
    }

    /// 시험을 돌리는 이 프로세스는 출시 앱이 아니다 — 시험 실행이 운영 통계로 가지 않는다
    func testThisTestProcessIsNotARelease() {
        XCTAssertFalse(TelemetryGate.isRelease(TelemetrySigning.readSelf()))
        XCTAssertFalse(TelemetryGate.isRelease(TelemetrySigning.current))
        XCTAssertEqual(TelemetryGate.decide(signing: TelemetrySigning.current, override: nil), .skip(.notReleaseBuild))
        if ProcessInfo.processInfo.environment[TelemetryGate.overrideKey] == nil {
            XCTAssertEqual(Telemetry.decision, .skip(.notReleaseBuild))
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

    /// 이 Mac 에 공식 출시 앱이 깔려 있으면 (실행하지 않고 서명만 읽어) 출시 앱으로 알아보는지 본다
    func testTheInstalledReleaseIsRecognized() throws {
        let app = URL(fileURLWithPath: "/Applications/Spiralday.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("/Applications/Spiralday.app 없음") }
        let s = TelemetrySigning.read(at: app)
        guard s.teamID == TelemetryGate.releaseTeamID else { throw XCTSkip("공식 서명이 아닌 Spiralday.app") }
        XCTAssertTrue(s.developerID, "팀 \(TelemetryGate.releaseTeamID) 의 Developer ID 요구 조건을 만족해야 한다")
        XCTAssertTrue(TelemetryGate.isRelease(s))
    }
}
