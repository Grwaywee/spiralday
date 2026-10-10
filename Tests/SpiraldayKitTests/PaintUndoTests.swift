#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import SpiraldayKit

/// 1.1.1 부터 칠한 칸을 같은 색으로 다시 칠하거나 한 번 누르기만 해도 그 칸의 손글씨 메모 · 밥시간이 지워진다 (iPhone 처럼).
/// 그런데 Mac 타임테이블에는 되돌리기가 없어서 지운 손글씨를 되살릴 길이 없었다 (회의적 검토 2026-10-10 — iPhone 은 같은 붓질 뒤에
/// ‘…지웠어요’ 알림과 [되돌리기]가 뜬다). 이제 칠하기 · 지우기 붓질 하나를 ⌘Z 한 번으로 되돌리고 ⇧⌘Z 로 다시 한다.
/// 진짜 PageView(일간 · 주간)를 화면 밖 창에 띄우고, 마우스 이벤트를 창에 보내고, ⌘Z 는 편집 메뉴처럼 첫 응답자에게 undo: 로 보낸다.
@MainActor
final class PaintUndoTests: XCTestCase {
    private static let repoFonts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Fonts")

    private var windows: [NSWindow] = []
    private var eventNumber = 1700

    override func setUp() async throws {
        Fonts.extraFontDirectories = [Self.repoFonts]
        Fonts.register()
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        for w in windows { w.undoManager?.removeAllActions(); w.orderOut(nil) }
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
        let win = UndoKeyWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: w, height: h), styleMask: [.borderless],
                                backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = UndoFirstMouseHost(rootView: AnyView(PageView(kind: kind, index: state.index)
            .frame(width: w, height: h)
            .environmentObject(store).environmentObject(state)))
        win.orderFrontRegardless()
        win.makeKey()
        windows.append(win)
        state.plannerWindow = win
        await spin(0.3)
        let date = kind == .daily ? state.dayDate(state.index) : Dates.add(days: 2, to: state.weekStart(state.index))
        return Rig(kind: kind, store: store, state: state, win: win, date: date, u: w / kind.design.width, height: h)
    }

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

    private func point(_ r: Rig, _ p: CGPoint) -> NSPoint { NSPoint(x: p.x * r.u, y: r.height - p.y * r.u) }

    private func send(_ r: Rig, _ type: NSEvent.EventType, _ p: NSPoint) {
        eventNumber += 1
        r.win.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: r.win.windowNumber, context: nil, eventNumber: eventNumber,
                                           clickCount: type == .mouseMoved ? 0 : 1,
                                           pressure: type == .leftMouseDown ? 1 : 0)!)
    }

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

    /// 편집 메뉴의 ‘실행 취소’ · ‘실행 복귀’처럼: 창의 첫 응답자에서 응답자 사슬로 undo: · redo:
    @discardableResult
    private func menu(_ r: Rig, _ action: String) async -> Bool {
        let handled = (r.win.firstResponder ?? r.win).tryToPerform(Selector((action)), with: nil)
        await spin(0.2)
        return handled
    }

    private func slots(_ r: Rig) -> [Int] { r.store.day(r.date).slots }
    private func noteIDs(_ r: Rig) -> Set<UUID> { Set(r.store.day(r.date).notes.map(\.id)) }
    private let empty = -1

    // MARK: 같은 펜 한 번 클릭으로 지운 칸 · 손글씨는 ⌘Z 로 돌아온다

    private func checkSamePenClickUndo(_ kind: PageKind) async throws {
        let r = await rig(kind)
        let p = r.store.categories[0].id
        r.store.editDay(r.date) { d in for s in 60...65 { d.slots[s] = p } }
        let text = r.store.addNote(r.date, TimeNote(kind: .text, start: 62, end: 63, text: "회의"))
        let meal = r.store.addNote(r.date, TimeNote(kind: .meal, start: 64, end: 69))
        await spin(0.2)
        r.state.tool = p
        await stroke(r, from: 63, to: 63)
        XCTAssertEqual(slots(r)[63], empty, "\(kind): 같은 펜으로 누른 칸이 지워진다 (틀)")
        XCTAssertFalse(noteIDs(r).contains(text), "\(kind): 그 칸의 손글씨도 지워진다 (틀)")
        XCTAssertTrue(r.win.undoManager?.canUndo ?? false, "\(kind): 지운 붓질은 창의 되돌리기 기록에 남는다")
        let handled = await menu(r, "undo:")
        XCTAssertTrue(handled, "\(kind): ⌘Z 를 종이가 받는다")
        XCTAssertEqual(Array(slots(r)[60...65]), Array(repeating: p, count: 6), "\(kind): ⌘Z 로 칸이 돌아온다")
        XCTAssertEqual(noteIDs(r), [text, meal], "\(kind): ⌘Z 로 지운 손글씨가 돌아온다")
        XCTAssertEqual(r.store.day(r.date).notes.first { $0.id == text }?.text, "회의", "\(kind): 글도 그대로")
        // ⇧⌘Z: 다시 지운다
        let redone = await menu(r, "redo:")
        XCTAssertTrue(redone)
        XCTAssertEqual(slots(r)[63], empty, "\(kind): ⇧⌘Z 로 다시 지운다")
        XCTAssertEqual(noteIDs(r), [meal], "\(kind): ⇧⌘Z 로 손글씨도 다시 지운다")
        await menu(r, "undo:")
        XCTAssertEqual(noteIDs(r), [text, meal])
    }

    func testDailySamePenClickIsUndoable() async throws { try await checkSamePenClickUndo(.daily) }
    func testWeeklySamePenClickIsUndoable() async throws { try await checkSamePenClickUndo(.weekly) }

    // MARK: 붓질 하나 = ⌘Z 한 번 (칠하기 · 지우개도)

    private func checkStrokesUndoOneByOne(_ kind: PageKind) async throws {
        let r = await rig(kind)
        let p = r.store.categories[0].id, q = r.store.categories[1].id
        let meal = r.store.addNote(r.date, TimeNote(kind: .meal, start: 92, end: 97))
        await spin(0.2)
        // 1. 빈 칸에 칠하기
        r.state.tool = p
        await stroke(r, from: 90, to: 95)
        XCTAssertEqual(Array(slots(r)[90...95]), Array(repeating: p, count: 6))
        // 2. 다른 색으로 덧칠
        r.state.tool = q
        await stroke(r, from: 93, to: 95)
        XCTAssertEqual(Array(slots(r)[90...95]), [p, p, p, q, q, q])
        // 3. 지우개 (밥도 함께)
        r.state.tool = AppState.eraser
        await stroke(r, from: 91, to: 92)
        XCTAssertEqual(Array(slots(r)[90...95]), [p, empty, empty, q, q, q])
        XCTAssertFalse(noteIDs(r).contains(meal))
        // 하나씩 거꾸로
        await menu(r, "undo:")
        XCTAssertEqual(Array(slots(r)[90...95]), [p, p, p, q, q, q], "\(kind): ⌘Z 한 번은 지우개 붓질 하나")
        XCTAssertTrue(noteIDs(r).contains(meal), "\(kind): 지우개가 지운 밥도 돌아온다")
        await menu(r, "undo:")
        XCTAssertEqual(Array(slots(r)[90...95]), Array(repeating: p, count: 6), "\(kind): 덧칠 붓질 하나")
        await menu(r, "undo:")
        XCTAssertEqual(Array(slots(r)[90...95]), Array(repeating: empty, count: 6), "\(kind): 칠하기 붓질 하나")
        XCTAssertTrue(noteIDs(r).contains(meal))
    }

    func testDailyStrokesUndoOneByOne() async throws { try await checkStrokesUndoOneByOne(.daily) }
    func testWeeklyStrokesUndoOneByOne() async throws { try await checkStrokesUndoOneByOne(.weekly) }

    // MARK: ⌘Z 는 그 사이 다른 기기가 바꾼 것을 지우지 않는다

    func testUndoKeepsWhatAnotherDeviceChangedMeanwhile() async throws {
        let r = await rig(.daily)
        let p = r.store.categories[0].id, q = r.store.categories[2].id
        r.store.editDay(r.date) { d in for s in 60...65 { d.slots[s] = p } }
        let text = r.store.addNote(r.date, TimeNote(kind: .text, start: 62, end: 63, text: "회의"))
        await spin(0.2)
        r.state.tool = p
        await stroke(r, from: 60, to: 65)
        XCTAssertEqual(Array(slots(r)[60...65]), Array(repeating: empty, count: 6))
        XCTAssertFalse(noteIDs(r).contains(text))
        // 다른 기기(실시간 동기화가 끝나는 저장소 호출과 같다): 61 을 다른 색으로, 다른 줄에 밥 하나, 30 을 칠함
        r.store.editDay(r.date) { d in d.slots[61] = q; d.slots[30] = q }
        let theirs = r.store.addNote(r.date, TimeNote(kind: .meal, start: 100, end: 105))
        await spin(0.2)
        await menu(r, "undo:")
        XCTAssertEqual(Array(slots(r)[60...65]), [p, q, p, p, p, p], "붓질이 바꾼 칸만 돌아오고, 그 사이 다른 기기가 칠한 61 은 그대로")
        XCTAssertEqual(slots(r)[30], q, "붓질 밖의 칸은 건드리지 않는다")
        XCTAssertEqual(noteIDs(r), [text, theirs], "지운 손글씨는 돌아오고 다른 기기의 밥은 그대로")
    }

    /// 아무것도 바꾸지 않은 붓질(지운 칸이 없는 지우개)은 되돌리기 기록에 남기지 않는다 — ⌘Z 가 헛돌지 않게
    func testAStrokeThatChangesNothingLeavesNoUndo() async throws {
        let r = await rig(.daily)
        r.state.tool = AppState.eraser
        await stroke(r, from: 40, to: 44)
        XCTAssertFalse(r.win.undoManager?.canUndo ?? false)
    }
}

private final class UndoKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

private final class UndoFirstMouseHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
#endif
