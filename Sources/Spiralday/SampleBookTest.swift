import AppKit
import SwiftUI
import SpiraldayKit

// MARK: - QA CLI

/// `Spiralday --sample-book-test <dir>` — 앱의 실제 데이터 폴더는 건드리지 않는다. 오늘을 기준으로 예시 플래너를 만들어
///   sample.json                 책 내용 (PlannerData)
///   daily-YYYY-MM-DD.png        14일치 일간 (1277 × 2000, --snapshot 과 같은 PageSnapshotter)
///   daily-YYYY-MM-DD-write.png  DAY OFF 날을 ▾ → 작성하기로 돌렸을 때 (가려 둔 COMMENT)
///   weekly-YYYY-MM-DD.png       겹치는 주 (주 시작 날짜)
///   daily-cover.png · daily-motto.png · weekly-cover.png · weekly-motto.png   책 맨 앞의 표지 · 첫 장
///   home.png                    홈
///   onboarding-ready.png        튜토리얼 마지막 장 (예시 플래너 안내 줄)
///   settings-books*.png         설정 → 플래너 (예시 표시 / 지운 뒤 ‘다시 넣기’)
/// 을 쓰고, <dir>/store-sim 임시 폴더에서 첫 실행 · 1.0.3 에서 업데이트 · 다시 켜기 · 지우기를 흉내 내 확인한다.
@MainActor
enum SampleBookTest {
    private static var failures = 0

