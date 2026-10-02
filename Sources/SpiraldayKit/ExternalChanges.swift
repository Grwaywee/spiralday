import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 밖에서 바뀐 내용을 PlannerStore 에 넣기 (가져오기 도구 등 이 저장소 밖에서 만든 내용)
//
// 알림 (Models.swift 의 PlannerStore)
//   onSaved(bookID, libraryChanged)   이 저장소가 파일을 쓴 뒤 — 무엇이 바뀌었는지 (밖에서 그것을 읽어 비교한다)
//   onDeleted(bookID)                 사용자가 책을 지웠다
//   isApplyingExternalChange          아래 apply… 가 data · library 를 바꾸는 동안 true ($data · $library 를 보는 쪽이 가른다)
//   libraryCreated                    이번 실행에서 library.json 이 없어 책장을 새로 시작했다
//
// 넣기 (모두 MainActor 에서 바로 — 사이에 사용자의 편집이 끼어들지 않는다)
//   applyLibrary(_:)                  책장 (책 더하기 · 정보 바꾸기 · 빼기). 펼친 책이 빠지면 다른 책을 편다
//   applyActiveData(_:keepingEditOf:base:) 펼친 책의 내용. 쓰는 중인 칸은 화면의 글을 지킨다 (포커스만 있는 칸은 아니다). 바로 저장한다
//   noteEditingField(_:)              쓰기 시작한 칸 (AppState.editingKey 가 바뀔 때 알린다) — 쓰는 중인지를 그 칸의 편집으로 가른다
//   readBookRaw / writeBookRaw / removeBookFile   펼치지 않은 책 파일
//
// 데이터 안전 규칙은 앱과 같다: 읽지 못한 파일(unreadableBooks · libraryUnreadable)은 읽거나 쓰거나 지우지 않고,
// 앱이 읽을 수 없는 내용은 쓰지 않으며, 쓰기는 모두 원자적이다 (임시 파일에 다 쓴 뒤 이름 바꾸기).
// ─────────────────────────────────────────────────────────────────────────────

/// applyLibrary · applyActiveData 가 한 일
public struct ExternalApplyResult: Equatable, Sendable {
    /// data · library 를 바꿨는지 (같은 내용이면 false — 바꾸지 않았다. 저장 · 알림은 keptEdit 일 때만)
    public var changed = false
    /// applyLibrary: 펼친 책이 책장에서 빠져서 닫았다 (그 책의 내용은 저장하지 않았다)
    public var closedBook: UUID?
    /// applyLibrary: 다른 책을 폈다 (빠진 책 대신, 또는 아무 책도 펴지 않았을 때 들어온 내가 만든 첫 책)
    public var openedBook: UUID?
    /// applyActiveData: 쓰는 중인 칸이 넣으려던 값과 달라서 화면의 글을 지켰다 (다음 비교에서 새 편집으로 보인다)
    public var keptEdit = false
    /// applyActiveData: 쓰고 있던 할 일 · 타임테이블 메모가 없어졌다 (다른 곳에서 지움) — 앱이 편집을 끝낸다
    public var editedItemRemoved = false

    public init(changed: Bool = false, closedBook: UUID? = nil, openedBook: UUID? = nil,
                keptEdit: Bool = false, editedItemRemoved: Bool = false) {
        self.changed = changed
        self.closedBook = closedBook
        self.openedBook = openedBook
        self.keptEdit = keptEdit
        self.editedItemRemoved = editedItemRemoved
    }
}

/// 펼치지 않은 책 파일을 읽은 결과 (readBookRaw)
public enum RawBookFile: Equatable, Sendable {
    /// 파일이 없다 (아직 저장하지 않은 새 책, 지운 책)
    case missing
    /// 있는데 읽지 못한다 (깨짐 · 이 버전이 모르는 형식 · 읽기 권한 없음). unreadableBooks 에 적혀 있고 손대지 않는다
    case unreadable
    /// 파일 내용 그대로 (앱이 읽을 수 있음을 확인했다)
    case data(Data)
}

/// writeBookRaw · removeBookFile 이 거절한 까닭
public enum BookFileError: Error, Equatable, Sendable {
    /// 펼친 책이다 — applyActiveData 로 넣는다
    case bookIsOpen
    /// 아직 책장에 있는 책이다 — 먼저 applyLibrary 로 뺀다 (removeBookFile)
    case bookIsListed
    /// 지금 파일을 읽지 못한다 — 그대로 둔다 (unreadableBooks)
    case unreadable
    /// 넣으려는 내용을 앱이 읽을 수 없다 (쓰지 않았다)
    case invalidContent(String)
    /// 디스크에 쓰거나 지우지 못했다
    case fileError(String)
}

