import AppKit

/// GitHub ⭐ 부탁. 서로 다른 날로 7일째 쓰면 딱 한 번, 켜고 조금 뒤 본 창 위에 시트로 조용히 묻는다.
/// 어느 쪽을 눌러도 다시는 묻지 않는다. 데모·스냅샷 같은 개발 실행에서는 날짜도 세지 않는다.
@MainActor
enum StarPrompt {
    static let daysKey = "starPromptDays"
    static let lastDayKey = "starPromptLastDay"
    static let doneKey = "starPromptDone"
    /// 이만큼 서로 다른 날을 쓰면 묻는다
    static let daysNeeded = 7
    /// 켜고 나서 창이 자리 잡을 때까지 기다린다
    static let delay: Duration = .seconds(4)

    private static var observer: NSObjectProtocol?
    private static var scheduled = false
    /// 시트가 떠 있는 동안 플래너 단축키(넘기기, W·D·H …)가 뒤에서 움직이지 않게 막는 모니터
    private static var keyMonitor: Any?

    /// 일반 실행에서 앱을 켤 때 한 번. 오늘을 쓴 날로 세고, 때가 됐으면 잠시 뒤 본 창에 띄운다.
    /// 앱을 며칠씩 켜 두고 쓰기도 하니, 앱으로 돌아올 때마다 날짜도 다시 센다.
    static func start(store: PlannerStore, window: @escaping @MainActor () -> NSWindow?) {
        countToday()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                              object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { countToday() }
            }
        }
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey), d.integer(forKey: daysKey) >= daysNeeded else { return }
        schedule(persist: true) {
            // 튜토리얼 · 둘러보기 중이거나 내 플래너가 없으면 이번에는 건너뛴다 (다음에 켤 때 다시). 예시 플래너는 세지 않는다
            guard !store.userBooks.isEmpty, !onboardingShowing, !TourController.shared.isRunning else { return nil }
            return window()
        }
    }

    /// `Spiralday --star-prompt`: 조건과 상관없이 띄워 본다. 테스트용이라 기록은 남기지 않는다.
    static func force(window: @escaping @MainActor () -> NSWindow?) {
        schedule(persist: false, window)
    }

    /// 오늘(이 Mac 의 날짜)이 처음이면 쓴 날을 하나 늘린다
    private static func countToday() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        let today = Dates.key(Date())
        guard d.string(forKey: lastDayKey) != today else { return }
        d.set(today, forKey: lastDayKey)
        d.set(d.integer(forKey: daysKey) + 1, forKey: daysKey)
    }

    private static var onboardingShowing: Bool {
        NSApp.windows.contains { $0.identifier == OnboardingController.windowIdentifier && $0.isVisible }
    }

    private static func schedule(persist: Bool, _ target: @escaping @MainActor () -> NSWindow?) {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            // 창이 내려가 있거나 다른 시트가 떠 있으면 방해하지 않는다
            guard let w = target(), w.isVisible, !w.isMiniaturized, w.attachedSheet == nil else { return }
            present(on: w, persist: persist)
        }
    }

    private static func present(on window: NSWindow, persist: Bool) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Spiralday가 마음에 드시나요?"
        alert.informativeText = "GitHub에서 ⭐ 하나 눌러 주시면 계속 만드는 데 큰 힘이 돼요."
        alert.addButton(withTitle: "별 주러 가기")
        alert.addButton(withTitle: "괜찮아요").keyEquivalent = "\u{1b}"   // Esc

        let sheet = alert.window
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Return · Esc · Tab · Space 와 ⌘ 단축키만 시트로 보내고, 나머지 글자 키는 삼킨다
            let passes: Set<UInt16> = [36, 76, 53, 48, 49]
            guard e.window === sheet, !passes.contains(e.keyCode), !e.modifierFlags.contains(.command) else { return e }
            return nil
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                keyMonitor = nil
                if persist { UserDefaults.standard.set(true, forKey: doneKey) }
                if response == .alertFirstButtonReturn { Links.open(Links.github) }
            }
        }
    }
}
