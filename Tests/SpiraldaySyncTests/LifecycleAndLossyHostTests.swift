// 앱 수명 경쟁 (뒤로 갔다가 금방 앞으로) · 모르는 키를 버리는 앱 (모델로 읽고 다시 쓰는 iOS · Windows)
import XCTest
@testable import SpiraldaySync
import SpiraldaySyncTesting

/// 모르는 키를 버린다: 앱이 아는 키만 남긴다 (iOS 의 decode → encode, Windows 의 stringifyPlannerData 와 같다)
private func dropUnknown(_ data: JSONValue) -> JSONValue {
    guard case var .object(o) = data, case let .object(days)? = o["days"] else { return data }
    var out: [String: JSONValue] = [:]
    for (k, d) in days {
        guard case var .object(r) = d else { continue }
        for key in r.keys where !DAY_KNOWN.contains(key) { r[key] = nil }
        if case let .array(tasks)? = r["tasks"] {
            r["tasks"] = .array(tasks.map { t in
                guard case var .object(x) = t else { return t }
                for key in x.keys where !TASK_KNOWN.contains(key) { x[key] = nil }
                return .object(x)
            })
        }
        out[k] = .object(r)
    }
    o["days"] = .object(out)
    return .object(o)
}

private func day(_ d: Dev, _ book: String) -> JSONValue? { d.host.book(book)?["days"]?[D] }