extension PlannerStore {
    // MARK: 앱 파일 형식

    /// 앱 파일과 같은 JSON (JSONEncoder: .iso8601 날짜, .sortedKeys)
    public static func encodeFile<T: Encodable>(_ value: T) throws -> Data {
        try enc.encode(value)
    }

    /// 앱 파일과 같은 방식으로 읽는다 (JSONDecoder: .iso8601 날짜)
    public static func decodeFile<T: Decodable>(_ type: T.Type, from raw: Data) throws -> T {
        try dec.decode(type, from: raw)
    }

    // MARK: 책장

    /// 밖에서 합친 책장을 넣는다 (책 더하기 · 책 정보 바꾸기 · 책 빼기). 바뀐 것이 있으면 library.json 에 쓰고 onSaved(nil, true).
    /// - 펼친 책(activeID)은 이 저장소의 것이라 그대로 둔다. merged.activeID 는 보지 않는다.
    /// - 펼친 책이 빠졌으면: 그 책의 내용은 저장하지 않고(파일은 removeBookFile 로 따로 지운다) deleteBook 과 같은 순서로
    ///   다른 책을 편다 (내가 만든 책이 먼저, 없으면 예시 플래너, 읽지 못한 책은 건너뛴다).
    /// - 아무 책도 펴지 않았는데(처음 켬) 내가 만든 책이 들어오면 그 첫 책을 편다 (켤 때 init 과 같은 규칙).
    /// - 예시 플래너를 꽂았다는 표시(sampleSeeded)는 지우지 않는다. 같은 id 의 책이 둘이면 앞의 것만.
    /// - library.json 을 읽지 못한 실행(libraryUnreadable)에서는 아무것도 하지 않는다 (원본을 그대로 둔다).
    /// 책 날짜(start · end)는 받은 그대로 둔다 (시간대가 다른 곳에서 만든 값을 이 저장소의 시간대로 다시 맞추지 않는다).
    @discardableResult
    public func applyLibrary(_ merged: Library) -> ExternalApplyResult {
        var result = ExternalApplyResult()
        guard !libraryUnreadable else { return result }
        var next = merged
        var seen = Set<UUID>()
        next.books = merged.books.filter { seen.insert($0.id).inserted }
        next.sampleSeeded = merged.sampleSeeded || library.sampleSeeded
        let current = library.activeID
        let stillListed = current.map { id in next.books.contains { $0.id == id } } ?? false
        next.activeID = stillListed ? current : nil
        guard next.books != library.books || next.activeID != library.activeID || next.sampleSeeded != library.sampleSeeded else {
            return result
        }
        result.changed = true
        isApplyingExternalChange = true
        defer { isApplyingExternalChange = false }
        if let current, !stillListed {
            // 빠진 책의 저장 예약을 버린다 (그 파일을 다시 만들지 않게)
            saveWork?.cancel()
            saveWork = nil
            library = next
            library.activeID = fallbackBook(excluding: current)?.id
            openActiveBook(notifying: true)
            result.closedBook = current
            result.openedBook = library.activeID
        } else if current == nil, let first = next.books.first(where: { !$0.isSample && unreadableBooks[$0.id] == nil }) {
            library = next
            library.activeID = first.id
            openActiveBook(notifying: true)
            result.openedBook = library.activeID
        } else {
            library = next
        }
        bump()
        writeLibrary()
        return result
    }

    // MARK: 펼친 책