    static func run(to dir: URL) async -> Int32 {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath().path.lowercased()
        let target = dir.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        for name in ["spiralday", "paperplanner"] where target == support + "/" + name || target.hasPrefix(support + "/" + name + "/") {
            print("결과 폴더를 앱의 실제 데이터 폴더(~/Library/Application Support) 안에 둘 수 없어요")
            return 2
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let today = Dates.day(Date())
        let (book, data) = PlannerStore.makeSampleBook(today: today)

        // 같은 오늘이면 같은 내용인지
        let again = PlannerStore.makeSampleBook(today: today).data
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let json = try? enc.encode(data) else { print("JSON 로 만들지 못했어요"); return 1 }
        do { try json.write(to: dir.appendingPathComponent("sample.json"), options: .atomic) } catch {
            print("sample.json 을 쓰지 못했어요: \(error.localizedDescription)")
            return 1
        }

        let store = PlannerStore(inMemory: true)
        store.useBook(book, data: data)
        print("예시 플래너: \(book.name) · \(book.periodText) · 표지 \(ColorConcept.of(book.cover).name) · isSample \(book.isSample)")
        check("같은 오늘로 다시 만들면 같은 내용", (try? enc.encode(again)) == json)
        print("저장한 D-day: " + store.ddayLibrary.map { "\($0.title) \(Dates.key($0.date)) (\($0.count(from: today)))" }.joined(separator: " · "))

        var d = book.start
        while d <= today {
            let state = AppState(kind: .daily, today: today)
            state.store = store
            state.dayIndex = Dates.daysBetween(state.baseDay, d)
            render(store, state, .daily, state.dayIndex, dir.appendingPathComponent("daily-\(Dates.key(d)).png"))
            let r = store.day(d)
            // ↳ = 전날 → 에서 넘어온 할 일
            let marks = r.tasks.map { ($0.carriedFrom != nil ? "↳" : "") + sym($0.mark) }.joined()
            let (h, m) = formatHM(store.minutes(d))
            let dd = r.ddays.map { "\($0.title) \($0.count(from: d))" }.joined(separator: ", ")
            let meals = r.notes.filter { $0.kind == .meal }.count, texts = r.notes.filter { $0.kind == .text }.count
            print("\(Dates.key(d)) \(Dates.weekdayEN[Dates.comp(d).weekday!].prefix(3)) 할 일 \(r.tasks.count) [\(marks)] "
                  + "TOTAL \(h)H\(m)M · 밥 \(meals) · 글씨 \(texts) · 컬러 \(r.theme.map { ColorConcept.of($0).name } ?? "기본") · "
                  + "D-day [\(dd)] · COMMENT \(r.comment.isEmpty ? "-" : "‘\(r.comment)’") · MEMO \(r.memos.filter { !$0.isEmpty }.count)"
                  + (r.dayOff ? " · DAY OFF" : ""))
            d = Dates.add(days: 1, to: d)
        }
        // DAY OFF 날을 작성하기로 돌렸을 때: 가려 둔 COMMENT 가 그날 일기로 읽히는지 눈으로 본다 (다른 그림에는 영향 없게 따로)
        for (key, r) in data.days where r.dayOff {
            guard let off = Dates.parse(key) else { continue }
            let write = PlannerStore(inMemory: true)
            write.useBook(book, data: data)
            write.setDayOff(off, false)
            let state = AppState(kind: .daily, today: today)
            state.store = write
            state.dayIndex = Dates.daysBetween(state.baseDay, off)
            render(write, state, .daily, state.dayIndex, dir.appendingPathComponent("daily-\(key)-write.png"))
            check("DAY OFF 를 작성하기로 돌리면 COMMENT 가 그대로 보인다 (\(key) ‘\(write.day(off).comment)’)",
                  !write.isDayOff(off) && !write.day(off).comment.isEmpty && write.day(off).comment == r.comment)
        }
        let found = problems(data, today: today)
        for p in found { print("  · \(p)") }
        check("내용 점검 (오늘): 요일·이야기 순서 · 주간 목표는 그 주 이야기 · → 는 다음 날에 하나 (carriedFrom · 같은 글 · 같은 형광펜 · "
              + "이야기대로 표시) · 넘어온 할 일은 전날 → 에서 · ○ 형광펜은 타임테이블에도 · 오늘은 쓰는 중 (→ 없음) · 오늘 D-day · "
              + "D-day 0/1/2개 날 · 이웃한 날 컬러 다름 · 컬러 5가지 이상 · 주간 목표와 별점 · TOTAL 평일 4–10시간 / 주말 1–3시간 · "
              + "DAY OFF 는 쉬는 날(첫째 주 일요일) 하루만, 가볍게 · 할 일 줄은 15줄 안 · 형광펜끼리 이어서 · 한 줄 비우고 쓴 날", found.isEmpty)
        // 오늘의 요일에 따라 준비 주 · 첫째 주 · 둘째 주에서 잘라 오는 곳이 달라지므로, 요일 7가지 모두 내용만 따로 점검한다
        var rotations: [String] = []
        for k in 1..<7 {
            let other = Dates.add(days: k, to: today)
            let p = problems(PlannerStore.makeSampleBook(today: other).data, today: other)
            if !p.isEmpty { rotations.append("\(Dates.key(other)): " + p.joined(separator: " / ")) }
        }
        for r in rotations { print("  · \(r)") }
        check("내용 점검 (오늘이 다른 요일일 때 6가지도)", rotations.isEmpty)
        // 앱의 setMark 로 → 를 다시 눌러 만든 것과 같은지 (요일 7가지 모두)
        var appDiffs: [String] = []
        for k in 0..<7 {
            let other = Dates.add(days: k, to: today)
            let p = carryMismatches(today: other)
            if !p.isEmpty { appDiffs.append("\(Dates.key(other)): " + p.joined(separator: " / ")) }
        }
        for r in appDiffs { print("  · \(r)") }
        check("→ 넘기기가 앱과 같다 (요일 7가지): 표시를 떼고 앱에서 → 를 다시 누르면 같은 줄에 같은 할 일이 넘어가고, "
              + "그대로 → 를 또 눌러도 늘지 않는다", appDiffs.isEmpty)

        var ws = Dates.weekStart(book.start)
        while ws <= today {
            let state = AppState(kind: .weekly, today: today)
            state.store = store
            state.weekIndex = Dates.daysBetween(state.baseWeek, ws) / 7
            render(store, state, .weekly, state.weekIndex, dir.appendingPathComponent("weekly-\(Dates.key(ws)).png"))
            let w = store.week(ws)
            print("주간 \(Dates.key(ws)) 목표 ‘\(w.goal)’ · 별 \(w.stars) · 돌아보기 ‘\(w.review)’")
            ws = Dates.add(days: 7, to: ws)
        }

        // 책 맨 앞의 표지 · 첫 장 (하고 싶은 말)
        for kind in [PageKind.daily, .weekly] {
            let state = AppState(kind: kind, today: today)
            state.store = store
            for page in FrontPage.allCases {
                render(store, state, kind, state.frontIndex(page, kind),
                       dir.appendingPathComponent("\(kind.rawValue)-\(page == .cover ? "cover" : "motto").png"))
            }
        }
        check("첫 장에 하고 싶은 말이 적혀 있다 (‘\(store.data.prefs.motto.replacingOccurrences(of: "\n", with: " / "))’)",
              store.data.prefs.motto == SampleBook.motto)

        let home = AppState(kind: .home, today: today)
        home.store = store
        render(store, home, .home, 0, dir.appendingPathComponent("home.png"))

        // 튜토리얼 마지막 장: 첫 플래너를 만든 뒤 예시 플래너가 옆에 꽂힌 책장
        let fresh = PlannerStore(inMemory: true)
        fresh.addSampleBook(today: today)
        let draft = OnboardingModel(store: fresh)
        check("예시만 있을 때 튜토리얼은 처음처럼: 플래너 만들기 · ‘내 플래너’ · 체리 표지",
              draft.needsBook && draft.plannerMode == .create && draft.draft.name == BookDraft.defaultName && draft.draft.cover == 0)
        fresh.createBook(name: draft.draft.resolvedName, start: today, end: nil, cover: draft.draft.cover)
        check("튜토리얼에서 만든 책이 펼쳐지고, 예시는 책장 끝에",
              fresh.activeBook?.isSample == false && fresh.books.last?.isSample == true && fresh.userBooks.count == 1)
        let ready = ImageRenderer(content: OnboardingView(model: OnboardingModel(store: fresh, step: .ready))
            .environmentObject(fresh).environmentObject(AppState()))
        ready.scale = 2
        if let img = ready.cgImage { Snapshotter.write(img, dir.appendingPathComponent("onboarding-ready.png")) }

        // 설정 → 플래너: 예시 표시, 지운 뒤 ‘예시 플래너 다시 넣기’
        await renderSettings(fresh, dir.appendingPathComponent("settings-books.png"))
        if let sample = fresh.books.first(where: \.isSample) { fresh.deleteBook(sample.id) }
        await renderSettings(fresh, dir.appendingPathComponent("settings-books-no-sample.png"))
        check("예시를 지우면 ‘다시 넣기’로 새로 꽂히고 펼친 책은 그대로",
              !fresh.hasSampleBook && fresh.addSampleBook(today: today) != nil && fresh.activeBook?.isSample == false)

        simulateStore(in: dir.appendingPathComponent("store-sim"), today: today)
        print(failures == 0 ? "모든 확인 통과" : "확인 실패 \(failures)개")
        print("결과: \(dir.path)")
        return failures == 0 ? 0 : 1
    }

    /// 요일이 어떻게 놓여도 지켜야 할 것. 어긋난 것을 글로 돌려준다 (없으면 빈 배열).
    static func problems(_ data: PlannerData, today now: Date) -> [String] {
        var out: [String] = []
        let today = Dates.day(now)
        let cats = Dictionary(uniqueKeysWithValues: data.prefs.categories.map { ($0.id, $0) })
        let start = Dates.add(days: -(SampleBook.dayCount - 1), to: today)
        let s = SampleBook.firstStoryDay(today: today)
        if !(1...7).contains(s) { out.append("첫날 장 번호 \(s)") }
        if !(s..<(s + SampleBook.dayCount)).contains(SampleBook.dayOffStoryDay) { out.append("쉬는 날이 14일 안에 없음") }
        let storyOff = (0..<SampleBook.storyDayCount).filter { SampleBook.page(storyDay: $0).dayOff }
        if storyOff != [SampleBook.dayOffStoryDay] { out.append("이야기의 DAY OFF 장이 \(storyOff) (dayOffStoryDay 하나여야)") }
        if data.days.count != SampleBook.dayCount { out.append("기록한 날이 \(data.days.count)일 (14일 밖에 넘어간 것)") }
        var previousTheme: Int? = nil
        var carriedCount = 0
        var blankDays = 0
        for i in 0..<SampleBook.dayCount {
            let d = Dates.add(days: i, to: start), k = Dates.key(d)
            guard let r = data.days[k] else { out.append("\(k) 기록 없음"); continue }
            let isToday = i == SampleBook.dayCount - 1
            let weekend = SampleBook.weekday(d) >= 5
            let j = s + i
            // 이야기 순서: 장의 요일 = 날짜의 요일, 오늘 = 둘째 주, 주간 목표 = 그날이 든 이야기 주
            if j % 7 != SampleBook.weekday(d) { out.append("\(k) 요일과 장(\(j))이 어긋남") }
            if isToday && j / 7 != 2 { out.append("오늘이 둘째 주 장이 아님") }
            if data.weeks[Dates.key(Dates.weekStart(d))]?.goal != SampleBook.weeks[j / 7].goal { out.append("\(k) 주간 목표가 그 주 이야기와 어긋남") }
            let minutes = r.slots.filter { cats[$0]?.counts == true }.count * 10
            if j == SampleBook.dayOffStoryDay {
                // 쉬는 날: 할 일은 조금, TOTAL 은 비워 둔다
                if !weekend || isToday { out.append("\(k) 쉬는 날이 주말이 아니거나 오늘") }
                if r.tasks.count > 3 { out.append("\(k) 쉬는 날인데 할 일 \(r.tasks.count)개") }
                if minutes > 0 { out.append("\(k) 쉬는 날인데 TOTAL \(minutes)분") }
            } else {
                if !(3...8).contains(r.tasks.count) { out.append("\(k) 할 일 \(r.tasks.count)개") }
                if weekend ? !(60...180).contains(minutes) : !(240...600).contains(minutes) { out.append("\(k) TOTAL \(minutes)분") }
            }
            // 할 일 줄 (1.0.5): 15줄 안에서 줄 순서대로 겹치지 않게, 같은 형광펜끼리 이어서 (빈 줄은 건너뛰고 본다)
            if !r.taskRowsReady || r.tasks.contains(where: { ($0.row ?? .max) >= DailyForm.taskCount }) {
                out.append("\(k) 할 일 줄이 어긋남 \(r.tasks.map { $0.row ?? -1 })")
            }
            if PlannerStore.grouped(r.tasks) != r.tasks { out.append("\(k) 형광펜끼리 모이지 않음") }
            if let last = r.tasks.last?.row, last + 1 > r.tasks.count { blankDays += 1 }
            if r.comment.isEmpty { out.append("\(k) COMMENT 없음") }
            // → : 앱처럼 다음 날에 이 할 일에서 넘어온 것(carriedFrom = 이 id)이 꼭 하나 — 같은 글 · 같은 형광펜 ·
            // 이야기에서 정한 표시. 오늘은 플래너의 마지막 날이라 앱도 넘기지 않으므로 → 가 없어야 한다.
            let next = data.days[Dates.key(Dates.add(days: 1, to: d))]?.tasks ?? []
            for t in r.tasks where t.mark == .moved {
                if isToday { out.append("오늘 ‘\(t.text)’ 가 → (마지막 날은 넘기지 않음)"); continue }
                let copies = next.filter { $0.carriedFrom == t.id }
                let then = SampleBook.page(storyDay: j).tasks.first { $0.mark == .moved && $0.text == t.text && $0.cat == t.cat }?.then ?? .done
                if copies.count != 1 {
                    out.append("\(k) ‘\(t.text)’ → 가 다음 날에 \(copies.count)개 넘어감")
                } else if let c = copies.first, c.text != t.text || c.cat != t.cat || c.mark != then {
                    out.append("\(k) ‘\(t.text)’ → 복사본이 글 · 형광펜 · 표시(\(sym(then)))와 다름")
                }
                if next.filter({ $0.text == t.text && $0.cat == t.cat }).count != 1 { out.append("\(k) ‘\(t.text)’ 가 다음 날에 겹쳐 있음") }
            }
            // 넘어온 할 일: 전날의 → 할 일(같은 글 · 같은 형광펜)을 가리킨다
            let prev = i > 0 ? data.days[Dates.key(Dates.add(days: -1, to: d))]?.tasks ?? [] : []
            for t in r.tasks where t.carriedFrom != nil {
                carriedCount += 1
                let o = prev.first { $0.id == t.carriedFrom }
                if o?.mark != .moved || o?.text != t.text || o?.cat != t.cat { out.append("\(k) ‘\(t.text)’ 가 전날의 → 할 일에서 넘어오지 않음") }
            }
            // DAY OFF 는 이야기의 쉬는 날 하루만
            if r.dayOff != (j == SampleBook.dayOffStoryDay) { out.append("\(k) DAY OFF 가 \(r.dayOff ? "쉬는 날이 아닌 날에" : "쉬는 날에 없음")") }
            for t in r.tasks where t.mark == .done {
                if let c = t.cat, cats[c]?.counts == true, !r.slots.contains(c) { out.append("\(k) ‘\(t.text)’ ○ 인데 그 색 시간이 없음") }
            }
            // 고르지 않은 날(nil)은 기본 컬러로 보이므로 그것까지 견준다
            let theme = r.theme ?? data.prefs.defaultTheme
            if theme == previousTheme { out.append("\(k) 전날과 같은 컬러") }
            previousTheme = theme
            if r.ddays.contains(where: { $0.date <= today }) { out.append("\(k) 지난 D-day") }
            if isToday {
                if r.tasks.filter({ $0.mark == .none }).count < 2 { out.append("오늘 남은 할 일이 두 개보다 적음") }
                if r.tasks.filter({ $0.mark == .done }).count < 2 { out.append("오늘 끝낸 일이 두 개보다 적음") }
                if r.ddays.isEmpty { out.append("오늘 D-day 없음") }
                if r.slots[SampleBook.slot(SampleBook.todayCutoff)...].contains(where: { $0 >= 0 }) { out.append("오늘 저녁이 칠해져 있음") }
            }
        }
        if carriedCount == 0 { out.append("다음 날로 넘어간 할 일이 없음") }
        if blankDays == 0 { out.append("한 줄 비우고 쓴 날이 없음 (아무 줄에나 쓰는 예시)") }
        if data.days.values.filter(\.dayOff).count != 1 { out.append("DAY OFF 가 \(data.days.values.filter(\.dayOff).count)일") }
        if Set(data.days.values.map(\.ddays.count)) != [0, 1, 2] { out.append("D-day 0/1/2개 날이 다 있지 않음") }
        if Set(data.days.values.compactMap(\.theme)).count < 5 || !data.days.values.contains(where: { $0.theme == nil }) {
            out.append("컬러가 다양하지 않음")
        }
        if data.prefs.ddays.contains(where: { $0.date <= today }) { out.append("저장한 D-day 가 오늘보다 앞") }
        var ws = Dates.weekStart(start)
        while ws <= today {
            let w = data.weeks[Dates.key(ws)]
            if (w?.goal ?? "").isEmpty || (w?.stars ?? 0) == 0 { out.append("주간 \(Dates.key(ws)) 목표·별점 없음") }
            ws = Dates.add(days: 7, to: ws)
        }
        return out
    }

    /// 예시의 → 마다 앱의 PlannerStore.setMark 를 그대로 거쳐 본다. 어긋난 것을 글로 돌려준다.
    ///  1) 예시 그대로 → 를 또 눌러도 다음 날 할 일이 늘지 않는다 (앱이 넘어간 것으로 알아본다)
    ///  2) 넘어간 할 일을 지우고 표시를 뗀 뒤 → 를 누르고, 넘어간 것에 이야기대로 표시하면 예시와 똑같아진다
    ///     (글 · 형광펜 · 표시 · carriedFrom · 줄. 새로 만든 할 일의 id 만 다르다)
    static func carryMismatches(today: Date) -> [String] {
        let (book, data) = PlannerStore.makeSampleBook(today: today)
        func shape(_ days: [String: DayRecord]) -> [String: [String]] {
            days.mapValues { $0.tasks.map { "\($0.text)|\($0.cat ?? -1)|\($0.mark.rawValue)|\($0.carriedFrom?.uuidString ?? "-")|\($0.row ?? -1)" } }
        }
        var out: [String] = []
        let same = PlannerStore(inMemory: true)
        same.useBook(book, data: data)
        let redo = PlannerStore(inMemory: true)
        redo.useBook(book, data: data)
        for key in data.days.keys.sorted() {
            guard let d = Dates.parse(key) else { continue }
            let nextKey = Dates.key(Dates.add(days: 1, to: d))
            for t in data.days[key]?.tasks ?? [] where t.mark == .moved {
                same.setMark(d, t.id, .moved)
                if same.day(Dates.add(days: 1, to: d)).tasks != data.days[nextKey]?.tasks { out.append("\(key) ‘\(t.text)’ 를 또 → 하면 다음 날이 바뀜") }

                guard let copy = data.days[nextKey]?.tasks.first(where: { $0.carriedFrom == t.id }) else {
                    out.append("\(key) ‘\(t.text)’ 넘어간 것이 없음"); continue
                }
                let next = Dates.add(days: 1, to: d)
                redo.editDay(next) { $0.tasks.removeAll { $0.id == copy.id } }
                redo.editDay(d) { r in if let i = r.tasks.firstIndex(where: { $0.id == t.id }) { r.tasks[i].mark = .none } }
                redo.setMark(d, t.id, .moved)
                guard let made = redo.carriedCopy(of: t.id, from: d) else { out.append("\(key) ‘\(t.text)’ 앱이 넘기지 않음"); continue }
                redo.setMark(next, made.id, copy.mark)
            }
        }
        let want = shape(data.days), got = shape(redo.data.days)
        for key in Set(want.keys).union(got.keys).sorted() where want[key] != got[key] {
            out.append("\(key) 앱으로 다시 넘긴 할 일이 예시와 다름: \(got[key] ?? []) ≠ \(want[key] ?? [])")
        }
        return out
    }

    /// 체크 표시 한 글자 (· = 표시 없음)
    private static func sym(_ m: Mark) -> String { ["·", "○", "△", "×", "→"][m.rawValue] }

    private static func check(_ what: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("\(ok ? "✓" : "✗ 실패") \(what)")
    }

    private static func render(_ store: PlannerStore, _ state: AppState, _ kind: PageKind, _ index: Int, _ url: URL) {
        let snap = PageSnapshotter(store: store, state: state)
        if let img = snap.image(kind: kind, index: index, size: kind.design, scale: 1) { Snapshotter.write(img, url) }
    }

    /// 설정 → 플래너 화면을 화면 밖 창에 그려 PNG 로 (Form 은 ImageRenderer 로 그려지지 않는다)
    private static func renderSettings(_ store: PlannerStore, _ url: URL) async {
        let state = AppState()
        state.store = store
        state.fontsReady = true
        // 설정 창을 가장 좁게 줄였을 때의 오른쪽 칸 폭
        let size = CGSize(width: 490, height: 600)
        let host = NSHostingView(rootView: SettingsBooksPanePreview()
            .environmentObject(store).environmentObject(state)
            .frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        }
        w.orderOut(nil)
    }

    /// 임시 폴더를 앱의 저장 폴더처럼 써서, 켤 때마다 하는 일(책장 읽기 → 예시 꽂기)을 흉내 낸다
    private static func simulateStore(in root: URL, today: Date) {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        func launch(_ dir: URL) -> PlannerStore {
            let s = PlannerStore(folder: dir)
            s.seedSampleBookIfNeeded(today: today)
            return s
        }
        func library(_ dir: URL) -> [String: Any] {
            (try? Data(contentsOf: dir.appendingPathComponent("library.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }

        // 1) 처음 설치: 예시만 꽂히고 펼치지 않는다 → 튜토리얼
        let first = root.appendingPathComponent("first-run")
        var s = launch(first)
        check("처음 켜기: 예시 플래너 한 권이 꽂히고 펼치지 않는다 (튜토리얼 필요)",
              s.books.count == 1 && s.hasSampleBook && s.activeBook == nil && s.userBooks.isEmpty)
        check("처음 켜기: 예시 책 파일이 books 폴더에 있다",
              s.books.first.map { fm.fileExists(atPath: first.appendingPathComponent("books/\($0.id.uuidString).json").path) } ?? false)
        // 튜토리얼 도중 끄고 다시 켜도 예시는 한 권, 여전히 튜토리얼
        s = launch(first)
        check("튜토리얼 전에 다시 켜기: 예시는 그대로 한 권, 펼친 책 없음",
              s.books.count == 1 && s.activeBook == nil && s.userBooks.isEmpty)
        s.createBook(name: BookDraft.defaultName, start: today, end: nil)
        s = launch(first)
        check("내 플래너를 만든 뒤 다시 켜기: 내 플래너가 펼쳐지고 예시는 그대로",
              s.activeBook?.name == BookDraft.defaultName && s.books.count == 2 && s.books.last?.isSample == true)
        // 예시를 펼쳐 둔 채 지우면 내 플래너가 펼쳐진다
        if let sample = s.books.first(where: \.isSample) { s.activate(sample.id); s.deleteBook(sample.id) }
        check("펼친 예시를 지우면 내 플래너가 펼쳐진다", s.activeBook?.isSample == false && !s.hasSampleBook)
        s = launch(first)
        check("예시를 지운 뒤 다시 켜기: 다시 꽂지 않는다", !s.hasSampleBook && s.books.count == 1)
        check("library.json 에 sampleSeeded = true", library(first)["sampleSeeded"] as? Bool == true)

        // 2) 1.0.3 에서 업데이트: 쓰던 책은 그대로 펼친 채, 예시가 끝에 한 번 꽂힌다
        let update = root.appendingPathComponent("update-from-1.0.3")
        try? fm.createDirectory(at: update.appendingPathComponent("books"), withIntermediateDirectories: true)
        let oldID = UUID()
        let oldLibrary = """
        {"activeID":"\(oldID.uuidString)","books":[{"cover":1,"created":"2026-01-01T00:00:00Z","id":"\(oldID.uuidString)",\
        "name":"회사 플래너","start":"2026-01-01T00:00:00Z"}]}
        """
        try? oldLibrary.data(using: .utf8)?.write(to: update.appendingPathComponent("library.json"))
        try? #"{"days":{},"weeks":{},"prefs":{"ddaysPerDay":true}}"#.data(using: .utf8)?
            .write(to: update.appendingPathComponent("books/\(oldID.uuidString).json"))
        s = launch(update)
        check("업데이트: 쓰던 책은 그대로 펼쳐 있고 예시가 끝에 꽂힌다",
              s.activeBook?.id == oldID && s.books.count == 2 && s.books.last?.isSample == true && s.books.first?.isSample == false)
        s = launch(update)
        check("업데이트 뒤 다시 켜기: 예시는 한 권뿐", s.books.filter(\.isSample).count == 1)
        let saved = (library(update)["books"] as? [[String: Any]]) ?? []
        check("library.json: 예시 책에만 isSample 이 적힌다",
              saved.filter { $0["isSample"] as? Bool == true }.count == 1 && saved.filter { $0["isSample"] == nil }.count == 1)

        // 3) 읽지 못하는 library.json: 덮어쓰지 않는다
        let broken = root.appendingPathComponent("unreadable-library")
        try? fm.createDirectory(at: broken, withIntermediateDirectories: true)
        let junk = Data("{ 이건 JSON 이 아니에요".utf8)
        try? junk.write(to: broken.appendingPathComponent("library.json"))
        s = launch(broken)
        check("읽지 못하는 library.json 은 그대로 두고 예시를 꽂지 않는다",
              !s.hasSampleBook && (try? Data(contentsOf: broken.appendingPathComponent("library.json"))) == junk)
    }
}
