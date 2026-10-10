#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import SpiraldayKit

/// 사장님 신고 (2026-10-08): "일간에서 task 작성할 때 카테고리 선택 부분이 종종 안 눌린다".
/// 원인 두 가지 — (1) 분류 칸이 탭 제스처라 누른 채 약 5pt 넘게 움직이거나(트랙패드를 눌러서 클릭) 0.8초 넘게 누르면 아무 알림 없이
/// 취소됐다. (2) 누를 수 있는 사각형이 인쇄된 분류 칸보다 작아서, 칸 가장자리 · 점선 언저리를 누르면 종이(쓰기 끝)로 떨어져
/// 막 시작한 빈 할 일이 지워졌다. 진짜 PageView 를 화면 밖 창에 띄우고 마우스 이벤트를 창에 보내 확인한다
/// (xctest 는 활성 앱이 아니어서 key 창인 척하는 창과 첫 클릭을 받는 호스트를 쓴다. 메뉴는 띄우지 않고 받아서 센다).
@MainActor
final class TaskCategoryCellTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    private static let repoFonts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Fonts")

    private var menus: [NSMenu] = []
    private var windows: [NSWindow] = []
    private var eventNumber = 100

    override func setUp() async throws {
        Fonts.extraFontDirectories = [Self.repoFonts]
        Fonts.register()
        _ = NSApplication.shared
        menus = []
        TaskCategoryMenu.presentForTesting = { [weak self] m in self?.menus.append(m) }
    }

    override func tearDown() async throws {
        TaskCategoryMenu.presentForTesting = nil
        for w in windows { w.orderOut(nil) }
        windows = []
    }

    // MARK: 틀

    private struct Rig {
        let store: PlannerStore
        let state: AppState
        let win: NSWindow
        let date: Date
        let u: CGFloat
        let height: CGFloat
    }

    private func spin(_ s: Double = 0.15) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private func rig(_ kind: PageKind = .daily, width: CGFloat? = nil) async -> Rig {
        let store = PlannerStore(inMemory: true)
        let state = AppState(kind: kind)
        state.store = store
        let w = width ?? (kind == .daily ? 753 : 1400)
        let h = (w * kind.design.height / kind.design.width).rounded()
        let win = FakeKeyWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: w, height: h), styleMask: [.borderless],
                                backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = FirstMouseHost(rootView: AnyView(PageView(kind: kind, index: state.index)
            .frame(width: w, height: h)
            .environmentObject(store).environmentObject(state)))
        win.orderFrontRegardless()
        win.makeKey()
        windows.append(win)
        state.plannerWindow = win
        await spin(0.3)
        let date = kind == .daily ? state.dayDate(state.index) : state.weekStart(state.index)
        return Rig(store: store, state: state, win: win, date: date, u: w / kind.design.width, height: h)
    }

    /// 디자인 좌표 → 창 좌표 (아래가 원점)
    private func point(_ r: Rig, _ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * r.u, y: r.height - y * r.u) }

    private func send(_ r: Rig, _ type: NSEvent.EventType, _ p: NSPoint) {
        eventNumber += 1
        r.win.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: r.win.windowNumber, context: nil, eventNumber: eventNumber,
                                           clickCount: type == .mouseMoved ? 0 : 1,
                                           pressure: type == .leftMouseDown ? 1 : 0)!)
    }

    /// 누르고 · (travel pt 만큼 dir 쪽으로 끌고) · hold 초 뒤 뗀다. dir 은 창 좌표 (기본: 오른쪽으로, 살짝 아래로)
    private func press(_ r: Rig, _ p: NSPoint, travel: CGFloat = 0, dir: CGVector = CGVector(dx: 1, dy: -0.25),
                       hold: Double = 0.05) async {
        send(r, .mouseMoved, p)
        await spin(0.05)
        send(r, .leftMouseDown, p)
        await spin(hold)
        var end = p
        if travel > 0 {
            // 트랙패드를 눌러 클릭할 때처럼 몇 걸음에 나눠 미끄러진다
            for k in 1...4 {
                end = NSPoint(x: p.x + dir.dx * travel * CGFloat(k) / 4, y: p.y + dir.dy * travel * CGFloat(k) / 4)
                send(r, .leftMouseDragged, end)
                await spin(0.02)
            }
        }
        send(r, .leftMouseUp, end)
        await spin(0.25)
    }

    private func editor(_ r: Rig) -> NSTextView? { r.win.firstResponder as? NSTextView }

    private func waitEditor(_ r: Rig, _ what: String = "할 일 글 칸에 포커스") async throws {
        for _ in 0..<150 {
            if editor(r) != nil { return }
            await spin(0.02)
        }
        XCTFail("기다림: \(what)")
        throw CancellationError()
    }

    private func type(_ r: Rig, _ s: String) async {
        editor(r)?.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
        await spin(0.1)
    }

    private typealias F = DailyForm

    /// 일간 할 일 줄의 분류 칸 한가운데 (디자인 좌표)
    private func dailyCellCenter(row: Int, rows: Int = F.taskCount) -> CGPoint {
        let hit = F.taskCategoryHitRect(row: row, span: 1, rows: rows)
        return CGPoint(x: (F.left + F.categoryX) / 2, y: hit.midY)
    }

    /// 빈 줄을 눌러 새 할 일을 시작한다 (사용자처럼). 돌려주는 것: 그 할 일 id
    private func startTask(_ r: Rig, row: Int) async throws -> UUID {
        let y = F.gridTop + (CGFloat(row) + 0.5) * F.pitch
        await press(r, point(r, F.taskTextX + 200, y))
        try await waitEditor(r)
        return try XCTUnwrap(r.state.editingTaskID(on: r.date), "빈 줄을 누르면 그 줄에 새 할 일을 쓴다")
    }

    private func assertStillWriting(_ r: Rig, _ id: UUID, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.state.editingKey, AppState.taskKey(r.date, id), "\(what): 쓰기가 끝나면 안 된다", file: file, line: line)
        XCTAssertNotNil(editor(r), "\(what): 글 칸이 포커스를 잃으면 안 된다", file: file, line: line)
        XCTAssertTrue(r.store.day(r.date).tasks.contains { $0.id == id }, "\(what): 쓰던 할 일이 지워지면 안 된다", file: file, line: line)
    }

    // MARK: (1) 누름 인식 — 움직여도 · 천천히 눌러도

    func testCategoryCellOpensDespitePointerTravelAndSlowPress() async throws {
        let r = await rig()
        // 막 시작한 빈 할 일 · 글을 쓴 할 일 각각
        let empty = try await startTask(r, row: 2)
        var checks: [(String, CGFloat, Double)] = [("그냥 클릭", 0, 0.05), ("8pt 미끄러짐", 8, 0.05), ("20pt 미끄러짐", 20, 0.05),
                                                   ("1.2초 누름", 0, 1.2)]
        for (what, travel, hold) in checks {
            let before = menus.count
            await press(r, point(r, dailyCellCenter(row: 2).x - 10 / r.u, dailyCellCenter(row: 2).y), travel: travel, hold: hold)
            XCTAssertEqual(menus.count, before + 1, "빈 할 일 · \(what): 형광펜 메뉴가 떠야 한다")
            assertStillWriting(r, empty, "빈 할 일 · \(what)")
        }

        await press(r, point(r, F.taskTextX + 200, F.gridTop + 6.5 * F.pitch))
        try await waitEditor(r)
        let typed = try XCTUnwrap(r.state.editingTaskID(on: r.date))
        await type(r, "운동하기")
        XCTAssertEqual(r.store.day(r.date).tasks.first { $0.id == typed }?.text, "운동하기")
        checks.append(("트랙패드 6pt + 0.9초", 6, 0.9))
        for (what, travel, hold) in checks {
            let before = menus.count
            await press(r, point(r, dailyCellCenter(row: 6).x - 10, dailyCellCenter(row: 6).y), travel: travel, hold: hold)
            XCTAssertEqual(menus.count, before + 1, "글을 쓴 할 일 · \(what): 형광펜 메뉴가 떠야 한다")
            assertStillWriting(r, typed, "글을 쓴 할 일 · \(what)")
        }
        // 쓰지 않을 때도 그대로 열린다
        r.state.endEditing()
        await spin(0.2)
        let before = menus.count
        await press(r, point(r, dailyCellCenter(row: 6).x, dailyCellCenter(row: 6).y), travel: 8)
        XCTAssertEqual(menus.count, before + 1)
    }

    // MARK: (2) 누르는 범위 — 인쇄된 분류 칸 전체

    func testWholePrintedCategoryColumnOpensMenuWhileWriting() async throws {
        let rowY = { (row: Int) in F.gridTop + CGFloat(row) * F.pitch }
        let probes: [(String, CGFloat, (Int) -> CGFloat)] = [
            ("한가운데", (F.left + F.categoryX) / 2, { rowY($0) + F.pitch / 2 }),
            ("윗줄 선 바로 아래", (F.left + F.categoryX) / 2, { rowY($0) + 1.5 }),
            ("아랫줄 선 바로 위", (F.left + F.categoryX) / 2, { rowY($0 + 1) - 1.5 }),
            ("왼쪽 끝", F.left + 1.5, { rowY($0) + F.pitch / 2 }),
            ("점선 바로 앞", F.categoryX - 2, { rowY($0) + F.pitch / 2 }),
            ("점선과 글 시작 사이", F.categoryX + 8, { rowY($0) + F.pitch / 2 }),
        ]
        for (what, x, y) in probes {
            let r = await rig()
            let id = try await startTask(r, row: 1)
            XCTAssertEqual(r.store.day(r.date).tasks.first { $0.id == id }?.text, "", "아직 비어 있는 할 일")
            let before = menus.count
            await press(r, point(r, x, y(1)))
            XCTAssertEqual(menus.count, before + 1, "\(what): 인쇄된 분류 칸 안이면 메뉴가 떠야 한다")
            assertStillWriting(r, id, what)
            r.win.orderOut(nil)
        }
    }

    /// 여러 줄을 쓰는 할 일 (둘째 줄의 칸 가장자리) · 16줄 넘게 써서 줄 간격이 좁아진 쪽 (sc < 1)
    func testCategoryColumnCoversLongTasksAndDenseDays() async throws {
        let r = await rig()
        let long = r.store.addTask(r.date, row: 3)
        r.store.taskText(r.date, id: long).wrappedValue = String(repeating: "아주 긴 할 일을 적어 본다 ", count: 4)
        await spin(0.2)
        let L = r.store.day(r.date).taskLayout
        let item = try XCTUnwrap(L.items.first)
        XCTAssertGreaterThan(item.span, 1, "두 줄 넘게 쓰는 할 일")
        r.state.editingKey = AppState.taskKey(r.date, long)
        try await waitEditor(r)
        let before = menus.count
        // 그 할 일의 마지막 줄, 아랫줄 선 바로 위
        let hit = F.taskCategoryHitRect(row: item.row, span: item.span, rows: L.rows)
        await press(r, point(r, F.left + 4, hit.maxY - 1.5))
        XCTAssertEqual(menus.count, before + 1)
        assertStillWriting(r, long, "여러 줄 할 일의 마지막 줄 가장자리")

        // 17번째 줄(16)에 할 일 → 17줄로 늘어 줄 간격이 좁아진다
        let r2 = await rig()
        let deep = r2.store.addTask(r2.date, row: 16)
        r2.state.editingKey = AppState.taskKey(r2.date, deep)
        try await waitEditor(r2)
        let L2 = r2.store.day(r2.date).taskLayout
        XCTAssertGreaterThan(L2.rows, F.taskCount)
        XCTAssertLessThan(L2.scale, 1)
        let h2 = F.taskCategoryHitRect(row: 16, span: 1, rows: L2.rows)
        for (what, y) in [("윗줄 선 바로 아래", h2.minY + 1.2), ("아랫줄 선 바로 위", h2.maxY - 1.2), ("한가운데", h2.midY)] {
            let n = menus.count
            await press(r2, point(r2, F.categoryX - 2, y))
            XCTAssertEqual(menus.count, n + 1, "좁아진 줄 · \(what)")
            assertStillWriting(r2, deep, "좁아진 줄 · \(what)")
        }
    }

    // MARK: 고르기 — 고른 뒤에도 계속 쓴다

    func testPickingFromMenuWhileWritingKeepsWriting() async throws {
        let r = await rig()
        let cats = r.store.categories
        XCTAssertGreaterThanOrEqual(cats.count, 2)
        let id = try await startTask(r, row: 4)
        await type(r, "기획서")
        let c = dailyCellCenter(row: 4)
        await press(r, point(r, c.x, c.y), travel: 8)
        let menu = try XCTUnwrap(menus.last, "형광펜 메뉴")
        // 형광펜마다 한 줄 + 없음, 지금은 없음에 체크
        XCTAssertEqual(menu.items.filter { $0.action != nil }.map(\.title), cats.map(\.name) + ["없음"])
        XCTAssertEqual(menu.items.first { $0.title == "없음" }?.state, .on)
        let pick = try XCTUnwrap(menu.items.firstIndex { $0.title == cats[1].name })
        menu.performActionForItem(at: pick)
        await spin(0.2)
        XCTAssertEqual(r.store.day(r.date).tasks.first { $0.id == id }?.cat, cats[1].id)
        assertStillWriting(r, id, "형광펜을 고른 뒤")
        XCTAssertEqual(r.store.day(r.date).tasks.first { $0.id == id }?.text, "기획서")
        // 다시 열면 고른 것에 체크
        let row = try XCTUnwrap(r.store.day(r.date).tasks.first { $0.id == id }?.row)
        let c2 = dailyCellCenter(row: row)
        await press(r, point(r, c2.x, c2.y))
        XCTAssertEqual(menus.last?.items.first { $0.title == cats[1].name }?.state, .on)

        // Return 으로 내려온 빈 할 일에서도: 메뉴가 뜨고, 골라도 할 일이 남고 계속 쓴다
        let ed = try XCTUnwrap(editor(r))
        ed.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await spin(0.3)
        let next = try XCTUnwrap(r.state.editingTaskID(on: r.date))
        XCTAssertNotEqual(next, id, "Return: 아랫줄에 새 할 일")
        let nextRow = try XCTUnwrap(r.store.day(r.date).tasks.first { $0.id == next }?.row)
        let c3 = dailyCellCenter(row: nextRow)
        let before = menus.count
        await press(r, point(r, c3.x, c3.y + 10), travel: 6)
        XCTAssertEqual(menus.count, before + 1)
        assertStillWriting(r, next, "Return 으로 내려온 빈 할 일")
        let m3 = try XCTUnwrap(menus.last)
        m3.performActionForItem(at: try XCTUnwrap(m3.items.firstIndex { $0.title == cats[0].name }))
        await spin(0.2)
        XCTAssertEqual(r.store.day(r.date).tasks.first { $0.id == next }?.cat, cats[0].id)
        assertStillWriting(r, next, "빈 할 일에 형광펜을 고른 뒤")
    }

    // MARK: 주간 (왼쪽 색 막대 자리 — 같은 칸)

    func testWeeklyCategoryCellOpensDespitePointerTravelAndEdges() async throws {
        let r = await rig(.weekly)
        let id = r.store.addTask(r.date, row: 0)
        r.store.taskText(r.date, id: id).wrappedValue = "주간 회의"
        r.state.editingKey = AppState.taskKey(r.date, id)
        try await waitEditor(r, "주간 할 일 글 칸에 포커스")
        let x0 = WK.colX(0), y0 = WK.colTop + WK.taskY(0)
        let midX = x0 + (WK.tickX - 8 + WK.textX) / 2
        let mid = point(r, midX, y0 + WK.taskH / 2)
        // 주간 칸은 좁다 (가로 18 단위): 칸 안에서 세로로 미끄러진다
        let down = CGVector(dx: 0.2, dy: -1)
        let probes: [(String, NSPoint, CGFloat, Double)] = [
            ("그냥 클릭", mid, 0, 0.05),
            ("8pt 미끄러짐", point(r, midX, y0 + 6), 8, 0.05),
            ("1.2초 누름", mid, 0, 1.2),
            ("윗줄 선 바로 아래", point(r, x0 + WK.tickX, y0 + 1), 0, 0.05),
            ("아랫줄 선 바로 위", point(r, x0 + WK.tickX, y0 + WK.taskH - 1), 0, 0.05),
            ("글 시작 바로 앞", point(r, x0 + WK.textX - 1, y0 + WK.taskH / 2), 0, 0.05),
        ]
        for (what, p, travel, hold) in probes {
            let before = menus.count
            await press(r, p, travel: travel, dir: down, hold: hold)
            XCTAssertEqual(menus.count, before + 1, "주간 · \(what): 형광펜 메뉴가 떠야 한다")
            XCTAssertEqual(r.state.editingKey, AppState.taskKey(r.date, id), "주간 · \(what): 쓰기가 끝나면 안 된다")
        }
    }

    // MARK: 누르는 사각형 (공유 벡터 — Windows · Android web 과 같은 값)

    func testHitRectVectors() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("task-category-cell.json"))
        let f = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(f["version"] as? Int, 1)
        func rect(_ v: Any?) throws -> CGRect {
            let a = try XCTUnwrap(v as? [NSNumber]).map { CGFloat($0.doubleValue) }
            return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        }
        func close(_ a: CGRect, _ b: CGRect, _ what: String) {
            for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] {
                XCTAssertEqual(x, y, accuracy: 0.01, what)
            }
        }
        let daily = try XCTUnwrap(f["daily"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(daily.count, 3)
        for v in daily {
            let row = try XCTUnwrap(v["row"] as? Int), span = try XCTUnwrap(v["span"] as? Int), rows = try XCTUnwrap(v["rows"] as? Int)
            let hit = F.taskCategoryHitRect(row: row, span: span, rows: rows)
            let shade = F.taskCategoryHighlightRect(row: row, span: span, rows: rows)
            close(hit, try rect(v["hit"]), "\(v["name"] ?? v) hit")
            close(shade, try rect(v["highlight"]), "\(v["name"] ?? v) highlight")
            // 칠하는 모양은 누르는 자리 안 · 누르는 자리는 인쇄된 칸 전체 (왼쪽 끝 ~ 글 시작, 그 줄들 전체)
            XCTAssertTrue(hit.contains(shade))
            XCTAssertEqual(hit.minX, F.left, accuracy: 0.001)
            XCTAssertEqual(hit.maxX, F.taskTextX, accuracy: 0.001)
            XCTAssertEqual(hit.minY, F.gridTop + CGFloat(row) * F.taskPitch(rows), accuracy: 0.001)
            XCTAssertEqual(hit.height, CGFloat(span) * F.taskPitch(rows), accuracy: 0.001)
        }
        // 이웃한 할 일의 누르는 자리는 틈 없이 맞닿는다 (그 사이를 눌러도 종이로 떨어지지 않는다)
        let a = F.taskCategoryHitRect(row: 2, span: 1, rows: 15), b = F.taskCategoryHitRect(row: 3, span: 2, rows: 15)
        XCTAssertEqual(a.maxY, b.minY, accuracy: 0.0001)
        let weekly = try XCTUnwrap(f["weekly"] as? [String: Any])
        close(CGRect(x: WK.tickX - 8, y: WK.taskY(0), width: WK.textX - (WK.tickX - 8), height: WK.taskH), try rect(weekly["hit0"]),
              "weekly hit0")
    }
}

private final class FakeKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

private final class FirstMouseHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
#endif
