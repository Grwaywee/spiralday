#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import SpiraldayKit

/// iPhone 이 기준 (TimePaintView.finish): 지우는 붓질이면 — 지우개든, 칠한 칸을 같은 색 형광펜으로 다시 칠해 지우든 (paint == -1) —
/// 그 범위와 겹친 글씨 메모 · 밥시간도 함께 지운다. Mac 은 지우개일 때만 지워서, 같은 색으로 다시 칠해 지운 칸 위에 글씨 · 밥이 남았다.
/// 진짜 PageView(일간 · 주간)를 화면 밖 창에 띄우고 마우스 이벤트를 창에 보내 확인한다.
@MainActor
final class RepaintEraseNotesTests: XCTestCase {
    private static let repoFonts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Fonts")

    private var windows: [NSWindow] = []
    private var eventNumber = 500

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
        let win = RepaintKeyWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: w, height: h), styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = RepaintFirstMouseHost(rootView: AnyView(PageView(kind: kind, index: state.index)
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
    private func cellCenter(_ r: Rig, _ s: Int) -> CGPoint {
        switch r.kind {
        case .weekly:
            return CGPoint(x: WK.colX(2) + WK.cellsX + (CGFloat(s % 6) + 0.5) * WK.cellW,
                           y: WK.colTop + WK.ttTop + (CGFloat(s / 6) + 0.5) * WK.rowH)
        default:
            return CGPoint(x: DailyForm.slotsLeft + (CGFloat(s % 6) + 0.5) * DailyForm.cell,
                           y: DailyForm.gridTop + (CGFloat(s / 6) + 0.5) * DailyForm.hourPitch)
        }
    }

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
            for k in 1...5 {
                send(r, .leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * CGFloat(k) / 5, y: a.y + (b.y - a.y) * CGFloat(k) / 5))
                await spin(0.02)
            }
        }
        send(r, .leftMouseUp, b)
        await spin(0.25)
    }

    private func slots(_ r: Rig) -> [Int] { r.store.day(r.date).slots }
    private func noteIDs(_ r: Rig) -> [UUID] { r.store.day(r.date).notes.map(\.id) }
    /// 칠하지 않은 칸
    private let empty = -1

    /// 10:00 줄(60…65)을 펜 p 로 칠하고, 그 위에 글씨 메모(62–63) · 밥(64 부터 한 시간), 다른 줄(11:20, 74)에 글씨 메모를 둔다
    private func prepare(_ r: Rig, pen p: Int) async -> (text: UUID, meal: UUID, away: UUID) {
        r.store.editDay(r.date) { d in for s in 60...65 { d.slots[s] = p } }
        let text = r.store.addNote(r.date, TimeNote(kind: .text, start: 62, end: 63, text: "회의"))
        let meal = r.store.addNote(r.date, TimeNote(kind: .meal, start: 64, end: 69))
        let away = r.store.addNote(r.date, TimeNote(kind: .text, start: 74, end: 75, text: "산책"))
        await spin(0.15)
        return (text, meal, away)
    }

    // MARK: 같은 색으로 다시 칠해 지우면 메모 · 밥도 함께 (iPhone 처럼)

    private func checkSamePenRepaintRemovesNotes(_ kind: PageKind) async throws {
        let r = await rig(kind)
        let p = r.store.categories[0].id
        let (text, meal, away) = await prepare(r, pen: p)
        r.state.tool = p
        // 칠한 칸(60)에서 같은 펜으로 시작한 끌기 = 지우는 붓질 (paint == -1)
        await stroke(r, from: 60, to: 65)
        XCTAssertEqual(Array(slots(r)[60...65]), Array(repeating: empty, count: 6), "\(kind): 같은 색으로 다시 칠하면 칸이 지워진다 (틀)")
        let left = noteIDs(r)
        XCTAssertFalse(left.contains(text), "\(kind): 같은 색으로 다시 칠해 지운 칸의 글씨 메모도 지워져야 한다 (iPhone 처럼)")
        XCTAssertFalse(left.contains(meal), "\(kind): 같은 색으로 다시 칠해 지운 칸의 밥시간도 지워져야 한다 (iPhone 처럼)")
        XCTAssertTrue(left.contains(away), "\(kind): 지운 범위 밖의 메모는 그대로")
    }

    func testDailySamePenRepaintRemovesNotes() async throws { try await checkSamePenRepaintRemovesNotes(.daily) }
    func testWeeklySamePenRepaintRemovesNotes() async throws { try await checkSamePenRepaintRemovesNotes(.weekly) }

    /// 칠한 칸 하나를 같은 펜으로 누르기만 해도 지우는 붓질 — 그 칸을 지나는 밥시간(화살표 칸)도 함께 지운다 (iPhone 처럼)
    private func checkSamePenClickRemovesOverlappingMeal(_ kind: PageKind) async throws {
        let r = await rig(kind)
        let p = r.store.categories[0].id
        let (text, meal, away) = await prepare(r, pen: p)
        r.state.tool = p
        // 65 는 밥(64…69)의 화살표 칸 — 동그라미(64)도 글씨(62)도 아닌 칠하기 층
        await stroke(r, from: 65, to: 65)
        XCTAssertEqual(Array(slots(r)[60...65]), [p, p, p, p, p, empty], "\(kind): 누른 칸만 지워진다 (틀)")
        let left = noteIDs(r)
        XCTAssertFalse(left.contains(meal), "\(kind): 지운 칸을 지나는 밥시간도 지워져야 한다 (iPhone 처럼)")
        XCTAssertTrue(left.contains(text), "\(kind): 겹치지 않는 글씨 메모는 그대로")
        XCTAssertTrue(left.contains(away))
    }

    func testDailySamePenClickRemovesOverlappingMeal() async throws { try await checkSamePenClickRemovesOverlappingMeal(.daily) }
    func testWeeklySamePenClickRemovesOverlappingMeal() async throws { try await checkSamePenClickRemovesOverlappingMeal(.weekly) }

    // MARK: 칠하는 붓질은 메모 · 밥을 그대로 둔다

    private func checkOtherPenKeepsNotes(_ kind: PageKind) async throws {
        let r = await rig(kind)
        let p = r.store.categories[0].id, q = r.store.categories[1].id
        let (text, meal, away) = await prepare(r, pen: p)
        // 다른 색 펜: 덧칠 (지우는 붓질이 아니다)
        r.state.tool = q
        await stroke(r, from: 60, to: 65)
        XCTAssertEqual(Array(slots(r)[60...65]), Array(repeating: q, count: 6), "\(kind): 다른 색이면 덧칠 (틀)")
        XCTAssertEqual(Set(noteIDs(r)), [text, meal, away], "\(kind): 칠하는 붓질은 메모 · 밥을 지우지 않는다")
        // 빈 칸에서 시작한 같은 펜: 칠하기 (빈 칸 → 펜)
        r.state.tool = p
        await stroke(r, from: 54, to: 57)
        XCTAssertEqual(Array(slots(r)[54...57]), Array(repeating: p, count: 4))
        XCTAssertEqual(Set(noteIDs(r)), [text, meal, away])
    }

    func testDailyOtherPenKeepsNotes() async throws { try await checkOtherPenKeepsNotes(.daily) }
    func testWeeklyOtherPenKeepsNotes() async throws { try await checkOtherPenKeepsNotes(.weekly) }

    /// 지우개는 예전처럼 겹친 메모 · 밥을 지운다
    private func checkEraserStillRemovesNotes(_ kind: PageKind) async throws {
        let r = await rig(kind)
        let p = r.store.categories[0].id
        let (text, meal, away) = await prepare(r, pen: p)
        r.state.tool = AppState.eraser
        await stroke(r, from: 60, to: 63)
        XCTAssertEqual(Array(slots(r)[60...65]), [empty, empty, empty, empty, p, p])
        let left = noteIDs(r)
        XCTAssertFalse(left.contains(text), "\(kind): 지우개는 겹친 글씨 메모를 지운다")
        XCTAssertTrue(left.contains(meal), "\(kind): 겹치지 않는 밥은 그대로")
        XCTAssertTrue(left.contains(away))
    }

    func testDailyEraserStillRemovesNotes() async throws { try await checkEraserStillRemovesNotes(.daily) }
    func testWeeklyEraserStillRemovesNotes() async throws { try await checkEraserStillRemovesNotes(.weekly) }
}

private final class RepaintKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

private final class RepaintFirstMouseHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
#endif
