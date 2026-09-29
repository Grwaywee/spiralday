import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var kind: PageKind
    @Published var weekIndex = 0
    @Published var dayIndex = 0
    @Published var editingKey: String? = nil
    /// 형광펜 카테고리 id, -1 = 지우개
    @Published var tool = 0
    @Published var fontsReady = false
    /// 주간 ↔ 일간 전환으로 창 비율이 바뀌는 중
    @Published var morphing = false

    let curl = CurlController()
    /// 숫자 키로 형광펜을 고를 때 순서 → id 변환용
    weak var store: PlannerStore?
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

    // MARK: pages

    var index: Int {
        switch kind {
        case .weekly: weekIndex
        case .daily: dayIndex
        case .home: 0
        }
    }

    func weekStart(_ i: Int) -> Date { Dates.add(days: 7 * i, to: baseWeek) }
    func dayDate(_ i: Int) -> Date { Dates.add(days: i, to: baseDay) }

    var currentDate: Date { kind == .weekly ? weekStart(weekIndex) : dayDate(dayIndex) }

    /// 홈에서 주간/일간으로 갈 때 돌아갈 곳
    private var lastPageKind: PageKind = .daily

    private func step(_ d: Int) {
        if kind == .weekly { weekIndex += d } else if kind == .daily { dayIndex += d }
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
        curl.flip(dir)
    }

    func goToday() {
        guard curl.isIdle, !morphing else { return }
        if kind == .home {
            dayIndex = 0
            weekIndex = 0
            setKind(lastPageKind)
            return
        }
        let target = 0
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
        dayIndex = Dates.daysBetween(baseDay, d)
        setKind(.daily)
    }

    func switchKind(_ k: PageKind) {
        guard k != kind else { return }
        endEditing()
        if k == .home {
            lastPageKind = kind
        } else if kind == .home {
            // 홈에서 돌아갈 때는 보던 날/주 그대로
        } else if k == .weekly {
            weekIndex = Dates.daysBetween(baseWeek, Dates.weekStart(dayDate(dayIndex))) / 7
        } else {
            let ws = weekStart(weekIndex)
            let inWeek = (0..<7).contains(Dates.daysBetween(ws, baseDay))
            dayIndex = inWeek ? 0 : Dates.daysBetween(baseDay, ws)
        }
        setKind(k)
    }

    private func setKind(_ k: PageKind) {
        guard curl.isIdle, !morphing, k != kind else { return }
        let apply = { [weak self] in
            guard let self else { return }
            self.kind = k
            self.curl.edge = k.edge
            self.onPageChange?()
        }
        if let kindTransition { kindTransition(k, apply) } else { apply() }
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
