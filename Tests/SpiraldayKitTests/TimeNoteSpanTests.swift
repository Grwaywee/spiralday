import XCTest
@testable import SpiraldayKit

/// 지우개 · 같은 색으로 다시 칠해 지우기 (1.1.1 부터 같은 펜 한 번 클릭도) 가 타는 removeNotes 는 메모를 `start...end` 로 읽어서,
/// 시작 · 끝이 거꾸로 든 메모(start > end)가 하나라도 있으면 범위를 만들다 앱이 멈췄다 (회의적 검토 2026-10-10).
/// 지금 메모를 만드는 곳(Mac · iOS · web)은 모두 순서를 맞추지만, 그리는 쪽(drawMeal · mealHandle)처럼 순서와 상관없이 읽는다.
final class TimeNoteSpanTests: XCTestCase {
    private let day = Dates.day(Date())

    func testSpanIgnoresTheOrderOfStartAndEnd() {
        XCTAssertEqual(TimeNote(kind: .meal, start: 64, end: 69).span, 64...69)
        XCTAssertEqual(TimeNote(kind: .meal, start: 69, end: 64).span, 64...69)
        XCTAssertEqual(TimeNote(kind: .text, start: 7, end: 7).span, 7...7)
    }

    @MainActor
    func testRemoveNotesReadsAReversedNoteWithoutStopping() {
        let store = PlannerStore(inMemory: true)
        let reversed = store.addNote(day, TimeNote(kind: .meal, start: 69, end: 64))
        let away = store.addNote(day, TimeNote(kind: .text, start: 10, end: 12, text: "아침"))
        // 겹치지 않는 범위: 아무것도 지우지 않는다 (거꾸로 든 메모를 읽다 멈추지 않는다)
        store.removeNotes(day, overlapping: 30...31)
        XCTAssertEqual(Set(store.day(day).notes.map(\.id)), [reversed, away])
        // 거꾸로 든 메모의 가운데 칸 (66 은 64…69 안)
        store.removeNotes(day, overlapping: 66...66)
        XCTAssertEqual(store.day(day).notes.map(\.id), [away], "거꾸로 든 밥시간도 덮는 칸과 겹치면 지운다")
    }
}
