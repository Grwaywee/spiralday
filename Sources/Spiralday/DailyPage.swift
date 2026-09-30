import SwiftUI

/// 일간 페이지 (디자인 1277 × 2000). 인쇄된 양식(DailyFormPrint) 위에 손글씨·펜·형광펜을 올린다.
struct DailyPage: View {
    let date: Date
    let u: CGFloat

    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.isPrinting) private var isPrinting

    @State private var editingDDay = false

    private typealias F = DailyForm

    private var concept: ColorConcept { store.concept(date) }

    var body: some View {
        let day = store.day(date)
        let tasksL = F.taskLayout(day.tasks)
        let memoL = memoLayout(day)
        ZStack(alignment: .topLeading) {
            DailyFormPrint(u: u, taskRows: tasksL.rows, memoRows: memoL.rows, commentMenu: reservesCommentMenu)

            // DATE · D-DAY 칸 (양식 위 여백)
            dateField
                .place(F.dateBox.inset(top: 16, left: 16, bottom: 10, right: 16), u)
            ddayField
                .place(F.ddayBox.inset(top: 16, left: 16, bottom: 10, right: 16), u)

            if day.dayOff {
                DayOffStamp(color: concept.accent, u: u)
                    .place(F.commentBox, u)
            } else {
                comment
                    .place(F.commentBox.inset(top: 16, left: 16, bottom: 10, right: 16), u)
            }
            // COMMENT ▾ : 작성하기 · DAY OFF (화면에서만 누를 수 있다. PDF 에는 없다)
            if showsCommentMenu {
                CommentModeMenu(date: date, u: u)
                    .place(CommentModeMenu.rect, u)
            } else if reservesCommentMenu {
                // 넘김 스냅샷: 같은 자리에 누를 수 없는 ▾ 만 (넘기는 동안 ▾ 와 머리선이 움직이지 않게)
                DownTriangle()
                    .fill(Ink.print)
                    .place(CommentModeMenu.arrowRect, u)
            }
            TotalTime(minutes: store.minutes(date), color: concept.accent, u: u)
                .place(F.totalBox.inset(top: 16, left: 16, bottom: 10, right: 16), u)

            tasksView(day.tasks, tasksL)
            memosView(day, memoL)

            SlotPainter(date: date, cellW: F.cell * u, rowH: F.hourPitch * u)
                .offset(x: F.slotsLeft * u, y: F.gridTop * u)

            // 오른쪽 아래 워드마크: 누르면 spiralday.com
            if !isSnapshot {
                WordmarkLink()
                    .place(CGRect(x: F.wordmarkRight - 190, y: F.wordmarkBaseline - 36, width: 196, height: 48), u)
            }
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

    /// 이 날에 붙인 D-day (최대 2개). 1개면 칸 한가운데, 2개면 위아래로 나눠 가운데. 숫자는 이 날에서 센다.
    private var ddayField: some View {
        let list = store.ddays(date)
        let two = list.count > 1
        return VStack(spacing: (two ? 2 : 0) * u) {
            // 빈 칸 안내 글씨는 화면에서만 (PDF 에는 찍지 않는다)
            if list.isEmpty && !isPrinting {
                Text("+ D-day")
                    .font(Fonts.hand(46 * u))
                    .foregroundStyle(Ink.faint)
            }
            ForEach(list) { d in
                HStack(alignment: .firstTextBaseline, spacing: 14 * u) {
                    Text(d.title.isEmpty ? "D-day" : d.title)
                        .font(Fonts.hand((two ? 38 : 48) * u))
                        .foregroundStyle(Ink.text)
                    Text(d.count(from: date))
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
        .popover(isPresented: $editingDDay, arrowEdge: .bottom) { DDayEditor(date: date).environmentObject(store) }
        .help("이 날의 D-day — 저장한 D-day 를 고르거나 새로 만들어 붙여요 (최대 \(Prefs.maxDDays)개)")
    }

    // MARK: COMMENT

    /// ▾ 자리를 비운다: 화면과 넘김 스냅샷은 같은 모양 (PDF 는 인쇄 양식 그대로)
    private var reservesCommentMenu: Bool { !isPrinting }
    /// 누를 수 있는 ▾ 메뉴는 화면에서만
    private var showsCommentMenu: Bool { reservesCommentMenu && !isSnapshot }

    private static let commentFont: CGFloat = 50
    private var commentRect: CGRect { F.commentBox.inset(top: 16, left: 16, bottom: 10, right: 16) }

    /// 가운데 정렬. 글이 길어지면 상자 안에 다 들어가도록 글자가 조금씩 작아진다.
    private var comment: some View {
        let text = store.day(date).comment
        let r = commentRect
        let sc = RuledText.fitScale(text, fontSize: Self.commentFont, width: r.width - 16,
                                    height: r.height - 6, maxLines: 99)
        return InlineField(text: store.dayField(date, \.comment), font: Fonts.hand(Self.commentFont * sc * u),
                           key: "c|\(Dates.key(date))", lines: 8, alignment: .center)
    }

    // MARK: TASKS
    // 1.0.5: 할 일은 아무 줄에나 쓰고 (누른 줄에 그대로 남는다), 형광펜(분류)은 다 쓴 뒤에 그 할 일의 왼쪽 칸을 눌러 고른다.
    // 오른쪽 팔레트의 펜은 타임테이블을 칠할 때만 쓴다.

    private func taskKey(_ id: UUID) -> String { AppState.taskKey(date, id) }

    /// 빈 줄을 누르면: 그 줄에 새 할 일을 만들고 바로 쓰기 (형광펜은 나중에 왼쪽 칸에서)
    private func startTask(at row: Int) {
        state.editingKey = taskKey(store.addTask(date, row: row))
    }

    @ViewBuilder
    private func tasksView(_ tasks: [PlanTask], _ L: RuledText.RowLayout) -> some View {
        let p = F.taskPitch(L.rows)
        // 빈 줄: 누르면 그 줄에 새 할 일
        ForEach(L.emptyRows, id: \.self) { r in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { startTask(at: r) }
                .place(CGRect(x: F.taskTextX, y: F.gridTop + CGFloat(r) * p, width: F.taskTextWidth, height: p), u)
        }
        ForEach(Array(tasks.enumerated()), id: \.element.id) { k, _ in
            if k < L.items.count { taskEntry(k, tasks, L) }
        }
    }

    @ViewBuilder
    private func taskEntry(_ k: Int, _ tasks: [PlanTask], _ L: RuledText.RowLayout) -> some View {
        let p = F.taskPitch(L.rows)
        let sc = L.scale
        let task = tasks[k]
        let item = L.items[k]
        let cat = store.category(task.cat)
        let r0 = item.row
        let id = task.id
        let key = taskKey(id)

        // 형광펜 이름: 바로 윗줄의 할 일과 형광펜이 다르거나 윗줄이 비었을 때만 (같은 형광펜이 이어지면 묶음처럼 첫 줄에만)
        if let cat, L.owner(r0 - 1).map({ store.category(tasks[$0].cat)?.id != cat.id }) ?? true {
            CategoryTag(name: cat.name, u: u * sc)
                .place(CGRect(x: F.left + 6, y: F.gridTop + CGFloat(r0) * p + 3 * sc, width: F.categoryX - F.left - 12,
                              height: p - 6 * sc), u)
        }
        // 왼쪽 칸: 누르면 형광펜(분류) 메뉴. 화면에서만 (넘김 스냅샷 · PDF 에는 없다)
        if !isSnapshot {
            TaskCategoryCell(date: date, taskID: id, hint: Fonts.hand(30 * sc * u), cornerRadius: 6 * u)
                .place(CGRect(x: F.left + 3, y: F.gridTop + CGFloat(r0) * p + 3 * sc, width: F.categoryX - F.left - 7,
                              height: CGFloat(item.span) * p - 6 * sc), u)
        }

        RuledEntry(
            text: store.taskText(date, id: id),
            lines: item.lines, key: key, fontSize: F.taskFont * sc * item.fit, pitch: p, u: u,
            // 형광펜은 끝낸(○) 일에만, 그 할 일의 형광펜 색으로 긋는다 (형광펜이 없으면 긋지 않는다)
            highlight: task.mark == .done ? cat?.color : nil,
            // Return: 바로 아랫줄이 비었으면 거기에 새 할 일 (같은 형광펜), 할 일이 있으면 그 할 일로
            onSubmit: { [store, state, date] in Self.submitTask(store, state, date, id) },
            onEnd: { [store, state, date] in store.cleanup(date, keep: state.editingTaskID(on: date)) },
            // ↑ ↓ : 윗줄 / 아랫줄로 (빈 줄이면 거기에 새 할 일)
            canMoveLine: { [store, state, date] down in
                state.editingKey == AppState.taskKey(date, id) && Self.caretAtEdge(store, date, id, down: down)
            },
            moveLine: { [store, state, date] down in Self.moveLine(store, state, date, id, down: down) }
        )
        .place(CGRect(x: F.taskTextX, y: F.gridTop + CGFloat(r0) * p, width: F.taskTextWidth,
                      height: CGFloat(item.span) * p), u)
        .contextMenu {
            if state.editingKey != key { TaskMenu(date: date, task: task) }
        }

        // 첫 줄의 인쇄된 점선 체크 박스 한가운데에 펜 표시
        let box = F.box(r0, rows: L.rows)
        MarkButton(mark: task.mark, size: box.width * 0.98 * u, color: concept.accent,
                   lineWidth: 5.6 * sc * u, showsPlaceholder: false) {
            store.cycleMark(date, id)
        }
        .position(x: box.midX * u, y: box.midY * u)
    }

    /// Return: 이 할 일이 쓰는 줄 바로 아래가 비었으면 그 줄에 새 할 일 (형광펜이 있으면 같은 형광펜),
    /// 다른 할 일이 있으면 그 할 일을 이어서 쓴다. 맨 아랫줄이면 쓰기를 마친다.
    private static func submitTask(_ store: PlannerStore, _ state: AppState, _ date: Date, _ id: UUID) {
        let day = store.day(date)
        guard let k = day.tasks.firstIndex(where: { $0.id == id }) else { state.endEditing(); return }
        let L = day.taskLayout
        let next = L.items[k].row + L.items[k].span
        // 맨 아랫줄에서도 글이 있으면 한 줄 더 (칸이 하나 늘고 줄 간격이 조금 줄어든다)
        guard next < L.rows || (next == L.rows && !day.tasks[k].text.isEmpty) else { state.endEditing(); return }
        if next < L.rows, let o = L.owner(next) {
            state.editingKey = AppState.taskKey(date, day.tasks[o].id)
        } else {
            state.editingKey = AppState.taskKey(date, store.addTask(date, row: next, cat: day.tasks[k].cat))
        }
    }

    /// ↑ ↓ 로 줄을 옮겨도 되는지: 긴 할 일 안에서는 글자 커서가 첫 줄(↑) / 마지막 줄(↓)에 있을 때만,
    /// 그리고 옮겨 갈 줄이 있을 때만 (맨 윗줄에서 ↑, 맨 아랫줄에서 ↓ 는 글상자에 맡긴다).
    private static func caretAtEdge(_ store: PlannerStore, _ date: Date, _ id: UUID, down: Bool) -> Bool {
        let day = store.day(date)
        guard let k = day.tasks.firstIndex(where: { $0.id == id }) else { return false }
        let L = day.taskLayout
        let item = L.items[k]
        let target = down ? item.row + item.span : item.row - 1
        guard target >= 0, target < L.rows else { return false }
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return true }
        let ranges = RuledText.lineRanges(tv.string, fontSize: F.taskFont * L.scale * item.fit, width: F.taskWrapWidth)
        let caret = tv.selectedRange().location
        let line = ranges.lastIndex { $0.location <= caret } ?? 0
        return down ? line >= ranges.count - 1 : line == 0
    }

    /// ↑ : 이 할 일 바로 윗줄, ↓ : 이 할 일이 쓰는 줄 바로 아랫줄. 그 줄을 쓰는 할 일이 있으면 그 할 일을,
    /// 비어 있으면 그 줄에 새 할 일(형광펜 없이)을 쓴다. 아무것도 쓰지 않고 떠나면 빈 할 일은 지워진다.
    private static func moveLine(_ store: PlannerStore, _ state: AppState, _ date: Date, _ id: UUID, down: Bool) {
        let day = store.day(date)
        guard let k = day.tasks.firstIndex(where: { $0.id == id }) else { return }
        let L = day.taskLayout
        let item = L.items[k]
        let target = down ? item.row + item.span : item.row - 1
        guard target >= 0, target < L.rows else { return }
        if let o = L.owner(target) {
            state.editingKey = AppState.taskKey(date, day.tasks[o].id)
        } else {
            state.editingKey = AppState.taskKey(date, store.addTask(date, row: target))
        }
    }

    // MARK: MEMO

    private static let memoFont: CGFloat = 46
    private var memoTextRect: (x: CGFloat, width: CGFloat) { (F.categoryX + 16, F.leftEnd - 12 - (F.categoryX + 16)) }

    /// 끝에 붙은 빈 메모는 칸으로만 남긴다
    private func memoCount(_ d: DayRecord) -> Int {
        var n = 0
        for i in 0..<max(d.memos.count, d.memoTags.count) {
            let m = i < d.memos.count ? d.memos[i] : ""
            let t = i < d.memoTags.count ? d.memoTags[i] : ""
            if !m.isEmpty || !t.isEmpty { n = i + 1 }
        }
        return n
    }

    private func memoKey(_ i: Int) -> String { "m|\(Dates.key(date))|\(i)" }

    private func memoLayout(_ d: DayRecord) -> RuledText.Layout {
        let n = memoCount(d)
        var items = (0..<n).map { $0 < d.memos.count ? d.memos[$0] : "" }
        if let k = state.editingKey, k == memoKey(n) || k == "mt|\(Dates.key(date))|\(n)" { items.append("") }
        return RuledText.layout(items, minRows: F.memoCount, fontSize: Self.memoFont, width: memoTextRect.width - 12)
    }

    /// 왼쪽 작은 칸(꼬리표) + 본문. 본문이 길면 아래 칸으로 이어진다.
    @ViewBuilder
    private func memosView(_ d: DayRecord, _ L: RuledText.Layout) -> some View {
        let p = F.memoPitch(L.rows)
        let sc = L.scale
        let dk = Dates.key(date)
        ForEach(0..<L.lines.count, id: \.self) { i in
            let r0 = L.start[i]
            InlineField(text: store.memoTag(date, i), font: Fonts.hand(34 * sc * u), key: "mt|\(dk)|\(i)",
                        alignment: .center)
                .padding(.top, 4 * sc * u)
                .place(CGRect(x: F.left + 4, y: F.memoTop + CGFloat(r0) * p, width: F.categoryX - F.left - 8, height: p), u)
            RuledEntry(text: store.memo(date, i), lines: L.lines[i], key: memoKey(i),
                       fontSize: Self.memoFont * sc, pitch: p, u: u,
                       onSubmit: { [state] in state.editingKey = memoKey(i + 1) })
                .place(CGRect(x: memoTextRect.x, y: F.memoTop + CGFloat(r0) * p, width: memoTextRect.width,
                              height: CGFloat(L.lines[i].count) * p), u)
        }
        ForEach(L.used..<L.rows, id: \.self) { r in
            let n = memoCount(d)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { state.editingKey = memoKey(n) }
                .place(CGRect(x: memoTextRect.x, y: F.memoTop + CGFloat(r) * p, width: memoTextRect.width, height: p), u)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { state.editingKey = "mt|\(dk)|\(n)" }
                .place(CGRect(x: F.left + 4, y: F.memoTop + CGFloat(r) * p, width: F.categoryX - F.left - 8, height: p), u)
        }
    }
}

/// 인쇄된 워드마크 위의 투명한 링크
private struct WordmarkLink: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { Links.open(Links.website) }
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.pointingHand.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .help("spiralday.com 열기")
    }
}

// MARK: - Ruled entry (여러 칸에 걸쳐 쓰는 한 항목)

/// 인쇄된 줄 여러 개에 걸쳐 쓴 손글씨 한 항목.
/// 보기: 줄마다 따로 (형광펜·완료 줄도 줄마다). 편집: 같은 줄 간격의 여러 줄 입력칸.
private struct RuledEntry: View {
    @Binding var text: String
    let lines: [String]
    let key: String
    /// 디자인 단위 글자 크기 / 줄 간격
    let fontSize: CGFloat
    let pitch: CGFloat
    let u: CGFloat
    var highlight: Color? = nil
    var strike: Color? = nil
    var onSubmit: (() -> Void)? = nil
    var onEnd: (() -> Void)? = nil
    /// 쓰는 중에 ↑ ↓ 로 윗줄 / 아랫줄로 옮기기 (할 일). canMoveLine 이 false 면 키는 글상자가 받는다.
    var canMoveLine: (@MainActor (_ down: Bool) -> Bool)? = nil
    var moveLine: (@MainActor (_ down: Bool) -> Void)? = nil

    @EnvironmentObject private var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let lh = RuledText.lineHeight(fontSize: fontSize)
        // 글자 줄을 인쇄된 칸 가운데보다 살짝 아래(줄 위에 얹히게)
        let top = max(0, (pitch - lh) / 2 + fontSize * 0.09)
        if state.editingKey == key && !isSnapshot {
            InlineField(text: $text, font: Fonts.hand(fontSize * u), key: key, lines: max(lines.count, 1) + 1,
                        lineSpacing: max(0, (pitch - lh) * u), onSubmit: onSubmit, onEnd: onEnd)
                .padding(.top, top * u)
                .background {
                    if let canMoveLine, let moveLine { LineKeyMonitor(canMove: canMoveLine, move: moveLine) }
                }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(Fonts.hand(fontSize * u))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                        .fixedSize()
                        .background {
                            if let highlight, !line.isEmpty {
                                HighlighterBar(color: highlight)
                                    .padding(.horizontal, -4 * u)
                                    .padding(.top, 3 * u)
                                    .padding(.bottom, 1 * u)
                            }
                        }
                        .overlay { if let strike, !line.isEmpty { StrikeLine(color: strike) } }
                        .padding(.top, top * u)
                        .frame(maxWidth: .infinity, minHeight: pitch * u, maxHeight: pitch * u, alignment: .topLeading)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { state.editingKey = key }
        }
    }
}

