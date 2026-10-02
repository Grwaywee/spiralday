import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 읽기만 하는 곳 (iOS 위젯 · 잠금 화면, 미리보기)에서 저장 파일을 읽는다.
// PlannerStore 는 책을 열 때 예전 파일을 옮기거나 저장할 수 있지만, 여기서는 파일에 아무것도 쓰지 않는다.
// 앱과 같은 화면이 나오도록 예전 형식(1.0.2 까지의 D-day · 1.0.4 까지의 할 일 줄)은 메모리에서만 맞춘다.
// ─────────────────────────────────────────────────────────────────────────────

/// 펼친 책 한 권의 내용 (읽기 전용 복사본)
public struct PlannerSnapshot: Sendable {
    /// 펼친 책 (책장에 없으면 nil)
    public let book: BookInfo?
    public let data: PlannerData
    /// 읽은 시각
    public let readAt: Date

    public init(book: BookInfo?, data: PlannerData, readAt: Date = Date()) {
        self.book = book
        self.data = data
        self.readAt = readAt
    }
}

public enum PlannerSnapshotReader {
    /// 저장 폴더(기본: PlannerStore.sharedFolder — iOS 는 앱 그룹)에서 펼친 책을 읽는다.
    /// 책장이 없거나 읽지 못하면 nil. 파일에는 아무것도 쓰지 않는다.
    public static func read(folder: URL = PlannerStore.sharedFolder, today: Date = Date()) -> PlannerSnapshot? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let raw = try? Data(contentsOf: folder.appendingPathComponent("library.json")),
              let library = try? dec.decode(Library.self, from: raw) else { return nil }
        // 앱과 같은 차례: 펼친 책 → 없으면 사용자가 만든 첫 책 → 예시 플래너
        let candidates = [library.activeID].compactMap { $0 }
            + library.books.filter { !$0.isSample }.map(\.id) + library.books.filter(\.isSample).map(\.id)
        for id in candidates {
            let url = folder.appendingPathComponent("books/\(id.uuidString).json")
            let book = library.books.first { $0.id == id }
            guard FileManager.default.fileExists(atPath: url.path) else {
                if id == library.activeID { return PlannerSnapshot(book: book, data: PlannerData()) }
                continue
            }
            guard let bookRaw = try? Data(contentsOf: url), var data = try? dec.decode(PlannerData.self, from: bookRaw) else { continue }
            if !data.prefs.ddaysPerDay { _ = PlannerStore.migrateDDaysPerDay(&data, today: today, book: book) }
            for (k, r) in data.days where !r.taskRowsReady { data.days[k]?.assignTaskRows() }
            return PlannerSnapshot(book: book, data: data)
        }
        return nil
    }
}

// MARK: - 읽기 도우미 (PlannerStore 와 같은 계산, 액터 밖에서도)

extension PlannerData {
    /// 그날 기록 (없으면 빈 기록)
    public func record(on d: Date) -> DayRecord { days[Dates.key(d)] ?? DayRecord() }

    /// 그 주 기록 (start = 주 시작)
    public func week(starting start: Date) -> WeekRecord { weeks[Dates.key(start)] ?? WeekRecord() }

    /// 그날 칠한 시간 (분). cat 이 없으면 TOTAL TIME 과 같이 counts 인 형광펜만 더한다 (PlannerStore.minutes 와 같다).
    public func minutes(on d: Date, category cat: Int? = nil) -> Int {
        let slots = record(on: d).slots
        if let cat { return slots.filter { $0 == cat }.count * 10 }
        let counted = Set(prefs.categories.filter(\.counts).map(\.id))
        return slots.filter { counted.contains($0) }.count * 10
    }

    /// 그날의 컬러 컨셉 (고르지 않았으면 기본값)
    public func concept(on d: Date) -> ColorConcept { ColorConcept.of(record(on: d).theme ?? prefs.defaultTheme) }

    /// 형광펜 id → 형광펜 (지운 형광펜이면 nil)
    public func category(_ id: Int?) -> Category? {
        guard let id else { return nil }
        return prefs.categories.first { $0.id == id }
    }
}