    /// 밖에서 합친 펼친 책의 내용을 넣고 바로 저장한다 (onSaved(펼친 책, true)).
    /// 보통은 지금 `data` 로 합친 결과를 같은 MainActor 차례 안에서 바로 넘긴다 (그 사이에 사용자의 편집이 끼어들지 않게).
    /// - base: merged 를 만든 바탕 (밖에서 그때 읽은 data). 주지 않으면 지금 data 로 만든 것으로 본다.
    /// - editingKey (AppState.editingKey): 쓰고 있는 칸(할 일 · 타임테이블 메모 · COMMENT · 메모 · 메모 태그 · 주간 목표 · 첫 장의 말)은
    ///   지금 쓰는 중이면 — base 를 줬으면 base 뒤로 고쳤을 때, 주지 않았으면 그 칸을 editingGrace 안에 고쳤을 때
    ///   (noteEditingField 로 알린 칸이면 그 칸의 글이 바뀐 때로, 아니면 책 전체의 마지막 편집 lastLocalEdit 로) — 화면의 글을 그대로 둔다
    ///   (글자 · 커서 · 한글 조합이 흔들리지 않는다. 그 칸은 다음 비교에서 새 편집으로 보인다).
    ///   포커스만 있고 쓰지 않은 칸은 merged 의 값을 넣는다 (다른 곳의 더 새 글을 화면의 옛 글로 덮어 되돌리지 않게).
    ///   쓰던 할 일 · 메모가 없어졌으면(다른 곳에서 지움) 되살리지 않고 editedItemRemoved 로 알린다 → 앱이 편집을 끝낸다.
    /// - 저장소마다 따로인 값(prefs.lastKind · prefs.ddaysPerDay)은 이 저장소의 것을 둔다.
    /// - 줄이 없는 할 일에는 책을 열 때처럼 줄을 매긴다.
    /// - 내용이 같으면 data · version 은 그대로다. 저장 · 알림도 없다 — 다만 쓰는 칸을 지켰으면(keptEdit) 그 칸이
    ///   다시 비교되도록 저장하고 알린다.
    /// - 펼친 책이 없거나 그 책 파일을 읽지 못했으면(unreadableBooks) 아무것도 하지 않는다.
    /// 되돌리기 기록은 isApplyingExternalChange 로 이 변경을 가르고 PlannerData.rebased(from:to:) 로 쌓인 단계에 옮겨 둔다.
    @discardableResult
    public func applyActiveData(_ merged: PlannerData, keepingEditOf editingKey: String? = nil, base: PlannerData? = nil) -> ExternalApplyResult {
        var result = ExternalApplyResult()
        guard let id = library.activeID, unreadableBooks[id] == nil else { return result }
        var next = merged
        next.prefs.lastKind = data.prefs.lastKind
        next.prefs.ddaysPerDay = data.prefs.ddaysPerDay
        if let editingKey {
            let kept = PlannerData.keepingEditedField(editingKey, mine: data, merged: next,
                                                      base: base ?? (isTyping(in: editingKey) ? nil : data))
            next = kept.data
            result.keptEdit = kept.kept
            result.editedItemRemoved = kept.removed
        }
        for (k, r) in next.days where !r.taskRowsReady { next.days[k]?.assignTaskRows() }
        if next != data {
            result.changed = true
            isApplyingExternalChange = true
            data = next
            isApplyingExternalChange = false
            bump()
            // 밖에서 넣은 글은 사용자가 고친 것이 아니다: 쓰는 칸의 기록을 새 글로 맞춘다 (고친 때는 그대로)
            if var f = fieldEdit {
                f.text = PlannerData.editedText(f.key, in: data)
                fieldEdit = f
            }
        }
        if result.changed || result.keptEdit { saveNow() }
        return result
    }

    /// 쓰기 시작한 칸을 알린다 (AppState.editingKey 가 바뀔 때 — 편집을 끝내면 nil). 그 칸의 지금 글을 적어 두고,
    /// 그 뒤로 그 글이 바뀌어야(사용자가 쳐야) 그 칸을 쓰는 중으로 본다 (applyActiveData).
    /// 같은 칸을 다시 알리면 아무것도 하지 않는다 (고친 때를 그대로 둔다)
    public func noteEditingField(_ key: String?) {
        guard let key else {
            fieldEdit = nil
            return
        }
        guard fieldEdit?.key != key else { return }
        fieldEdit = FieldEdit(key: key, text: PlannerData.editedText(key, in: data), at: nil)
    }

    /// 그 칸을 지금 쓰는 중인지 (editingGrace 안에 고쳤는지). 알린 칸이면 그 칸의 편집으로, 아니면 책 전체의 마지막 편집으로
    func isTyping(in key: String, now: Date = Date()) -> Bool {
        if let f = fieldEdit, f.key == key {
            guard let at = f.at else { return false }
            return now.timeIntervalSince(at) < editingGrace
        }
        return lastLocalEdit.map { now.timeIntervalSince($0) < editingGrace } ?? false
    }

    // MARK: 펼치지 않은 책

