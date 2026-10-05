import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine

/// 넘김을 가로채는 호스트 (iPad 의 펼친 책). 책은 펼침 단위로 넘기고 쪽 번호(index)는 초점 쪽으로만 쓴다.
/// Mac · 폰 · 한 장 놓기는 달지 않는다 (nil → AppState 가 지금처럼 한 장씩 넘긴다).
@MainActor
public protocol PageTurnRouter: AnyObject {
    /// 지금 이 쪽(일간 · 주간)을 책이 넘기는지
    func routes(_ kind: PageKind) -> Bool
    func canTurn(_ dir: FlipDirection) -> Bool
    func turn(_ dir: FlipDirection)
    func goToday()
    /// 쪽 번호로 점프 (표지 · 첫 장 보이기 등)
    func show(index: Int)
}

@MainActor
public final class AppState: ObservableObject {
    @Published public private(set) var kind: PageKind
    @Published public var weekIndex = 0
    @Published public var dayIndex = 0
    @Published public var editingKey: String? = nil {
        // 저장소가 쓰는 칸을 알게 한다 (밖에서 온 편집이 쓰는 중인 칸만 지키게 — PlannerStore.noteEditingField)
        didSet { if editingKey != oldValue { store?.noteEditingField(editingKey) } }
    }
    /// 형광펜 카테고리 id, 또는 아래 특수 도구
    @Published public var tool = 0
    public static let eraser = -1
    public static let textTool = -2
    public static let mealTool = -3
    @Published public var fontsReady = false
    /// 주간 ↔ 일간 전환으로 창 비율이 바뀌는 중
    @Published public var morphing = false
    /// 팔레트 자리를 만드느라 창 크기를 바꾸는 중 (그동안 쪽을 바꾸지 않는다: 창 애니메이션이 겹치지 않게)
    public var frameBusy = false

    public let curl = CurlController()
    /// 숫자 키로 형광펜을 고를 때 순서 → id 변환용, 펼친 책의 범위
    public weak var store: PlannerStore? {
        didSet { bindStore() }
    }
    private var bookWatch: AnyCancellable?
    private var frontWatch: AnyCancellable?
    public let baseDay: Date
    public let baseWeek: Date

    /// 창 컨트롤러가 주입: 창 비율 전환 애니메이션. apply() 를 적절한 시점에 호출해야 한다.
    public var kindTransition: ((_ to: PageKind, _ apply: @escaping () -> Void) -> Void)?
    /// 페이지/데이터가 바뀌었을 때 (창 제목, 스냅샷 미리 그리기 등)
    public var onPageChange: (() -> Void)?
    /// 단축키(1–7 · E)로 도구를 바꿨을 때 (접힌 팔레트를 잠깐 펼쳐 보여 준다)
    public var onToolShortcut: (() -> Void)?
    /// 넘김을 가로채는 책 (iPad 펼친 책). flip · goToday · showFront 가 맨 처음 이것을 본다 (끝 진동 검사보다 먼저)
    public weak var turnRouter: PageTurnRouter?

    /// 지금 쪽을 넘기는 책 (없으면 nil)
    private var router: PageTurnRouter? {
        guard let r = turnRouter, r.routes(kind) else { return nil }
        return r
    }

    #if os(macOS)
    private var monitors: [Any] = []
    private var swipe = DesktopSwipeTracker()
    /// 플래너 종이 창 (호스트가 정한다). 이 창의 키 · 스크롤만 플래너가 받는다 — 다른 창(PDF 내보내기 · 설정 · 업데이트 · 팝오버)은 그 창으로
    public weak var plannerWindow: NSWindow?
    /// 플래너에 딸린 패널인지 (팔레트 — 키는 플래너 단축키로 본다). 호스트가 정한다
    public var isPlannerPanel: ((NSWindow) -> Bool)?
    #endif

    public init(kind: PageKind = .daily, today: Date = Date()) {
        self.kind = kind
        baseDay = Dates.day(today)
        baseWeek = Dates.weekStart(today)
        curl.edge = kind.edge
        curl.willBegin = { [weak self] in self?.endEditing() }
        curl.commit = { [weak self] delta in self?.step(delta) }
    }

