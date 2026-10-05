import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// 데스크톱(Mac · Windows) 넘김 입력 규칙 — 순수 함수 (시험: DesktopInputRoutingTests. 공유 벡터 Tests/Fixtures/desktop-turn-input.json 은
// Windows 의 web/tests/fixtures/desktop-turn-input.json 과 같은 파일 — web/src/shell/desktopTurnInput.ts 가 같은 값을 쓴다.
// Mac 만의 창 가리기 · 손짓 단계는 Tests/Fixtures/mac-turn-input.json).
//
// · 트랙패드 두 손가락 가로 쓸기: 종이 어디서나 종이를 잡고 넘긴다 (왼쪽 = 다음 장). 일간 · 주간 · 홈 모두
// · 두 손가락 세로 쓸기: 위가 묶인 쪽(주간 · 홈)에서만 (위로 = 다음 장) — 사장님 결정 4 (2026-10-05): 가로도 그대로 둔다.
//   Mac 의 홈은 한 장뿐(PageKind.flips == false)이라 넘길 것이 없다 — 키는 먹고(시스템 '삑' 없이) 아무 일도 하지 않는다
// · 축: 첫 움직임에서 한 축이 다른 축의 1.2 배를 넘을 때 그 축으로 한 번 정한다 (폰 주간 세로 넘김 docs/mobile-tour.md §2.3 과 같은 값)
// · 키: ← → 는 늘, ↑ ↓ 는 주간 · 홈에서만 (↓ = 다음 장). Mac 의 fn+↑ · fn+↓ (PageUp · PageDown) 도 Windows 처럼 주간 · 홈에서
// · 보통 마우스의 세로 휠은 Mac 에서 넘기지 않는다 (Windows 는 트랙패드도 휠로 오므로 주간 세로 휠을 넘김으로 본다 — 공유 벡터의 windows 줄)
// · 플래너 창(과 거기 딸린 팔레트)의 입력만 플래너가 받는다: PDF 내보내기 · 설정 · 업데이트(Sparkle) 창 · 팝오버의 키와 스크롤은 그 창으로
// · 글을 쓰는 중이거나 날짜 고르기(NSDatePicker)가 입력을 받는 중이면 숫자 · 화살표 · 글자는 그 칸으로
// ─────────────────────────────────────────────────────────────────────────────

public enum DesktopTurnInput {
    /// 한 축의 움직임이 다른 축의 이만큼을 넘어야 그 축의 쓸기로 본다
    public static let dominance: CGFloat = 1.2
    /// 이만큼(pt)도 움직이지 않으면 아직 쓸기가 아니다
    public static let minDelta: CGFloat = 0.5
    /// 보통 마우스의 가로 휠: 이보다 크게 굴려야 한 장 넘긴다
    public static let wheelStep: CGFloat = 2

    public enum Axis: String, Sendable, Equatable {
        case horizontal, vertical
    }

    /// 두 손가락 쓸기의 첫 움직임으로 잡을 축 (nil = 넘김이 아니다 — 스크롤에 맡긴다).
    /// dx · dy 는 손가락이 움직인 방향 (dx < 0 왼쪽, dy < 0 위)
    public static func swipeAxis(dx: CGFloat, dy: CGFloat, kind: PageKind) -> Axis? {
        if abs(dx) > abs(dy) * dominance, abs(dx) > minDelta { return .horizontal }
        if kind.edge == .top, abs(dy) > abs(dx) * dominance, abs(dy) > minDelta { return .vertical }
        return nil
    }

    /// 넘김 엔진(CurlController.swipe)에 줄 값: 잡은 축의 손가락 움직임 (음수 = 다음 장 쪽 — 왼쪽 · 위)
    public static func turnDelta(_ axis: Axis, dx: CGFloat, dy: CGFloat) -> CGFloat {
        axis == .horizontal ? dx : dy
    }

    /// 한 번의 손가락 움직임이 넘기는 쪽 (벡터 시험용: 축을 잡지 못하면 nil)
    public static func swipeDirection(dx: CGFloat, dy: CGFloat, kind: PageKind) -> FlipDirection? {
        guard let axis = swipeAxis(dx: dx, dy: dy, kind: kind) else { return nil }
        return turnDelta(axis, dx: dx, dy: dy) < 0 ? .forward : .backward
    }

    /// 넘기는 키
    public enum Key: String, Sendable, CaseIterable {
        case left, right, up, down, pageUp, pageDown
    }

    /// 키 → 넘김 (nil = 이 쪽에서는 넘기는 키가 아니다)
    public static func turn(_ key: Key, kind: PageKind) -> FlipDirection? {
        switch key {
        case .left: return .backward
        case .right: return .forward
        case .up, .pageUp: return kind.edge == .top ? .backward : nil
        case .down, .pageDown: return kind.edge == .top ? .forward : nil
        }
    }