final class LossyHostTests: XCTestCase {
    /// 새 버전 기기가 쓴 모르는 키(하루의 키 · 할 일 안의 키)를, 그 키를 모르는 기기가 편집하며 null 로 지우지 않는다
    func testUnknownKeysSurviveAHostThatDropsThem() async throws {
        let server = FakeSyncServer()
        let a = await device(server, platform: "Mac")
        let book = addBook(a.host, "책", withComment("처음"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A (새 버전)")
        let b = await device(server, platform: "iPhone")
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await syncAll(a, b)

        // A(새 버전 앱): 하루에 futureField, 할 일에 futureTaskField
        let task = "AAAAAAAA-0000-4000-8000-0000000000F1"
        a.host.edit(book) { data in
            guard case var .object(o) = data, case var .object(days)? = o["days"], case var .object(r)? = days[D] else { return data }
            r["futureField"] = ["v": 2]
            r["tasks"] = [["id": .string(task), "text": "새 할 일", "mark": 0, "row": 0, "futureTaskField": "남겨 주세요"]]
            days[D] = .object(r)
            o["days"] = .object(days)
            return .object(o)
        }
        a.engine.localChanged(bookId: book)
        try await syncAll(a, b)
        XCTAssertEqual(day(b, book)?["futureField"], ["v": 2], "MemoryHost 는 받은 그대로 둔다")

        // B 는 모르는 키를 버리고(파일을 모델로 다시 씀) 아무 칸이나 고친다
        b.host.edit(book) { applyOp(dropUnknown($0), ["t": "comment", "date": 1, "text": "B 가 고침"]) }
        XCTAssertNil(day(b, book)?["futureField"])
        b.engine.localChanged(bookId: book)
        try await syncAll(b, a)

        XCTAssertEqual(comment(a, book), "B 가 고침")
        XCTAssertEqual(day(a, book)?["futureField"], ["v": 2], "버린 키를 null 로 올려 새 버전 기기의 값을 지우지 않는다")
        let t = day(a, book)?["tasks"]?.arrayValue?.first { $0["id"]?.stringValue == task }
        XCTAssertEqual(t?["futureTaskField"], "남겨 주세요", "할 일 안의 모르는 키도")

        // 모르는 키를 null 로 넘기면 지운다 (지우는 길은 남아 있다)
        a.host.edit(book) { data in
            guard case var .object(o) = data, case var .object(days)? = o["days"], case var .object(r)? = days[D] else { return data }
            r["futureField"] = .null
            days[D] = .object(r)
            o["days"] = .object(days)
            return .object(o)
        }
        a.engine.localChanged(bookId: book)
        try await syncAll(a, b)
        // 새로 들어온 기기(받은 그대로 두는 앱)에는 지운 키는 없고, 남긴 키는 있다
        let c = await device(server, platform: "iPad", ip: "10.0.0.3")
        try await c.engine.initialize()
        try await pairQr(a, c)
        try await syncAll(c)
        XCTAssertEqual(comment(c, book), "B 가 고침")
        XCTAssertNil(day(c, book)?["futureField"])
        XCTAssertEqual(day(c, book)?["tasks"]?.arrayValue?.first?["futureTaskField"], "남겨 주세요")
    }

    func testDiffIgnoresUnknownKeysTheAppDropped() {
        let clock = HLC(node: "00000000000000b1", wall: { 1_000 })
        var prev = Records.flattenDay(["comment": "a", "futureField": 1,
                                       "tasks": [["id": "AAAAAAAA-0000-4000-8000-000000000001", "text": "t", "x2": true]]])
        let cur = Records.flattenDay(["comment": "a", "tasks": [["id": "AAAAAAAA-0000-4000-8000-000000000001", "text": "t"]]])
        XCTAssertTrue(CRDT.isEmptyDelta(Records.diff(.day, prev: prev, cur: cur, clock: clock)))
        // 앱이 null 로 넘기면 지운 것
        let cleared = Records.flattenDay(["comment": "a", "futureField": .null,
                                          "tasks": [["id": "AAAAAAAA-0000-4000-8000-000000000001", "text": "t", "x2": .null]]])
        let d = Records.diff(.day, prev: prev, cur: cleared, clock: clock)
        XCTAssertEqual(d.f["x:futureField"]?.value, .null)
        XCTAssertEqual(d.c["tasks"]?["AAAAAAAA-0000-4000-8000-000000000001"]?.f["x:x2"]?.value, .null)
        // 아는 키는 그대로: 없어지면 기본값으로 바뀐 것
        prev = Records.flattenDay(["comment": "a"])
        XCTAssertEqual(Records.diff(.day, prev: prev, cur: Records.flattenDay([:]), clock: clock).f["comment"]?.value, "")
    }
}

final class LifecycleTests: XCTestCase {
    func until(_ what: String, timeout: TimeInterval = 10, _ f: () async -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await f() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("기다렸지만 안 됨: \(what)")
    }

    /// 뒤로 가서 올리는 동안(느린 망) 앞으로 돌아왔다: suspend 가 끝나도 엔진은 멈추지 않는다
    func testResumeWhileSuspendIsPushingKeepsTheEngineRunning() async throws {
        let server = FakeSyncServer()
        let a = await device(server, platform: "Windows", auto: true)
        let book = addBook(a.host, "책", withComment("처음"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let slow = FakeNet()
        let b = await device(server, platform: "iPhone", auto: true, net: slow)
        try await b.engine.initialize()
        try await pairQr(a, b)
        await until("B 가 받음") { comment(b, book) == "처음" }
        await until("B 가 실시간") { await b.engine.status.live }

        // 올리기를 느리게 (Link Conditioner 3G 처럼)
        slow.fail = { method, path in
            if method != "GET", path.contains("/records") { usleep(400_000) }
            return false
        }
        b.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "뒤로 가기 직전"]) }
        let suspending = Task { await b.engine.suspend() }
        try await Task.sleep(nanoseconds: 120_000_000)       // suspend 가 올리는 중
        await b.engine.resume()                               // 그 사이 앞으로 왔다
        await suspending.value
        slow.fail = nil

        await until("A 가 B 의 편집을 받음") { comment(a, book) == "뒤로 가기 직전" }
        await until("B 가 다시(또는 그대로) 실시간") { await b.engine.status.live }
        // 앞에 있는 동안 다른 기기의 편집이 들어오고, 이 기기의 편집도 올라간다 (다시 resume 하지 않아도)
        a.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "A 가 그 뒤에 씀"]) }
        a.engine.localChanged(bookId: book)
        await until("B 가 앞에서 받음", timeout: 5) { comment(b, book) == "A 가 그 뒤에 씀" }
        b.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "B 도 그 뒤에 씀"]) }
        b.engine.localChanged(bookId: book)
        await until("A 가 받음", timeout: 5) { comment(a, book) == "B 도 그 뒤에 씀" }

        // 순서대로면 예전처럼: suspend 가 끝나면 멈추고, resume 으로 다시
        await b.engine.suspend()
        let off = await b.engine.status
        XCTAssertFalse(off.live)
        a.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "뒤에 있는 동안"]) }
        a.engine.localChanged(bookId: book)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(comment(b, book), "B 도 그 뒤에 씀")
        await b.engine.resume()
        await until("B 가 앞으로 와서 받음", timeout: 5) { comment(b, book) == "뒤에 있는 동안" }
        await a.engine.dispose()
        await b.engine.dispose()
    }
}
