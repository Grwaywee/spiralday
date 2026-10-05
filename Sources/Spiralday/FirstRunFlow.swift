import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 처음 안내의 상태 기계 (순수 함수). iOS apple/App/FirstRunFlow.swift 와 같은 코드 · 같은 공유 벡터
// (Tests/Fixtures/mobile-tour.json = 비공개 저장소 web/tests/fixtures/mobile-tour.json — 시험: FirstRunJoinTests).
// 비공개 docs/mobile-tour.md §3:
//   · 동기화는 처음 안내를 닫지 않는다. 플래너가 어디서 왔든 (만듦 · 합류 · 복구 코드 · 다시 깐 앱이 그룹에 다시 붙음)
//     이 기기에서 처음이면 준비 끝 → 시작하기 → 둘러보기.
//   · 켤 때의 시작 단계는 (내 플래너가 있나 × 동기화 그룹에 있나) 로 정한다 — 앱이 어느 순간에 꺼져도 맞는 자리에서.
//   · 합류하는 동안에는 책을 억지로 만들지 않는다. [새 플래너 만들기] 는 기다린 지 30초가 지나야 보인다.
// Mac 의 처음 안내는 1 환영 → 2 플래너 → 3–6 사용법 → 7 준비 끝 이라서, 상태 기계의 ready(*) 는 "사용법을 거쳐 닿는 준비 끝의 모양" 이다
// (OnboardingModel.apply: 합류 시트를 닫으면 3 으로 넘어가 사용법을 보고 7 에서 그 모양 — 사장님 피드백 I: 합류해도 튜토리얼 · 둘러보기를 건너뛰지 않는다).
// ─────────────────────────────────────────────────────────────────────────────

/// 준비 끝 단계의 변형 (§3.5)
enum FirstRunReady: String, CaseIterable, Equatable, Sendable {
    /// 이 기기에서 플래너를 만들었다
    case created
    /// 다른 기기에 합류해 플래너를 받았다
    case joined
    /// 복구 코드로 그룹에 다시 들어왔다
    case restored
    /// 그룹에 들어왔는데 플래너가 아직 오지 않았다
    case waiting
}

/// 처음 안내 화면의 단계
enum FirstRunStage: Equatable, Sendable {
    case welcome
    case planner
    case ready(FirstRunReady)

    /// 아래 점 (환영 · 플래너 · 준비 끝)
    var dot: Int {
        switch self {
        case .welcome: 0
        case .planner: 1
        case .ready: 2
        }
    }

    /// 벡터 · 실행 인자의 이름 (ready 는 "ready.joined" 처럼)
    var name: String {
        switch self {
        case .welcome: "welcome"
        case .planner: "planner"
        case .ready(let r): "ready.\(r.rawValue)"
        }
    }
}

/// 합류 시트에서 끝난 흐름
enum FirstRunSyncOutcome: String, Equatable, Sendable {
    case joined, restored
}

enum FirstRunFlow {
    /// 처음 안내를 띄우는지 (예시 플래너만 있으면 아직 처음이다)
    static func needsFirstRun(onboardingDone: Bool, hasUserBook: Bool) -> Bool {
        !onboardingDone || !hasUserBook
    }

    /// 켤 때 처음 안내가 시작할 단계 (§3.3). forced 는 --first-run-step 값.
    static func startStage(hasUserBook: Bool, inGroup: Bool, forced: String? = nil) -> FirstRunStage {
        if let forced, let s = stage(named: forced) { return s }
        switch (hasUserBook, inGroup) {
        case (true, true): return .ready(.joined)
        case (true, false): return .ready(.created)
        case (false, true): return .ready(.waiting)
        case (false, false): return .welcome
        }
    }

    /// --first-run-step 값 → 단계 (waiting-late 는 waiting 과 같은 단계 — 30초가 지난 모습은 화면이 정한다)
    static func stage(named n: String) -> FirstRunStage? {
        switch n {
        case "welcome": .welcome
        case "planner": .planner
        case "ready", "created": .ready(.created)
        case "joined": .ready(.joined)
        case "restored": .ready(.restored)
        case "waiting", "waiting-late": .ready(.waiting)
        default: nil
        }
    }

    /// 합류 시트가 닫혔다 (§3.4). 그룹에 들어가지 못했으면 그대로.
    static func sheetClosed(_ stage: FirstRunStage, inGroup: Bool, hasUserBook: Bool,
                            outcome: FirstRunSyncOutcome?) -> FirstRunStage {
        guard inGroup else { return stage }
        guard hasUserBook else { return .ready(.waiting) }
        return .ready(outcome == .restored ? .restored : .joined)
    }

    /// 시트 없이 동기화로 내 플래너가 들어왔다 (다시 깐 앱이 그룹에 다시 붙음 · 기다리던 플래너가 도착함)
    static func bookArrived(_ stage: FirstRunStage, inGroup: Bool, outcome: FirstRunSyncOutcome?) -> FirstRunStage {
        switch stage {
        case .welcome:
            return inGroup ? .ready(.joined) : .welcome
        case .ready(.waiting):
            return .ready(outcome == .restored ? .restored : .joined)
        default:
            // 플래너 단계는 받은 플래너(ExistingStep)로 바뀌고 [다음] 이 준비 끝으로 (nextFromPlanner)
            return stage
        }
    }

    /// 플래너 단계의 [다음] · [플래너 만들기]
    static func nextFromPlanner(created: Bool, inGroup: Bool, outcome: FirstRunSyncOutcome?) -> FirstRunStage {
        if created { return .ready(.created) }
        if inGroup { return .ready(outcome == .restored ? .restored : .joined) }
        return .ready(.created)
    }

    /// 준비 끝의 [이전]: 플래너 단계로 (내 플래너가 있으니 "한 권 더 만들기")
    static func back(_ stage: FirstRunStage) -> FirstRunStage {
        switch stage {
        case .welcome, .planner: .welcome
        case .ready: .planner
        }
    }

    /// 기다리는 동안 이만큼 지나도 플래너가 오지 않으면 [새 플래너 만들기] 를 보인다
    static let waitingPatience: TimeInterval = 30
}
