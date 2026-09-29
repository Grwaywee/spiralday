import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 홈(통계) 페이지에 쓰는 숫자들. PlannerData 를 받아 계산만 하는 순수 함수.
//
// data.days 는 한 번만 훑는다. 날짜 키 "yyyy-MM-dd" 는 DateFormatter 없이 정수 일련번호
// (1970-01-01 = 0) 로 바꿔서, 모든 기간 비교를 정수 비교로 한다.
// "기록한 날" = 타임테이블에 (지금 있는) 형광펜을 한 칸이라도 칠한 날.
// DAY OFF(쉬는 날)는 기록한 날로 세지 않지만 연속 기록을 끊지도 않는다 (건너뛴다).
// 시간 합계는 TOTAL TIME 과 같이 counts 인 형광펜만 더한다.
// ─────────────────────────────────────────────────────────────────────────────

struct HomeStats {
    static let weekCount = 12
    /// 요일별 평균을 내는 기간 (주)
    static let weekdayWeeks = 8
    /// 시간대 분포를 보는 기간 (일)
    static let heatDays = 28
    /// 잔디 달력 줄 수 (주, 이번 주가 마지막 줄)
    static let calendarWeeks = 5

    struct Week {
        let start: Date
        /// 0 = 이번 주, -1 = 지난주 …
        let offset: Int
        let minutes: Int
        /// 합계에 들어가는 형광펜별 분 (store.categories 순서)
        let byCategory: [Int]
    }

    struct CategoryTotal {
        let id: Int
        let minutes: Int
        let counts: Bool
    }

    struct HeatCell {
        /// 이 칸에 가장 자주 칠한 형광펜 id (없으면 nil)
        let category: Int?
        /// 칠한 날 / 본 날 (0...1)
        let ratio: Double
    }

    struct DayCell {
        let date: Date
        let minutes: Int
        let recorded: Bool
        let theme: Int?
        let isToday: Bool
        let isFuture: Bool
        /// 쉬는 날 (DAY OFF)
        var dayOff = false
    }

    // 요약 숫자
    var weekMinutes = 0
    var monthMinutes = 0
    /// 이번 달에 기록한 날
    var monthDays = 0
    var daysInMonth = 30
    var month = 1
    var streak = 0
    /// 오늘도 기록했는지 (아니면 streak 는 어제까지)
    var streakIncludesToday = false
    /// 오늘이 쉬는 날인지 (칠하지 않았어도 연속 기록이 이어진다)
    var todayOff = false

    // 이번 달 할 일 표시
    var done = 0, partial = 0, missed = 0, moved = 0, unmarked = 0
    var marked: Int { done + partial + missed + moved }
    /// 완료 / 표시한 할 일. 표시한 할 일이 없으면 nil
    var completion: Double? { marked > 0 ? Double(done) / Double(marked) : nil }

    /// 기록한 날 평균 (분)
    var dailyAverage: Int { monthDays > 0 ? monthMinutes / monthDays : 0 }

    var weeks: [Week] = []
    /// 이번 달 형광펜별 합계, 많은 순
    var categories: [CategoryTotal] = []
    /// 월 … 일 평균 (분)
    var weekdayAverage = [Int](repeating: 0, count: 7)
    /// 06:00 → 다음날 05:50, 10분 칸 144개
    var heat = [HeatCell](repeating: HeatCell(category: nil, ratio: 0), count: DayRecord.slotCount)
    /// 가장 자주 칠한 한 시간 (0 = 06시 줄), 기록이 없으면 nil
    var peakHour: Int? = nil
    /// 잔디: 5주 × 7일, 월요일부터
    var calendar: [DayCell] = []

    /// 타임테이블을 한 번이라도 칠했는지 (빈 페이지 안내용)
    var hasTime = false

    // MARK: - Build

