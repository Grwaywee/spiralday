#if os(macOS)
import XCTest
import AppKit
import SwiftUI
@testable import SpiraldayKit

/// COMMENT 편집기 글이 그 글상자의 보이는 자리(tv.visibleRect) 안에 다 있는지 — 첫 줄 위 · 마지막 줄(Return 을 막 친 빈 줄 포함) 아래 —
/// 그리고 COMMENT 상자보다 높지 않은지. TextKit 2 면 layoutManager 를 꺼내지 않는다 (꺼내면 그것만으로 TextKit 1 로 바뀐다)
@MainActor
func assertCommentLinesVisible(_ tv: NSTextView, u: CGFloat, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    let used: CGRect
    if let tlm = tv.textLayoutManager {
        tlm.ensureLayout(for: tlm.documentRange)
        used = tlm.usageBoundsForTextContainer
    } else if let lm = tv.layoutManager, let tc = tv.textContainer {
        lm.ensureLayout(for: tc)
        used = lm.usedRect(for: tc)
    } else {
        return XCTFail("글 배치가 없다", file: file, line: line)
    }
    let o = tv.textContainerOrigin
    let text = used.offsetBy(dx: o.x, dy: o.y)
    let vis = tv.visibleRect
    XCTAssertGreaterThanOrEqual(text.minY, vis.minY - 0.5, "\(what): 첫 줄 윗부분이 가려진다 (글 \(text) · 보이는 자리 \(vis))",
                                file: file, line: line)
    XCTAssertLessThanOrEqual(text.maxY, vis.maxY + 0.5, "\(what): 마지막 줄이 가려진다 (글 \(text) · 보이는 자리 \(vis))", file: file, line: line)
    XCTAssertLessThanOrEqual(text.height, DailyForm.commentTextRect.height * u + 0.5, "\(what): 글이 COMMENT 상자보다 높다",
                             file: file, line: line)
}

/// 회의적 검토 (2026-10-08): "COMMENT 를 두 줄 이상 쓰는 동안 편집 칸이 첫 줄을 가린다 — 두 줄이면 '첫째' 가 '섯째' 처럼, 다섯 줄이면 첫 줄이 통째로".
/// 앱의 보통 길(TextKit 2 필드 편집기)에서는 일어나지 않는다 (CommentReturnTests.testEditorShowsEveryLineWhileWriting). 그 그림은 필드 편집기가
/// TextKit 1 로 바뀐 뒤의 모습이다: 새 NSLayoutManager 는 손글씨 글꼴의 줄 사이(글자 크기의 1/4)를 넣어 줄이 1.25 배로 벌어지는데
/// SwiftUI 는 줄 사이 없이 칸 높이를 잡아서, 편집기가 커서 쪽으로 스크롤되며 첫 줄이 가려진다. 누군가 필드 편집기의 layoutManager 를
/// 꺼내기만 해도 바뀌고, SwiftUI 글 칸은 앱의 모든 창이 필드 편집기 하나를 같이 써서 앱을 끌 때까지 그대로다.
/// 고침: COMMENT 를 쓰는 동안 그 필드 편집기가 줄 사이를 넣으면 TextKit 2 때와 같게 뺀다 (Components.swift matchSwiftUILineHeight).
///
/// 이 시험은 같이 쓰는 필드 편집기를 TextKit 1 로 바꾸고 되돌릴 수 없어서, 화면을 쓰는 다른 시험이 모두 끝난 뒤 돌게 이름을 붙였다
/// (XCTest 는 클래스 이름 순서로 돈다 — TaskCategoryCellTests 다음, 화면을 쓰지 않는 VectorsTests 앞).
@MainActor
final class TextKit1FallbackTests: XCTestCase {
    private static let repoFonts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Fonts")
    private var windows: [NSWindow] = []
    private let today = Dates.day(Date())
    private var commentKey: String { "c|\(Dates.key(today))" }

    override func setUp() async throws {
        Fonts.extraFontDirectories = [Self.repoFonts]
        Fonts.register()
    }

