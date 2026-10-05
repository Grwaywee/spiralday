import XCTest
#if os(macOS)
import AppKit
#endif
@testable import SpiraldayKit

/// 데스크톱 넘김 입력 (사장님 피드백 G · H, 그리고 Mac 감사에서 찾은 "플래너 키 · 스크롤 감시가 다른 창의 입력을 먹음").
/// 규칙은 Kit DesktopTurnInput · DesktopSwipeTracker 의 순수 함수이고, 값은 Windows 와 같은 공유 벡터
/// Tests/Fixtures/desktop-turn-input.json (spiralday-apps web/tests/fixtures/desktop-turn-input.json 과 같은 파일) 과
/// Mac 만의 창 가리기 · 손짓 단계 벡터 Tests/Fixtures/mac-turn-input.json 이다.
@MainActor
final class DesktopInputRoutingTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    private func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func kind(_ s: Any?) throws -> PageKind { try XCTUnwrap(PageKind(rawValue: XCTUnwrap(s as? String))) }

    private func dir(_ s: Any?) -> FlipDirection? {
        switch s as? String {
        case "forward": .forward
        case "backward": .backward
        default: nil
        }
    }

    private func num(_ v: Any?) -> CGFloat { CGFloat((v as? NSNumber)?.doubleValue ?? 0) }

    /// 날을 정해 두어 결과가 오늘에 따라 바뀌지 않게
    static let today = Dates.parse("2026-10-07")!

    // MARK: 공유 벡터 (Windows 와 같은 파일)

    private func expect(_ s: Any?) -> FlipDirection? {
        switch s as? String {
        case "next": .forward
        case "prev": .backward
        default: nil
        }
    }

    /// 그 벡터가 Mac 에서도 성립하는지 (platforms 가 없으면 두 플랫폼 모두, "windows" 만이면 Windows 만)
    private func holdsOnMac(_ r: [String: Any]) -> Bool {
        guard let p = r["platforms"] as? [String] else { return true }
        return p.contains("mac")
    }

    func testSharedConstantsMatchWindows() throws {
        let f = try load("desktop-turn-input.json")
        XCTAssertEqual(f["version"] as? Int, 1)
        let rules = try XCTUnwrap(f["rules"] as? [String: Any])
        XCTAssertEqual(num(rules["dominance"]), DesktopTurnInput.dominance)
    }

    /// 두 손가락 쓸기: 가로는 늘, 세로는 위가 묶인 쪽(주간 · 홈)에서만, 위로 = 다음 장 (사장님 결정 4)
    func testTwoFingerVectors() throws {
        let rows = try XCTUnwrap(load("desktop-turn-input.json")["twoFinger"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(rows.count, 10)
        var checked = 0
        for r in rows where holdsOnMac(r) {
            let k = try kind(r["kind"])
            let f = try XCTUnwrap(r["fingers"] as? [Any])
            let dx = num(f[0]), dy = num(f[1])
            XCTAssertEqual(DesktopTurnInput.swipeDirection(dx: dx, dy: dy, kind: k), expect(r["expect"]), "\(r["name"] ?? r)")
            if let axis = r["axis"] as? String {
                XCTAssertEqual(DesktopTurnInput.swipeAxis(dx: dx, dy: dy, kind: k), axis == "x" ? .horizontal : .vertical, "\(r["name"] ?? r)")
            }
            // 실제 트랙패드 손짓으로도 (began → changed → ended): 넘김 엔진에 가는 첫 값의 부호가 같은 쪽
            var t = DesktopSwipeTracker()
            _ = t.handle(phase: .began, momentum: false, dx: 0, dy: 0, kind: k)
            let (action, eat) = t.handle(phase: .changed, momentum: false, dx: dx, dy: dy, kind: k)
            switch expect(r["expect"]) {
            case .forward?:
                guard case .swipe(.began, let d)? = action else { return XCTFail("\(r["name"] ?? r): 넘김을 잡지 않았다") }
                XCTAssertLessThan(d, 0)
                XCTAssertTrue(eat)
            case .backward?:
                guard case .swipe(.began, let d)? = action else { return XCTFail("\(r["name"] ?? r): 넘김을 잡지 않았다") }
                XCTAssertGreaterThan(d, 0)
                XCTAssertTrue(eat)
            case nil:
                XCTAssertNil(action, "\(r["name"] ?? r)")
                XCTAssertFalse(eat, "넘김이 아니면 스크롤을 먹지 않는다")
            }
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 10)
    }

    /// 폰 주간 위아래 넘김(docs/mobile-tour.md §2.3)과 축 · 문턱 · 방향이 같다 — 주간의 세로 쓸기는 어느 기기에서나 같은 판단
    func testWeeklyVerticalSwipeMatchesThePhoneRule() throws {
        let rows = try XCTUnwrap(load("mobile-tour.json")["weekSwipe"] as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty)
        for r in rows {
            let dx = num(r["dx"]), dy = num(r["dy"])
            // 폰 표의 null 은 "세로 넘김이 아니다" — 가로로 잡히는 경우는 데스크톱에서 가로 넘김이므로 세로 축만 견준다
            let vertical = DesktopTurnInput.swipeAxis(dx: dx, dy: dy, kind: .weekly) == .vertical
            let got: FlipDirection? = vertical ? (dy < 0 ? .forward : .backward) : nil
            XCTAssertEqual(got, dir(r["dir"]), "\(r)")
        }
    }

    /// 키: ← → 는 늘, ↑ ↓ 는 주간 · 홈에서만 (↓ = 다음 장), 글을 쓰는 중이면 넘기지 않는다 — 실제 handleKey 로
    func testKeyVectors() throws {
        let rows = try XCTUnwrap(load("desktop-turn-input.json")["keys"] as? [[String: Any]])
        let names: [String: DesktopTurnInput.Key] = ["ArrowLeft": .left, "ArrowRight": .right, "ArrowUp": .up, "ArrowDown": .down,
                                                     "PageUp": .pageUp, "PageDown": .pageDown]
        let codes: [DesktopTurnInput.Key: UInt16] = [.left: 123, .right: 124, .up: 126, .down: 125, .pageUp: 116, .pageDown: 121]
        var checked = 0
        for r in rows where holdsOnMac(r) {
            let key = try XCTUnwrap(names[XCTUnwrap(r["key"] as? String)])
            let k = try kind(r["kind"])
            let want = expect(r["expect"])
            let typing = r["typing"] as? Bool ?? false
            if !typing { XCTAssertEqual(DesktopTurnInput.turn(key, kind: k), want, "\(r)") }
            #if os(macOS)
            let state = AppState(kind: k, today: Self.today)
            state.store = PlannerStore(inMemory: true)
            let before = state.index
            let ate = state.handleKey(window: .planner, responder: typing ? .text : .none, keyCode: codes[key]!, characters: nil, modifiers: [])
            XCTAssertEqual(ate, want != nil, "\(r): 넘기는 키만 먹는다")
            XCTAssertEqual(state.kind, k)
            if let want, k.flips {
                // 먹기만 하지 않고 실제로 그 쪽으로 한 장 넘긴다 (넘김 그림이 없는 시험에서는 바로 넘어간다)
                XCTAssertEqual(state.index, before + want.delta, "\(r): 넘어가야 한다")
            } else {
                // 넘기지 않는 키 · Mac 의 홈(한 장뿐 — PageKind.flips == false): 장이 바뀌지 않는다.
                // 홈의 ← → ↑ ↓ 는 먹지만 아무 일도 하지 않는다 (먹지 않으면 시스템이 '삑' 한다)
                XCTAssertEqual(state.index, before, "\(r)")
            }
            #endif
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 11)
        // Mac: fn+↑ · fn+↓ (PageUp · PageDown) 도 주간 · 홈에서만 (Windows 와 같은 쪽 — 공유 벡터의 Windows 줄과 같은 값)
        for r in rows where (r["platforms"] as? [String]) == ["windows"] {
            let key = try XCTUnwrap(names[XCTUnwrap(r["key"] as? String)])
            XCTAssertEqual(DesktopTurnInput.turn(key, kind: try kind(r["kind"])), expect(r["expect"]), "\(r)")
        }
        #if os(macOS)
        // Mac 물리 키 코드
        XCTAssertEqual(AppState.turnKey(123), .left)
        XCTAssertEqual(AppState.turnKey(124), .right)
        XCTAssertEqual(AppState.turnKey(126), .up)
        XCTAssertEqual(AppState.turnKey(125), .down)
        XCTAssertEqual(AppState.turnKey(116), .pageUp)
        XCTAssertEqual(AppState.turnKey(121), .pageDown)
        XCTAssertNil(AppState.turnKey(18))
        #endif
    }

    func testRoutingVectors() throws {
        let routing = try XCTUnwrap(load("mac-turn-input.json")["routing"] as? [String: Any])
        for r in try XCTUnwrap(routing["key"] as? [[String: Any]]) {
            let w = try XCTUnwrap(DesktopTurnInput.Window(rawValue: XCTUnwrap(r["window"] as? String)))
            let p = try XCTUnwrap(DesktopTurnInput.Responder(rawValue: XCTUnwrap(r["responder"] as? String)))
            XCTAssertEqual(DesktopTurnInput.plannerTakesKey(window: w, responder: p), r["takes"] as? Bool, "\(r)")
        }
        for r in try XCTUnwrap(routing["scroll"] as? [[String: Any]]) {
            let w = try XCTUnwrap(DesktopTurnInput.Window(rawValue: XCTUnwrap(r["window"] as? String)))
            XCTAssertEqual(DesktopTurnInput.plannerTakesScroll(window: w), r["takes"] as? Bool, "\(r)")
        }
    }

    /// 손짓 하나(began … ended + 관성)를 따라가며: 축은 처음 한 번, 잡은 손짓과 그 관성은 먹고, 일간의 세로는 넘기지 않는다
    func testGestureSequences() throws {
        let rows = try XCTUnwrap(load("mac-turn-input.json")["gestures"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        for g in rows {
            let k = try kind(g["kind"])
            let events = try XCTUnwrap(g["events"] as? [[String: Any]])
            let expect = try XCTUnwrap(g["expect"] as? [[String: Any]])
            XCTAssertEqual(events.count, expect.count)
            var t = DesktopSwipeTracker()
            for (i, (e, x)) in zip(events, expect).enumerated() {
                let phase = DesktopSwipeTracker.Phase(rawValue: (e["phase"] as? String) ?? "none") ?? .none
                let (action, eat) = t.handle(phase: phase, momentum: e["momentum"] as? Bool ?? false,
                                             momentumEnded: e["momentumEnded"] as? Bool ?? false,
                                             dx: num(e["dx"]), dy: num(e["dy"]), kind: k)
                let label = "\(g["_doc"] ?? "") #\(i)"
                XCTAssertEqual(eat, x["eat"] as? Bool, label)
                if let a = x["action"] as? [Any] {
                    if (a[0] as? String) == "flip" {
                        XCTAssertEqual(action, .flip(try XCTUnwrap(dir(a[1]))), label)
                    } else {
                        let p: SwipePhase = switch a[0] as? String {
                        case "began": .began
                        case "changed": .changed
                        case "ended": .ended
                        default: .cancelled
                        }
                        XCTAssertEqual(action, .swipe(p, num(a[1])), label)
                    }
                } else {
                    XCTAssertNil(action, label)
                }
            }
            XCTAssertFalse(t.isActive, "손짓이 끝나면 놓는다")
        }
    }

    #if os(macOS)
    // MARK: Mac 창 · 칸 가리기

    /// 플래너 창 · 팔레트 · 다른 창(PDF 내보내기 · 설정 · 업데이트) · 날짜 고르기를 실제 AppKit 객체로
    func testWindowAndResponderClassification() {
        let state = AppState(kind: .daily)
        let planner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let palette = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        let pdf = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let settings = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        XCTAssertEqual(state.inputWindow(planner), .other, "플래너 창을 정하기 전에는 아무 창도 플래너가 아니다")
        state.plannerWindow = planner
        state.isPlannerPanel = { $0 === palette }
        XCTAssertEqual(state.inputWindow(planner), .planner)
        XCTAssertEqual(state.inputWindow(palette), .plannerPanel)
        XCTAssertEqual(state.inputWindow(pdf), .other, "PDF 내보내기 창 (보통 NSWindow)")
        XCTAssertEqual(state.inputWindow(settings), .other, "설정 패널")
        XCTAssertEqual(state.inputWindow(nil), .other)

        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        pdf.contentView?.addSubview(picker)
        XCTAssertTrue(pdf.makeFirstResponder(picker))
        XCTAssertEqual(AppState.inputResponder(pdf), .datePicker)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        planner.contentView?.addSubview(field)
        XCTAssertTrue(planner.makeFirstResponder(field))
        XCTAssertEqual(AppState.inputResponder(planner), .text)
        field.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(AppState.inputResponder(planner), .composing)
        planner.makeFirstResponder(nil)
        XCTAssertEqual(AppState.inputResponder(planner), .none)
    }

    /// 다른 창의 키는 플래너가 먹지 않는다: PDF 내보내기 창 날짜 칸의 숫자 1–7 이 형광펜으로, ← → 가 뒤의 플래너 넘김으로 가던 문제
    func testKeysFromOtherWindowsPassThrough() {
        let store = PlannerStore(inMemory: true)
        let state = AppState(kind: .daily)
        state.store = store
        let pen = store.categories[1].id
        // 다른 창 · 날짜 고르기: 숫자 · 화살표 · 글자 모두 그 창으로
        for (w, r) in [(DesktopTurnInput.Window.other, DesktopTurnInput.Responder.none), (.other, .datePicker), (.planner, .datePicker),
                       (.planner, .text), (.planner, .composing)] {
            XCTAssertFalse(state.handleKey(window: w, responder: r, keyCode: 19, characters: "2", modifiers: []), "\(w) \(r) 숫자")
            XCTAssertFalse(state.handleKey(window: w, responder: r, keyCode: 124, characters: nil, modifiers: []), "\(w) \(r) →")
            XCTAssertFalse(state.handleKey(window: w, responder: r, keyCode: 13, characters: "w", modifiers: []), "\(w) \(r) W")
        }
        XCTAssertNotEqual(state.tool, pen)
        XCTAssertEqual(state.kind, .daily)
        // 다른 창의 Esc 는 그 창 몫
        XCTAssertFalse(state.handleKey(window: .other, responder: .text, keyCode: 53, characters: "\u{1b}", modifiers: []))
        // 플래너 창 · 팔레트에서는 그대로
        XCTAssertTrue(state.handleKey(window: .planner, responder: .none, keyCode: 19, characters: "2", modifiers: []))
        XCTAssertEqual(state.tool, pen)
        XCTAssertTrue(state.handleKey(window: .plannerPanel, responder: .none, keyCode: 14, characters: "e", modifiers: []))
        XCTAssertEqual(state.tool, AppState.eraser)
        XCTAssertFalse(state.handleKey(window: .planner, responder: .none, keyCode: 19, characters: "2", modifiers: [.command]),
                       "⌘ 단축키는 메뉴 몫")
        // ↑ ↓ 는 일간에서 넘기지 않는다 (먹지도 않는다)
        XCTAssertFalse(state.handleKey(window: .planner, responder: .none, keyCode: 126, characters: nil, modifiers: []))
        XCTAssertFalse(state.handleKey(window: .planner, responder: .none, keyCode: 125, characters: nil, modifiers: []))
        XCTAssertTrue(state.handleKey(window: .planner, responder: .none, keyCode: 13, characters: "w", modifiers: []))
        XCTAssertEqual(state.kind, .weekly)
        // 주간에서는 ↑ ↓ · PageUp PageDown 도 넘기는 키
        for code: UInt16 in [126, 125, 116, 121] {
            XCTAssertTrue(state.handleKey(window: .planner, responder: .none, keyCode: code, characters: nil, modifiers: []), "\(code)")
        }
    }
    #endif
}