    /// 책 파일을 그대로 읽는다 (펼치지 않는다, 옮기지 않는다, 쓰지 않는다).
    /// - 펼친 책이면 지금 내용(저장 전 편집 포함)을 앱 형식으로 (encodeFile(data)).
    /// - 앱이 읽을 수 없는 파일이면 책을 열 때와 같이 원본은 그대로 두고 복사본을 남긴 뒤 unreadableBooks 에 적는다 → .unreadable.
    ///   그 뒤로 이 실행에서는 그 파일을 쓰거나 지우지 않는다 (사용자가 펼치려 할 때 알림이 뜬다).
    public func readBookRaw(_ id: UUID) -> RawBookFile {
        if unreadableBooks[id] != nil { return .unreadable }
        if id == library.activeID {
            return (try? Self.enc.encode(data)).map { .data($0) } ?? .unreadable
        }
        guard let url = bookURL(id) else {
            return memoryBooks[id].flatMap { try? Self.enc.encode($0) }.map { .data($0) } ?? .missing
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let raw = try Data(contentsOf: url)
            _ = try Self.dec.decode(PlannerData.self, from: raw)
            return .data(raw)
        } catch {
            noteUnreadableBook(id, url, error)
            return .unreadable
        }
    }

    /// 펼치지 않은 책의 파일을 이 내용으로 바꾼다 (없으면 만든다 — 책장에 아직 없는 책이어도 된다). 원자적 쓰기.
    /// 내용은 그대로 쓰되, 앱이 읽을 수 있는지 먼저 확인한다. onSaved 로 알리지 않는다.
    /// 거절 (아무것도 쓰지 않는다): 펼친 책 (.bookIsOpen) · 읽지 못한 책이나 지금 파일을 읽을 수 없음 (.unreadable) ·
    /// 앱이 읽을 수 없는 내용 (.invalidContent).
    public func writeBookRaw(_ id: UUID, _ raw: Data) throws {
        guard id != library.activeID else { throw BookFileError.bookIsOpen }
        guard unreadableBooks[id] == nil else { throw BookFileError.unreadable }
        let decoded: PlannerData
        do {
            decoded = try Self.dec.decode(PlannerData.self, from: raw)
        } catch {
            throw BookFileError.invalidContent(Self.reason(error))
        }
        guard let url = bookURL(id) else {
            memoryBooks[id] = decoded
            return
        }
        try checkReadableIfPresent(id, url)
        do {
            try raw.write(to: url, options: .atomic)
        } catch {
            throw BookFileError.fileError(error.localizedDescription)
        }
    }

    /// 책장에서 뺀 책의 파일을 지운다 (D-day 옮기기 때 남긴 원본 사본도 — deleteBook 과 같다). 파일이 없으면 아무것도 하지 않는다.
    /// onDeleted · onSaved 로 알리지 않는다.
    /// 거절: 펼친 책 (.bookIsOpen) · 아직 책장에 있는 책 (.bookIsListed) · 읽지 못하는 파일 (.unreadable — 읽지 못한 것은 지우지 않는다).
    public func removeBookFile(_ id: UUID) throws {
        guard id != library.activeID else { throw BookFileError.bookIsOpen }
        guard unreadableBooks[id] == nil else { throw BookFileError.unreadable }
        guard let url = bookURL(id) else {
            guard !library.books.contains(where: { $0.id == id }) else { throw BookFileError.bookIsListed }
            memoryBooks[id] = nil
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard !library.books.contains(where: { $0.id == id }) else { throw BookFileError.bookIsListed }
        try checkReadableIfPresent(id, url)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw BookFileError.fileError(error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: Self.ddayBackupURL(url))
    }

    // MARK: 데이터 안전

    /// 파일이 있으면 앱이 읽을 수 있는지 본다. 읽지 못하면 책을 열 때와 같이 적어 두고(복사본을 남긴다) .unreadable 을 던진다.
    private func checkReadableIfPresent(_ id: UUID, _ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            _ = try Self.dec.decode(PlannerData.self, from: Data(contentsOf: url))
        } catch {
            noteUnreadableBook(id, url, error)
            throw BookFileError.unreadable
        }
    }

    /// 읽지 못한 책 파일: 원본은 손대지 않고 복사본을 남기며, 이 실행에서는 그 파일에 쓰지 않도록 적어 둔다 (loadBook 과 같다)
    func noteUnreadableBook(_ id: UUID, _ url: URL, _ error: Error) {
        let name = library.books.first { $0.id == id }?.name
        unreadableBooks[id] = UnreadableFile(kind: .book(id), url: url, copy: Self.preserveUnreadable(url), name: name,
                                             reason: Self.reason(error))
    }
}