    /// 입력이 온 창
    public enum Window: String, Sendable {
        /// 플래너 종이 창
        case planner
        /// 플래너에 딸린 패널 (팔레트) — 키는 플래너 단축키로 본다, 스크롤은 보지 않는다
        case plannerPanel
        /// 다른 창: PDF 내보내기 · 설정 · 업데이트 · 팝오버 · 시트 · 처음 안내 …
        case other
    }

    /// 그 창에서 입력을 받는 것
    public enum Responder: String, Sendable {
        case none
        /// 글 칸 (필드 편집기 · 글상자)
        case text
        /// 한글 조합 중인 글 칸
        case composing
        /// 날짜 고르기 (숫자 · 화살표를 쓴다)
        case datePicker
    }

    /// 플래너 단축키(넘기기 · 쪽 바꾸기 · 도구)로 볼지. 아니면 키는 그 창 · 그 칸으로 그대로 간다
    public static func plannerTakesKey(window: Window, responder: Responder) -> Bool {
        guard window == .planner || window == .plannerPanel else { return false }
        return responder == .none
    }

    /// Esc: 플래너 창(팔레트 포함)의 Esc 는 쓰기를 마친다 (예전 그대로 — 다른 창의 Esc 는 그 창 몫)
    public static func escEndsEditing(window: Window, responder: Responder) -> Bool {
        window == .planner || window == .plannerPanel
    }

    /// 두 손가락 쓸기 · 휠을 플래너가 볼지 (플래너 종이 창만)
    public static func plannerTakesScroll(window: Window) -> Bool {
        window == .planner
    }
}

/// 트랙패드 · 매직 마우스 스크롤 이벤트를 넘김으로 — 한 손짓(began … ended)마다 축을 한 번 정한다.
/// 쓸기가 넘김을 잡았으면 그 손짓의 남은 이벤트와 뒤따르는 관성(momentum) 이벤트는 먹는다.
public struct DesktopSwipeTracker: Sendable {
    public enum Phase: String, Sendable {
        /// 단계 없음: 보통 마우스 휠
        case none
        case mayBegin, began, changed, ended, cancelled
    }

    public enum Action: Equatable, Sendable {
        case swipe(SwipePhase, CGFloat)
        case flip(FlipDirection)
    }

    /// 넘김을 잡은 축 (손짓 중에만)
    public private(set) var axis: DesktopTurnInput.Axis?
    /// 넘김을 잡았던 손짓 뒤의 관성 이벤트를 먹는 중
    public private(set) var eatingMomentum = false

    public var isActive: Bool { axis != nil }

    public init() {}

    /// dx · dy: 손가락 방향 (dx < 0 왼쪽, dy < 0 위). momentum: 관성 단계의 이벤트. momentumEnded: 관성의 마지막 이벤트
    /// 돌려주는 것: 넘김 엔진에 할 일과 이 이벤트를 먹을지
    public mutating func handle(phase: Phase, momentum: Bool, momentumEnded: Bool = false,
                                dx: CGFloat, dy: CGFloat, kind: PageKind) -> (action: Action?, eat: Bool) {
        if momentum {
            let eat = isActive || eatingMomentum
            if momentumEnded { eatingMomentum = false }
            return (nil, eat)
        }
        switch phase {
        case .none:
            // 보통 마우스의 가로 휠: 한 장씩 (세로 휠은 넘기지 않는다 — 스크롤 몫)
            eatingMomentum = false
            if abs(dx) > abs(dy), abs(dx) > DesktopTurnInput.wheelStep { return (.flip(dx < 0 ? .forward : .backward), false) }
            return (nil, false)
        case .mayBegin:
            return (nil, false)
        case .began:
            axis = nil
            eatingMomentum = false
            return (nil, false)
        case .changed:
            if let axis {
                return (.swipe(.changed, DesktopTurnInput.turnDelta(axis, dx: dx, dy: dy)), true)
            }
            guard let a = DesktopTurnInput.swipeAxis(dx: dx, dy: dy, kind: kind) else { return (nil, false) }
            axis = a
            return (.swipe(.began, DesktopTurnInput.turnDelta(a, dx: dx, dy: dy)), true)
        case .ended, .cancelled:
            guard isActive else { return (nil, false) }
            axis = nil
            eatingMomentum = true
            return (.swipe(phase == .ended ? .ended : .cancelled, 0), true)
        }
    }

    /// 쪽 바꾸기 등으로 손짓을 놓는다
    public mutating func reset() {
        axis = nil
        eatingMomentum = false
    }
}
