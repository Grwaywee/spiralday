import XCTest
import SpiraldayKit
import SpiraldaySync
@testable import Spiralday

/// Mac 동기화 화면의 말 · 입력 다루기 (Windows · iOS 앱과 같은 규칙, "이 Mac")
final class SyncTextTests: XCTestCase {
    func testCodeInputFormatsLikeTheEngineReadsIt() {
        XCTAssertEqual(SyncText.formatCodeInput("abcd efgh"), "ABCD-EFGH")
        XCTAssertEqual(SyncText.formatCodeInput("o1il-u"), "0111")          // O→0, I/L→1, U 는 버린다
        XCTAssertEqual(SyncText.formatCodeInput("ABCDEFGHJK"), "ABCD-EFGH")  // 8자까지
        XCTAssertEqual(SyncText.formatCodeInput("ab-c"), "ABC")
        XCTAssertFalse(SyncText.pairingCodeComplete("ABCD-EFG"))
        XCTAssertTrue(SyncText.pairingCodeComplete(Codes.newPairingCode()))
    }

    func testPastedLinkIsFoundInsideOtherText() {
        let secret = String(repeating: "A", count: 43)
        XCTAssertEqual(SyncText.pastedPairingLink("여기 SPIRALDAY-PAIR:1:\(secret) 붙여"), "SPIRALDAY-PAIR:1:\(secret)")
        XCTAssertNil(SyncText.pastedPairingLink("SPIRALDAY-PAIR:1:short"))
        XCTAssertNil(SyncText.pastedPairingLink("SPIRALDAY-PAIR:1:\(secret)B"), "44자는 연결 글이 아니다")
        XCTAssertNil(SyncText.pastedPairingLink("ABCD-EFGH"))
    }

    func testDigitsInputKeepsFourAsciiDigits() {
        XCTAssertEqual(SyncText.digitsInput("8 3-0 1 9"), "8301")
        XCTAssertEqual(SyncText.digitsInput("٨٣٠١"), "", "아라비아 숫자 같은 다른 글자 숫자는 받지 않는다")
        XCTAssertEqual(SyncText.digitsInput("12"), "12")
    }

    func testRecoveryGroupsAndCheckingTypedGroups() {
        let code = Codes.newRecoveryCode()
        let groups = SyncText.recoveryGroups(code)
        XCTAssertEqual(groups.count, 5)
        XCTAssertTrue(groups.allSatisfy { $0.count == 5 })
        XCTAssertEqual(groups.joined(separator: "-"), Codes.formatRecoveryCode(code))
        XCTAssertTrue(SyncText.groupMatches(groups[2].lowercased(), groups[2]))
        XCTAssertTrue(SyncText.groupMatches("10I0O", "10100"), "I → 1, O → 0")
        XCTAssertTrue(SyncText.groupMatches("1-0 1-0 0", "10100"), "빈칸 · 하이픈은 가리지 않는다")
        XCTAssertFalse(SyncText.groupMatches("", ""))
        XCTAssertFalse(SyncText.groupMatches("ABCDE", "ABCDF"))
        for _ in 0..<200 {
            let (a, b) = SyncText.pickCheckGroups()
            XCTAssertTrue(a < b && a >= 0 && b < 5)
        }
        XCTAssertEqual(SyncText.pickCheckGroups(random: { 0.99 }).1, 4)
        XCTAssertEqual(SyncText.pickCheckGroups(random: { 0 }).0, 0)
    }

    func testRecoveryInputHint() {
        XCTAssertTrue(SyncText.recoveryInputHint(Codes.newRecoveryCode().lowercased()).ok)
        XCTAssertFalse(SyncText.recoveryInputHint("").problem)
        XCTAssertEqual(SyncText.recoveryInputHint("").text, "하이픈(-)은 없어도 돼요. 대소문자도 가리지 않아요.")
        XCTAssertEqual(SyncText.recoveryInputHint("ABCDE-FG").text, "7/25")
        var bad = Array(Codes.newRecoveryCode())
        bad[0] = bad[0] == "A" ? "B" : "A"
        XCTAssertTrue(SyncText.recoveryInputHint(String(bad)).problem, "한 글자 틀리면 검사 값으로 알아챈다")
        XCTAssertTrue(SyncText.recoveryInputHint("ÄBCDE").problem)
        XCTAssertTrue(SyncText.recoveryInputHint(Codes.newRecoveryCode() + "AB").problem)
    }