// MARK: - 쓰고 있는 칸 지키기 · 되돌리기 기록 옮기기

extension PlannerData {
    /// editingKey 가 가리키는 칸의 글 (할 일 · 메모가 없거나 모르는 키면 nil)
    public static func editedText(_ editingKey: String, in d: PlannerData) -> String? {
        if editingKey == FrontPage.mottoKey { return d.prefs.motto }
        let parts = editingKey.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, Dates.parse(parts[1]) != nil else { return nil }
        let k = parts[1]
        let index = parts.count >= 3 ? Int(parts[2]) : nil
        let itemID = parts.count >= 3 ? UUID(uuidString: parts[2]) : nil
        switch parts[0] {
        case "t": return itemID.flatMap { id in d.days[k]?.tasks.first { $0.id == id }?.text }
        case "tn": return itemID.flatMap { id in d.days[k]?.notes.first { $0.id == id }?.text }
        case "c": return d.days[k]?.comment ?? ""
        case "m", "mt":
            guard let i = index, (0..<16).contains(i) else { return nil }
            let lines = (parts[0] == "m" ? d.days[k]?.memos : d.days[k]?.memoTags) ?? []
            return i < lines.count ? lines[i] : ""
        case "wg": return d.weeks[k]?.goal ?? ""
        default: return nil
        }
    }

    /// editingKey(AppState.editingKey — "t|날|할 일 id", "tn|날|메모 id", "c|날", "m|날|n", "mt|날|n", "wg|주 시작", "motto")
    /// 의 칸을 mine 의 값으로 merged 에 되돌린다. 할 일 · 메모가 merged 에 없으면 되살리지 않는다 (removed).
    /// kept = 되돌린 값이 merged 와 달랐다.
    /// base (merged 를 만든 바탕)를 주면, 그 칸을 base 뒤로 고쳤을 때만 되돌린다 — 포커스만 있던 칸이 다른 곳의 더 새 글을 덮지 않게.
    public static func keepingEditedField(_ editingKey: String, mine: PlannerData, merged: PlannerData, base: PlannerData? = nil)
        -> (data: PlannerData, kept: Bool, removed: Bool) {
        if let base, let typed = editedText(editingKey, in: mine), editedText(editingKey, in: base) == typed {
            // base 뒤로 쓰지 않았다: merged 그대로. 쓰던 할 일 · 메모가 merged 에서 없어졌는지만 알린다
            return (merged, false, editedText(editingKey, in: merged) == nil)
        }
        var out = merged
        let parts = editingKey.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if editingKey == FrontPage.mottoKey {
            guard mine.prefs.motto != merged.prefs.motto else { return (out, false, false) }
            out.prefs.motto = mine.prefs.motto
            return (out, true, false)
        }
        guard parts.count >= 2, Dates.parse(parts[1]) != nil else { return (out, false, false) }
        let k = parts[1]
        let index = parts.count >= 3 ? Int(parts[2]) : nil
        let itemID = parts.count >= 3 ? UUID(uuidString: parts[2]) : nil

        /// 그날 기록의 한 칸을 되돌린다 (그날이 없어졌으면 다시 만든다 — 글을 쓰는 중이므로)
        func keepDay(_ mineValue: String, _ get: (DayRecord) -> String, _ set: (inout DayRecord) -> Void) -> (PlannerData, Bool, Bool) {
            let theirs = merged.days[k].map(get) ?? get(DayRecord())
            guard mineValue != theirs else { return (out, false, false) }
            var r = merged.days[k] ?? DayRecord()
            set(&r)
            out.days[k] = r.isEmpty ? nil : r
            return (out, true, false)
        }

        switch parts[0] {
        case "t":
            guard let itemID, let text = mine.days[k]?.tasks.first(where: { $0.id == itemID })?.text else { return (out, false, false) }
            guard let i = merged.days[k]?.tasks.firstIndex(where: { $0.id == itemID }) else { return (out, false, true) }
            guard merged.days[k]!.tasks[i].text != text else { return (out, false, false) }
            out.days[k]!.tasks[i].text = text
            return (out, true, false)
        case "tn":
            guard let itemID, let text = mine.days[k]?.notes.first(where: { $0.id == itemID })?.text else { return (out, false, false) }
            guard let i = merged.days[k]?.notes.firstIndex(where: { $0.id == itemID }) else { return (out, false, true) }
            guard merged.days[k]!.notes[i].text != text else { return (out, false, false) }
            out.days[k]!.notes[i].text = text
            return (out, true, false)
        case "c":
            let text = mine.days[k]?.comment ?? ""
            return keepDay(text, \.comment) { $0.comment = text }
        case "m", "mt":
            guard let i = index, (0..<16).contains(i) else { return (out, false, false) }
            let path: WritableKeyPath<DayRecord, [String]> = parts[0] == "m" ? \.memos : \.memoTags
            func line(_ r: DayRecord) -> String { i < r[keyPath: path].count ? r[keyPath: path][i] : "" }
            let text = mine.days[k].map(line) ?? ""
            return keepDay(text, line) { r in
                while r[keyPath: path].count <= i { r[keyPath: path].append("") }
                r[keyPath: path][i] = text
            }
        case "wg":
            let text = mine.weeks[k]?.goal ?? ""
            guard text != (merged.weeks[k]?.goal ?? "") else { return (out, false, false) }
            var w = merged.weeks[k] ?? WeekRecord()
            w.goal = text
            out.weeks[k] = w
            return (out, true, false)
        default:
            return (out, false, false)
        }
    }

