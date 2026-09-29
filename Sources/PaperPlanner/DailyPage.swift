import SwiftUI

/// 일간 페이지 (디자인 1277 × 2000). 인쇄된 양식(DailyFormPrint) 위에 손글씨·펜·형광펜을 올린다.
struct DailyPage: View {
    let date: Date
    let u: CGFloat

    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState

    @State private var editingDDay = false

    private typealias F = DailyForm

    private var concept: ColorConcept { store.concept(date) }

    var body: some View {
        let day = store.day(date)
        ZStack(alignment: .topLeading) {
            DailyFormPrint(u: u)

            // DATE · D-DAY 칸 (양식 위 여백)
            dateField
                .place(F.dateBox, u)
            ddayField
                .place(F.ddayBox, u)

            comment
                .place(F.commentBox.inset(top: 16, left: 16, bottom: 10, right: 16), u)
            TotalTime(minutes: store.minutes(date), color: concept.accent, u: u)
                .place(F.totalBox, u)

            ForEach(0..<F.taskCount, id: \.self) { i in
                taskRow(i, day.tasks)
            }
            ForEach(0..<F.memoCount, id: \.self) { i in
                memoRow(i)
            }

            SlotPainter(date: date, cellW: F.cell * u, rowH: F.hourPitch * u)
                .offset(x: F.slotsLeft * u, y: F.gridTop * u)
        }
        .frame(width: PageKind.daily.design.width * u, height: PageKind.daily.design.height * u, alignment: .topLeading)
    }

    // MARK: DATE · D-DAY