/// 할 일을 쓰는 동안 ↑ ↓ 를 글상자보다 먼저 받는다. canMove 가 true 면 키를 먹고 줄을 옮긴다.
/// 한글을 조합하는 중이면 키를 글상자로 흘려 보내 조합을 끝내게 하고 (마지막 글자가 남도록) 줄은 바로 뒤에 옮긴다.
private struct LineKeyMonitor: View {
    let canMove: @MainActor (_ down: Bool) -> Bool
    let move: @MainActor (_ down: Bool) -> Void
    @State private var box = LineKeyMonitorBox()

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onAppear { box.install(canMove: canMove, move: move) }
            .onDisappear { box.remove() }
    }
}

@MainActor
private final class LineKeyMonitorBox {
    private var token: Any?

    func install(canMove: @escaping @MainActor (Bool) -> Bool, move: @escaping @MainActor (Bool) -> Void) {
        remove()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // ↓ 125 · ↑ 126, 다른 키를 함께 누르지 않았을 때만
            let code = e.keyCode
            guard code == 125 || code == 126,
                  e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return e }
            let down = code == 125
            let eat: Bool = MainActor.assumeIsolated {
                guard canMove(down) else { return false }
                if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true {
                    Task { @MainActor in move(down) }
                    return false
                }
                move(down)
                return true
            }
            return eat ? nil : e
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

// MARK: - COMMENT ▾ (작성하기 · DAY OFF)

/// 인쇄된 COMMENT 라벨 바로 뒤의 작은 ▾. 누르면 작성하기 / DAY OFF 를 고른다 (지금 것에 체크).
/// 라벨과 ▾ 를 함께 누를 수 있다. 화면에서만 누를 수 있고 (넘김 스냅샷에는 같은 자리에 ▾ 모양만, PDF 에는 없다),
/// 그 자리만큼 양식의 머리선이 뒤로 물러난다 (DailyFormPrint.commentMenu).
private struct CommentModeMenu: View {
    let date: Date
    let u: CGFloat

    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @State private var hover = false