    // MARK: book range (시작일 이전 / 종료일 이후로는 넘어가지 않는다)

    private var book: BookInfo? { store?.activeBook }

    public var dayRange: ClosedRange<Int> {
        guard let b = book else { return -100_000...100_000 }
        let lo = Dates.daysBetween(baseDay, b.start)
        let hi = b.end.map { Dates.daysBetween(baseDay, $0) } ?? 100_000
        return lo...max(lo, hi)
    }

    public var weekRange: ClosedRange<Int> {
        guard let b = book else { return -20_000...20_000 }
        let lo = Dates.daysBetween(baseWeek, Dates.weekStart(b.start)) / 7
        let hi = b.end.map { Dates.daysBetween(baseWeek, Dates.weekStart($0)) / 7 } ?? 20_000
        return lo...max(lo, hi)
    }

    // MARK: front pages (책의 첫 장보다 앞: 표지 → 첫 장 → 첫 날/첫 주)
    // 앞 장은 첫 장 바로 앞의 번호를 쓴다 (일간: 첫날 −2 = 표지, −1 = 첫 장 / 주간: 첫 주 기준 같은 식).
    // 그래서 넘기기·모서리 끌기·스와이프·페이지 넘김 스냅샷이 모두 번호 하나로 그대로 동작한다.

    /// 앞 장이 있는지 (펼친 책이 있을 때만)
    public var hasFront: Bool { book != nil }

    /// k 쪽(일간/주간)에서 그 앞 장의 번호
    public func frontIndex(_ page: FrontPage, _ k: PageKind) -> Int {
        let first = k == .weekly ? weekRange.lowerBound : dayRange.lowerBound
        return first - FrontPage.allCases.count + page.rawValue
    }

    /// k 쪽의 index 번째 장이 앞 장이면 그 장
    public func frontPage(kind k: PageKind, index i: Int) -> FrontPage? {
        guard hasFront, k.flips else { return nil }
        let first = k == .weekly ? weekRange.lowerBound : dayRange.lowerBound
        return FrontPage(rawValue: i - (first - FrontPage.allCases.count))
    }

    /// 지금 펼친 장이 표지 / 첫 장이면 그 장 (날짜 페이지·홈이면 nil)
    public var front: FrontPage? { frontPage(kind: kind, index: index) }

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
    public func canStep(_ delta: Int) -> Bool { kind.flips && pageRange(kind).contains(index + delta) }

    /// 그 방향으로 넘길 수 있는지 (책이 넘기면 책의 펼침 기준, 아니면 한 장)
    public func canFlip(_ dir: FlipDirection) -> Bool {
        if let r = router { return r.canTurn(dir) }
        return canStep(dir.delta)
    }

    /// 초점 쪽 바꾸기 (넘기지 않고 번호만 — 책의 펼침이 바뀌었을 때 · 펼친 두 쪽 중 다른 쪽을 쓸 때). 범위 안으로
    public func focus(index i: Int) {
        guard kind.flips else { return }
        let c = clampPage(i, kind)
        guard c != index else { return }
        if kind == .weekly { weekIndex = c } else { dayIndex = c }
        onPageChange?()
    }

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

    /// 넘길 수 없을 때: 트랙패드(iOS: 손끝) 진동으로 알려 준다
    private func bump() {
        Haptics.bump()
    }

    // MARK: pages

    public var index: Int {
        switch kind {
        case .weekly: weekIndex
        case .daily: dayIndex
        case .home: 0
        }
    }

    /// 앞 장(표지·첫 장)의 번호는 책의 첫 주 / 첫날로 읽는다 (팔레트의 컬러·D-day, PDF ‘지금 페이지’ 등)
    public func weekStart(_ i: Int) -> Date { Dates.add(days: 7 * (hasFront ? max(i, weekRange.lowerBound) : i), to: baseWeek) }
    public func dayDate(_ i: Int) -> Date { Dates.add(days: hasFront ? max(i, dayRange.lowerBound) : i, to: baseDay) }

    public var currentDate: Date { kind == .weekly ? weekStart(weekIndex) : dayDate(dayIndex) }

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

    public func endEditing() {
        guard editingKey != nil else { return }
        editingKey = nil
        #if os(macOS)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #else
        PlatformServices.endTextEditing?()
        #endif
    }

