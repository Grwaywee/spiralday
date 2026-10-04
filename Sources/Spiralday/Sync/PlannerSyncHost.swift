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
//   · 파일 없이 연 책 (PlannerStore.booksOpenedWithoutFile — 앱이 꺼진 동안 파일을 잃어 빈 책으로 폄)은 엔진이 받아들일 때까지
//     (missingNoted · updateBook) readBook 에 .missing — 빈 책을 이 기기의 편집으로 비교해 다른 기기의 할 일 · COMMENT · 형광펜을
//     지우지 않게. 엔진은 동기화된 내용으로 되살린다 (2026-10-04 형광펜 사고 조사)
//   · 설정 창의 동기화되는 글 칸(형광펜 이름 · 저장한 D-day 제목 — 칠 때마다 저장소에 쓴다)은 쓰는 칸 지키기 밖이다.
//     그 값이 다른 기기의 값으로 바뀌었으면 onSettingsTextReplaced 로 새 값들을 알린다 → 앱이 그 칸의 ⌘Z 기록을 비운다
//   · 쓰는 칸 지키기는 엔진이 정한다 (engine.editingProtected — 마지막 입력부터 5초). 호스트의 안전망(keepingEditOf)은 엔진이
//     지키는 동안만 — 엔진보다 더 지키면 옛 글이 새 도장을 얻어 더 새 글을 덮는다
//
// 실시간 (Docs/SpiraldaySync.md §7.2 — 다른 기기에서 막 친 글자 · 칠한 칸)
//   readLive    열린 책의 레코드(하루 · 한 주 · 책 설정)를 메모리에서 하나씩, 앱 파일과 같은 인코더로 (조합 중인 글자 포함)
//   applyLive   transform(지금 값) → 같은 차례 안에서 메모리에 (밖에서 온 변경 — PlannerStore.applyActiveChange). 파일은 평소 묶음 저장
//   조합 중인 글자  SwiftUI 글 칸은 조합(marked text)이 끝나야 바인딩을 바꾸고, 조합 중에 바인딩에 그 글을 넣으면 다음 화면 갱신이
//               조합을 깬다 → 저장소에는 넣지 않고, 엔진이 보는 값(readLive · readBook · updateBook · applyLive 의 지금 값)에만 얹는다
//               (composing). 넣을 때 그 칸이 조합 중인 글 그대로면 저장소의 글로 되돌려 넣는다 — 저장소 · 화면은 조합을 모른다
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
    /// 설정 창에서 고치는 글(형광펜 이름 · 저장한 D-day 제목)이 다른 기기의 값으로 바뀌었다 (바뀐 새 값들)
    var onSettingsTextReplaced: (_ newValues: Set<String>) -> Void = { _ in }
    /// 엔진이 쓰는 칸을 지금 지키는지 (engine.editingProtected — nil: 엔진이 쓰는 칸을 모른다 → 저장소의 규칙대로)
    var editingProtected: () -> Bool? = { nil }
    /// 받은 초안을 열린 책 메모리에 넣었다 (applyLive)
    var onLiveApplied: (ExternalApplyResult) -> Void = { _ in }
    /// 쓰는 칸에서 조합 중인 글 (그 칸의 편집 키 · 필드 편집기의 글 전체). 조합 중이 아니면 nil
    var composing: () -> (key: String, text: String)? = { nil }

    init(store: PlannerStore) { self.store = store }

    func libraryRecreated() async -> Bool { store.libraryCreated }

    func readLibrary() async -> JSONValue? {
        // 책장을 읽지 못한 실행에서는 nil → 엔진은 비교하지 않는다 (지운 것으로 오해하지 않게)
        if store.libraryUnreadable { return nil }
        return try? JSONValue.parse(PlannerStore.encodeFile(store.library))
    }

    func readBook(id: String) async -> BookRead {
        guard let uuid = UUID(uuidString: id) else { return .unreadable }
        // 파일 없이 연 빈 책은 사용자의 플래너가 아니다: 엔진이 되살린다
        if store.booksOpenedWithoutFile.contains(uuid) { return .missing }
        if uuid == store.library.activeID, store.unreadableBooks[uuid] == nil {
            // 펼친 책 (저장할 때마다 비교): 지금 내용(저장 전 편집 포함)을 MainActor 에서 값으로만 잡고, 앱 형식 JSON 으로 쓰고
            // 다시 읽는 일은 메인 밖에서 — 몇 년 치 책이어도 타이핑 · 넘김 중에 프레임이 끊기지 않게. 비교에만 쓰는 값이다
            // (넣기 updateBook 은 MainActor 한 차례 안에서 그대로)
            let data = viewData()
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
        let openedWithoutFile = store.booksOpenedWithoutFile.contains(uuid)
        let composing = !openedWithoutFile && uuid == store.library.activeID && store.unreadableBooks[uuid] == nil ? composing() : nil
        if openedWithoutFile {
            // 파일 없이 연 펼친 책 (엔진이 아직 받아들이지 않음): 메모리의 빈 책은 사용자의 플래너가 아니다 → readBook 의 .missing 과 같게
            // nil. 엔진은 그 책을 다시 비교해 되살린다 (missingNoted 뒤에는 메모리 값). 조합 중이어도 같다 — readBookRaw · 조합 중인 값은
            // 펼친 책의 메모리 값이라, 넘기면 옛 그림자와 비교돼 모든 기기에서 날 · 형광펜이 지워졌다 (2026-10-04 사고 검토 W1)
            cur = nil
        } else if let composing {
            // 펼친 책에서 조합 중: 엔진이 보는 값은 조합 중인 글을 얹은 것 (readBook · readLive 와 같게)
            guard case let .ok(v) = Self.appJSON(store.data.settingEditedText(composing.key, composing.text)) else { return }
            cur = v
        } else {
            switch store.readBookRaw(uuid) {
            case .unreadable: return                            // 읽지 못한 파일: transform 을 부르지 않고 그대로
            case .missing: cur = nil
            case .data(let raw):
                guard let v = try? JSONValue.parse(raw) else { return }
                cur = v
            }
        }
        let next = transform(cur)
        // 여기부터 넣지 못하면 던진다
        if uuid == store.library.activeID {
            guard let next else { return }                      // 펼친 책은 이렇게 지우지 않는다 (엔진은 책장에서 먼저 뺀다)
            let key = editingKey()
            let old = store.data
            let merged = try PlannerStore.decodeFile(PlannerData.self, from: next.jsonData()).withoutComposing(composing, committed: old)
            // 안전망: 엔진이 그 칸을 지키지 않으면(쓰지 않고 포커스만 있음) 저장소도 지키지 않는다 (엔진이 모르면 저장소의 규칙대로)
            let r = store.applyActiveData(merged, keepingEditOf: editingProtected() == false ? nil : key)
            if r.changed { onActiveApplied(r) }
            afterApply(r, key: key, old: old)
        } else if let next {
            // 앱 모델로 읽고 다시 써서 Mac 의 JSONEncoder 와 같은 바이트로 (모든 기기의 책 파일이 같은 바이트).
            // writeBookRaw 는 앱이 읽을 수 있는지 다시 보고 원자적으로 쓴다
            try store.writeBookRaw(uuid, PlannerStore.encodeFile(try PlannerStore.decodeFile(PlannerData.self, from: next.jsonData())))
        } else if cur != nil {
            try store.removeBookFile(uuid)                      // 책장에서 이미 빠진 책
        }
        if next != nil { store.clearOpenedWithoutFile(uuid) }    // 동기화된 내용을 넣었다 (되살림)
    }

    func missingNoted(bookId: String) async {
        guard let uuid = UUID(uuidString: bookId) else { return }
        store.clearOpenedWithoutFile(uuid)
    }

    /// 펼친 책에 넣은 뒤: 쓰던 할 일 · 메모가 지워졌으면 편집을 끝내고, 쓰던 칸(포커스만)의 글이 바뀌었으면 그 칸의 ⌘Z 기록을,
    /// 설정 창의 글이 바뀌었으면 그 칸의 ⌘Z 기록을 비우게 알린다
    private func afterApply(_ r: ExternalApplyResult, key: String?, old: PlannerData) {
        let before = key.flatMap { PlannerData.editedText($0, in: old) }
        let removed = r.editedItemRemoved || (key.map { before != nil && PlannerData.editedText($0, in: store.data) == nil } ?? false)
        if removed {
            onEditedItemRemoved()
        } else if let key, r.changed, before != nil, case let after = PlannerData.editedText(key, in: store.data), after != before {
            onEditedFieldReplaced(after)
        }
        if r.changed {
            let settingsBefore = Self.settingsTexts(old)
            let replaced = Self.settingsTexts(store.data).filter { k, v in settingsBefore[k].map { $0 != v } ?? false }
            if !replaced.isEmpty { onSettingsTextReplaced(Set(replaced.values)) }
        }
    }

    // MARK: 실시간 (Docs/SpiraldaySync.md §7.2)

    /// 열린 책의 레코드 값 (메모리 — 저장 전 편집 · 조합 중인 글자 포함). 열린 책이 아니거나 읽지 못한 책이면 nil (엔진은 readBook 으로)
    func readLive(bookId: String, keys: [String]) async -> [String: JSONValue]? {
        guard isOpenBook(bookId) else { return nil }
        return liveValues(keys)
    }

    /// 엔진이 보는 펼친 책의 지금 값: 저장소의 값 + 쓰는 칸에서 조합 중인 글
    private func viewData() -> PlannerData {
        guard let c = composing() else { return store.data }
        return store.data.settingEditedText(c.key, c.text)
    }

    /// 받은 초안을 열린 책 메모리에 바로 — 같은 MainActor 차례 안에서 transform(지금 값) 을 부르고 그 값을 넣는다.
    /// 밖에서 온 변경이라 사용자의 편집으로 세지 않고(liveEdit 없음 · 되돌리기는 rebased), 파일은 평소처럼 묶어서 저장한다.
    /// 넣을 수 없으면(열린 책이 아님 · 읽지 못한 책) transform 을 부르지 않고 false. 앱 모델로 읽지 못한 값도 넣지 않고 false —
    /// 엔진의 장부는 바뀌지 않았고(transform 은 사본으로 계산한다) 다음 바퀴의 updateBook 으로 다시 넣는다
    func applyLive(bookId: String, keys: [String], _ transform: @Sendable ([String: JSONValue]) -> [String: JSONValue]) async -> Bool {
        guard isOpenBook(bookId) else { return false }
        let composing = composing()
        let next = transform(liveValues(keys))
        var days: [String: DayRecord?] = [:]
        var weeks: [String: WeekRecord?] = [:]
        var prefs: Prefs?
        do {
            for key in keys {
                guard let pk = RecordKeys.parse(key), let v = next[key] else { continue }
                switch pk.kind {
                case .day:
                    let r = v.isNull ? nil : try PlannerStore.decodeFile(DayRecord.self, from: v.jsonData())
                    days[pk.date!] = .some(r.flatMap { $0.isEmpty ? nil : $0 })
                case .week:
                    weeks[pk.date!] = .some(v.isNull ? nil : try PlannerStore.decodeFile(WeekRecord.self, from: v.jsonData()))
                case .prefs:
                    if !v.isNull { prefs = try PlannerStore.decodeFile(Prefs.self, from: v.jsonData()) }
                default:
                    break
                }
            }
        } catch {
            return false
        }
        let key = editingKey()
        let old = store.data
        let r = store.applyActiveChange(editingKey: key) { d in
            for (k, v) in days { d.days[k] = v }
            for (k, v) in weeks { d.weeks[k] = v }
            if let prefs { d.prefs = prefs }
            // 조합 중인 칸을 엔진이 그대로 두었으면(쓰는 중) 저장소에는 조합 전 글 그대로 (조합이 깨지지 않게)
            d = d.withoutComposing(composing, committed: old)
        }
        afterApply(r, key: key, old: old)
        if r.changed { onLiveApplied(r) }
        return true
    }

    private func isOpenBook(_ bookId: String) -> Bool {
        guard let uuid = UUID(uuidString: bookId) else { return false }
        // 파일 없이 연 책은 실시간으로 다루지 않는다 (엔진이 먼저 updateBook 으로 되살린다)
        return uuid == store.library.activeID && store.unreadableBooks[uuid] == nil && !store.booksOpenedWithoutFile.contains(uuid)
    }

    /// 레코드 키마다 열린 책의 지금 값 (없는 날 · 주는 .null). 책 전체가 아니라 레코드 하나씩 (입력마다 불린다)
    func liveValues(_ keys: [String]) -> [String: JSONValue] {
        let data = viewData()
        var out: [String: JSONValue] = [:]
        for key in keys {
            guard let pk = RecordKeys.parse(key) else { continue }
            switch pk.kind {
            case .day: out[key] = Self.recordJSON(data.days[pk.date ?? ""])
            case .week: out[key] = Self.recordJSON(data.weeks[pk.date ?? ""])
            case .prefs: out[key] = Self.recordJSON(data.prefs)
            default: break
            }
        }
        return out
    }

    /// 레코드 하나 → 앱 파일과 같은 JSON (없으면 .null)
    private static func recordJSON<T: Encodable>(_ v: T?) -> JSONValue {
        guard let v, let raw = try? PlannerStore.encodeFile(v), let j = try? JSONValue.parse(raw) else { return .null }
        return j
    }

    /// 앱이 방금 파일에 쓴 그 책의 값 (localChanged(saved:) — 엔진이 필요할 때만, 엔진 쪽에서 부른다)
    nonisolated static func savedJSON(_ data: PlannerData) -> JSONValue? {
        if case let .ok(v) = appJSON(data) { return v }
        return nil
    }

    /// 설정 창에서 칠 때마다 저장소에 쓰는 글 (형광펜 이름 · 저장한 D-day 제목), id 마다
    static func settingsTexts(_ d: PlannerData) -> [String: String] {
        var m: [String: String] = [:]
        for c in d.prefs.categories { m["pen|\(c.id)"] = c.name }
        for dd in d.prefs.ddays { m["dday|\(dd.id.uuidString)"] = dd.title }
        return m
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

extension PlannerData {
    /// 편집 키(AppState.editingKey)가 가리키는 칸의 글을 바꾼 사본 (없는 할 일 · 메모 · 모르는 키면 그대로). 하루가 비면 없앤다
    func settingEditedText(_ key: String, _ text: String) -> PlannerData {
        var d = self
        if key == FrontPage.mottoKey {
            d.prefs.motto = text
            return d
        }
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, Dates.parse(parts[1]) != nil else { return self }
        let k = parts[1]
        func editDay(_ f: (inout DayRecord) -> Void) {
            var r = d.days[k] ?? DayRecord()
            f(&r)
            d.days[k] = r.isEmpty ? nil : r
        }
        switch (parts[0], parts.count) {
        case ("t", 3):
            guard let id = UUID(uuidString: parts[2]), let i = d.days[k]?.tasks.firstIndex(where: { $0.id == id }) else { return self }
            d.days[k]!.tasks[i].text = text
        case ("tn", 3):
            guard let id = UUID(uuidString: parts[2]), let i = d.days[k]?.notes.firstIndex(where: { $0.id == id }) else { return self }
            d.days[k]!.notes[i].text = text
        case ("c", 2):
            editDay { $0.comment = text }
        case ("m", 3), ("mt", 3):
            guard let i = Int(parts[2]), (0..<16).contains(i) else { return self }
            let path: WritableKeyPath<DayRecord, [String]> = parts[0] == "m" ? \.memos : \.memoTags
            editDay { r in
                while r[keyPath: path].count <= i { r[keyPath: path].append("") }
                r[keyPath: path][i] = text
            }
        case ("wg", 2):
            var w = d.weeks[k] ?? WeekRecord()
            w.goal = text
            d.weeks[k] = w == WeekRecord() && weeks[k] == nil ? nil : w
        default:
            return self
        }
        return d
    }

    /// 넣을 값에서 조합 중인 칸이 조합 중인 글 그대로면(엔진이 쓰는 칸을 지켰다) 저장소의 글(committed)로 되돌린 것.
    /// 저장소에는 조합 중인 글을 넣지 않는다 (넣으면 다음 화면 갱신이 SwiftUI 글 칸의 조합을 깬다)
    func withoutComposing(_ c: (key: String, text: String)?, committed: PlannerData) -> PlannerData {
        guard let c, PlannerData.editedText(c.key, in: self) == c.text, let orig = PlannerData.editedText(c.key, in: committed),
              orig != c.text else { return self }
        return settingEditedText(c.key, orig)
    }
}
