#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import SpiraldayKit

/// 사장님 (직원 시험 2026-10-08, Android 폰 — Mac 도 같은 원인): "밥 표시하는 부분의 원 부분에서 선택이 어려워서 밑줄을 지울 수 없음 —
/// 밑줄 중에는 밥 동그라미가 선택을 가져가지 않게". 타임테이블의 🍴 동그라미(오른쪽 클릭 '밥시간 지우기' 자리)가 칠하기 층 위에 따로
/// 얹혀 있어서, 동그라미에서 시작한 마우스 끌기는 층에 닿지 않았다 — 형광펜 · 지우개 · 글씨 · 밥 무엇으로도 아무 일이 없었고,
/// 동그라미 밑 칸은 지울 수 없었다 (iPhone TimePaintView 는 한 뷰가 모든 터치를 받는다 — 기준).
/// 진짜 PageView(일간 · 주간)를 화면 밖 창에 띄우고 마우스 이벤트를 창에 보내 확인한다.
@MainActor
final class MealCircleStrokeTests: XCTestCase {
    private static let repoFonts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Fonts")

    private var windows: [NSWindow] = []
    private var eventNumber = 100

    override func setUp() async throws {
        Fonts.extraFontDirectories = [Self.repoFonts]
        Fonts.register()
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        for w in windows { w.orderOut(nil) }
        windows = []
    }

    // MARK: 틀

    private struct Rig {
        let kind: PageKind
        let store: PlannerStore
        let state: AppState
        let win: NSWindow
        let date: Date
        let u: CGFloat
        let height: CGFloat
    }