    // MARK: navigation

    public func flip(_ dir: FlipDirection) {
        guard !morphing, kind.flips else { return }
        if let r = router { r.turn(dir); return }
        guard canStep(dir.delta) else { bump(); return }
        curl.flip(dir)
    }

    public func goToday() {
        guard curl.isIdle, !morphing else { return }
        if kind == .home {
            dayIndex = clampDay(0)
            weekIndex = clampWeek(0)
            setKind(lastPageKind)
            return
        }
        if let r = router { r.goToday(); return }
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

    public func openDay(_ d: Date) {
        endEditing()
        dayIndex = clampDay(Dates.daysBetween(baseDay, d))
        setKind(.daily)
    }

    public func switchKind(_ k: PageKind) {
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
        guard curl.isIdle, !morphing, !frameBusy, k != kind else { return }
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
    public func showFront(_ page: FrontPage, in k: PageKind? = nil) {
        showFront(page, in: k, tries: 0)
    }

    private func showFront(_ page: FrontPage, in k: PageKind?, tries: Int) {
        guard hasFront else { return }
        let showing = morphTarget ?? kind
        let target = k ?? (showing == .home ? lastPageKind : showing)
        guard target.flips else { return }
        let busy = !curl.isIdle || frameBusy || (morphing && target != showing)
        if busy {
            guard tries < 40 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.showFront(page, in: k, tries: tries + 1)
            }
            return
        }
        endEditing()
        let i = frontIndex(page, target)
        if target == kind && !morphing, let r = router {
            r.show(index: i)
            return
        }
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

    // MARK: keyboard (공용)

    /// 단축키로 도구 고르기 (팔레트가 접혀 있으면 잠깐 펼쳐 보여 준다)
    public func pickTool(_ id: Int) {
        tool = id
        onToolShortcut?()
    }

    /// 하드웨어 키보드 단축키 (macOS 는 아래 키 감시가, iOS 는 앱의 키 명령이 부른다). 맥과 같은 키:
    /// ← → 넘기기 · T 오늘 · W 주간 · D 일간 · H 홈 · E 지우개 · 1–7 형광펜 (한글 자판 ㅅ ㅈ ㅇ ㅗ ㄷ 도)
    public enum KeyShortcut: Equatable {
        case previousPage, nextPage, today, weekly, daily, home, eraser
        /// 팔레트 순서 (0 = 첫 형광펜)
        case pen(Int)

        /// 누른 글자 (수정 키 없이) → 단축키
        public init?(character c: String) {
            switch c.lowercased() {
            case "t", "ㅅ": self = .today
            case "w", "ㅈ": self = .weekly
            case "d", "ㅇ": self = .daily
            case "h", "ㅗ": self = .home
            case "e", "ㄷ": self = .eraser
            case "1", "2", "3", "4", "5", "6", "7": self = .pen(Int(c)! - 1)
            default: return nil
            }
        }
    }

    /// 단축키를 실행한다. 처리했으면 true.
    @discardableResult
    public func perform(_ k: KeyShortcut) -> Bool {
        switch k {
        case .previousPage: flip(.backward)
        case .nextPage: flip(.forward)
        case .today: goToday()
        case .weekly: switchKind(.weekly)
        case .daily: switchKind(.daily)
        case .home: switchKind(.home)
        case .eraser: pickTool(Self.eraser)
        case .pen(let i):
            guard let cats = store?.categories, i >= 0, i < cats.count else { return false }
            pickTool(cats[i].id)
        }
        return true
    }

    #if os(macOS)
    // MARK: keyboard & trackpad (macOS)

    public func installMonitors() {
        guard monitors.isEmpty else { return }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let eat = MainActor.assumeIsolated { self?.handleKey(e) ?? false }
            return eat ? nil : e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            let eat = MainActor.assumeIsolated { self?.handleScroll(e) ?? false }
            return eat ? nil : e
        } as Any)
    }

    /// 입력이 온 창
    public func inputWindow(_ w: NSWindow?) -> DesktopTurnInput.Window {
        guard let w else { return .other }
        if let plannerWindow, w === plannerWindow { return .planner }
        if isPlannerPanel?(w) == true { return .plannerPanel }
        return .other
    }

