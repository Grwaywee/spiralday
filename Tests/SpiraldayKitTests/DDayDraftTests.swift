#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import SpiraldayKit

/// 직원 시험 5-1 (Android 폰, 2026-10-08 — Mac · iPad · iPhone 의 Kit DDayEditor 도 같은 원인): "한 장 전체에 있는 디데이를 눌러서
/// 나오는 디데이는 완료를 눌러도 표시가 안됨". ‘새로 만들기’에 적은 이름은 [붙이기](또는 Return)로만 붙고, 편집기를 다른 식으로
/// 닫으면(Mac: 팝오버 바깥 클릭 · iPhone: 시트의 [완료] · 아래로 쓸기 · iPad: 바깥 톡) 적은 것이 말없이 버려졌다.
/// 이제 닫으면 [붙이기]처럼 붙는다. Esc(⌘.)는 ‘취소’라 적은 것을 버린다 (사장님 약속: 키보드의 Esc 는 취소).
/// 진짜 일간 PageView 를 화면 밖 창에 띄우고 D-DAY 칸을 눌러 진짜 팝오버를 연다. 바깥 클릭 · Esc 는 앱의 이벤트 줄을 거쳐
/// 보낸다 (NSApp.currentEvent 가 그 이벤트가 되게 — 앱이 실제로 받는 순서 그대로).
@MainActor
final class DDayDraftTests: XCTestCase {
    private static let repoFonts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Fonts")

    private var windows: [NSWindow] = []
    private let popovers = PopoverLog()
    private var shown: [NSPopover] { popovers.shown }
    private var eventNumber = 300

    override func setUp() async throws {
        Fonts.extraFontDirectories = [Self.repoFonts]
        Fonts.register()
        _ = NSApplication.shared
        popovers.start()
    }

    override func tearDown() async throws {
        popovers.stop()
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

    private let typed = "시험공부"
    private let placeholder = "무엇까지? (예: 시험)"

    private func spin(_ s: Double = 0.15) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private func rig() async -> Rig {
        let store = PlannerStore(inMemory: true)
        let state = AppState(kind: .daily)
        state.store = store
        let w: CGFloat = 753
        let h = (w * PageKind.daily.design.height / PageKind.daily.design.width).rounded()
        let win = DDayKeyWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: w, height: h), styleMask: [.borderless],
                                backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = DDayFirstMouseHost(rootView: AnyView(PageView(kind: .daily, index: state.index)
            .frame(width: w, height: h)
            .environmentObject(store).environmentObject(state)))
        win.orderFrontRegardless()
        win.makeKey()
        windows.append(win)
        state.plannerWindow = win
        await spin(0.3)
        return Rig(store: store, state: state, win: win, date: state.dayDate(state.index), u: w / PageKind.daily.design.width, height: h)
    }

    /// 디자인 좌표 → 창 좌표 (아래가 원점)
    private func point(_ r: Rig, _ p: CGPoint) -> NSPoint { NSPoint(x: p.x * r.u, y: r.height - p.y * r.u) }

