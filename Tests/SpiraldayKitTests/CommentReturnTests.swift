import XCTest
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import SpiraldayKit

/// 사장님 신고 (2026-10-08): "코멘트 부분에서 엔터를 쳐서 줄바꿈이 안 된다".
/// Mac 의 필드 편집기는 Return(insertNewline:)에 쓰기를 마쳐서 COMMENT 에 줄을 넣을 길이 ⌥↩ 밖에 없었다 (iPhone 은 Return = 줄 바꿈).
/// 규칙은 Kit MultilineReturn · DailyForm.commentFits 의 순수 함수이고, 값은 Windows · Android web 과 같은 공유 벡터
/// Tests/Fixtures/comment-return.json 이다. Mac 에서는 진짜 DailyPage 를 화면 밖 창에 띄워 키를 앱이 받는 길(NSApp.sendEvent)로 보낸다.
@MainActor
final class CommentReturnTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    private static let repoFonts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Fonts")

    override func setUp() async throws {
        Fonts.extraFontDirectories = [Self.repoFonts]
        Fonts.register()
    }

    private func load() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("comment-return.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: 공유 벡터 (Windows · Android web 과 같은 파일)

    func testBoxMatchesSharedVectors() throws {
        let f = try load()
        XCTAssertEqual(f["version"] as? Int, 1)
        let box = try XCTUnwrap(f["box"] as? [String: Any])
        func num(_ k: String) -> CGFloat { CGFloat((box[k] as? NSNumber)?.doubleValue ?? -1) }
        XCTAssertEqual(num("font"), DailyForm.commentFont)
        XCTAssertEqual(num("minScale"), DailyForm.commentMinScale)
        XCTAssertEqual(num("wrapWidth"), DailyForm.commentWrapWidth, accuracy: 0.001)
        XCTAssertEqual(num("fitHeight"), DailyForm.commentFitHeight, accuracy: 0.001)
        XCTAssertEqual(box["maxLines"] as? Int, DailyForm.commentMaxLines)
        XCTAssertEqual(DailyForm.commentMaxLines, 5, "가장 작은 글씨(20)의 줄 높이 22.5 × 5 = 112.5 ≤ 115.35")
    }

    func testKeyVectors() throws {
        let rows = try XCTUnwrap(load()["keys"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(rows.count, 8)
        for r in rows {
            var mods: MultilineReturn.Modifiers = []
            for m in try XCTUnwrap(r["mods"] as? [String]) {
                switch m {
                case "shift": mods.insert(.shift)
                case "alt": mods.insert(.option)
                case "ctrl": mods.insert(.control)
                case "meta": mods.insert(.command)
                default: XCTFail("모르는 수식키 \(m)")
                }
            }
            let fits = try XCTUnwrap(r["fits"] as? Bool)
            let expect = try XCTUnwrap(MultilineReturn.Action(rawValue: XCTUnwrap(r["expect"] as? String)))
            XCTAssertEqual(MultilineReturn.action(mods) { fits }, expect, "\(r["name"] ?? r)")
        }
    }

    func testCapacityVectors() throws {
        let rows = try XCTUnwrap(load()["capacity"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(rows.count, 8)
        for r in rows {
            let text = try XCTUnwrap(r["text"] as? String)
            let sel = try XCTUnwrap(r["selection"] as? [Int])
            let after = MultilineReturn.inserting(into: text, selection: NSRange(location: sel[0], length: sel[1]))
            XCTAssertEqual(after, r["after"] as? String, "\(r["name"] ?? r)")
            XCTAssertEqual(DailyForm.commentFits(after), r["fits"] as? Bool, "\(r["name"] ?? r): \(after.debugDescription)")
        }
    }

    func testNewlineInsertionVectors() throws {
        let rows = try XCTUnwrap(load()["insertion"] as? [[String: Any]])
        for r in rows {
            XCTAssertEqual(MultilineReturn.isNewlineInsertion(from: try XCTUnwrap(r["old"] as? String), to: try XCTUnwrap(r["new"] as? String)),
                           r["isNewline"] as? Bool, "\(r["name"] ?? r)")
        }
    }

    /// 끝의 줄 바꿈 뒤 빈 줄(Return 을 막 친 줄)도 센다 — 그래야 커서가 있는 줄까지 상자 안에 보이게 글씨를 줄인다
    func testTrailingNewlineCountsAsALine() {
        let w = DailyForm.commentWrapWidth
        XCTAssertEqual(RuledText.wrap("가\n", fontSize: 20, width: w), ["가"])
        XCTAssertEqual(RuledText.lineCount("가\n", fontSize: 20, width: w), 2)
        XCTAssertEqual(RuledText.lineCount("\n", fontSize: 20, width: w), 2)
        XCTAssertEqual(RuledText.lineCount("가\n\n", fontSize: 20, width: w), 3)
        XCTAssertEqual(RuledText.lineCount("", fontSize: 20, width: w), 1)
        XCTAssertEqual(RuledText.lineCount("가\n나", fontSize: 20, width: w), 2)
        // 넷째 줄을 막 시작한 글은 세 줄짜리보다 작은 글씨
        XCTAssertLessThan(DailyForm.commentScale("가\n나\n다\n"), DailyForm.commentScale("가\n나\n다"))
        // 다섯 줄은 가장 작은 글씨로 상자에 들어간다 (넘치는 예전 글도 그 글씨로, 다섯 줄까지만 보인다)
        XCTAssertEqual(DailyForm.commentScale("가\n나\n다\n라\n마"), DailyForm.commentMinScale)
        let lh = RuledText.lineHeight(fontSize: DailyForm.commentFont * DailyForm.commentMinScale)
        XCTAssertLessThanOrEqual(CGFloat(DailyForm.commentMaxLines) * lh, DailyForm.commentFitHeight)
        XCTAssertGreaterThan(CGFloat(DailyForm.commentMaxLines + 1) * lh, DailyForm.commentFitHeight)
    }

    #if os(macOS)
    // MARK: Mac — 진짜 DailyPage 에서

    private var windows: [NSWindow] = []
    private let today = Dates.day(Date())
    private var commentKey: String { "c|\(Dates.key(today))" }
    private var refused = 0

    override func tearDown() async throws {
        for w in windows { w.orderOut(nil) }
        windows = []
        ReturnNewlineMonitorView.refuseFeedback = { NSSound.beep() }
    }

    private func until(_ what: String, timeout: Double = 5, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("기다림: \(what)")
        throw CancellationError()
    }

    /// editing: 처음에 쓸 칸의 키를 정한다 (기본: 오늘의 COMMENT)
    private func rig(editing: ((PlannerStore) -> String)? = nil) async throws -> (PlannerStore, AppState, NSWindow, NSTextView) {
        _ = NSApplication.shared
        refused = 0
        ReturnNewlineMonitorView.refuseFeedback = { [weak self] in self?.refused += 1 }
        let store = PlannerStore(inMemory: true)
        let state = AppState(kind: .daily)
        state.store = store
        let u: CGFloat = 0.5
        let size = CGSize(width: PageKind.daily.design.width * u, height: PageKind.daily.design.height * u)
        let w = KeyWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: DailyPage(date: today, u: u).environmentObject(store).environmentObject(state))
        w.orderFrontRegardless()
        w.makeKey()
        windows.append(w)
        state.plannerWindow = w
        state.editingKey = editing?(store) ?? commentKey
        try await until("글 칸에 포커스") { w.firstResponder is NSTextView }
        return (store, state, w, w.firstResponder as! NSTextView)
    }

    private func keyEvent(_ w: NSWindow, code: UInt16, chars: String, mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    /// 앱이 키를 받는 길 (NSApp.sendEvent → 로컬 감시 → 창)
    private func appKey(_ w: NSWindow, code: UInt16 = 36, chars: String = "\r", mods: NSEvent.ModifierFlags = []) async throws {
        NSApp.sendEvent(keyEvent(w, code: code, chars: chars, mods: mods))
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private func type(_ tv: NSTextView, _ s: String) async throws {
        tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(nanoseconds: 60_000_000)
    }

    func testReturnBreaksTheLineAtTheCaretAndKeepsWriting() async throws {
        let (store, state, w, tv) = try await rig()
        try await type(tv, "오늘은맑음")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        try await appKey(w)
        XCTAssertEqual(store.day(today).comment, "오늘은\n맑음", "Return 은 커서 자리에 줄을 바꾼다 (iPhone 과 같게)")
        XCTAssertEqual(state.editingKey, commentKey, "Return 으로 쓰기가 끝나면 안 된다")
        XCTAssertTrue(w.firstResponder === tv)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 4, length: 0), "커서는 새 줄의 맨 앞")
        // 이어서 치는 글은 새 줄에
        try await type(tv, "!")
        XCTAssertEqual(store.day(today).comment, "오늘은\n!맑음")
        // ⌘Z 로 되돌릴 수 있다
        XCTAssertTrue(tv.undoManager?.canUndo ?? false)
    }

    func testSelectionShiftReturnKeypadEnterAndOptionReturn() async throws {
        let (store, state, w, tv) = try await rig()
        try await type(tv, "가나다")
        // 선택한 글은 줄 바꿈으로 바뀐다 (숫자패드 Enter)
        tv.setSelectedRange(NSRange(location: 1, length: 1))
        try await appKey(w, code: 76, chars: "\u{3}")
        XCTAssertEqual(store.day(today).comment, "가\n다")
        // ⇧↩ · ⌥↩ 도 줄 바꿈 (⌥↩ 은 1.1.0 까지 Mac 에서 줄을 바꾸던 숨은 길 — 그대로 된다)
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        try await appKey(w, mods: [.shift])
        XCTAssertEqual(store.day(today).comment, "가\n다\n")
        try await appKey(w, mods: [.option])
        XCTAssertEqual(store.day(today).comment, "가\n다\n\n")
        XCTAssertEqual(state.editingKey, commentKey)
        XCTAssertEqual(refused, 0)
    }

    func testCommandReturnAndEscEndWriting() async throws {
        let (store, state, w, tv) = try await rig()
        try await type(tv, "끝")
        try await appKey(w, mods: [.command])
        XCTAssertNil(state.editingKey, "⌘↩ 은 쓰기를 마친다")
        XCTAssertEqual(store.day(today).comment, "끝", "⌘↩ 은 줄을 넣지 않는다")
        // ⌃↩ 도 마친다 (Windows 의 Ctrl+Enter 와 같게)
        let (store2, state2, w2, tv2) = try await rig()
        try await type(tv2, "끝2")
        try await appKey(w2, mods: [.control])
        XCTAssertNil(state2.editingKey)
        XCTAssertEqual(store2.day(today).comment, "끝2")
        // Esc 는 예전 그대로 쓰기를 마친다 (플래너의 키 감시)
        let (_, state3, w3, _) = try await rig()
        XCTAssertTrue(state3.handleKey(window: .planner, responder: AppState.inputResponder(w3), keyCode: 53,
                                       characters: "\u{1b}", modifiers: []))
        XCTAssertNil(state3.editingKey)
    }

    /// 한글 조합 중 Return: 조합하던 글자가 한 번만 남고 줄이 바뀐다 ('오늘한한' · '오늘\n' 이 아니게). 다음 글자는 새 줄에
    func testReturnWhileComposingCommitsOnceThenBreaks() async throws {
        let (store, state, w, tv) = try await rig()
        try await type(tv, "오늘")
        tv.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(tv.hasMarkedText())
        try await appKey(w)
        XCTAssertFalse(tv.hasMarkedText(), "조합이 끝났다")
        XCTAssertEqual(tv.string, "오늘한\n")
        XCTAssertEqual(store.day(today).comment, "오늘한\n")
        XCTAssertEqual(state.editingKey, commentKey)
        tv.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.insertText("가", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.day(today).comment, "오늘한\n가")
    }

    /// 다섯 줄이 찬 뒤의 Return 은 받지 않는다 (삑). 글을 더 치는 것은 그대로 받는다
    func testReturnThatWouldOverflowTheBoxIsRefused() async throws {
        let (store, state, w, tv) = try await rig()
        try await type(tv, "가")
        for _ in 0..<4 { try await appKey(w) }
        XCTAssertEqual(store.day(today).comment, "가\n\n\n\n", "다섯 줄까지는 줄을 바꾼다")
        XCTAssertEqual(refused, 0)
        try await appKey(w)
        try await appKey(w, mods: [.option])
        XCTAssertEqual(store.day(today).comment, "가\n\n\n\n", "여섯째 줄을 만드는 Return 은 받지 않는다")
        XCTAssertEqual(refused, 2)
        XCTAssertEqual(state.editingKey, commentKey, "받지 않아도 계속 쓴다")
        try await type(tv, "나")
        XCTAssertEqual(store.day(today).comment, "가\n\n\n\n나")
        // 중간의 빈 줄을 지우면 다시 받는다
        tv.setSelectedRange(NSRange(location: 2, length: 1))
        tv.deleteBackward(nil)
        try await Task.sleep(nanoseconds: 60_000_000)
        try await appKey(w)
        XCTAssertEqual(store.day(today).comment.components(separatedBy: "\n").count, 5)
        XCTAssertEqual(refused, 2)
    }

    /// 다른 창의 글 칸에서 친 Return 은 그 창 몫 (COMMENT 를 쓰는 중이어도)
    func testOtherWindowsReturnIsLeftAlone() async throws {
        let (store, state, _, _) = try await rig()
        let other = KeyWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 80), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        let field = NSTextField(string: "설정 이름")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 30)
        other.contentView?.addSubview(field)
        other.orderFrontRegardless()
        windows.append(other)
        other.makeKey()
        other.makeFirstResponder(field)
        let otherEditor = try XCTUnwrap(other.firstResponder as? NSTextView)
        try await appKey(other)
        XCTAssertFalse(otherEditor.string.contains("\n"), "다른 창의 칸에는 줄 바꿈을 넣지 않는다")
        XCTAssertEqual(store.day(today).comment, "", "다른 창의 Return 이 COMMENT 로 가지 않는다")
        XCTAssertEqual(state.editingKey, commentKey)
    }

    /// 할 일 · MEMO 는 바꾸지 않는다: Return = 아랫줄로 (1.0.5)
    func testTaskReturnStillMovesToTheNextRow() async throws {
        var task = UUID()
        let (store, state, w, tv) = try await rig { [today] store in
            task = store.addTask(today, row: 0)
            return AppState.taskKey(today, task)
        }
        try await type(tv, "운동")
        XCTAssertEqual(store.day(today).tasks.first { $0.id == task }?.text, "운동")
        w.sendEvent(keyEvent(w, code: 36, chars: "\r"))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.day(today).tasks.first { $0.id == task }?.text, "운동", "할 일에는 줄 바꿈이 들어가지 않는다")
        let next = try XCTUnwrap(state.editingTaskID(on: today), "Return: 아랫줄의 새 할 일을 쓴다")
        XCTAssertNotEqual(next, task)
        XCTAssertEqual(store.day(today).comment, "")
    }
    #endif
}

#if os(macOS)
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
#endif