    override func tearDown() async throws {
        for w in windows { w.orderOut(nil) }
        windows = []
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private func until(_ what: String, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if cond() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("기다림: \(what)")
        throw CancellationError()
    }

    private func rig(u: CGFloat, text: String = "") async throws -> (PlannerStore, NSWindow, NSTextView) {
        _ = NSApplication.shared
        let store = PlannerStore(inMemory: true)
        if !text.isEmpty { store.dayField(today, \.comment).wrappedValue = text }
        let state = AppState(kind: .daily)
        state.store = store
        let size = CGSize(width: PageKind.daily.design.width * u, height: PageKind.daily.design.height * u)
        let w = KeyWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: DailyPage(date: today, u: u).environmentObject(store).environmentObject(state))
        w.orderFrontRegardless()
        w.makeKey()
        windows.append(w)
        state.plannerWindow = w
        state.editingKey = commentKey
        try await until("글 칸에 포커스") { w.firstResponder is NSTextView }
        return (store, w, w.firstResponder as! NSTextView)
    }

    private func settle(_ tv: NSTextView) async throws {
        try await Task.sleep(nanoseconds: 80_000_000)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        try await Task.sleep(nanoseconds: 80_000_000)
    }

    func testEditorShowsEveryLineAfterTextKit1Fallback() async throws {
        // 1) 쓰는 중에 TextKit 1 로 바뀔 때 (바뀌었다는 알림으로 고친다). 앱(시험 프로세스)에서 처음 바뀔 때만 볼 수 있다
        let shared: NSTextView
        do {
            let five = "첫째\n둘째\n셋째\n넷째\n다섯째"
            let (_, w, tv) = try await rig(u: 0.5, text: five)
            shared = tv
            if tv.textLayoutManager != nil {
                _ = tv.layoutManager
                XCTAssertNil(tv.textLayoutManager, "TextKit 1 로 바뀌었다")
                XCTAssertEqual(tv.layoutManager?.usesFontLeading, false, "바뀌자마자 줄 사이를 뺀다")
                try await settle(tv)
                assertCommentLinesVisible(tv, u: 0.5, "쓰는 중 TextKit 1 로 · 다섯 줄")
            }
            w.orderOut(nil)
        }
        // 2) 이미 TextKit 1 인 필드 편집기(새 NSLayoutManager 처럼 줄 사이를 넣는)로 쓰기 시작할 때 — 포커스를 받을 때 고친다.
        //    SwiftUI 글 칸은 창마다 같은 필드 편집기를 쓴다
        for u in [CGFloat(0.3), 0.5, 0.8] {
            for t in CommentReturnTests.lineSamples {
                let lm = try XCTUnwrap(shared.layoutManager)
                lm.usesFontLeading = true
                let (_, w, tv) = try await rig(u: u, text: t)
                XCTAssertTrue(tv === shared, "SwiftUI 글 칸은 필드 편집기 하나를 같이 쓴다")
                XCTAssertNil(tv.textLayoutManager)
                XCTAssertEqual(lm.usesFontLeading, false, "u \(u) \(t.debugDescription): 쓰기 시작하면 줄 사이를 뺀다")
                try await settle(tv)
                assertCommentLinesVisible(tv, u: u, "TextKit 1 · u \(u) \(t.debugDescription)")
                w.orderOut(nil)
            }
        }
        // 3) TextKit 1 인 채로 Return 으로 줄을 더해도 (앱이 키를 받는 길)
        let (store, w, tv) = try await rig(u: 0.5)
        for (i, word) in ["첫째", "둘째", "셋째", "넷째", "다섯째"].enumerated() {
            tv.insertText(word, replacementRange: NSRange(location: NSNotFound, length: 0))
            if i < 4 {
                NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                 context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                 isARepeat: false, keyCode: 36)!)
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            assertCommentLinesVisible(tv, u: 0.5, "TextKit 1 · Return 으로 \(i + 1)줄")
        }
        XCTAssertEqual(store.day(today).comment, "첫째\n둘째\n셋째\n넷째\n다섯째")
    }

}
#endif
