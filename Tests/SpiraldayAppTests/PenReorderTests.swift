import XCTest
import AppKit
import SwiftUI
@testable import SpiraldayKit
@testable import Spiralday

/// 사장님 신고 (2026-10-08): 설정 › 형광펜 › 펜 목록에서 줄을 끌어 위아래 순서를 바꿀 수 없다.
/// 원인: 펜 줄이 grouped Form 안의 ForEach.onMove 였는데, Mac 의 grouped Form 은 표(NSTableView)가 아니라서 .onMove 가 붙을 곳이
/// 없었다 (2829ba7 부터 한 번도 끌어지지 않았다). 이제 펜 줄은 Form 안의 진짜 표(List)에 있다.
/// 진짜 SettingsView(형광펜 칸)를 화면 밖 창에 띄워, SwiftUI 표가 끌어 놓을 때 지나는 AppKit 길
/// (pasteboardWriterForItem → draggingSession willBegin → validateDrop → acceptDrop)을 그대로 지나며 확인한다.
/// 저장소는 임시 폴더 (사용자 데이터를 건드리지 않는다).
@MainActor
final class PenReorderTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var dirs: [URL] = []

    override func tearDown() async throws {
        for w in windows { w.orderOut(nil) }
        windows = []
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private final class FakeDrag: NSObject, NSDraggingInfo {
        let src: NSView, pb: NSPasteboard
        init(src: NSView, pb: NSPasteboard) { self.src = src; self.pb = pb }
        var draggingDestinationWindow: NSWindow? { src.window }
        var draggingSourceOperationMask: NSDragOperation { [.move, .generic] }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { pb }
        var draggingSource: Any? { src }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    private struct Rig {
        let dir: URL
        let store: PlannerStore
        let state: AppState
        let win: NSWindow
    }

    private func spin(_ s: Double = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func rig(pens: Int = 7, height: CGFloat = 560) throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pen-reorder-\(UUID().uuidString)")
        dirs.append(dir)
        let store = PlannerStore(folder: dir)
        _ = store.createBook(name: "펜 순서", start: Dates.parse("2026-10-05")!, end: nil)
        while store.categories.count < pens {
            _ = store.addCategory(name: "형광펜 \(store.categories.count + 1)", hex: "A0C4FF")
        }
        while store.categories.count > pens, let last = store.categories.last { store.removeCategory(last.id) }
        let state = AppState(kind: .daily)
        state.store = store
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pen-reorder-\(UUID().uuidString)"))
        let sync = SyncController.unavailable(store: store, defaults: defaults)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 720, height: height),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: SettingsView(fixedPane: .pens)
            .environmentObject(store).environmentObject(state).environmentObject(sync))
        w.setContentSize(NSSize(width: 720, height: height))
        w.orderFrontRegardless()
        windows.append(w)
        spin(1.2)
        return Rig(dir: dir, store: store, state: state, win: w)
    }

    private func walk(_ v: NSView, _ out: inout [NSView]) {
        out.append(v)
        for s in v.subviews { walk(s, &out) }
    }

    /// 펜 줄을 담은 표 (옆 막대의 설정 칸 목록은 빼고)
    private func penTable(_ r: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> NSOutlineView {
        var all: [NSView] = []
        walk(r.win.contentView!, &all)
        let tables = all.compactMap { $0 as? NSOutlineView }
            .filter { t in !(t.dataSource.map { String(describing: type(of: $0)) } ?? "").contains("SettingsPane") }
        return try XCTUnwrap(tables.first { $0.numberOfRows == r.store.categories.count },
                             "펜 \(r.store.categories.count)줄을 담은 표가 없다 — grouped Form 안의 .onMove 는 Mac 에서 붙을 곳이 없다",
                             file: file, line: line)
    }

    /// row 번째 줄을 끌어 childIndex 자리(원래 배열 기준, 끝 = 펜 수)에 놓는다
    private func drag(_ r: Rig, row: Int, to childIndex: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let ov = try penTable(r, file: file, line: line)
        let ds = try XCTUnwrap(ov.dataSource, file: file, line: line)
        let item = ov.item(atRow: row)
        let writer = try XCTUnwrap(ds.outlineView?(ov, pasteboardWriterForItem: item as Any), "\(row)번째 줄을 끌 수 없다",
                                   file: file, line: line)
        let pb = NSPasteboard(name: NSPasteboard.Name("pen-reorder-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([writer])
        let session = NSDraggingSession()
        ds.outlineView?(ov, draggingSession: session, willBeginAt: .zero, forItems: [item as Any])
        let info = FakeDrag(src: ov, pb: pb)
        let parent = ov.parent(forItem: item)
        XCTAssertNotEqual(ds.outlineView?(ov, validateDrop: info, proposedItem: parent, proposedChildIndex: childIndex) ?? [], [],
                          "놓을 수 있어야 한다", file: file, line: line)
        XCTAssertTrue(ds.outlineView?(ov, acceptDrop: info, item: parent, childIndex: childIndex) ?? false, file: file, line: line)
        ds.outlineView?(ov, draggingSession: session, endedAt: .zero, operation: .move)
        spin(0.4)
    }

    /// 숫자 키 n (1–7) 로 고른 펜
    private func penForDigit(_ r: Rig, _ n: Int) -> Int {
        let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26]
        _ = r.state.handleKey(window: .planner, responder: .none, keyCode: codes[n - 1], characters: "\(n)", modifiers: [])
        return r.state.tool
    }

    // MARK: 끌어 놓기

    func testDraggingAPenRowReordersRenumbersAndSaves() throws {
        let r = try rig()
        let before = r.store.categories.map(\.id)
        XCTAssertEqual(before.count, 7)
        let ov = try penTable(r)
        // 모든 줄을 끌 수 있다
        for row in 0..<ov.numberOfRows {
            XCTAssertNotNil(ov.dataSource?.outlineView?(ov, pasteboardWriterForItem: ov.item(atRow: row) as Any), "\(row)번째 줄")
        }
        // 첫 펜을 세 번째 펜 아래로
        try drag(r, row: 0, to: 3)
        let expected = [before[1], before[2], before[0]] + before[3...]
        XCTAssertEqual(r.store.categories.map(\.id), expected)
        // 숫자 배지 · 숫자 키 1–7 은 위에서부터 다시 매겨진다: 1 은 원래 두 번째 펜, 3 은 끌어 옮긴 펜
        XCTAssertEqual(penForDigit(r, 1), before[1])
        XCTAssertEqual(penForDigit(r, 3), before[0])
        XCTAssertEqual(penForDigit(r, 7), before[6])
        // 표도 새 순서로 다시 그려졌다 (다시 끌 수 있다)
        XCTAssertEqual(try penTable(r).numberOfRows, 7)
        // 저장: 같은 폴더를 다시 열어도 그 순서
        r.store.saveNow()
        XCTAssertEqual(PlannerStore(folder: r.dir).categories.map(\.id), expected)
    }

    func testDragBoundaries() throws {
        let r = try rig()
        let a = r.store.categories.map(\.id)
        // 맨 아래 → 맨 위
        try drag(r, row: 6, to: 0)
        let b = [a[6]] + a[0..<6]
        XCTAssertEqual(r.store.categories.map(\.id), b)
        XCTAssertEqual(penForDigit(r, 1), a[6])
        // 맨 위 → 맨 아래 (끝 = 펜 수)
        try drag(r, row: 0, to: 7)
        XCTAssertEqual(r.store.categories.map(\.id), a)
        // 한 칸 위로 (셋째 → 둘째)
        try drag(r, row: 2, to: 1)
        XCTAssertEqual(r.store.categories.map(\.id), [a[0], a[2], a[1]] + a[3...])
        // 제자리에 놓기는 아무것도 바꾸지 않는다
        try drag(r, row: 4, to: 4)
        try drag(r, row: 4, to: 5)
        XCTAssertEqual(r.store.categories.map(\.id), [a[0], a[2], a[1]] + a[3...])
    }

    // MARK: 표 모양 — 펜이 몇 개든 줄이 잘리지 않는다

    func testEveryPenRowIsFullyVisibleInTheTable() throws {
        for pens in [1, 7, Prefs.maxCategories] {
            let r = try rig(pens: pens, height: 1400)
            XCTAssertEqual(r.store.categories.count, pens)
            let ov = try penTable(r)
            let visible = try XCTUnwrap(ov.enclosingScrollView).documentVisibleRect
            for row in 0..<ov.numberOfRows {
                let rect = ov.rect(ofRow: row)
                XCTAssertEqual(rect.height, SettingsPenList.rowHeight, accuracy: 1, "펜 \(pens)개 · \(row)번째 줄 높이")
                XCTAssertTrue(visible.insetBy(dx: 0, dy: -0.5).contains(rect), "펜 \(pens)개 · \(row)번째 줄이 표 밖으로 잘린다 \(rect) / \(visible)")
            }
            // 표 아래에 빈 줄 자리가 남지 않는다
            XCTAssertEqual(visible.height, CGFloat(pens) * SettingsPenList.rowHeight, accuracy: 2, "펜 \(pens)개")
            r.win.orderOut(nil)
        }
    }

    /// 펜 줄이 안쪽 표로 옮겨 갔어도: 형광펜 추가 → 바깥 칸이 새 펜 줄까지 내려가고, 새 펜의 이름 칸에 바로 쓴다
    func testAddingAPenScrollsToItAndFocusesItsName() throws {
        let r = try rig(height: 460)
        let ov = try penTable(r)
        let inner = try XCTUnwrap(ov.enclosingScrollView)
        let box = inner.convert(inner.bounds, to: nil)
        // '형광펜 추가' 단추: 펜 표 오른쪽 위 (머리말 줄의 끝)
        let p = NSPoint(x: box.maxX - 55, y: box.maxY + 20.5)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            r.win.sendEvent(NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: r.win.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                                               pressure: t == .leftMouseDown ? 1 : 0)!)
            spin(0.1)
        }
        spin(0.9)
        XCTAssertEqual(r.store.categories.count, 8, "형광펜 추가 단추를 눌렀다")
        let ov2 = try penTable(r)
        let outer = try XCTUnwrap(ov2.enclosingScrollView?.superview?.enclosingScrollView, "바깥 칸(Form)의 스크롤")
        let last = ov2.convert(ov2.rect(ofRow: ov2.numberOfRows - 1), to: outer.documentView)
        XCTAssertTrue(outer.documentVisibleRect.insetBy(dx: 0, dy: -1).contains(last),
                      "새 펜 줄이 보이게 내려간다 \(last) / \(outer.documentVisibleRect)")
        XCTAssertEqual((r.win.firstResponder as? NSTextView)?.string, r.store.categories.last?.name, "새 펜의 이름 칸에 바로 쓴다")
    }

    // MARK: 끌지 않고 옮기기 (오른쪽 클릭 · 손쉬운 사용 동작이 쓰는 길)

    func testMoveUpAndDownByOne() throws {
        let store = PlannerStore(inMemory: true)
        let a = store.categories.map(\.id)
        XCTAssertGreaterThanOrEqual(a.count, 3)
        XCTAssertFalse(SettingsPenList.move(store, a[0], by: -1), "맨 위에서 위로는 없다")
        XCTAssertFalse(SettingsPenList.move(store, a[a.count - 1], by: 1), "맨 아래에서 아래로는 없다")
        XCTAssertEqual(store.categories.map(\.id), a)
        XCTAssertTrue(SettingsPenList.move(store, a[0], by: 1))
        XCTAssertEqual(store.categories.map(\.id), [a[1], a[0]] + a[2...])
        XCTAssertTrue(SettingsPenList.move(store, a[0], by: -1))
        XCTAssertEqual(store.categories.map(\.id), a)
        XCTAssertTrue(SettingsPenList.move(store, a[a.count - 1], by: -1))
        XCTAssertEqual(store.categories.map(\.id), a[0..<(a.count - 2)] + [a[a.count - 1], a[a.count - 2]])
        XCTAssertFalse(SettingsPenList.move(store, 9_999, by: 1), "없는 펜")
    }
}
