import SwiftUI
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var kind: PageKind
    @Published var weekIndex = 0
    @Published var dayIndex = 0
    @Published var editingKey: String? = nil
    /// 형광펜 카테고리 id, 또는 아래 특수 도구
    @Published var tool = 0
    static let eraser = -1
    static let textTool = -2
    static let mealTool = -3
    @Published var fontsReady = false
    /// 주간 ↔ 일간 전환으로 창 비율이 바뀌는 중
    @Published var morphing = false

    let curl = CurlController()
    /// 숫자 키로 형광펜을 고를 때 순서 → id 변환용, 펼친 책의 범위
    weak var store: PlannerStore? {
        didSet { bindStore() }
    }
    private var bookWatch: AnyCancellable?
    private var frontWatch: AnyCancellable?
    let baseDay: Date
    let baseWeek: Date

    /// 창 컨트롤러가 주입: 창 비율 전환 애니메이션. apply() 를 적절한 시점에 호출해야 한다.
    var kindTransition: ((_ to: PageKind, _ apply: @escaping () -> Void) -> Void)?
    /// 페이지/데이터가 바뀌었을 때 (창 제목, 스냅샷 미리 그리기 등)
    var onPageChange: (() -> Void)?

    private var monitors: [Any] = []
    private var swipeActive = false

    init(kind: PageKind = .daily, today: Date = Date()) {
        self.kind = kind
        baseDay = Dates.day(today)
        baseWeek = Dates.weekStart(today)
        curl.edge = kind.edge
        curl.willBegin = { [weak self] in self?.endEditing() }
        curl.commit = { [weak self] delta in self?.step(delta) }
    }

    // MARK: book range (시작일 이전 / 종료일 이후로는 넘어가지 않는다)

    private var book: BookInfo? { store?.activeBook }

    var dayRange: ClosedRange<Int> {
        guard let b = book else { return -100_000...100_000 }
        let lo = Dates.daysBetween(baseDay, b.start)
        let hi = b.end.map { Dates.daysBetween(baseDay, $0) } ?? 100_000
        return lo...max(lo, hi)
    }

    var weekRange: ClosedRange<Int> {
        guard let b = book else { return -20_000...20_000 }
        let lo = Dates.daysBetween(baseWeek, Dates.weekStart(b.start)) / 7
        let hi = b.end.map { Dates.daysBetween(baseWeek, Dates.weekStart($0)) / 7 } ?? 20_000
        return lo...max(lo, hi)
    }

    // MARK: front pages (책의 첫 장보다 앞: 표지 → 첫 장 → 첫 날/첫 주)
    // 앞 장은 첫 장 바로 앞의 번호를 쓴다 (일간: 첫날 −2 = 표지, −1 = 첫 장 / 주간: 첫 주 기준 같은 식).
    // 그래서 넘기기·모서리 끌기·스와이프·페이지 넘김 스냅샷이 모두 번호 하나로 그대로 동작한다.

    /// 앞 장이 있는지 (펼친 책이 있을 때만)
    var hasFront: Bool { book != nil }

    /// k 쪽(일간/주간)에서 그 앞 장의 번호
    func frontIndex(_ page: FrontPage, _ k: PageKind) -> Int {
        let first = k == .weekly ? weekRange.lowerBound : dayRange.lowerBound
        return first - FrontPage.allCases.count + page.rawValue
    }

    /// k 쪽의 index 번째 장이 앞 장이면 그 장
    func frontPage(kind k: PageKind, index i: Int) -> FrontPage? {
        guard hasFront, k.flips else { return nil }
        let first = k == .weekly ? weekRange.lowerBound : dayRange.lowerBound
        return FrontPage(rawValue: i - (first - FrontPage.allCases.count))
    }

    /// 지금 펼친 장이 표지 / 첫 장이면 그 장 (날짜 페이지·홈이면 nil)
    var front: FrontPage? { frontPage(kind: kind, index: index) }

    /// 넘길 수 있는 범위 = 앞 장 + 책의 날(주)
    private func pageRange(_ k: PageKind) -> ClosedRange<Int> {
        let r = k == .weekly ? weekRange : dayRange
        switch k {
        case .home: return 0...0
        default: return (r.lowerBound - (hasFront ? FrontPage.allCases.count : 0))...r.upperBound
        }
    }

    private func clampPage(_ i: Int, _ k: PageKind) -> Int {
        let r = pageRange(k)
        return min(max(i, r.lowerBound), r.upperBound)
    }

    /// 지금 페이지에서 delta 장 넘길 수 있는지
    func canStep(_ delta: Int) -> Bool { kind.flips && pageRange(kind).contains(index + delta) }

    private func clampDay(_ i: Int) -> Int { min(max(i, dayRange.lowerBound), dayRange.upperBound) }
    private func clampWeek(_ i: Int) -> Int { min(max(i, weekRange.lowerBound), weekRange.upperBound) }

    /// 책이 바뀌면 오늘(범위 밖이면 가장 가까운 장)부터 편다
    private func bindStore() {
        bookWatch = store?.$library
            .map(\.activeID)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.endEditing()
                    self.dayIndex = self.clampDay(0)
                    self.weekIndex = self.clampWeek(0)
                    self.onPageChange?()
                }
            }
        // 같은 책의 기간·이름·표지 색을 바꿔도 (설정) 보던 표지 / 첫 장에 그대로 머문다.
        // $library 는 바뀌기 직전에 알려 주므로 여기서 본 front 는 바꾸기 전 기준이다.
        frontWatch = store?.$library
            .sink { [weak self] lib in
                guard let self, let f = self.front, let id = self.store?.library.activeID, lib.activeID == id else { return }
                DispatchQueue.main.async {
                    guard self.store?.library.activeID == id, self.kind.flips, self.front != f else { return }
                    if self.kind == .weekly { self.weekIndex = self.frontIndex(f, .weekly) } else { self.dayIndex = self.frontIndex(f, .daily) }
                    self.onPageChange?()
                }
            }
        dayIndex = clampDay(dayIndex)
        weekIndex = clampWeek(weekIndex)
    }

    /// 넘길 수 없을 때: 트랙패드 진동으로 알려 준다
    private func bump() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    // MARK: pages

    var index: Int {
        switch kind {
        case .weekly: weekIndex
        case .daily: dayIndex
        case .home: 0
        }
    }

    /// 앞 장(표지·첫 장)의 번호는 책의 첫 주 / 첫날로 읽는다 (팔레트의 컬러·D-day, PDF ‘지금 페이지’ 등)
    func weekStart(_ i: Int) -> Date { Dates.add(days: 7 * (hasFront ? max(i, weekRange.lowerBound) : i), to: baseWeek) }
    func dayDate(_ i: Int) -> Date { Dates.add(days: hasFront ? max(i, dayRange.lowerBound) : i, to: baseDay) }

    var currentDate: Date { kind == .weekly ? weekStart(weekIndex) : dayDate(dayIndex) }

    /// 홈에서 주간/일간으로 갈 때 돌아갈 곳
    private var lastPageKind: PageKind = .daily
    /// 창 비율이 바뀌는 중이면 바뀐 뒤의 쪽 (apply 전까지 kind 는 아직 이전 쪽이다)
    private var morphTarget: PageKind?

    private func step(_ d: Int) {
        // 넘기는 중에 쌓인 넘김이 책 밖으로 나가지 않게 범위 안으로
        if kind == .weekly {
            weekIndex = clampPage(weekIndex + d, .weekly)
        } else if kind == .daily {
            dayIndex = clampPage(dayIndex + d, .daily)
        }
        onPageChange?()
    }

    private func setIndex(_ i: Int) {
        if kind == .weekly { weekIndex = i } else if kind == .daily { dayIndex = i }
        onPageChange?()
    }

    // MARK: editing

    func endEditing() {
        guard editingKey != nil else { return }
        editingKey = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    // MARK: navigation

    func flip(_ dir: FlipDirection) {
        guard !morphing, kind.flips else { return }
        guard canStep(dir.delta) else { bump(); return }
        curl.flip(dir)
    }

    func goToday() {
        guard curl.isIdle, !morphing else { return }
        if kind == .home {
            dayIndex = clampDay(0)
            weekIndex = clampWeek(0)
            setKind(lastPageKind)
            return
        }
        let target = kind == .weekly ? clampWeek(0) : clampDay(0)
        let delta = target - index
        if delta == 0 { return }
        if abs(delta) == 1 {
            curl.flip(delta > 0 ? .forward : .backward)
        } else {
            // 여러 장 건너뛸 때: 한 장 넘기는 모습으로 도착 페이지를 보여준다
            curl.flip(delta > 0 ? .forward : .backward, landingOffset: delta)
        }
    }

    func openDay(_ d: Date) {
        endEditing()
        dayIndex = clampDay(Dates.daysBetween(baseDay, d))
        setKind(.daily)
    }

    func switchKind(_ k: PageKind) {
        guard k != kind else { return }
        endEditing()
        if k == .home {
            lastPageKind = kind
        } else if kind == .home {
            // 홈에서 돌아갈 때는 보던 날/주 그대로
        } else if let f = front {
            // 표지 / 첫 장에서 바꾸면 다른 쪽의 같은 장
            if k == .weekly { weekIndex = frontIndex(f, .weekly) } else { dayIndex = frontIndex(f, .daily) }
        } else if k == .weekly {
            weekIndex = clampWeek(Dates.daysBetween(baseWeek, Dates.weekStart(dayDate(dayIndex))) / 7)
        } else {
            let ws = weekStart(weekIndex)
            let inWeek = (0..<7).contains(Dates.daysBetween(ws, baseDay))
            dayIndex = clampDay(inWeek ? 0 : Dates.daysBetween(baseDay, ws))
        }
        setKind(k)
    }

    private func setKind(_ k: PageKind) {
        guard curl.isIdle, !morphing, k != kind else { return }
        morphTarget = k
        let apply = { [weak self] in
            guard let self else { return }
            self.kind = k
            self.morphTarget = nil
            self.curl.edge = k.edge
            self.onPageChange?()
        }
        if let kindTransition { kindTransition(k, apply) } else { apply() }
    }

    /// 표지 / 첫 장을 편다 (튜토리얼 등에서 쓴다).
    /// - k: 일간/주간 중 어느 쪽에서 (nil = 지금 쪽, 홈이면 마지막으로 보던 쪽, 창 비율이 바뀌는 중이면 바뀐 뒤의 쪽)
    /// 같은 쪽이면 종이를 넘겨서 가고 (여러 장이면 한 번에), 다른 쪽이면 그 장을 편 채로 쪽을 바꾼다.
    /// 넘기는 중이거나 다른 쪽으로 바뀌는 중이면 끝난 뒤에 다시 해 본다.
    func showFront(_ page: FrontPage, in k: PageKind? = nil) {
        showFront(page, in: k, tries: 0)
    }

    private func showFront(_ page: FrontPage, in k: PageKind?, tries: Int) {
        guard hasFront else { return }
        let showing = morphTarget ?? kind
        let target = k ?? (showing == .home ? lastPageKind : showing)
        guard target.flips else { return }
        let busy = !curl.isIdle || (morphing && target != showing)
        if busy {
            guard tries < 40 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.showFront(page, in: k, tries: tries + 1)
            }
            return
        }
        endEditing()
        let i = frontIndex(page, target)
        if target == kind && !morphing {
            let delta = i - index
            guard delta != 0 else { return }
            curl.flip(delta > 0 ? .forward : .backward, landingOffset: abs(delta) == 1 ? nil : delta)
            return
        }
        // 다른 쪽으로 가거나 (홈 → 일간 등) 창 비율이 바뀌는 중: 그 장을 바로 편다
        if target == .weekly { weekIndex = i } else { dayIndex = i }
        if target == showing { onPageChange?() } else { setKind(target) }
    }

    // MARK: keyboard & trackpad

    func installMonitors() {
        guard monitors.isEmpty else { return }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return MainActor.assumeIsolated { self.handleKey(e) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self else { return e }
            return MainActor.assumeIsolated { self.handleScroll(e) }
        } as Any)
    }

    private var isTyping: Bool { NSApp.keyWindow?.firstResponder is NSTextView }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        if e.keyCode == 53 { endEditing(); return isTyping ? nil : e }
        if isTyping || !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return e }
        // 한글 입력 상태에서도 동작하도록 물리 키 코드와 자모 모두 확인
        switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "t", "ㅅ": goToday(); return nil
        case "w", "ㅈ": switchKind(.weekly); return nil
        case "d", "ㅇ": switchKind(.daily); return nil
        case "h", "ㅗ": switchKind(.home); return nil
        case "e", "ㄷ": tool = -1; return nil
        default: break
        }
        let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6]
        switch e.keyCode {
        case 123: flip(.backward)
        case 124: flip(.forward)
        case 17: goToday()
        case 13: switchKind(.weekly)
        case 2: switchKind(.daily)
        case 4: switchKind(.home)
        case 14: tool = -1
        case let k where digits[k] != nil:
            if let cats = store?.categories, digits[k]! < cats.count { tool = cats[digits[k]!].id }
        default: return e
        }
        return nil
    }

    /// 트랙패드 두 손가락 가로 스와이프로 종이를 잡고 넘긴다
    private func handleScroll(_ e: NSEvent) -> NSEvent? {
        guard !morphing, e.window?.isKind(of: NSPanel.self) != true else { return e }
        if !e.momentumPhase.isEmpty { return swipeActive ? nil : e }
        var dx = e.scrollingDeltaX
        if !e.isDirectionInvertedFromDevice { dx = -dx }

        if e.phase.isEmpty {
            // 일반 마우스 휠의 가로 스크롤: 한 장씩
            if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY), abs(dx) > 2 { flip(dx < 0 ? .forward : .backward) }
            return e
        }
        switch e.phase {
        case .began:
            swipeActive = false
        case .changed:
            if !swipeActive {
                guard abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) * 1.2, abs(dx) > 0.5 else { return e }
                swipeActive = true
                curl.swipe(.began, deltaX: dx)
            } else {
                curl.swipe(.changed, deltaX: dx)
            }
        case .ended:
            if swipeActive { curl.swipe(.ended, deltaX: 0) }
            swipeActive = false
        case .cancelled:
            if swipeActive { curl.swipe(.cancelled, deltaX: 0) }
            swipeActive = false
        default: break
        }
        return swipeActive ? nil : e
    }
}