    /// 그 창에서 입력을 받는 것
    public static func inputResponder(_ w: NSWindow?) -> DesktopTurnInput.Responder {
        switch w?.firstResponder {
        case let tv as NSTextView: return tv.hasMarkedText() ? .composing : .text
        case is NSDatePicker: return .datePicker
        default: return .none
        }
    }

    /// 처리했으면 true (이벤트를 먹는다)
    private func handleKey(_ e: NSEvent) -> Bool {
        handleKey(window: inputWindow(e.window), responder: Self.inputResponder(e.window), keyCode: e.keyCode,
                  characters: e.charactersIgnoringModifiers, modifiers: e.modifierFlags)
    }

    /// 키 하나 (시험이 창 · 칸을 정해 부른다). 처리했으면 true
    func handleKey(window: DesktopTurnInput.Window, responder: DesktopTurnInput.Responder, keyCode: UInt16,
                   characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        if keyCode == 53 {
            // Esc: 플래너에서 쓰던 글을 마친다 (다른 창의 Esc 는 그 창 몫)
            guard DesktopTurnInput.escEndsEditing(window: window, responder: responder) else { return false }
            endEditing()
            return responder == .text || responder == .composing
        }
        guard DesktopTurnInput.plannerTakesKey(window: window, responder: responder),
              modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        // 한글 입력 상태에서도 동작하도록 물리 키 코드와 자모 모두 확인
        switch characters?.lowercased() ?? "" {
        case "t", "ㅅ": goToday(); return true
        case "w", "ㅈ": switchKind(.weekly); return true
        case "d", "ㅇ": switchKind(.daily); return true
        case "h", "ㅗ": switchKind(.home); return true
        case "e", "ㄷ": pickTool(Self.eraser); return true
        default: break
        }
        if let key = Self.turnKey(keyCode) {
            // ← → 는 늘, ↑ ↓ · PageUp PageDown 은 위가 묶인 쪽(주간 · 홈)에서만 넘긴다
            guard let dir = DesktopTurnInput.turn(key, kind: kind) else { return false }
            flip(dir)
            return true
        }
        let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6]
        switch keyCode {
        case 17: goToday()
        case 13: switchKind(.weekly)
        case 2: switchKind(.daily)
        case 4: switchKind(.home)
        case 14: pickTool(Self.eraser)
        case let k where digits[k] != nil:
            if let cats = store?.categories, digits[k]! < cats.count { pickTool(cats[digits[k]!].id) }
        default: return false
        }
        return true
    }

    /// 넘기는 키의 물리 키 코드 (← → ↑ ↓ · PageUp PageDown)
    public static func turnKey(_ keyCode: UInt16) -> DesktopTurnInput.Key? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 126: return .up
        case 125: return .down
        case 116: return .pageUp
        case 121: return .pageDown
        default: return nil
        }
    }

    /// 트랙패드 두 손가락 쓸기로 종이를 잡고 넘긴다 (가로는 늘, 세로는 주간 · 홈 — DesktopTurnInput)
    /// 처리했으면 true (이벤트를 먹는다)
    private func handleScroll(_ e: NSEvent) -> Bool {
        guard !morphing, DesktopTurnInput.plannerTakesScroll(window: inputWindow(e.window)) else { return false }
        // 손가락 방향으로 (자연스러운 스크롤이면 그대로, 아니면 뒤집는다)
        var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if !e.isDirectionInvertedFromDevice { dx = -dx; dy = -dy }
        let phase: DesktopSwipeTracker.Phase
        switch e.phase {
        case []: phase = .none
        case .mayBegin: phase = .mayBegin
        case .began: phase = .began
        case .changed, .stationary: phase = .changed
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        default: phase = .changed
        }
        let (action, eat) = swipe.handle(phase: phase, momentum: !e.momentumPhase.isEmpty,
                                         momentumEnded: e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled),
                                         dx: dx, dy: dy, kind: kind)
        switch action {
        case .flip(let dir)?: flip(dir)
        case .swipe(let p, let d)?: curl.swipe(p, deltaX: d)
        case nil: break
        }
        return eat
    }
    #endif
}