    private func mouse(_ type: NSEvent.EventType, _ p: NSPoint, in w: NSWindow) -> NSEvent {
        eventNumber += 1
        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: w.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1,
                                  pressure: type == .leftMouseDown ? 1 : 0)!
    }

    /// 앱의 이벤트 줄을 거쳐 보낸다: 꺼낸 이벤트가 NSApp.currentEvent 가 된 채로 sendEvent (앱의 실행 고리와 같은 순서)
    private func dispatch(_ e: NSEvent) {
        NSApp.postEvent(e, atStart: true)
        guard let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else {
            XCTFail("이벤트 줄이 비었다")
            return
        }
        NSApp.sendEvent(next)
    }

    /// D-DAY 칸을 눌러 편집기(팝오버)를 연다
    private func open(_ r: Rig) async throws -> NSPopover {
        let c = point(r, CGPoint(x: DailyForm.ddayBox.midX, y: DailyForm.ddayBox.midY))
        let before = shown.count
        r.win.sendEvent(mouse(.leftMouseDown, c, in: r.win))
        await spin(0.05)
        r.win.sendEvent(mouse(.leftMouseUp, c, in: r.win))
        for _ in 0..<20 where shown.count == before { await spin(0.1) }
        let pop = try XCTUnwrap(shown.count > before ? shown.last : nil, "D-DAY 칸을 누르면 편집기 팝오버가 뜬다")
        await spin(0.3)
        return pop
    }

    private func field(_ pop: NSPopover) throws -> NSTextField {
        func find(_ v: NSView) -> NSTextField? {
            if let t = v as? NSTextField, t.isEditable, t.placeholderString == placeholder { return t }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        let root = try XCTUnwrap(pop.contentViewController?.view)
        return try XCTUnwrap(find(root.window?.contentView?.superview ?? root), "‘새로 만들기’ 이름 칸")
    }

    /// ‘새로 만들기’ 이름 칸에 글을 적는다 (입력기가 넣듯이 필드 편집기에)
    private func type(_ text: String, in pop: NSPopover) async throws {
        let tf = try field(pop)
        let w = try XCTUnwrap(tf.window)
        w.makeFirstResponder(tf)
        await spin(0.1)
        let editor = try XCTUnwrap(w.firstResponder as? NSTextView, "이름 칸이 쓰는 중")
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        await spin(0.2)
        XCTAssertEqual(tf.stringValue, text)
    }

    /// 이름 칸에 글을 적되 마지막 음절은 입력기가 아직 조합 중 (두벌식에서 스페이스 · Return 을 누르기 전)
    private func compose(_ text: String, marked: String, in pop: NSPopover) async throws -> NSTextView {
        let tf = try field(pop)
        let w = try XCTUnwrap(tf.window)
        w.makeFirstResponder(tf)
        await spin(0.1)
        let editor = try XCTUnwrap(w.firstResponder as? NSTextView, "이름 칸이 쓰는 중")
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        await spin(0.2)
        XCTAssertTrue(editor.hasMarkedText(), "틀 확인: 마지막 음절은 조합 중")
        XCTAssertEqual(editor.string, text + marked, "틀 확인: 이름 칸에는 다 보인다")
        return editor
    }

    /// [붙이기]를 마우스로 누른다. SwiftUI 가 그린 단추라 AppKit 단추가 없어서 자리로 누른다: ‘목록에도 저장’ 체크 상자
    /// (편집기의 하나뿐인 AppKit 단추)와 같은 줄, 편집기(폭 340 · 안쪽 여백 16)의 오른쪽 끝 단추
    private func pressAttach(_ pop: NSPopover) throws {
        let root = try XCTUnwrap(pop.contentViewController?.view)
        let w = try XCTUnwrap(root.window)
        func checkbox(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton { return b }
            for s in v.subviews { if let f = checkbox(s) { return f } }
            return nil
        }
        let box = try XCTUnwrap(checkbox(w.contentView?.superview ?? root), "‘목록에도 저장’ 체크 상자")
        let r = box.convert(box.bounds, to: nil)
        let p = NSPoint(x: r.minX - 16 + 340 - 16 - 20, y: r.midY)
        for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, Float(0))] {
            eventNumber += 1
            w.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1,
                                           pressure: pressure)!)
        }
    }

    /// 팝오버 바깥(종이의 다른 곳) 클릭으로 닫힌다: 그 클릭이 앱의 지금 이벤트인 채로 팝오버가 닫힌다
    /// (일시 팝오버가 바깥 클릭에 스스로 닫히는 것은 활성 앱에서만 일어나서, 닫기는 NSPopover 가 하듯 performClose 로)
    private func clickOutside(_ r: Rig, _ pop: NSPopover) async {
        let away = point(r, CGPoint(x: DailyForm.slotsLeft - 60, y: DailyForm.gridTop + 400))
        dispatch(mouse(.leftMouseDown, away, in: r.win))
        if !closed(pop) { pop.performClose(nil) }
        dispatch(mouse(.leftMouseUp, away, in: r.win))
        await spin(0.4)
    }

    /// 쓰는 중에 Esc (commandPeriod: ⌘. — 맥의 또 다른 취소 키)
    private func escape(_ pop: NSPopover, commandPeriod: Bool = false) async throws {
        let w = try XCTUnwrap(pop.contentViewController?.view.window)
        eventNumber += 1
        let (chars, code, flags): (String, UInt16, NSEvent.ModifierFlags) = commandPeriod ? (".", 47, .command) : ("\u{1b}", 53, [])
        dispatch(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                  isARepeat: false, keyCode: code)!)
        await spin(0.4)
    }

    /// 닫기 시작했다 (닫는 애니메이션은 활성 앱이 아니면 늦게 끝나서 isShown 대신 닫힘 알림을 본다)
    private func closed(_ pop: NSPopover) -> Bool { popovers.closing.contains(ObjectIdentifier(pop)) }

    private func titles(_ r: Rig) -> [String] { r.store.ddays(r.date).map(\.title) }

    // MARK: 닫으면 붙는다

    /// Mac: 이름을 적고 팝오버 바깥을 누르면 [붙이기]처럼 붙는다 (날짜 · ‘목록에도 저장’ 그대로)
    func testClickingOutsideAttachesTheTypedDDay() async throws {
        let r = await rig()
        XCTAssertTrue(titles(r).isEmpty)
        let pop = try await open(r)
        try await type("  \(typed) ", in: pop)
        await clickOutside(r, pop)
        XCTAssertTrue(closed(pop), "바깥을 누르면 닫힌다")
        XCTAssertEqual(titles(r), [typed], "바깥을 눌러 닫아도 적은 D-day 가 그 날에 붙어야 한다")
        let d = try XCTUnwrap(r.store.ddays(r.date).first)
        XCTAssertEqual(d.date, Dates.add(days: 30, to: r.date), "날짜는 ‘새로 만들기’의 날짜 (처음 값: 30일 뒤)")
        XCTAssertEqual(r.store.ddayLibrary.map(\.title), [typed], "‘목록에도 저장’(처음 켜짐)이면 저장한 목록에도")
        XCTAssertEqual(d.source, r.store.ddayLibrary.first?.id)
        // 다시 열면 ‘새로 만들기’는 비어 있다 (붙인 것은 위의 ‘붙인 D-day’ 줄에)
        let again = try await open(r)
        XCTAssertEqual(try field(again).stringValue, "")
        await clickOutside(r, again)
        XCTAssertEqual(titles(r), [typed], "빈 칸으로 다시 닫으면 더 붙지 않는다")
    }

    /// Return([붙이기]와 같다)으로 붙이고 닫으면 한 번만 붙는다
    func testReturnThenCloseAttachesOnce() async throws {
        let r = await rig()
        let pop = try await open(r)
        try await type(typed, in: pop)
        let editor = try XCTUnwrap(try field(pop).window?.firstResponder as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await spin(0.3)
        XCTAssertEqual(titles(r), [typed], "Return 은 [붙이기]")
        XCTAssertFalse(closed(pop), "붙이고 편집기는 열린 채")
        await clickOutside(r, pop)
        XCTAssertEqual(titles(r), [typed], "닫아도 또 붙지 않는다")
        XCTAssertEqual(r.store.ddayLibrary.count, 1)
    }

    /// 이름 없이 닫으면 아무것도 붙지 않는다 (날짜만 바꿨거나 아무것도 안 했을 때)
    func testClosingWithoutANameAttachesNothing() async throws {
        let r = await rig()
        let pop = try await open(r)
        try await type("   ", in: pop)
        await clickOutside(r, pop)
        XCTAssertTrue(closed(pop))
        XCTAssertTrue(titles(r).isEmpty, "빈 이름은 붙이지 않는다")
        XCTAssertTrue(r.store.ddayLibrary.isEmpty)
    }

    /// 2개가 찬 날은 닫아도 셋째를 붙이지 않는다 (적은 것도 남기지 않는다)
    func testAFullDayTakesNoThird() async throws {
        let r = await rig()
        r.store.addDDay(title: "하나", date: Dates.add(days: 3, to: r.date), to: r.date, save: false)
        r.store.addDDay(title: "둘", date: Dates.add(days: 5, to: r.date), to: r.date, save: false)
        let pop = try await open(r)
        try await type(typed, in: pop)
        await clickOutside(r, pop)
        XCTAssertEqual(titles(r), ["하나", "둘"])
        XCTAssertTrue(r.store.ddayLibrary.isEmpty, "붙지 않은 것은 목록에도 넣지 않는다")
        // 하나를 떼고 다시 열었다 닫아도, 아까 적었던 것이 뒤늦게 붙지 않는다
        r.store.removeDDay(r.store.ddays(r.date)[1].id, from: r.date)
        let again = try await open(r)
        await clickOutside(r, again)
        XCTAssertEqual(titles(r), ["하나"])
    }

    // MARK: Esc = 취소

    /// 쓰는 중에 Esc: 편집기가 닫히고 적은 것은 버린다
    func testEscapeDiscardsTheDraft() async throws {
        let r = await rig()
        let pop = try await open(r)
        try await type(typed, in: pop)
        try await escape(pop)
        XCTAssertTrue(closed(pop), "Esc 로 닫힌다")
        XCTAssertTrue(titles(r).isEmpty, "Esc 는 취소: 적은 D-day 를 붙이지 않는다")
        XCTAssertTrue(r.store.ddayLibrary.isEmpty)
        // 다시 열면 비어 있고, 바깥 클릭으로 닫아도 버린 것이 되살아나 붙지 않는다
        let again = try await open(r)
        XCTAssertEqual(try field(again).stringValue, "")
        await clickOutside(r, again)
        XCTAssertTrue(titles(r).isEmpty)
    }

    /// ⌘. 도 취소
    func testCommandPeriodDiscardsTheDraft() async throws {
        let r = await rig()
        let pop = try await open(r)
        try await type(typed, in: pop)
        try await escape(pop, commandPeriod: true)
        XCTAssertTrue(closed(pop), "⌘. 로 닫힌다")
        XCTAssertTrue(titles(r).isEmpty, "⌘. 는 취소: 적은 D-day 를 붙이지 않는다")
    }

    /// 종이(팝오버가 매달린 창)에 온 Esc 로 팝오버가 닫혀도 취소
    func testEscapeOnThePaperDiscardsTheDraft() async throws {
        let r = await rig()
        let pop = try await open(r)
        try await type(typed, in: pop)
        eventNumber += 1
        dispatch(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: r.win.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                  isARepeat: false, keyCode: 53)!)
        await spin(0.4)
        if !closed(pop) { pop.performClose(nil) }
        await spin(0.2)
        XCTAssertTrue(titles(r).isEmpty, "종이에 온 Esc 로 닫혀도 취소")
    }

    /// 앱의 ‘지금 이벤트’는 다음 이벤트까지 남는다: 예전에 다른 팝오버를 닫은 Esc 가, 이벤트 없이 닫힌 이번 편집기를 취소로 만들지 않는다
    func testAnEarlierEscapeElsewhereIsNotThisCancel() async throws {
        let first = await rig()
        let old = try await open(first)
        try await type("버릴 것", in: old)
        try await escape(old)
        XCTAssertTrue(closed(old))
        XCTAssertTrue(titles(first).isEmpty)
        XCTAssertEqual(NSApp.currentEvent?.keyCode, 53, "틀 확인: 앱의 지금 이벤트는 아직 그 Esc")
        let r = await rig()
        let pop = try await open(r)
        try await type(typed, in: pop)
        pop.performClose(nil)
        await spin(0.4)
        XCTAssertTrue(closed(pop))
        XCTAssertEqual(titles(r), [typed], "이번 닫기는 Esc 가 아니다: 적은 것이 붙는다")
    }

    // MARK: 한글 조합 중 (입력기가 마지막 음절을 아직 들고 있을 때)

    /// 두벌식은 스페이스 · Return 을 누르기 전까지 마지막 음절을 조합 중(밑줄 친 표시 글자)으로 둔다. 이름 칸에는 보이지만
    /// SwiftUI 의 글(바인딩)에는 아직 없어서, 그대로 바깥을 누르면 마지막 글자가 빠진 '시험공'이 붙고 목록에도 그렇게 들어갔다
    /// (회의적 검토 2026-10-10). 닫기 전에 조합을 마쳐 보이는 이름 그대로 한 번만 붙는다.
    func testClickingOutsideWhileComposingAttachesTheWholeName() async throws {
        let r = await rig()
        let pop = try await open(r)
        let editor = try await compose("시험공", marked: "부", in: pop)
        await clickOutside(r, pop)
        XCTAssertTrue(closed(pop))
        XCTAssertEqual(titles(r), [typed], "조합 중이던 마지막 글자까지 붙어야 한다")
        XCTAssertEqual(r.store.ddayLibrary.map(\.title), [typed], "목록에도 온전한 이름으로")
        // 입력기가 창이 바뀐 뒤에야 조합을 마쳐도 늦게 붙거나 두 번 붙지 않는다
        if editor.hasMarkedText() { editor.unmarkText() }
        await spin(0.3)
        let again = try await open(r)
        XCTAssertEqual(try field(again).stringValue, "")
        await clickOutside(r, again)
        XCTAssertEqual(titles(r), [typed])
        XCTAssertEqual(r.store.ddayLibrary.count, 1)
    }

    /// [붙이기]도 조합 중에 누르면 마지막 글자가 빠졌다 (원래 있던 문제 — 같은 원인). 붙인 뒤 이름 칸은 비고 닫아도 한 번
    func testAttachButtonWhileComposingAttachesTheWholeName() async throws {
        let r = await rig()
        let pop = try await open(r)
        _ = try await compose("시험공", marked: "부", in: pop)
        try pressAttach(pop)
        await spin(0.3)
        XCTAssertFalse(closed(pop), "[붙이기]는 편집기를 닫지 않는다")
        XCTAssertEqual(titles(r), [typed], "[붙이기]도 조합 중이던 글자까지 붙여야 한다")
        let tf = try field(pop)
        XCTAssertEqual(tf.stringValue, "", "붙인 뒤 이름 칸은 빈다")
        XCTAssertTrue((tf.window?.firstResponder as? NSTextView)?.delegate === tf, "이름 칸은 계속 쓰는 중 (조합하지 않을 때의 [붙이기]처럼)")
        await clickOutside(r, pop)
        XCTAssertEqual(titles(r), [typed], "닫아도 또 붙지 않는다")
        XCTAssertEqual(r.store.ddayLibrary.map(\.title), [typed])
    }

    /// 조합하지 않을 때 [붙이기] (대조: 단추를 누르는 틀이 맞는지, 그리고 조합을 마치는 일이 보통 [붙이기]를 바꾸지 않는지)
    func testAttachButtonAttaches() async throws {
        let r = await rig()
        let pop = try await open(r)
        try await type(typed, in: pop)
        try pressAttach(pop)
        await spin(0.3)
        XCTAssertEqual(titles(r), [typed])
        let tf = try field(pop)
        XCTAssertEqual(tf.stringValue, "")
        XCTAssertTrue((tf.window?.firstResponder as? NSTextView)?.delegate === tf, "[붙이기] 뒤에도 이름 칸은 쓰는 중")
        await clickOutside(r, pop)
        XCTAssertEqual(titles(r), [typed])
    }

    /// 조합 중이어도 Esc 는 취소: 아무것도 붙지 않는다
    func testEscapeWhileComposingDiscards() async throws {
        let r = await rig()
        let pop = try await open(r)
        _ = try await compose("시험공", marked: "부", in: pop)
        try await escape(pop)
        if !closed(pop) { pop.performClose(nil) }
        await spin(0.2)
        XCTAssertTrue(titles(r).isEmpty, "Esc 는 조합 중이어도 취소")
        XCTAssertTrue(r.store.ddayLibrary.isEmpty)
    }

    // MARK: 팝오버가 아닌 곳 (iPhone 시트처럼 편집기가 사라질 때)

    /// 편집기가 화면에서 사라지면(시트의 [완료] · 아래로 쓸기) 적은 것이 붙는다
    func testEditorGoingAwayAttaches() async throws {
        let store = PlannerStore(inMemory: true)
        let day = Dates.day(Date())
        let win = DDayKeyWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 640), styleMask: [.borderless],
                                backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = DDayFirstMouseHost(rootView: AnyView(DDayEditor(date: day).environmentObject(store)))
        win.orderFrontRegardless()
        win.makeKey()
        windows.append(win)
        await spin(0.3)
        func find(_ v: NSView) -> NSTextField? {
            if let t = v as? NSTextField, t.isEditable, t.placeholderString == placeholder { return t }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        let tf = try XCTUnwrap(find(try XCTUnwrap(win.contentView)))
        win.makeFirstResponder(tf)
        await spin(0.1)
        (win.firstResponder as? NSTextView)?.insertText(typed, replacementRange: NSRange(location: NSNotFound, length: 0))
        await spin(0.2)
        XCTAssertTrue(store.ddays(day).isEmpty)
        win.contentView = nil
        await spin(0.4)
        XCTAssertEqual(store.ddays(day).map(\.title), [typed], "편집기가 사라지면 적은 D-day 가 붙어야 한다")
    }
}