    private func spin(_ s: Double = 0.15) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private func rig(_ kind: PageKind) async -> Rig {
        let store = PlannerStore(inMemory: true)
        let state = AppState(kind: kind)
        state.store = store
        let w: CGFloat = kind == .daily ? 753 : 1400
        let h = (w * kind.design.height / kind.design.width).rounded()
        let win = MealKeyWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: w, height: h), styleMask: [.borderless],
                                backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = MealFirstMouseHost(rootView: AnyView(PageView(kind: kind, index: state.index)
            .frame(width: w, height: h)
            .environmentObject(store).environmentObject(state)))
        win.orderFrontRegardless()
        win.makeKey()
        windows.append(win)
        state.plannerWindow = win
        await spin(0.3)
        // 주간: 그 주의 수요일 칸 (가운데 기둥)
        let date = kind == .daily ? state.dayDate(state.index) : Dates.add(days: 2, to: state.weekStart(state.index))
        return Rig(kind: kind, store: store, state: state, win: win, date: date, u: w / kind.design.width, height: h)
    }

    /// 타임테이블 칸 s 의 한가운데 (디자인 좌표)
    private func cellCenter(_ r: Rig, _ s: Int) -> CGPoint { cellCenter(r.kind, s) }

    private func cellCenter(_ kind: PageKind, _ s: Int) -> CGPoint {
        switch kind {
        case .weekly:
            return CGPoint(x: WK.colX(2) + WK.cellsX + (CGFloat(s % 6) + 0.5) * WK.cellW,
                           y: WK.colTop + WK.ttTop + (CGFloat(s / 6) + 0.5) * WK.rowH)
        default:
            return CGPoint(x: DailyForm.slotsLeft + (CGFloat(s % 6) + 0.5) * DailyForm.cell,
                           y: DailyForm.gridTop + (CGFloat(s / 6) + 0.5) * DailyForm.hourPitch)
        }
    }

    /// 한 칸 너비 (디자인 좌표)
    private func cellW(_ r: Rig) -> CGFloat { cellW(r.kind) }
    private func cellW(_ kind: PageKind) -> CGFloat { kind == .weekly ? WK.cellW : DailyForm.cell }

    /// 디자인 좌표 → 창 좌표 (아래가 원점)
    private func point(_ r: Rig, _ p: CGPoint) -> NSPoint { NSPoint(x: p.x * r.u, y: r.height - p.y * r.u) }

    private func send(_ r: Rig, _ type: NSEvent.EventType, _ p: NSPoint) {
        eventNumber += 1
        r.win.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: r.win.windowNumber, context: nil, eventNumber: eventNumber,
                                           clickCount: type == .mouseMoved ? 0 : 1,
                                           pressure: type == .leftMouseDown ? 1 : 0)!)
    }

    /// 칸 from 에서 눌러 칸 to 까지 끌고 뗀다 (from == to 면 그 자리 클릭)
    private func stroke(_ r: Rig, from: Int, to: Int) async {
        let a = point(r, cellCenter(r, from)), b = point(r, cellCenter(r, to))
        send(r, .mouseMoved, a)
        await spin(0.05)
        send(r, .leftMouseDown, a)
        await spin(0.05)
        if from != to {
            for k in 1...4 {
                send(r, .leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * CGFloat(k) / 4, y: a.y + (b.y - a.y) * CGFloat(k) / 4))
                await spin(0.02)
            }
        }
        send(r, .leftMouseUp, b)
        await spin(0.25)
    }

    private func slots(_ r: Rig) -> [Int] { r.store.day(r.date).slots }
    private func meals(_ r: Rig) -> [TimeNote] { r.store.day(r.date).notes.filter { $0.kind == .meal } }

    /// 11:20 칸(32)에서 시작하는 밥 (11:20 – 12:10) — 동그라미가 칸 32 한가운데에 있다
    private let mealStart = 32
    @discardableResult
    private func addMeal(_ r: Rig) async -> UUID {
        let id = r.store.addNote(r.date, TimeNote(kind: .meal, start: mealStart, end: mealStart + 5))
        await spin(0.15)
        return id
    }

    private func pen(_ r: Rig) -> Int { r.store.categories[0].id }
    /// 칠하지 않은 칸
    private let empty = -1

    // MARK: 동그라미에서 시작한 끌기가 층에 닿는다

    private func checkPenStartsOnCircle(_ kind: PageKind) async throws {
        let r = await rig(kind)
        await addMeal(r)
        r.state.tool = pen(r)
        // 틀 확인: 동그라미 밖에서 시작한 끌기는 (고치기 전에도) 칠해진다
        await stroke(r, from: 60, to: 62)
        XCTAssertEqual(Array(slots(r)[60...62]), Array(repeating: pen(r), count: 3), "\(kind): 다른 칸의 끌기")
        XCTAssertEqual(slots(r)[mealStart], empty, "아직 칠하지 않은 칸")
        await stroke(r, from: mealStart, to: mealStart + 2)
        XCTAssertEqual(Array(slots(r)[mealStart...mealStart + 2]), Array(repeating: pen(r), count: 3),
                       "\(kind): 동그라미에서 시작한 형광펜 끌기가 칠해져야 한다")
        XCTAssertEqual(meals(r).count, 1, "밥은 그대로")
        // 동그라미 클릭 한 번도 다른 칸과 같다: 같은 펜으로 칠한 칸이면 지우고, 빈 칸이면 칠한다
        await stroke(r, from: mealStart, to: mealStart)
        XCTAssertEqual(slots(r)[mealStart], empty, "\(kind): 칠한 칸의 동그라미를 같은 펜으로 누르면 그 칸이 지워져야 한다")
        await stroke(r, from: mealStart, to: mealStart)
        XCTAssertEqual(slots(r)[mealStart], pen(r), "\(kind): 동그라미를 누르면 그 칸이 칠해져야 한다")
    }

    func testDailyPenStrokeStartingOnMealCirclePaints() async throws { try await checkPenStartsOnCircle(.daily) }
    func testWeeklyPenStrokeStartingOnMealCirclePaints() async throws { try await checkPenStartsOnCircle(.weekly) }

    private func checkEraserStartsOnCircle(_ kind: PageKind) async throws {
        let r = await rig(kind)
        let p = pen(r)
        r.store.editDay(r.date) { d in for s in 30...35 { d.slots[s] = p } }
        await addMeal(r)
        r.state.tool = AppState.eraser
        await stroke(r, from: mealStart, to: mealStart + 2)
        XCTAssertEqual(Array(slots(r)[30...35]), [p, p, empty, empty, empty, p], "\(kind): 동그라미 밑 칸부터 지워져야 한다")
        XCTAssertTrue(meals(r).isEmpty, "\(kind): 지우개가 지나간 밥시간도 지워져야 한다 (다른 칸에서 시작할 때와 같다)")
    }

    func testDailyEraserStartingOnMealCircleErases() async throws { try await checkEraserStartsOnCircle(.daily) }
    func testWeeklyEraserStartingOnMealCircleErases() async throws { try await checkEraserStartsOnCircle(.weekly) }

    private func checkTextAndMealToolsStartOnCircle(_ kind: PageKind) async throws {
        let r = await rig(kind)
        await addMeal(r)
        // 글씨(밑줄): 동그라미에서 끌면 그 범위에 글씨 메모가 생기고 쓰기 시작
        r.state.tool = AppState.textTool
        await stroke(r, from: mealStart, to: mealStart + 1)
        let text = r.store.day(r.date).notes.filter { $0.kind == .text }
        XCTAssertEqual(text.map { [$0.start, $0.end] }, [[mealStart, mealStart + 1]], "\(kind): 동그라미에서 시작한 글씨 끌기")
        XCTAssertEqual(r.state.editingKey, text.first.map { "tn|\(Dates.key(r.date))|\($0.id.uuidString)" })
        r.state.endEditing()
        await spin(0.1)
        // 밥: 동그라미를 누르면 그 자리에 한 시간 (다른 칸과 같다)
        r.state.tool = AppState.mealTool
        let other = r.store.day(r.date).notes.count
        await stroke(r, from: mealStart, to: mealStart)
        XCTAssertEqual(meals(r).count, 2, "\(kind): 동그라미를 눌러도 밥 도구가 동작해야 한다")
        XCTAssertEqual(r.store.day(r.date).notes.count, other + 1)
    }

    func testDailyTextAndMealToolsStartOnMealCircle() async throws { try await checkTextAndMealToolsStartOnCircle(.daily) }
    func testWeeklyTextAndMealToolsStartOnMealCircle() async throws { try await checkTextAndMealToolsStartOnCircle(.weekly) }

    // MARK: 동그라미의 메뉴는 그대로 (오른쪽 클릭 · ⌃클릭)

    private func rightClickMenu(_ r: Rig, at d: CGPoint) -> NSMenu? {
        let p = point(r, d)
        // 창이 하듯이: 창의 맨 바깥 뷰(콘텐츠 뷰의 부모)에 창 좌표로 묻는다 (호스팅 뷰는 뒤집힌 좌표라 직접 묻지 않는다)
        guard let frame = r.win.contentView?.superview, let hit = frame.hitTest(p) else { return nil }
        let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: r.win.windowNumber, context: nil, eventNumber: 9_999, clickCount: 1, pressure: 1)!
        var v: NSView? = hit
        while let view = v {
            if let m = view.menu(for: e) { return m }
            v = view.superview
        }
        return nil
    }

    private func checkMenuStays(_ kind: PageKind) async throws {
        let r = await rig(kind)
        let id = await addMeal(r)
        let menu = try XCTUnwrap(rightClickMenu(r, at: cellCenter(r, mealStart)), "\(kind): 동그라미를 오른쪽 클릭하면 메뉴")
        let item = try XCTUnwrap(menu.items.first { $0.title == "밥시간 지우기" }, "\(kind): '밥시간 지우기'")
        // 그 메뉴 항목이 그 밥을 지운다
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        await spin(0.2)
        XCTAssertFalse(r.store.day(r.date).notes.contains { $0.id == id }, "\(kind): '밥시간 지우기'가 그 밥을 지워야 한다")
        // 오른쪽 클릭은 칠하지 않는다
        XCTAssertEqual(slots(r)[mealStart], empty)
        // 동그라미 밖(같은 줄 다른 칸)에는 밥 메뉴가 없다
        await addMeal(r)
        let away = rightClickMenu(r, at: cellCenter(r, mealStart + 3))
        XCTAssertNil(away?.items.first { $0.title == "밥시간 지우기" }, "\(kind): 동그라미 밖에는 밥 메뉴가 없다")
    }

    func testDailyMealCircleMenuStillOffered() async throws { try await checkMenuStays(.daily) }
    func testWeeklyMealCircleMenuStillOffered() async throws { try await checkMenuStays(.weekly) }

    /// 동그라미를 오른쪽 클릭 · ⌃클릭하면 그 메뉴가 뜨고, 그 누름은 칸을 칠하지 않는다 (왼쪽 끌기만 칠하기 층으로 간다).
    /// 메뉴는 진짜로 띄우고, 뜨자마자 닫는다.
    private func checkMenuClickDoesNotPaint(_ kind: PageKind) async throws {
        let r = await rig(kind)
        await addMeal(r)
        r.state.tool = pen(r)
        var opened: [String] = []
        let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            let menu = n.object as? NSMenu
            MainActor.assumeIsolated {
                opened.append(menu?.items.map(\.title).joined(separator: ",") ?? "")
                RunLoop.main.perform(inModes: [.eventTracking, .default]) { menu?.cancelTrackingWithoutAnimation() }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let p = point(r, cellCenter(r, mealStart))
        let clicks: [(String, NSEvent.EventType, NSEvent.EventType, NSEvent.ModifierFlags)] = [
            ("오른쪽 클릭", .rightMouseDown, .rightMouseUp, []),
            ("⌃클릭", .leftMouseDown, .leftMouseUp, .control),
        ]
        for (name, down, up, flags) in clicks {
            opened = []
            for (type, pressure) in [(down, Float(1)), (up, Float(0))] {
                eventNumber += 1
                r.win.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: r.win.windowNumber, context: nil, eventNumber: eventNumber,
                                                   clickCount: 1, pressure: pressure)!)
                await spin(0.2)
            }
            XCTAssertEqual(opened, ["밥시간 지우기"], "\(kind) \(name): 동그라미의 메뉴")
            XCTAssertEqual(slots(r)[mealStart], empty, "\(kind) \(name): 메뉴를 여는 누름은 칸을 칠하지 않는다")
            XCTAssertEqual(meals(r).count, 1)
        }
    }

    func testDailyMealCircleMenuClickDoesNotPaint() async throws { try await checkMenuClickDoesNotPaint(.daily) }
    func testWeeklyMealCircleMenuClickDoesNotPaint() async throws { try await checkMenuClickDoesNotPaint(.weekly) }

    // MARK: 넘김 스냅샷 · PDF 에는 동그라미 그림만

    /// 넘김 스냅샷(PDF 도 같은 ImageRenderer · isSnapshot)에 동그라미의 AppKit 뷰가 찍히지 않는다 —
    /// 찍히면 ImageRenderer 가 그 자리에 노란 '그릴 수 없음' 자리표(시스템 노랑 255,204,0)를 그린다.
    private func checkSnapshotHasNoPlaceholder(_ kind: PageKind) throws {
        let store = PlannerStore(inMemory: true)
        let state = AppState(kind: kind)
        state.store = store
        let w: CGFloat = kind == .daily ? 753 : 1400
        let size = CGSize(width: w, height: (w * kind.design.height / kind.design.width).rounded())
        let date = kind == .daily ? state.dayDate(state.index) : Dates.add(days: 2, to: state.weekStart(state.index))
        store.addNote(date, TimeNote(kind: .meal, start: mealStart, end: mealStart + 5))
        let img = try XCTUnwrap(PageSnapshotter(store: store, state: state).image(kind: kind, index: state.index, size: size, scale: 2))
        let u = w / kind.design.width * 2
        let c = cellCenter(kind, mealStart)
        let box = CGRect(x: (c.x - cellW(kind)) * u, y: (c.y - cellW(kind)) * u, width: 2 * cellW(kind) * u, height: 2 * cellW(kind) * u)
        let crop = try XCTUnwrap(img.cropping(to: box.integral))
        let rep = NSBitmapImageRep(cgImage: crop)
        var placeholder = 0, inked = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let p = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let (r, g, b) = (p.redComponent * 255, p.greenComponent * 255, p.blueComponent * 255)
                if abs(r - 255) < 8 && abs(g - 204) < 8 && b < 10 { placeholder += 1 }
                if r + g + b < 600 { inked += 1 }
            }
        }
        XCTAssertGreaterThan(inked, 20, "\(kind): 동그라미 그림은 찍힌다")
        XCTAssertEqual(placeholder, 0, "\(kind): 스냅샷 · PDF 의 동그라미 자리에 노란 자리표가 없어야 한다")
    }

    func testDailySnapshotHasNoPlaceholderOnMealCircle() throws { try checkSnapshotHasNoPlaceholder(.daily) }
    func testWeeklySnapshotHasNoPlaceholderOnMealCircle() throws { try checkSnapshotHasNoPlaceholder(.weekly) }
}

private final class MealKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

private final class MealFirstMouseHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
#endif