    func testRecoveryFileAndPrintCardHaveTheCodeAndWhereToUseIt() {
        let code = Codes.newRecoveryCode()
        let at = Dates.parse("2026-10-02")!
        let text = SyncText.recoveryFileText(code, deviceName: "서재 Mac", at: at)
        XCTAssertTrue(text.contains(Codes.formatRecoveryCode(code)))
        XCTAssertTrue(text.contains("만든 기기: 서재 Mac"))
        XCTAssertTrue(text.contains("설정 → 동기화 → 복구 코드로 되살리기"))
        XCTAssertEqual(SyncText.recoveryFileName(at), "Spiralday 복구 코드 2026-10-02.txt")
        let html = SyncText.recoveryPrintHTML(groups: SyncText.recoveryGroups(code), at: at, deviceName: "<b>&</b>")
        XCTAssertTrue(html.contains(Codes.formatRecoveryCode(code)))
        XCTAssertTrue(html.contains("&lt;b&gt;&amp;&lt;/b&gt;"), "기기 이름은 HTML 로 읽히지 않게")
    }

    func testStatusLineForEveryStateSaysThisMac() {
        let now = Date()
        let ms = Int(now.timeIntervalSince1970 * 1000)
        for st in [SyncState.off, .idle, .syncing, .offline, .error, .quota, .removed, .groupGone] {
            let l = SyncText.statusLine(state: st, pending: 2, lastSyncAt: ms - 5000, error: nil, live: true, now: now)
            XCTAssertFalse(l.title.isEmpty, "\(st)")
            XCTAssertFalse(l.detail.contains("이 기기") || l.detail.contains("이 컴퓨터"), "Mac 은 '이 Mac': \(l.detail)")
        }
        XCTAssertEqual(SyncText.statusLine(state: .idle, pending: 0, lastSyncAt: ms - 5000, error: nil, live: false, now: now).detail,
                       "마지막으로 맞춘 때: 방금")
        XCTAssertEqual(SyncText.statusLine(state: .idle, pending: 0, lastSyncAt: ms - 180_000, error: nil, live: true, now: now).detail,
                       "다른 기기와 실시간으로 이어져 있어요 · 마지막으로 맞춘 때: 3분 전")
        XCTAssertEqual(SyncText.statusLine(state: .offline, pending: 3, lastSyncAt: nil, error: nil, live: false, now: now).detail,
                       "인터넷에 다시 연결되면 저절로 맞춰요. 이 Mac 에서 고친 기록 3개가 기다리고 있어요.")
        let err = SyncText.statusLine(state: .error, pending: 0, lastSyncAt: nil, error: "요청이 많아 잠깐 쉬고 있어요.", live: false, now: now)
        XCTAssertEqual(err.tone, .warn)
        XCTAssertEqual(err.detail, "요청이 많아 잠깐 쉬고 있어요. 저절로 다시 해 볼게요.")
        XCTAssertEqual(SyncText.statusLine(state: .quota, pending: 0, lastSyncAt: nil, error: nil, live: false).tone, .error)
        XCTAssertEqual(SyncText.statusLine(state: .removed, pending: 0, lastSyncAt: nil, error: nil, live: false).title, "이 Mac 은 동기화에서 빠졌어요")
        XCTAssertEqual(SyncText.statusLine(state: nil, pending: 0, lastSyncAt: nil, error: nil, live: false).tone, .busy)
        XCTAssertEqual(SyncText.statusShort(state: .offline, pending: 2, lastSyncAt: nil), "오프라인 · 기다리는 기록 2개")
        XCTAssertEqual(SyncText.statusShort(state: .idle, pending: 0, lastSyncAt: ms - 180_000, now: now), "동기화됨 · 3분 전")
    }

    func testEngineMessagesArePassedThroughInKorean() {
        XCTAssertEqual(SyncText.engineMessage("동기화 저장 공간(50MB)이 가득 찼어요."), "동기화 저장 공간(50MB)이 가득 찼어요.")
        XCTAssertNil(SyncText.engineMessage(nil))
        XCTAssertNil(SyncText.engineMessage(""))
        XCTAssertEqual(SyncText.engineMessage("책장을 읽을 수 없어 동기화를 시작하지 못했어요."),
                       SyncText.errorText(code: .libraryUnavailable, fallback: nil))
    }

    func testKeychainWordsMatchWhatHappened() {
        let e = KeychainError(status: -25308)
        XCTAssertTrue(SyncText.errorText(e, .launch).contains("읽지 못했어요"), "켤 때는 읽기 실패")
        XCTAssertTrue(SyncText.errorText(e).contains("두지 못했어요"), "하던 일에서는 저장 실패")
        XCTAssertEqual(SyncText.errorText(CredentialsUnreadable()), "이 Mac 의 동기화 열쇠를 열 수 없어요.")
    }