    private typealias F = DailyForm

    /// 누르는 자리 (디자인 단위): 라벨 앞부터 ▾ 뒤까지, 머리선 위아래로 조금
    static var rect: CGRect {
        CGRect(x: F.left - 6, y: F.headerY - 19, width: F.commentLabelEnd + 30 - (F.left - 6), height: 34)
    }
    /// ▾ 크기와 가운데 (디자인 단위). 라벨 대문자의 가운데 높이 (DailyFormPrint: 머리선 + 0.5)
    static let arrowSize = CGSize(width: 13, height: 8)
    static var arrowCenter: CGPoint { CGPoint(x: F.commentLabelEnd + 12.5, y: F.headerY + 0.5) }
    /// ▾ 가 그려지는 자리 (디자인 단위). 넘김 스냅샷의 누를 수 없는 ▾ 도 여기에 그린다.
    static var arrowRect: CGRect {
        CGRect(x: arrowCenter.x - arrowSize.width / 2, y: arrowCenter.y - arrowSize.height / 2,
               width: arrowSize.width, height: arrowSize.height)
    }

    var body: some View {
        let off = store.day(date).dayOff
        let accent = store.concept(date).accent
        Menu {
            Picker("COMMENT", selection: Binding(get: { store.isDayOff(date) },
                                                 set: { v in state.endEditing(); store.setDayOff(date, v) })) {
                Text("작성하기").tag(false)
                Text("DAY OFF").tag(true)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6 * u)
                    .fill(Ink.pen.opacity(hover ? 0.08 : 0))
                DownTriangle()
                    .fill(hover ? accent : Ink.print)
                    .frame(width: Self.arrowSize.width * u, height: Self.arrowSize.height * u)
                    .offset(x: (Self.arrowCenter.x - Self.arrowSize.width / 2 - Self.rect.minX) * u,
                            y: (Self.arrowCenter.y - Self.arrowSize.height / 2 - Self.rect.minY) * u)
            }
            .frame(width: Self.rect.width * u, height: Self.rect.height * u, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
        .onDisappear { if hover { NSCursor.arrow.set() } }
        .help(off ? "쉬는 날 (DAY OFF) — 눌러서 작성하기로 돌아가요. 적어 둔 COMMENT 는 그대로 있어요"
                  : "COMMENT — 눌러서 DAY OFF(쉬는 날)로 바꿀 수 있어요")
    }
}

/// 아래를 향한 작은 삼각형 (▾)
private struct DownTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// DAY OFF: COMMENT 칸 한가운데에 그날 컬러로 크게. TOTAL TIME 과 같은 둥근 굵은 스탬프 글자.
/// 칸 크기에 맞춰 u 로 함께 커지고 줄어든다. 누르는 자리가 아니라서 COMMENT 편집이 열리지 않는다.
private struct DayOffStamp: View {
    let color: Color
    let u: CGFloat

    var body: some View {
        Text("DAY OFF")
            .font(Fonts.rounded(96 * u, .black))
            .kerning(2 * u)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .padding(.horizontal, 24 * u)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 둥근 글꼴은 줄 상자의 아래(내림) 몫이 커서, 대문자 가운데를 칸 가운데에 맞추려고 조금 올린다
            .offset(y: -2.5 * u)
            .allowsHitTesting(false)
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
    let u: CGFloat

    var body: some View {
        Text(name)
            .font(Fonts.hand(37 * u))
            .foregroundStyle(Ink.text)
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
