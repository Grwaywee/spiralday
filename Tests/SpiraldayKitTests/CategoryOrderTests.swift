import XCTest
@testable import SpiraldayKit

/// 형광펜 순서 (사장님 신고 2026-10-08: 설정 › 형광펜 에서 순서를 바꿀 수 없었다 — 고침은 Mac 설정 칸, 시험 SpiraldayAppTests.PenReorderTests).
/// 순서를 바꾸는 길은 모두 PlannerStore.moveCategories 로 간다 (Mac 끌어 놓기 · 오른쪽 클릭 · 손쉬운 사용, iOS 편집 손잡이).
/// 여기서는 그 저장소 쪽: 위 · 아래 · 처음 · 끝 · 제자리, 펼친 책의 설정에 저장, 그리고 숫자 키 1–7 이 새 순서를 따르는지.
@MainActor
final class CategoryOrderTests: XCTestCase {
    func testMoveCategoriesUpDownFirstLastAndInPlace() {
        let store = PlannerStore(inMemory: true)
        let a = store.categories.map(\.id)
        XCTAssertEqual(a.count, 7)
        // 첫 펜을 세 번째 아래로 (SwiftUI onMove 의 목적지는 원래 배열 기준)
        store.moveCategories(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(store.categories.map(\.id), [a[1], a[2], a[0]] + a[3...])
        // 되돌리기 (셋째 → 맨 위)
        store.moveCategories(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.categories.map(\.id), a)
        // 맨 아래 → 맨 위, 맨 위 → 맨 아래
        store.moveCategories(from: IndexSet(integer: 6), to: 0)
        XCTAssertEqual(store.categories.map(\.id), [a[6]] + a[0..<6])
        store.moveCategories(from: IndexSet(integer: 0), to: 7)
        XCTAssertEqual(store.categories.map(\.id), a)
        // 제자리 (자기 자리 · 바로 아래 자리)
        store.moveCategories(from: IndexSet(integer: 3), to: 3)
        store.moveCategories(from: IndexSet(integer: 3), to: 4)
        XCTAssertEqual(store.categories.map(\.id), a)
        // 펼친 책의 설정(prefs.categories)에 그대로
        store.moveCategories(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(store.data.prefs.categories.map(\.id), [a[1], a[0]] + a[2...])
    }

    #if os(macOS)
    func testDigitKeysFollowTheNewOrder() {
        let store = PlannerStore(inMemory: true)
        let state = AppState(kind: .daily)
        state.store = store
        let a = store.categories.map(\.id)
        let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26]
        func pick(_ n: Int) -> Int {
            XCTAssertTrue(state.handleKey(window: .planner, responder: .none, keyCode: codes[n - 1], characters: "\(n)", modifiers: []))
            return state.tool
        }
        XCTAssertEqual(pick(1), a[0])
        store.moveCategories(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(pick(1), a[1])
        XCTAssertEqual(pick(2), a[2])
        XCTAssertEqual(pick(3), a[0])
        XCTAssertEqual(pick(7), a[6])
        // 글을 쓰는 중에는 숫자 키는 글 칸으로 (도구를 바꾸지 않는다)
        let before = state.tool
        XCTAssertFalse(state.handleKey(window: .planner, responder: .text, keyCode: 18, characters: "1", modifiers: []))
        XCTAssertEqual(state.tool, before)
    }
    #endif
}