    func testEveryEngineErrorCodeHasPlainWords() {
        let codes: [SyncEngineError.Code] = [.notInGroup, .alreadyInGroup, .invalidCode, .deviceLimit, .pairingLimit, .pairingDenied,
                                             .pairingExpired, .digitsMismatch, .rateLimited, .codeJoinPaused, .wrongKey,
                                             .recoveryNotFound, .libraryUnavailable, .offline, .server]
        for c in codes {
            for ctx in [SyncFlowContext.general, .join, .restore, .pair] {
                let t = SyncText.errorText(SyncEngineError(c, "엔진의 말"), ctx)
                XCTAssertFalse(t.isEmpty)
                XCTAssertNotEqual(t, "엔진의 말", "\(c) 는 앱의 말로")
                XCTAssertFalse(t.contains("이 기기는") || t.contains("이 컴퓨터"), t)
            }
        }
        XCTAssertEqual(SyncText.errorText(SyncEngineError(.invalidArgument, "엔진의 말")), "엔진의 말", "모르는 코드는 엔진의 한국어 그대로")
        XCTAssertTrue(SyncText.errorText(code: .rateLimited, fallback: nil, .join, retryAfter: 600).contains("10분"))
        XCTAssertTrue(SyncText.errorText(code: .invalidCode, fallback: nil, .restore).hasPrefix("복구 코드가"))
        XCTAssertTrue(SyncText.errorText(code: .pairingDenied, fallback: nil, .pair).contains("숫자가 여러 번"))
        XCTAssertEqual(SyncText.errorText(NetworkError("offline")),
                       SyncText.errorText(code: .offline, fallback: nil))
    }

    func testWaitCountdownWipeAndPaintedTime() {
        XCTAssertEqual(SyncText.waitText(30), "30초")
        XCTAssertEqual(SyncText.waitText(299), "5분")
        XCTAssertEqual(SyncText.waitText(7200), "2시간")
        XCTAssertEqual(SyncText.waitText(nil), "1분")
        let now = Date()
        XCTAssertEqual(SyncText.countdown(now.addingTimeInterval(581.4), now: now), "9:41")
        XCTAssertEqual(SyncText.countdown(now.addingTimeInterval(-5), now: now), "0:00")
        XCTAssertEqual(SyncText.countdownSpoken(now.addingTimeInterval(62), now: now), "1분 2초 남음")
        XCTAssertTrue(SyncText.wipeConfirmMatches("지우기"))
        XCTAssertTrue(SyncText.wipeConfirmMatches("  지우기 "))
        XCTAssertFalse(SyncText.wipeConfirmMatches("지우"))
        XCTAssertFalse(SyncText.wipeConfirmMatches(""))
        XCTAssertEqual(SyncText.paintedText(minutes: 20), "20분")
        XCTAssertEqual(SyncText.paintedText(minutes: 180), "3시간")
        XCTAssertEqual(SyncText.paintedText(minutes: 130), "2시간 10분")
    }