/// 뜨기 시작한 팝오버 · 닫기 시작한 팝오버 (알림은 메인 스레드에서 바로 온다).
/// 뜰 때는 didShow 가 아니라 willShow 를 듣는다: 화면이 잠겼거나 꺼져 있으면 여는 애니메이션이 끝나지 않아 didShow 가
/// 오지 않는다 (팝오버 창은 떠 있는데) — 그런 컴퓨터에서 시험이 모두 열기에서 멈추지 않게 (회의적 검토 2026-10-10)
private final class PopoverLog: NSObject {
    private(set) var shown: [NSPopover] = []
    private(set) var closing: [ObjectIdentifier] = []

    func start() {
        shown = []
        closing = []
        NotificationCenter.default.addObserver(self, selector: #selector(willShow(_:)), name: NSPopover.willShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willClose(_:)), name: NSPopover.willCloseNotification, object: nil)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        for p in shown where p.isShown { p.close() }
        shown = []
        closing = []
    }

    @objc private func willShow(_ n: Notification) { if let p = n.object as? NSPopover { shown.append(p) } }
    @objc private func willClose(_ n: Notification) { if let p = n.object as? NSPopover { closing.append(ObjectIdentifier(p)) } }
}

private final class DDayKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

private final class DDayFirstMouseHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
#endif
