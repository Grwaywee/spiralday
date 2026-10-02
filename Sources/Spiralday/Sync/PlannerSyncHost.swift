import Foundation
import SpiraldayKit
import SpiraldaySync

// ─────────────────────────────────────────────────────────────────────────────
// PlannerStore ↔ 동기화 엔진 (Docs/SpiraldaySync.md §4 그대로 — SpiraldayKit 의 ExternalChanges API 로).
// 값은 앱 파일과 같은 JSON (PlannerStore.encodeFile · decodeFile). 모두 MainActor 의 한 차례 안에서 읽고 바로 넣는다
// (transform 을 부른 뒤 사용자의 편집이 끼어들지 않게).
//
// 규칙
//   · 읽지 못한 책은 transform 을 부르기 "전에" 돌아간다 (엔진은 다음에 다시 넣는다)
//   · transform 을 부른 "뒤에" 넣지 못하면 반드시 던진다 — 던지지 않으면 엔진은 넣은 것으로 적고, 다음 비교에서
//     옛 값을 새 편집으로 올려 다른 기기의 편집을 되돌린다
//   · 쓰고 있는 칸(AppState.editingKey)은 SpiraldayKit 이 화면의 글을 지킨다. 그 칸의 글이 다른 기기의 글로 바뀌었으면
//     (쓰지 않고 포커스만 있던 칸) onEditedFieldReplaced 로 알린다 → 앱이 그 칸의 되돌리기(⌘Z) 기록을 비운다
//     (되돌리기가 다른 기기의 글을 지우고 옛 글로 돌아가지 않게)
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class PlannerSyncHost: SyncHost {
    let store: PlannerStore
    /// 지금 쓰고 있는 칸 (AppState.editingKey)
    var editingKey: () -> String? = { nil }
    /// 쓰던 할 일 · 메모가 다른 기기에서 지워졌다 → 편집을 끝낸다 (state.endEditing())
    var onEditedItemRemoved: () -> Void = {}
    /// 쓰고 있던 칸(포커스)의 글이 다른 기기의 글로 바뀌었다 (그 칸의 새 글) → 그 칸의 되돌리기 기록을 비운다
    var onEditedFieldReplaced: (_ text: String?) -> Void = { _ in }
    /// 책장을 넣었다 (펼친 책이 빠져 다른 책을 폈는지, 빠진 책들) — 화면이 안내 · 장 맞추기에 쓴다
    var onLibraryApplied: (ExternalApplyResult, _ removed: [BookInfo]) -> Void = { _, _ in }
    /// 펼친 책의 내용을 넣었다
    var onActiveApplied: (ExternalApplyResult) -> Void = { _ in }

    init(store: PlannerStore) { self.store = store }

    func libraryRecreated() async -> Bool { store.libraryCreated }

    func readLibrary() async -> JSONValue? {
        // 책장을 읽지 못한 실행에서는 nil → 엔진은 비교하지 않는다 (지운 것으로 오해하지 않게)
        if store.libraryUnreadable { return nil }
        return try? JSONValue.parse(PlannerStore.encodeFile(store.library))
    }

    func readBook(id: String) async -> BookRead {
        guard let uuid = UUID(uuidString: id) else { return .unreadable }
        if uuid == store.library.activeID, store.unreadableBooks[uuid] == nil {
            // 펼친 책 (저장할 때마다 비교): 지금 내용(저장 전 편집 포함)을 MainActor 에서 값으로만 잡고, 앱 형식 JSON 으로 쓰고
            // 다시 읽는 일은 메인 밖에서 — 몇 년 치 책이어도 타이핑 · 넘김 중에 프레임이 끊기지 않게. 비교에만 쓰는 값이다
            // (넣기 updateBook 은 MainActor 한 차례 안에서 그대로)
            let data = store.data
            return await Task.detached(priority: .utility) { Self.appJSON(data) }.value
        }
        switch store.readBookRaw(uuid) {
        case .missing: return .missing
        case .unreadable: return .unreadable
        case .data(let raw): return (try? JSONValue.parse(raw)).map { .ok($0) } ?? .unreadable   // 모르는 키도 그대로
        }
    }

    func updateBook(id: String, _ transform: @Sendable (JSONValue?) -> JSONValue?) async throws {
        guard let uuid = UUID(uuidString: id) else { return }
        let cur: JSONValue?
        switch store.readBookRaw(uuid) {
        case .unreadable: return                                // 읽지 못한 파일: transform 을 부르지 않고 그대로
        case .missing: cur = nil
        case .data(let raw):
            guard let v = try? JSONValue.parse(raw) else { return }
            cur = v
        }
        let next = transform(cur)
        // 여기부터 넣지 못하면 던진다
        if uuid == store.library.activeID {
            guard let next else { return }                      // 펼친 책은 이렇게 지우지 않는다 (엔진은 책장에서 먼저 뺀다)
            let merged = try PlannerStore.decodeFile(PlannerData.self, from: next.jsonData())
            let key = editingKey()
            let before = key.flatMap { PlannerData.editedText($0, in: store.data) }
            let r = store.applyActiveData(merged, keepingEditOf: key)
            if r.editedItemRemoved {
                onEditedItemRemoved()
            } else if let key, r.changed, before != nil, case let after = PlannerData.editedText(key, in: store.data), after != before {
                onEditedFieldReplaced(after)
            }
            if r.changed { onActiveApplied(r) }
        } else if let next {
            // 앱 모델로 읽고 다시 써서 Mac 의 JSONEncoder 와 같은 바이트로 (모든 기기의 책 파일이 같은 바이트).
            // writeBookRaw 는 앱이 읽을 수 있는지 다시 보고 원자적으로 쓴다
            try store.writeBookRaw(uuid, PlannerStore.encodeFile(try PlannerStore.decodeFile(PlannerData.self, from: next.jsonData())))
        } else if cur != nil {
            try store.removeBookFile(uuid)                      // 책장에서 이미 빠진 책
        }
    }

    /// 앱 파일과 같은 JSON (PlannerStore.encodeFile 과 같은 .iso8601 · .sortedKeys) → 엔진의 값. MainActor 밖에서도
    nonisolated static func appJSON(_ data: PlannerData) -> BookRead {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        guard let raw = try? e.encode(data), let v = try? JSONValue.parse(raw) else { return .unreadable }
        return .ok(v)
    }

    func updateLibrary(_ transform: @Sendable (JSONValue) -> JSONValue) async throws {
        guard !store.libraryUnreadable else { return }
        let cur = try JSONValue.parse(PlannerStore.encodeFile(store.library))
        let before = store.library.books
        let next = try PlannerStore.decodeFile(Library.self, from: transform(cur).jsonData())
        let r = store.applyLibrary(next)
        guard r.changed else { return }
        let kept = Set(store.library.books.map(\.id))
        let removed = before.filter { !kept.contains($0.id) }
        onLibraryApplied(r, removed)
    }
}