    func testRelativeTimes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = Date()
        let ms = Int(now.timeIntervalSince1970 * 1000)
        XCTAssertEqual(SyncText.relativeTime(ms - 10_000, now: now, calendar: cal), "방금")
        XCTAssertEqual(SyncText.relativeTime(ms - 300_000, now: now, calendar: cal), "5분 전")
        XCTAssertTrue(SyncText.relativeTime(ms - 400 * 86_400_000, now: now, calendar: cal).hasSuffix("일"), "다른 해는 날짜만")
        XCTAssertTrue(SyncText.versionTime(ms - 5_000, now: now, calendar: cal).hasPrefix("오늘 "), "오늘은 초까지")
    }

    func testDeviceNamesAndLabels() {
        XCTAssertEqual(SyncText.clampDeviceName("  서재\n Mac\t "), "서재 Mac")
        XCTAssertEqual(SyncText.clampDeviceName(String(repeating: "가", count: 60)).count, 40)
        XCTAssertEqual(SyncText.platformLabel(.windows), "Windows PC")
        XCTAssertEqual(SyncText.platformLabel(nil), "새 기기", "모르는 플랫폼은 새 기기 (보낸 이름을 믿지 않는다)")
        XCTAssertEqual(SyncText.deviceTitle(name: nil, platform: .iPhone), "iPhone (이름 정하는 중)")
        XCTAssertEqual(SyncText.deviceTitle(name: "  ", platform: nil), "알 수 없는 기기")
        for p in SyncPlatform.allCases { XCTAssertNotNil(NSImage(systemSymbolName: SyncText.platformSymbol(p), accessibilityDescription: nil), "\(p)") }
        XCTAssertNotNil(NSImage(systemSymbolName: SyncText.platformSymbol(nil), accessibilityDescription: nil))
    }

    func testMergeAndGroupWords() {
        XCTAssertEqual(SyncText.localBooksText([]), "")
        XCTAssertEqual(SyncText.localBooksText(["업무", "개인"]), "플래너 2권(업무, 개인)")
        XCTAssertEqual(SyncText.localBooksText(["a", "b", "c", "d"]), "플래너 4권(a, b, c …)")
        XCTAssertEqual(SyncText.groupNamesText([SyncGroupDeviceName(name: "작은 iPad", platform: .iPad),
                                                 SyncGroupDeviceName(name: nil, platform: .windows)]), "‘작은 iPad’, ‘Windows PC’")
        let many = (0..<5).map { SyncGroupDeviceName(name: "기기\($0)", platform: nil) }
        XCTAssertEqual(SyncText.groupNamesText(many), "‘기기0’, ‘기기1’ 외 3대")
    }

    func testBookNoticesAndWarnings() {
        XCTAssertNil(SyncText.removedBooksNotice([]))
        XCTAssertEqual(SyncText.removedBooksNotice(["회사"]), "다른 기기에서 ‘회사’ 플래너를 지웠어요.")
        XCTAssertEqual(SyncText.removedBooksNotice(["회사", "집", "운동"]), "다른 기기에서 ‘회사’ 외 2권의 플래너를 지웠어요.")
        for w in [SyncWarning.massDeleteBooks, .massDeleteDays, .bookMissing, .bookUnlisted, .bookDeletedElsewhere, .clockSkew,
                  .undecryptable, .updateRequired, .libraryUnreadable, .recordTooLarge] {
            let t = SyncText.warningText(w)
            XCTAssertFalse(t.title.isEmpty || t.detail.isEmpty, "\(w)")
            XCTAssertFalse(t.detail.contains("이 기기") || t.detail.contains("이 컴퓨터"), t.detail)
        }
        XCTAssertTrue(SyncText.warningText(.bookDeletedElsewhere, bookName: "2025 다이어리").detail.hasPrefix("‘2025 다이어리’"))
    }

    func testVersionSummaries() {
        let task: (String, Int) -> JSONValue = { t, m in ["id": .string(UUID().uuidString), "text": .string(t), "mark": .number(Double(m))] }
        let day: JSONValue = ["tasks": .array([task("견적서 비교", 1), task(" ", 0), task("운동", 3)]),
                              "slots": .array((0..<144).map { $0 < 13 ? 1 : -1 }),
                              "comment": " 좋았다 ", "memos": ["메모", "", ""], "memoTags": ["", "", ""], "dayOff": true]
        let s = SyncText.daySummary(day)
        XCTAssertEqual(s.summary, "할 일 2개 · 칠한 시간 2시간 10분 · 메모 1개 · 한 줄 평 · DAY OFF")
        XCTAssertEqual(s.preview, ["○ 견적서 비교", "× 운동", "“좋았다”"])
        XCTAssertEqual(SyncText.daySummary(nil).summary, "비어 있음")
        XCTAssertTrue(SyncText.daySummary(["tasks": "망가진 값"]).empty)
        let week: JSONValue = ["goal": "책 한 권", "review": "", "stars": 3]
        XCTAssertEqual(SyncText.weekSummary(week).summary, "목표 · 별 3개")
        XCTAssertTrue(SyncText.weekSummary(["goal": "", "review": "", "stars": 0]).empty)
        let short = SyncText.versionRows(week: false, [(seq: 1, at: 0, current: true, value: ["slots": .array((0..<144).map { $0 < 2 ? 1 : -1 })])])
        XCTAssertEqual(short[0].summary, "칠한 시간 20분", "0시간을 붙이지 않는다")
    }

    func testServerChoiceKeepsTheGroupsServerAndReleaseBuildsTakeHttpsOnly() {
        let d = SyncMemoryDefaults()
        XCTAssertEqual(SyncServer.choose(groupURL: nil, defaults: d, environment: [:], allowOverride: false).url, SyncServerConfig.productionURL)
        XCTAssertEqual(SyncServer.choose(groupURL: "https://sync.example.com", defaults: d, environment: [:], allowOverride: false).source, .group)
        d.set("http://127.0.0.1:9000", forKey: SyncServer.overrideKey)
        XCTAssertEqual(SyncServer.choose(groupURL: nil, defaults: d, environment: [:], allowOverride: false).source, .production,
                       "출시 빌드는 숨은 덮어쓰기를 보지 않는다")
        XCTAssertEqual(SyncServer.choose(groupURL: nil, defaults: d, environment: [:], allowOverride: true).source, .developerOverride)
        let insecureGroup = SyncServer.choose(groupURL: "http://127.0.0.1:9000", defaults: d, environment: [:], allowOverride: false)
        XCTAssertEqual(insecureGroup.source, .production)
        XCTAssertEqual(insecureGroup.ignored, "http://127.0.0.1:9000")
        XCTAssertEqual(SyncServer.display(URL(string: "https://sync.spiralday.com")!), "sync.spiralday.com")
    }
}
