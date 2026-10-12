import CryptoKit
import Foundation
import XCTest
@testable import SpiraldayKit

/// 앱 안 ‘소식’ 의 규칙 (Docs/InAppNews.md) — 공유 벡터 Tests/Fixtures/news-rules.json 을 SpiraldayKit 으로 그대로 돌린다.
/// 같은 파일을 Windows · Android web (web/tests/news.test.ts) 과 참고 구현 (node Scripts/news-check.mjs --fixtures) 도 통과해야 한다.
/// iPhone · iPad 는 KitSharedVectorsTests 에서 같은 파일을 읽는다.
final class InAppNewsTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtureURL = root.appendingPathComponent("Tests/Fixtures/news-rules.json")
    /// 공유 벡터의 바이트 (sha256). 이 값이 바뀌면 비공개 저장소의 web/tests/fixtures/news-rules.json 도 같은 바이트로 함께 바꾼다
    static let fixtureSHA256 = "9b64bb475da6f2628729da9f46b20ddee44046ca1ff6ba34a49796bc53976890"

    private func fixture() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtureURL)) as? [String: Any])
    }

    // MARK: 같은 바이트

    func testSharedVectorsAreTheAgreedBytes() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, Self.fixtureSHA256,
                       "news-rules.json 이 바뀌었어요 — 비공개 저장소 web/tests/fixtures/news-rules.json 에 같은 바이트로 복사하고 이 값을 함께 바꿔요")
        XCTAssertEqual(data.count, 66_262)
        // 비공개 저장소가 옆에 있으면 (SPIRALDAY_APPS_REPO=<spiralday-apps 경로>) 그 파일과 바이트를 견준다
        if let apps = ProcessInfo.processInfo.environment["SPIRALDAY_APPS_REPO"], !apps.isEmpty {
            let other = URL(fileURLWithPath: apps).appendingPathComponent("web/tests/fixtures/news-rules.json")
            guard FileManager.default.fileExists(atPath: other.path) else {
                throw XCTSkip("\(other.path) 이 아직 없어요 (비공개 저장소에 복사하기 전)")
            }
            XCTAssertEqual(try Data(contentsOf: other), data, "두 저장소의 news-rules.json 이 바이트까지 같아야 해요")
        }
    }

    func testConstantsMatchRequestAndLimits() throws {
        let f = try fixture()
        let limits = try XCTUnwrap(f["limits"] as? [String: Int])
        XCTAssertEqual(limits, [
            "maxBytes": NewsRules.Limits.maxBytes, "maxItems": NewsRules.Limits.maxItems, "maxDepth": NewsRules.Limits.maxDepth,
            "idMax": NewsRules.Limits.idMax, "titleMax": NewsRules.Limits.titleMax, "bodyMax": NewsRules.Limits.bodyMax,
            "linkMax": NewsRules.Limits.linkMax, "seenMax": NewsRules.Limits.seenMax,
        ])
        let r = try XCTUnwrap(f["request"] as? [String: Any])
        XCTAssertEqual(r["url"] as? String, NewsRules.Request.url.absoluteString)
        XCTAssertEqual(r["method"] as? String, NewsRules.Request.method)
        XCTAssertEqual(r["headers"] as? [String: String], NewsRules.Request.headers)
        XCTAssertEqual(r["conditional"] as? [String], NewsRules.Request.conditional)
        XCTAssertEqual(r["noQueryString"] as? Bool, true)
        XCTAssertNil(NewsRules.Request.url.query)
        XCTAssertNil(NewsRules.Request.url.fragment)
        XCTAssertEqual(r["cookies"] as? Bool, NewsRules.Request.cookies)
        XCTAssertEqual(r["followRedirects"] as? Bool, NewsRules.Request.followRedirects)
        XCTAssertEqual((r["timeoutSeconds"] as? NSNumber)?.doubleValue, NewsRules.Request.timeoutSeconds)
        XCTAssertEqual(r["minMinutesBetweenTries"] as? Int, NewsRules.Request.minMinutesBetweenTries)
        XCTAssertEqual(r["refreshHoursWhileOpen"] as? Int, NewsRules.Request.refreshHoursWhileOpen)
        XCTAssertEqual(r["openAfterAwayMinutes"] as? Int, NewsRules.Request.openAfterAwayMinutes)
    }

    // MARK: 날짜 · 버전 · 링크

    /// 벡터의 값: 글이 아니면 늘 아님
    private func str(_ v: Any) -> String? { v as? String }

    func testDates() throws {
        let rows = try XCTUnwrap(fixture()["dates"] as? [[Any]])
        XCTAssertGreaterThan(rows.count, 15)
        for r in rows {
            let ok = r[1] as! Bool
            XCTAssertEqual(str(r[0]).map(NewsRules.isDate) ?? false, ok, "\(r[0])")
        }
    }

    func testVersions() throws {
        let v = try XCTUnwrap(fixture()["versions"] as? [String: Any])
        for r in try XCTUnwrap(v["valid"] as? [[Any]]) {
            XCTAssertEqual(str(r[0]).flatMap(NewsRules.parseVersion) != nil, r[1] as! Bool, "\(r[0])")
        }
        for r in try XCTUnwrap(v["compare"] as? [[Any]]) {
            XCTAssertEqual(NewsRules.compareVersions(r[0] as! String, r[1] as! String), (r[2] as! NSNumber).intValue, "\(r)")
        }
    }

    func testLinks() throws {
        let rows = try XCTUnwrap(fixture()["links"] as? [[Any]])
        XCTAssertGreaterThan(rows.count, 20)
        for r in rows {
            XCTAssertEqual(str(r[0]).map(NewsRules.isAllowedLink) ?? false, r[1] as! Bool, "\(r[0])")
        }
    }

    // MARK: parse · select · fetch

    func testParseVectors() throws {
        let f = try fixture()
        let cases = try XCTUnwrap(f["parse"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 25)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let bytes = try XCTUnwrap(try Self.feedBytes(f, c), name)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            let r = NewsRules.parseFeed(bytes)
            XCTAssertEqual(r.feed != nil, expect["accepted"] as? Bool, "\(name): \(r)")
            guard let feed = r.feed else { continue }
            XCTAssertEqual(feed.items.map(\.id), expect["ids"] as? [String], name)
            if let links = expect["links"] as? [String: Any] {
                var got: [String: String?] = [:]
                for it in feed.items { got[it.id] = it.link }
                XCTAssertEqual(got.count, links.count, name)
                for (id, want) in links {
                    XCTAssertTrue(got.keys.contains(id), "\(name) — \(id)")
                    XCTAssertEqual(got[id] ?? nil, want as? String, "\(name) — \(id)")
                }
            }
        }
    }

    func testSelectVectors() throws {
        let f = try fixture()
        let defaults = try XCTUnwrap(f["selectDefaults"] as? [String: Any])
        let bundled = try XCTUnwrap(f["bundled"] as? [String: Any])
        let cases = try XCTUnwrap(f["select"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 20)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            var items: [NewsItem] = []
            if let bytes = try Self.feedBytes(f, c) {
                let feed = try XCTUnwrap(NewsRules.parseFeed(bytes).feed, "\(name): the feed is not accepted")
                items = feed.items
            }
            let envDict = (defaults["env"] as! [String: Any]).merging(c["env"] as? [String: Any] ?? [:]) { $1 }
            let stateDict = (defaults["state"] as! [String: Any]).merging(c["state"] as? [String: Any] ?? [:]) { $1 }
            let env = NewsEnv(platform: envDict["platform"] as! String, appVersion: envDict["appVersion"] as! String,
                              today: envDict["today"] as! String, lang: envDict["lang"] as! String,
                              syncOn: envDict["syncOn"] as! Bool, firstRun: envDict["firstRun"] as! Bool)
            let state = Self.state(stateDict)
            let doc: Any = (c["bundled"] as? String).map { bundled[$0]! } ?? c["bundled"] ?? bundled[defaults["bundled"] as! String]!
            let notes = NewsRules.parseBundled(try JSONSerialization.data(withJSONObject: doc))
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])

            let r = NewsRules.open(env: env, state: state, items: items, notes: notes)
            XCTAssertEqual(r.card, Self.card(expect["card"]), "\(name) — card")
            XCTAssertEqual(r.save, Self.state(try XCTUnwrap(expect["save"] as? [String: Any])), "\(name) — save")
            let l = NewsRules.list(env: env, state: r.save, items: items, notes: notes)
            let want = try XCTUnwrap(expect["list"] as? [[String: Any]])
            XCTAssertEqual(l.rows.map(\.id), want.map { $0["id"] as! String }, "\(name) — list")
            for (g, w) in zip(l.rows, want) {
                XCTAssertEqual(g.title, w["title"] as? String, "\(name) — \(g.id) title")
                XCTAssertEqual(g.body, w["body"] as? String, "\(name) — \(g.id) body")
                XCTAssertEqual(g.link, w["link"] as? String, "\(name) — \(g.id) link")
                XCTAssertEqual(g.unseen, w["unseen"] as? Bool, "\(name) — \(g.id) unseen")
            }
            XCTAssertEqual(l.dot, expect["dot"] as? Bool, "\(name) — dot")
            // 그 뒤 설정 › 소식을 열면 점이 모두 사라진다
            let after = NewsRules.markListSeen(env: env, state: r.save, items: items, notes: notes)
            XCTAssertFalse(NewsRules.list(env: env, state: after, items: items, notes: notes).dot, "\(name) — after opening the list")
        }
    }

    func testFetchVectors() throws {
        let cases = try XCTUnwrap(fixture()["fetch"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 8)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let status = (c["status"] as? NSNumber)?.intValue
            let body: Data? = switch c["body"] as? String {
            case "valid": Data(#"{"version":1,"items":[]}"#.utf8)
            case "invalid": Data(#"{"version":2,"items":[]}"#.utf8)
            case "tooBig": Data(repeating: 0x20, count: NewsRules.Limits.maxBytes + 1)
            default: nil
            }
            let want = c["expect"] as? String
            XCTAssertEqual(NewsRules.replacesCache(status: status, body: body) ? "replace" : "keep", want, name)
            // 앱이 쓰는 길 (NewsFetcher.outcome) 도 같은 답
            let result: NewsTransportResult = status.map { .response(status: $0, headers: ["ETag": "\"e\""], body: body ?? Data()) }
                ?? .failed("timeout")
            if case .replaced = NewsFetcher.outcome(result) { XCTAssertEqual(want, "replace", name) } else { XCTAssertEqual(want, "keep", name) }
        }
    }

    // MARK: 벡터 밖의 규칙

    func testFeedOnTheSiteIsReadWhole() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("site/news/news.json"))
        let feed = try XCTUnwrap(NewsRules.parseFeed(data).feed, "site/news/news.json 을 앱이 읽지 않아요")
        XCTAssertEqual(feed.dropped, [], "앱이 버리는 항목이 있어요")
        XCTAssertEqual(feed.linkRemoved, [], "앱이 링크를 빼는 항목이 있어요")
    }

    /// 앱에 넣는 노트 (build.sh 가 Docs/release-notes/whats-new.json 을 .app 에 복사한다): 적은 노트가 모두 읽히고 버전은 한 번씩
    func testBundledNotesAreAllRead() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Docs/release-notes/whats-new.json"))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let written = try XCTUnwrap(raw["notes"] as? [[String: Any]])
        let notes = NewsRules.parseBundled(data)
        XCTAssertFalse(notes.isEmpty)
        XCTAssertEqual(notes.count, written.count, "건너뛰는 노트가 있어요 (버전 · 날짜 · 600자 · 넣지 못하는 글자)")
        for (i, a) in notes.enumerated() {
            for b in notes[(i + 1)...] { XCTAssertNotEqual(NewsRules.compareVersions(a.app, b.app), 0, "같은 버전의 노트가 둘: \(a.app)") }
            XCTAssertNotNil(a.body.en, "\(a.app): 영어도 적어요")
            XCTAssertFalse(a.body.ko.contains("설치"), "\(a.app): 설치 안내는 빼요")
            // 소식 안의 길 표기는 ‘설정 › …’ 하나로 (카드 아래 글 · iPhone · iPad · Windows · Android 와 같게)
            XCTAssertFalse(a.body.ko.contains("설정 →") || (a.body.en ?? "").contains("Settings →"), "\(a.app): ‘설정 › …’ 로 적어요")
            // 릴리스 노트가 있는 버전만
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("Docs/release-notes/\(a.app).md").path),
                          "\(a.app): Docs/release-notes/\(a.app).md 가 없어요")
        }
    }

    func testTextIsCountedInCodePointsAndControlCharactersAreRefused() throws {
        func feed(title: String, body: String = "본문") -> Data {
            let item: [String: Any] = ["id": "a", "date": "2026-10-01", "kind": "notice", "importance": "normal",
                                       "title": ["ko": title], "body": ["ko": body]]
            return try! JSONSerialization.data(withJSONObject: ["version": 1, "items": [item]])
        }
        // 가족 이모지 하나 = 글자 묶음 1 · 코드 포인트 7 · UTF-16 11
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(family.unicodeScalars.count, 7)
        XCTAssertEqual(NewsRules.parseFeed(feed(title: String(repeating: family, count: 11))).feed?.items.count, 1, "77 코드 포인트")
        XCTAssertEqual(NewsRules.parseFeed(feed(title: String(repeating: family, count: 12))).feed?.items.count, 0, "84 코드 포인트")
        XCTAssertEqual(NewsRules.parseFeed(feed(title: "a\u{202E}b")).feed?.items.count, 0, "방향 제어")
        XCTAssertEqual(NewsRules.parseFeed(feed(title: "a\nb")).feed?.items.count, 0, "제목은 한 줄")
        XCTAssertEqual(NewsRules.parseFeed(feed(title: "t", body: "a\r\nb")).feed?.items.count, 0, "줄바꿈은 \\n 만")
        XCTAssertEqual(NewsRules.parseFeed(feed(title: "t", body: "**굵게** <b>x</b>")).feed?.items.first?.body.ko, "**굵게** <b>x</b>",
                       "HTML · 마크다운은 글 그대로")
    }

    func testJSONReaderIsStrict() {
        func accepted(_ s: String) -> Bool { NewsRules.parseFeed(Data(s.utf8)).feed != nil }
        XCTAssertTrue(accepted(#"{"version":1,"items":[]}"#))
        XCTAssertTrue(accepted(" \n\t{\"version\" : 1.0 , \"items\" : [ ] }\r\n"))
        XCTAssertFalse(accepted(#"{"version":1,"items":[],}"#), "끝의 쉼표")
        XCTAssertFalse(accepted(#"{"version":1,"items":[]} x"#), "뒤에 남은 글")
        XCTAssertFalse(accepted(#"{"version":01,"items":[]}"#), "0 으로 시작하는 수")
        XCTAssertFalse(accepted("{\"version\":1,\"items\":[],\"x\":\"a\u{01}b\"}"), "글 안의 제어 문자")
        XCTAssertFalse(accepted(#"{"version":1,"items":[],"x":"\udc00"}"#), "낮은 서로게이트 혼자")
        XCTAssertFalse(accepted(#"{"version":1,"items":[],"\ud800":1}"#), "키의 서로게이트")
        XCTAssertFalse(accepted(#"// x"# + "\n" + #"{"version":1,"items":[]}"#), "주석")
        XCTAssertFalse(NewsRules.parseFeed(Data([0xFF, 0xFE] + Array(#"{"version":1,"items":[]}"#.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })).feed != nil,
                       "UTF-16 은 읽지 않는다")
        XCTAssertFalse(NewsRules.parseFeed(Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF] + Array(#"{"version":1,"items":[]}"#.utf8))).feed != nil,
                       "BOM 은 하나만 뗀다")
        // 같은 키가 둘이면 뒤의 것 (JS 와 같다)
        XCTAssertTrue(accepted(#"{"version":2,"version":1,"items":[]}"#))
    }

    func testDisplayDateUsesTheCalendarDateAsWritten() {
        XCTAssertEqual(NewsRules.displayDate("2026-10-20", today: "2026-10-21", lang: "ko"), "10월 20일")
        XCTAssertEqual(NewsRules.displayDate("2025-12-03", today: "2026-10-21", lang: "ko"), "2025년 12월 3일")
        XCTAssertEqual(NewsRules.displayDate("2026-10-20", today: "2026-01-01", lang: "en"), "Oct 20")
        XCTAssertEqual(NewsRules.displayDate("2025-12-03", today: "2026-10-21", lang: "en"), "Dec 3, 2025")
        XCTAssertEqual(NewsCopy.noticeCaption(date: "2026-10-20", today: "2026-10-21", lang: "ko"), "소식 · 10월 20일")
    }

    // MARK: 문구 · 날짜 글 · 아이콘 (벡터 copy · dateLabels · icon — 사양 §1.3 표)

    /// Kit NewsCopy 의 글이 벡터의 `copy` 와 글자까지 같다 (’ U+2019 · › U+203A · · U+00B7 · … U+2026 까지).
    /// 벡터에 키가 늘면 여기도 늘려야 통과한다
    func testCopyIsTheSharedTable() throws {
        let copy = try XCTUnwrap(fixture()["copy"] as? [String: [String: String]])
        let date = "2026-10-20", today = "2026-10-21", app = "1.2.0"
        let ours: [String: (String) -> String] = [
            "pane": NewsCopy.paneTitle,
            "paneSubtitle": NewsCopy.paneSubtitle,
            "paneNote": NewsCopy.paneNote,
            "empty": NewsCopy.empty,
            "fetchSwitch": NewsCopy.fetchToggle,
            "fetchOn": NewsCopy.fetchOnDetail,
            "fetchOff": NewsCopy.fetchOffDetail,
            "kindNotice": { NewsCopy.kind(.notice, $0) },
            "kindUpdate": { NewsCopy.kind(.update, $0) },
            "unseen": NewsCopy.unseen,
            "noticeCaption": { NewsCopy.noticeCaption(date: date, today: today, lang: $0) },
            "whatsNewCaption": NewsCopy.whatsNewCaption,
            "whatsNewTitle": { _ in NewsCopy.whatsNewTitle(appVersion: app) },
            "whatsNewFoot": NewsCopy.whatsNewFootnote,
            "noteTitle": { NewsCopy.noteTitle(app: app, lang: $0) },
            "learnMore": NewsCopy.learnMore,
            "ok": NewsCopy.ok,
            "menu": NewsCopy.menu,
        ]
        XCTAssertEqual(Set(copy.keys), Set(ours.keys), "벡터의 copy 키와 NewsCopy 가 같은 줄들이어야 해요")
        for (key, t) in copy {
            guard let f = ours[key] else { continue }
            for lang in ["ko", "en"] {
                let want = try XCTUnwrap(t[lang], "\(key).\(lang)")
                    .replacingOccurrences(of: "{date}", with: NewsRules.displayDate(date, today: today, lang: lang))
                    .replacingOccurrences(of: "{appVersion}", with: app)
                    .replacingOccurrences(of: "{app}", with: app)
                XCTAssertEqual(f(lang), want, "copy.\(key).\(lang)")
            }
        }
        XCTAssertEqual(NewsRules.noteTitle(app).ko, "1.2.0 에서 달라진 점")
    }

    /// 목록 · 카드의 날짜 글 (벡터 `dateLabels`: [날짜, 오늘, 언어, 보일 글])
    func testDateLabelsAreTheSharedOnes() throws {
        let rows = try XCTUnwrap(fixture()["dateLabels"] as? [[String]])
        XCTAssertGreaterThanOrEqual(rows.count, 8)
        for r in rows {
            XCTAssertEqual(NewsRules.displayDate(r[0], today: r[1], lang: r[2]), r[3], "\(r)")
        }
    }

    /// ‘소식’ 아이콘: 신문 · #C2783A (벡터 `icon`)
    func testIconIsTheSharedOne() throws {
        let icon = try XCTUnwrap(fixture()["icon"] as? [String: String])
        XCTAssertEqual(icon["symbol"], NewsCopy.iconSymbol)
        XCTAssertEqual(icon["tint"], NewsCopy.iconTint)
        XCTAssertFalse(NewsCopy.iconSymbol.contains("megaphone"))
    }

    func testSeenKeepsTheNewest200() {
        let old = (0..<200).map { "old-\($0)" }
        let item = NewsItem(id: "n", date: "2026-10-01", kind: .notice, importance: .important, title: NewsText(ko: "t"),
                            body: NewsText(ko: "b"), platforms: nil, minVersion: nil, maxVersion: nil, syncOnly: false,
                            link: nil, expires: "2026-12-31")
        let env = NewsEnv(platform: "mac", appVersion: "1.2.0", today: "2026-10-20", lang: "ko", syncOn: false, firstRun: false)
        let r = NewsRules.open(env: env, state: NewsState(lastSeenAppVersion: "1.2.0", seen: old), items: [item], notes: [])
        XCTAssertEqual(r.card, .notice(id: "n"))
        XCTAssertEqual(r.save.seen.count, 200)
        XCTAssertEqual(r.save.seen.first, "old-1")
        XCTAssertEqual(r.save.seen.last, "n")
    }

    func testDefaultsStorageRoundTripsInItsOwnPlaces() throws {
        let suite = "spiralday.news.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spiralday-news-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let s = NewsDefaultsStorage(defaults: defaults, cacheFolder: folder)
        XCTAssertEqual(s.state, NewsState())
        XCTAssertTrue(s.fetchEnabled, "기본 켬")
        XCTAssertNil(s.cache)
        s.state = NewsState(lastSeenAppVersion: "1.2.0", since: "2026-10-20", seen: ["a", "app-1.2.0"])
        s.fetchEnabled = false
        s.cache = NewsCache(body: Data(#"{"version":1,"items":[]}"#.utf8), etag: "\"x\"", lastModified: "Tue, 20 Oct 2026 00:00:00 GMT")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        s.lastAttempt = t
        let again = NewsDefaultsStorage(defaults: defaults, cacheFolder: folder)
        XCTAssertEqual(again.state, NewsState(lastSeenAppVersion: "1.2.0", since: "2026-10-20", seen: ["a", "app-1.2.0"]))
        XCTAssertFalse(again.fetchEnabled)
        XCTAssertEqual(again.cache?.etag, "\"x\"")
        XCTAssertEqual(again.lastAttempt, t)
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("news.") }.sorted(),
                       ["news.fetchEnabled", "news.lastSeenAppVersion", "news.seen", "news.since"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("news.json")), Data(#"{"version":1,"items":[]}"#.utf8))
        // 캐시 폴더가 지워지면 조건부 헤더도 보내지 않는다
        try FileManager.default.removeItem(at: folder.appendingPathComponent("news.json"))
        XCTAssertNil(again.cache)
        XCTAssertNil(NewsFetcher.request(cache: again.cache).value(forHTTPHeaderField: "If-None-Match"))
    }

    // MARK: 벡터 읽기

    /// 벡터의 feed (이름 · 객체 · feedText · feedBase64 · bom · padToBytes) → 바이트 (feed 가 null 이면 nil — 받아 둔 것 없음)
    static func feedBytes(_ f: [String: Any], _ c: [String: Any]) throws -> Data? {
        if let b64 = c["feedBase64"] as? String { return Data(base64Encoded: b64) }
        var bytes: Data
        if let text = c["feedText"] as? String {
            bytes = Data(text.utf8)
        } else {
            guard let feed = c["feed"], !(feed is NSNull) else { return nil }
            let doc: Any = (feed as? String).map { (f["feeds"] as! [String: Any])[$0]! } ?? feed
            bytes = try JSONSerialization.data(withJSONObject: expand(doc))
        }
        if c["bom"] as? Bool == true { bytes = Data([0xEF, 0xBB, 0xBF]) + bytes }
        if let pad = (c["padToBytes"] as? NSNumber)?.intValue { bytes += Data(repeating: 0x20, count: pad - bytes.count) }
        return bytes
    }

    /// {"$repeat": "s", "times": n} → s 를 n 번, 배열 안의 {"$repeat": {항목}, "times": n} → id 에 -1 … -n 을 붙인 n 개
    static func expand(_ v: Any) -> Any {
        if let a = v as? [Any] {
            var out: [Any] = []
            for x in a {
                if let o = x as? [String: Any], let item = o["$repeat"] as? [String: Any] {
                    let times = (o["times"] as? NSNumber)?.intValue ?? 0
                    for n in stride(from: 1, through: times, by: 1) {
                        var copy = expand(item) as! [String: Any]
                        copy["id"] = "\(item["id"] as? String ?? "undefined")-\(n)"
                        out.append(copy)
                    }
                } else {
                    out.append(expand(x))
                }
            }
            return out
        }
        if let o = v as? [String: Any] {
            if let s = o["$repeat"] as? String { return String(repeating: s, count: (o["times"] as? NSNumber)?.intValue ?? 0) }
            return o.mapValues(expand)
        }
        return v
    }

    static func state(_ d: [String: Any]) -> NewsState {
        NewsState(lastSeenAppVersion: d["lastSeenAppVersion"] as? String, since: d["since"] as? String,
                  seen: d["seen"] as? [String] ?? [])
    }

    static func card(_ v: Any?) -> NewsCard? {
        guard let o = v as? [String: Any] else { return nil }
        switch o["type"] as? String {
        case "notice": return .notice(id: o["id"] as! String)
        case "whatsNew": return .whatsNew(app: o["app"] as! String)
        default: return nil
        }
    }
}
