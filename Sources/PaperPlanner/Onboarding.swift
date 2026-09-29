import AppKit
import SwiftUI

/// 처음 실행: 환영 → 플래너(책) 만들기 → 사용법. 끝나면 completion 에서 본 창을 연다.
/// STUB — to be replaced.
@MainActor
final class OnboardingController {
    static let shared = OnboardingController()
    static let doneKey = "onboardingDone"

    static var needsOnboarding: Bool { !UserDefaults.standard.bool(forKey: doneKey) }

    func show(store: PlannerStore, state: AppState, completion: @escaping () -> Void) {
        if store.books.isEmpty { store.createBook(name: "내 플래너", start: Date(), end: nil) }
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        completion()
    }
}