    /// base → theirs 로 바뀐 것(밖에서 온 변경)을 self(예: 그 전에 쌓아 둔 되돌리기 단계)에 옮긴 것.
    /// 칸마다: 그 변경이 바꾼 칸은 theirs 의 값, 나머지 칸은 self 의 값.
    /// 하루 기록은 할 일 · 칠한 칸 · COMMENT · 메모 · 메모 태그 · 컬러 · 타임테이블 메모 · D-day · DAY OFF 마다,
    /// 한 주는 목표 · 돌아보기 · 별점마다, 책 설정은 형광펜 · 저장한 D-day · 기본 컬러 · 첫 장의 말마다 가른다.
    /// (lastKind · ddaysPerDay 는 self 의 것.) 되돌리기가 밖에서 온 변경을 지우지 않게 할 때 쓴다.
    public func rebased(from base: PlannerData, to theirs: PlannerData) -> PlannerData {
        func pick<T: Equatable>(_ b: T, _ m: T, _ t: T) -> T { b == t ? m : t }
        var out = self
        for k in Set(base.days.keys).union(theirs.days.keys) {
            let b = base.days[k], t = theirs.days[k]
            guard b != t else { continue }
            let bb = b ?? DayRecord(), tt = t ?? DayRecord()
            var r = days[k] ?? DayRecord()
            r.tasks = pick(bb.tasks, r.tasks, tt.tasks)
            r.slots = pick(bb.slots, r.slots, tt.slots)
            r.comment = pick(bb.comment, r.comment, tt.comment)
            r.memos = pick(bb.memos, r.memos, tt.memos)
            r.memoTags = pick(bb.memoTags, r.memoTags, tt.memoTags)
            r.theme = pick(bb.theme, r.theme, tt.theme)
            r.notes = pick(bb.notes, r.notes, tt.notes)
            r.ddays = pick(bb.ddays, r.ddays, tt.ddays)
            r.dayOff = pick(bb.dayOff, r.dayOff, tt.dayOff)
            out.days[k] = r.isEmpty ? nil : r
        }
        for k in Set(base.weeks.keys).union(theirs.weeks.keys) {
            let b = base.weeks[k], t = theirs.weeks[k]
            guard b != t else { continue }
            let bb = b ?? WeekRecord(), tt = t ?? WeekRecord()
            var w = weeks[k] ?? WeekRecord()
            w.goal = pick(bb.goal, w.goal, tt.goal)
            w.review = pick(bb.review, w.review, tt.review)
            w.stars = pick(bb.stars, w.stars, tt.stars)
            out.weeks[k] = t == nil && w == WeekRecord() ? nil : w
        }
        out.prefs.categories = pick(base.prefs.categories, prefs.categories, theirs.prefs.categories)
        out.prefs.ddays = pick(base.prefs.ddays, prefs.ddays, theirs.prefs.ddays)
        out.prefs.defaultTheme = pick(base.prefs.defaultTheme, prefs.defaultTheme, theirs.prefs.defaultTheme)
        out.prefs.motto = pick(base.prefs.motto, prefs.motto, theirs.prefs.motto)
        return out
    }
}