    /// "20260929 TUE" — 칸 한가운데에 크게 손으로 쓴 날짜, 아래에 컨셉 색 형광펜
    private var dateField: some View {
        let c = Dates.comp(date)
        let wd = String(Dates.weekdayEN[c.weekday!].prefix(3))
        let digits = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        return (Text(digits).foregroundStyle(Ink.text) + Text(" " + wd).foregroundStyle(concept.accent))
            .font(Fonts.hand(86 * u))
            .tracking(2 * u)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .background(alignment: .bottom) {
                HighlighterBar(color: concept.tint)
                    .frame(height: 24 * u)
                    .padding(.horizontal, -10 * u)
                    .offset(y: -4 * u)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }

    /// D-day 최대 2개. 1개면 칸 한가운데, 2개면 위아래로 나눠 가운데.
    private var ddayField: some View {
        let list = store.data.prefs.ddays
        let two = list.count > 1
        return VStack(spacing: (two ? 2 : 0) * u) {
            if list.isEmpty {
                Text("+ D-day")
                    .font(Fonts.hand(46 * u))
                    .foregroundStyle(Ink.faint)
            }
            ForEach(list) { d in
                let n = Dates.daysBetween(date, d.date)
                HStack(alignment: .firstTextBaseline, spacing: 14 * u) {
                    Text(d.title.isEmpty ? "D-day" : d.title)
                        .font(Fonts.hand((two ? 38 : 48) * u))
                        .foregroundStyle(Ink.text)
                    Text(n > 0 ? "D-\(n)" : n == 0 ? "D-DAY" : "D+\(-n)")
                        .font(Fonts.hand((two ? 46 : 64) * u))
                        .foregroundStyle(concept.accent)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            }
        }
        .padding(.horizontal, 10 * u)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { editingDDay = true }
        .popover(isPresented: $editingDDay, arrowEdge: .bottom) { DDayEditor().environmentObject(store) }
        .help("D-day 설정 (최대 2개)")
    }

    // MARK: COMMENT

    private var comment: some View {
        InlineField(text: store.dayField(date, \.comment), font: Fonts.hand(50 * u),
                    key: "c|\(Dates.key(date))", lines: 3, alignment: .center)
    }

    // MARK: TASKS

    private func taskKey(_ i: Int) -> String { "t|\(Dates.key(date))|\(i)" }

    @ViewBuilder
    private func taskRow(_ i: Int, _ tasks: [PlanTask]) -> some View {
        let row = F.taskRow(i)
        let task = i < tasks.count ? tasks[i] : nil
        let cat = store.category(task?.cat)

        // 같은 형광펜이 이어지는 묶음의 첫 줄에만 카테고리 이름 + 그 색으로 칠한 시간
        if let task, let cat, i == 0 || tasks[i - 1].cat != task.cat {
            CategoryTag(name: cat.name, minutes: store.minutes(date, cat: cat.id), color: concept.accent, u: u)
                .place(CGRect(x: F.left + 6, y: row.minY + 3, width: F.categoryX - F.left - 12, height: row.height - 6), u)
        }

        // 입력 중 첫 글자로 할 일이 생겨도 같은 필드가 유지되도록 구조를 바꾸지 않는다
        InlineField(
            text: store.taskText(date, i, defaultCat: { [state] in state.tool >= 0 ? state.tool : nil }),
            font: Fonts.hand(46 * u),
            key: taskKey(i),
            tapKey: task == nil ? taskKey(tasks.count) : nil,
            highlight: cat?.color,
            strike: task?.mark == .done ? concept.accent : nil,
            onSubmit: { [state] in
                if i + 1 < F.taskCount { state.editingKey = taskKey(i + 1) } else { state.endEditing() }
            },
            onEnd: { [store, date] in store.cleanup(date) }
        )
        .padding(.top, 5 * u)
        .place(CGRect(x: F.categoryX + 16, y: row.minY, width: F.boxMinX - 14 - (F.categoryX + 16), height: row.height), u)
        .contextMenu {
            if let task { TaskMenu(date: date, task: task) }
        }

        // 인쇄된 점선 체크 박스 한가운데에 펜 표시
        if let task {
            MarkButton(mark: task.mark, size: 42 * u, color: concept.accent, lineWidth: 5.6 * u, showsPlaceholder: false) {
                store.cycleMark(date, task.id)
            }
            .position(x: F.boxMidX * u, y: F.box(i).midY * u)
        }
    }

    // MARK: MEMO

    /// 왼쪽 작은 칸(꼬리표) + 본문
    @ViewBuilder
    private func memoRow(_ i: Int) -> some View {
        let row = F.memoRow(i)
        let key = Dates.key(date)
        InlineField(text: store.memoTag(date, i), font: Fonts.hand(34 * u), key: "mt|\(key)|\(i)",
                    alignment: .center)
            .padding(.top, 4 * u)
            .place(CGRect(x: F.left + 4, y: row.minY, width: F.categoryX - F.left - 8, height: row.height), u)
        InlineField(text: store.memo(date, i), font: Fonts.hand(46 * u), key: "m|\(key)|\(i)")
            .padding(.top, 5 * u)
            .place(CGRect(x: F.categoryX + 16, y: row.minY, width: F.leftEnd - 12 - (F.categoryX + 16),
                          height: row.height), u)
    }
}

// MARK: - TOTAL TIME

/// 타임테이블에서 칠한 시간의 합 (휴식·개인처럼 집계하지 않는 색은 빼고). 빨간 스탬프 숫자 "8H36M".
private struct TotalTime: View {
    let minutes: Int
    let color: Color
    let u: CGFloat

    var body: some View {
        let (h, m) = formatHM(minutes)
        let zero = minutes == 0
        let digits = Fonts.rounded(98 * u, .black)
        let unit = Fonts.rounded(50 * u, .black)
        (Text(h).font(digits) + Text("H").font(unit) + Text(m).font(digits) + Text("M").font(unit))
            .kerning(-1.5 * u)
            .monospacedDigit()
            .foregroundStyle(zero ? color.opacity(0.12) : color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText(value: Double(minutes)))
            .animation(.snappy(duration: 0.28), value: minutes)
            .padding(.horizontal, 18 * u)
            .padding(.top, 6 * u)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}

// MARK: - Category tag (TASKS 왼쪽 칸)

private struct CategoryTag: View {
    let name: String
    let minutes: Int
    let color: Color
    let u: CGFloat

    var body: some View {
        VStack(spacing: -3 * u) {
            Text(name)
                .font(Fonts.hand(37 * u))
                .foregroundStyle(Ink.text)
            if minutes > 0 {
                let (h, m) = formatHM(minutes)
                Text("\(h)H\(m)M")
                    .font(Fonts.rounded(18.5 * u, .heavy))
                    .foregroundStyle(color)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

// MARK: - Layout helpers

private extension CGRect {
    func inset(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) -> CGRect {
        CGRect(x: minX + left, y: minY + top, width: width - left - right, height: height - top - bottom)
    }
}

private extension View {
    /// 디자인 좌표의 사각형에 그대로 놓는다 (부모는 topLeading ZStack)
    func place(_ r: CGRect, _ u: CGFloat) -> some View {
        frame(width: r.width * u, height: r.height * u, alignment: .topLeading)
            .offset(x: r.minX * u, y: r.minY * u)
    }
}