    static func make(_ data: PlannerData, today now: Date) -> HomeStats {
        var s = HomeStats()
        let cats = data.prefs.categories
        let nc = cats.count
        // 형광펜 id → 팔레트 순서 (지운 형광펜 id 는 -1)
        var index = [Int](repeating: -1, count: max(0, (cats.map(\.id).max() ?? -1) + 1))
        for (i, c) in cats.enumerated() where c.id >= 0 { index[c.id] = i }
        func slot(_ v: Int) -> Int { v >= 0 && v < index.count ? index[v] : -1 }
        let counted = cats.map(\.counts)

        let today = Dates.day(now)
        let tc = Dates.comp(today)
        let t = civilOrdinal(tc.year ?? 1970, tc.month ?? 1, tc.day ?? 1)
        let weekStart = t - weekday(t)
        s.month = tc.month ?? 1

        // 기간 (정수 일련번호, 양 끝 포함)
        let weeksFrom = weekStart - 7 * (weekCount - 1), weeksTo = weekStart + 6
        let monthFrom = civilOrdinal(tc.year ?? 1970, s.month, 1)
        let monthTo = (s.month == 12 ? civilOrdinal((tc.year ?? 1970) + 1, 1, 1) : civilOrdinal(tc.year ?? 1970, s.month + 1, 1)) - 1
        s.daysInMonth = monthTo - monthFrom + 1
        let weekdayFrom = t - 7 * weekdayWeeks + 1
        let heatFrom = t - heatDays + 1
        let calFrom = weekStart - 7 * (calendarWeeks - 1)
        let calCount = 7 * calendarWeeks

        var weekMin = [Int](repeating: 0, count: weekCount)
        var weekCat = [Int](repeating: 0, count: weekCount * nc)
        var monthCat = [Int](repeating: 0, count: nc)
        var weekdaySum = [Int](repeating: 0, count: 7)
        var heatCount = [Int](repeating: 0, count: DayRecord.slotCount * max(nc, 1))
        var calMin = [Int](repeating: 0, count: calCount)
        var calRec = [Bool](repeating: false, count: calCount)
        var calTheme = [Int?](repeating: nil, count: calCount)
        var calOff = [Bool](repeating: false, count: calCount)
        var recordedPast = Set<Int>()
        /// 오늘까지의 쉬는 날
        var offPast = Set<Int>()
        var firstRecorded = Int.max
        var perCat = [Int](repeating: 0, count: nc)

        for (key, day) in data.days {
            guard let o = ordinal(key) else { continue }

            // 형광펜별 칸 수
            for i in perCat.indices { perCat[i] = 0 }
            var painted = 0
            for v in day.slots {
                let i = slot(v)
                if i >= 0 { perCat[i] += 1; painted += 1 }
            }
            var minutes = 0
            for i in 0..<nc where counted[i] { minutes += perCat[i] * 10 }
            let recorded = painted > 0
            if day.dayOff, o <= t { offPast.insert(o) }

            if recorded {
                s.hasTime = true
                firstRecorded = min(firstRecorded, o)
                if o <= t { recordedPast.insert(o) }
            }
            if (weeksFrom...weeksTo).contains(o) {
                let w = (o - weeksFrom) / 7
                weekMin[w] += minutes
                for i in 0..<nc where counted[i] { weekCat[w * nc + i] += perCat[i] * 10 }
            }
            if (monthFrom...monthTo).contains(o) {
                s.monthMinutes += minutes
                if recorded { s.monthDays += 1 }
                for i in 0..<nc { monthCat[i] += perCat[i] * 10 }
                for task in day.tasks {
                    switch task.mark {
                    case .done: s.done += 1
                    case .partial: s.partial += 1
                    case .missed: s.missed += 1
                    case .moved: s.moved += 1
                    case .none: s.unmarked += 1
                    }
                }
            }
            if (weekdayFrom...t).contains(o) { weekdaySum[weekday(o)] += minutes }
            if recorded, nc > 0, (heatFrom...t).contains(o) {
                for (k, v) in day.slots.enumerated() {
                    let i = slot(v)
                    if i >= 0 { heatCount[k * nc + i] += 1 }
                }
            }
            if (calFrom..<(calFrom + calCount)).contains(o) {
                calMin[o - calFrom] = minutes
                calRec[o - calFrom] = recorded
                calTheme[o - calFrom] = day.theme
                calOff[o - calFrom] = day.dayOff
            }
        }

        // 12주
        s.weeks = (0..<weekCount).map { w in
            let off = w - (weekCount - 1)
            return Week(start: Dates.add(days: weeksFrom + 7 * w - t, to: today), offset: off,
                        minutes: weekMin[w], byCategory: Array(weekCat[(w * nc)..<(w * nc + nc)]))
        }
        s.weekMinutes = weekMin[weekCount - 1]

        // 이번 달 형광펜별 (같으면 팔레트 순서)
        s.categories = cats.indices
            .map { CategoryTotal(id: cats[$0].id, minutes: monthCat[$0], counts: cats[$0].counts) }
            .enumerated()
            .sorted { a, b in a.element.minutes != b.element.minutes ? a.element.minutes > b.element.minutes : a.offset < b.offset }
            .map(\.element)

        // 연속 기록: 오늘부터 (오늘이 비어 있으면 어제부터) 거꾸로. 칠하지 않은 쉬는 날은 세지 않고 건너뛴다.
        s.streakIncludesToday = recordedPast.contains(t)
        s.todayOff = offPast.contains(t)
        var o = s.streakIncludesToday || s.todayOff ? t : t - 1
        while true {
            if recordedPast.contains(o) {
                s.streak += 1
            } else if !offPast.contains(o) {
                break
            }
            o -= 1
        }

        // 요일별 평균: 처음 기록한 날 이후의 그 요일 수로 나눈다
        if firstRecorded <= t {
            let from = max(weekdayFrom, firstRecorded)
            var n = [Int](repeating: 0, count: 7)
            for d in from...t { n[weekday(d)] += 1 }
            s.weekdayAverage = (0..<7).map { n[$0] > 0 ? weekdaySum[$0] / n[$0] : 0 }
        }

        // 시간대: 칸마다 가장 자주 칠한 형광펜과 그 빈도
        if firstRecorded <= t, nc > 0 {
            let seen = Double(t - max(heatFrom, firstRecorded) + 1)
            var hourFill = [Int](repeating: 0, count: 24)
            s.heat = (0..<DayRecord.slotCount).map { k in
                var best = -1, bestN = 0, total = 0
                for i in 0..<nc {
                    let c = heatCount[k * nc + i]
                    total += c
                    if c > bestN { best = i; bestN = c }
                }
                hourFill[k / 6] += total
                return HeatCell(category: best >= 0 ? cats[best].id : nil, ratio: min(1, Double(total) / seen))
            }
            if let m = hourFill.max(), m > 0 { s.peakHour = hourFill.firstIndex(of: m) }
        }

        // 잔디
        s.calendar = (0..<calCount).map { i in
            let o = calFrom + i
            return DayCell(date: Dates.add(days: o - t, to: today), minutes: calMin[i], recorded: calRec[i],
                           theme: calTheme[i], isToday: o == t, isFuture: o > t, dayOff: calOff[i])
        }
        return s
    }

    // MARK: - Day numbers

    /// "yyyy-MM-dd" → 1970-01-01 부터 센 날 수
    static func ordinal(_ key: String) -> Int? {
        var n = (0, 0, 0), part = 0
        for b in key.utf8 {
            if b == 45 {
                part += 1
                if part > 2 { return nil }
                continue
            }
            guard b >= 48, b <= 57 else { return nil }
            let v = Int(b - 48)
            switch part {
            case 0: n.0 = n.0 * 10 + v
            case 1: n.1 = n.1 * 10 + v
            default: n.2 = n.2 * 10 + v
            }
        }
        guard part == 2, (1...12).contains(n.1), (1...31).contains(n.2) else { return nil }
        return civilOrdinal(n.0, n.1, n.2)
    }

    /// 그레고리력 날짜 → 일련번호 (H. Hinnant, days_from_civil)
    static func civilOrdinal(_ year: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * ((m + 9) % 12) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// 월 = 0 … 일 = 6 (1970-01-01 은 목요일)
    static func weekday(_ ordinal: Int) -> Int { ((ordinal + 3) % 7 + 7) % 7 }
}
