import AppKit
import Combine
import SwiftUI
import SpiraldayKit
import SpiraldaySync

// ─────────────────────────────────────────────────────────────────────────────
// 실시간 쓰기를 Mac 앱에 붙이는 곳 (Docs/SpiraldaySync.md §7.3) — 두 기기가 함께 열려 있으면 친 글자 하나(한글은 조합되는 음절마다) ·
// 칠한 칸 하나가 상대 종이에 바로 보인다.
//
//   바꿀 때마다     store.$data 를 보고 바뀐 레코드(하루 · 한 주 · 책 설정)만 engine.liveEdit (밖에서 넣은 것은 빼고)
//   조합 중인 글자  SwiftUI 글 칸은 조합(marked text)이 끝나야 바인딩을 바꾸고, 조합 중에 그 글을 바인딩에 넣으면 다음 화면 갱신이
//                   조합을 깬다 → 저장소에는 넣지 않는다. 필드 편집기의 글이 바뀔 때마다(조합 단계 포함) 그 칸의 레코드를 liveEdit 하고,
//                   호스트가 엔진이 보는 값에만 조합 중인 글을 얹는다 (PlannerSyncHost.composing) — 상대 종이에 ㅎ → 하 → 한
//   쓰는 칸        AppState.editingKey → engine.setEditing (칸 주소)
//   정리 · 저장     쓰기를 마친 뒤의 정리(빈 할 일 지우기)는 미뤄 둔 상대 글을 넣은 뒤 (setEditingAndSettle), 묶어 둔 저장은
//                   엔진 저장소가 뒤처졌으면 먼저 맞춘 뒤 (storageBehind → flushLive) — 둘 다 오래 기다리지 않는다
//   알림           .remoteTyping(editing) → 쓰는 칸 오른쪽 위에 "다른 기기에서 쓰는 중" (3초), .held → "다른 기기의 글이 있어요"
//
// 엔진이 있을 때만 만든다 — 동기화가 꺼져 있으면 아무것도 보지 않고 아무것도 그리지 않는다 (화면이 그대로).
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class SyncLiveBridge {
    let store: PlannerStore
    weak var state: AppState?
    private weak var engine: SyncEngine?
    /// 플래너 종이가 있는 창 (조합 중인 글자 · 알림을 그 창의 글 칸에서만)
    private let plannerWindow: () -> NSWindow?
    let hints = SyncLiveHints()

    private var bag = Set<AnyCancellable>()
    private var base: PlannerData
    private var baseBook: UUID?
    private var textObserver: NSObjectProtocol?
    private var events: Task<Void, Never>?

    /// QA · 테스트: 받은 초안을 넣은 횟수 · 지금 presence · 보낸 liveEdit 횟수
    private(set) var appliedCount = 0
    private(set) var presence: LivePresence?
    private var presenceSeen = false
    private(set) var editsSent = 0
    /// QA · 테스트: 조합 중인 글자로 liveEdit 한 횟수
    private(set) var composedEdits = 0
    /// 마지막으로 알린 때 조합 중이던 칸의 레코드 (조합이 끝나면 — 확정 · 마지막 자모를 지워 취소 — 글이 저장소와 같아도 한 번 더 알린다)
    private var composedRecord: String?

    init(store: PlannerStore, state: AppState?, engine: SyncEngine, plannerWindow: @escaping () -> NSWindow?) {
        self.store = store
        self.state = state
        self.engine = engine
        self.plannerWindow = plannerWindow
        base = store.data
        baseBook = store.library.activeID
    }

    func start() {
        guard let engine else { return }
        // @Published 는 바뀌기 직전에 새 값을 준다 (store.data 는 아직 옛 값) — 바뀐 레코드만 골라 알린다
        store.$data
            .sink { [weak self] next in self?.dataWillChange(next) }
            .store(in: &bag)
        state?.$editingKey
            .removeDuplicates()
            .sink { [weak self] key in self?.editingChanged(key) }
            .store(in: &bag)
        textObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let tv = n.object as? NSTextView else { return }
                self?.fieldTextChanged(tv)
            }
        }
        store.settleBeforeCleanup = { [weak self] run in
            guard let self, let engine = self.engine else { return run() }
            let at = self.address(self.state?.editingKey)
            let once = Once(run)
            Task { @MainActor in
                await engine.setEditingAndSettle(at)
                once.fire()
            }
            // 엔진이 바빠도 정리를 오래 미루지 않는다
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { once.fire() }
        }
        store.beforeScheduledSave = { [weak self] write in
            guard let engine = self?.engine else { return write() }
            let once = Once(write)
            Task { @MainActor in
                // 앱 파일이 엔진 저장소보다 앞선 채 꺼지지 않게 (다시 켤 때 그 값이 이 기기의 새 편집으로 올라가 더 새 글을 덮는다)
                if await engine.storageBehind { await engine.flushLive() }
                once.fire()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { once.fire() }
        }
        let stream = engine.liveEvents()
        events = Task { @MainActor [weak self] in
            for await e in stream {
                guard let self else { return }
                self.handle(e)
            }
        }
        // 붙기 전에 정해진 presence (이벤트가 먼저 오면 그것이 앞선다)
        Task { @MainActor [weak self] in
            let p = await engine.presence
            guard let self, !self.presenceSeen else { return }
            self.presence = p
        }
        engine.setEditing(address(state?.editingKey))
    }

    func stop() {
        bag = []
        if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
        textObserver = nil
        events?.cancel()
        events = nil
        store.settleBeforeCleanup = nil
        store.beforeScheduledSave = nil
        hints.hideAll()
        engine?.setEditing(nil)
    }

    // MARK: 바꿀 때마다

    private func dataWillChange(_ next: PlannerData) {
        let book = store.library.activeID
        defer {
            base = next
            baseBook = book
        }
        // 다른 책을 폈다 (library.activeID 가 data 보다 먼저 바뀐다) · 밖에서 넣었다 (받은 초안 · 받은 레코드): 알리지 않는다
        guard let book, book == baseBook, !store.isApplyingExternalChange else { return }
        let keys = Self.changedKeys(book: book, from: base, to: next)
        guard !keys.isEmpty else { return }
        editsSent += 1
        engine?.liveEdit(keys)
    }

    /// 바뀐 레코드 키 (하루 · 한 주 · 책 설정). 바뀌지 않은 날은 값을 나눠 쓰고 있어 비교가 거의 공짜다
    static func changedKeys(book: UUID, from a: PlannerData, to b: PlannerData) -> [String] {
        let id = book.uuidString
        var out: [String] = []
        if a.days != b.days {
            for (k, v) in b.days where a.days[k] != v { out.append(RecordKeys.day(id, k)) }
            for k in a.days.keys where b.days[k] == nil { out.append(RecordKeys.day(id, k)) }
        }
        if a.weeks != b.weeks {
            for (k, v) in b.weeks where a.weeks[k] != v { out.append(RecordKeys.week(id, k)) }
            for k in a.weeks.keys where b.weeks[k] == nil { out.append(RecordKeys.week(id, k)) }
        }
        if a.prefs != b.prefs { out.append(RecordKeys.prefs(id)) }
        return out
    }

    // MARK: 쓰는 칸

    private func editingChanged(_ key: String?) {
        // 조합 중에 칸을 떠났다: 엔진이 본 조합 글을 저장소의 글로 바로잡게 그 레코드를 다시 (조합 글은 이제 얹히지 않는다)
        if let r = composedRecord {
            composedRecord = nil
            editsSent += 1
            engine?.liveEdit([r])
        }
        engine?.setEditing(address(key))
        if key == nil { hints.hideAll() }
    }

    func address(_ key: String?) -> FieldAddress? { Self.address(key, book: store.library.activeID) }

    /// 글 칸의 편집 키(AppState.editingKey) → 엔진의 칸 주소 (TS editingAddress 와 같다). 모르면 nil
    static func address(_ key: String?, book: UUID?) -> FieldAddress? {
        guard let key, let book else { return nil }
        let id = book.uuidString
        if key == FrontPage.mottoKey { return FieldAddress(key: RecordKeys.prefs(id), field: "mottoText") }
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, Dates.parse(parts[1]) != nil, RecordKeys.isDateKey(parts[1]) else { return nil }
        let day = RecordKeys.day(id, parts[1])
        switch (parts[0], parts.count) {
        case ("t", 3):
            guard let item = UUID(uuidString: parts[2]) else { return nil }
            return FieldAddress(key: day, coll: .tasks, item: item.uuidString, field: "text")
        case ("tn", 3):
            guard let item = UUID(uuidString: parts[2]) else { return nil }
            return FieldAddress(key: day, coll: .notes, item: item.uuidString, field: "text")
        case ("c", 2):
            return FieldAddress(key: day, field: "comment")
        case ("m", 3), ("mt", 3):
            guard let i = Int(parts[2]), i >= 0 else { return nil }
            return FieldAddress(key: day, field: i < DayRecord.memoCount ? "\(parts[0])\(i)" : "\(parts[0])+")
        case ("wg", 2):
            return FieldAddress(key: RecordKeys.week(id, parts[1]), field: "goal")
        default:
            return nil
        }
    }

    // MARK: 조합 중인 글자

    /// 플래너 창의 쓰는 칸(필드 편집기)의 글이 바뀌었다 (키 입력 · 조합 단계 · 조합 취소). 조합 중인 글자는 SwiftUI 가 바인딩에 넣지
    /// 않으므로($data 가 바뀌지 않는다) 그 칸의 레코드를 바로 liveEdit — 엔진은 호스트가 얹은 조합 중인 글을 읽는다.
    /// 조합이 막 끝났으면 글이 저장소와 같아도 알린다: 마지막 자모를 Backspace 로 지워 조합을 취소하면(‘회의 ㄱ’ → ‘회의 ’) 바인딩도
    /// $data 도 바뀌지 않는다 — 알리지 않으면 엔진이 본 ‘회의 ㄱ’ 이 도장과 함께 남아 상대 종이에 보이고 레코드로 올라가며,
    /// 그 사이 앱이 죽으면 다시 켤 때 내 글에 되살아난다. 그 밖에 저장소와 같은 글이면 아무것도 하지 않는다 (보통 입력은 $data 가 알린다)
    private func fieldTextChanged(_ tv: NSTextView) {
        guard let w = tv.window, w === plannerWindow(), w.firstResponder === tv, let key = state?.editingKey,
              let cur = PlannerData.editedText(key, in: store.data), let record = address(key)?.key else { return }
        let composing = tv.hasMarkedText()
        let was = composedRecord
        composedRecord = composing ? record : nil
        guard composing || was != nil || tv.string != cur else { return }
        if composing { composedEdits += 1 }
        editsSent += 1
        engine?.liveEdit(was.map { $0 == record ? [record] : [record, $0] } ?? [record])
    }

    /// 쓰는 칸에서 조합 중인 글 (그 칸의 편집 키 · 필드 편집기의 글 전체 — 조합 중인 글자 포함). 조합 중이 아니면 nil
    func composing() -> (key: String, text: String)? {
        guard let key = state?.editingKey, let w = plannerWindow(), let tv = w.firstResponder as? NSTextView, tv.hasMarkedText() else { return nil }
        return (key, tv.string)
    }

    // MARK: 알림

    private func handle(_ e: SyncLiveEvent) {
        switch e {
        case .presence(let p):
            presenceSeen = true
            presence = p
        case .remoteTyping(_, _, let editing):
            if editing { hints.showTyping(in: plannerWindow()) }
        case .held(let at):
            hints.setHeld(at != nil, in: plannerWindow())
        case .applied:
            appliedCount += 1
        }
    }

    /// 한 번만 부르는 일 (엔진이 답하거나 기다림이 끝나거나 — 먼저 온 쪽)
    private final class Once {
        private var run: (@MainActor () -> Void)?
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
        @MainActor func fire() {
            guard let r = run else { return }
            run = nil
            r()
        }
    }
}

// MARK: - "다른 기기에서 쓰는 중" · "다른 기기의 글이 있어요"

/// 쓰는 칸 오른쪽 위의 작은 회색 글 (플래너 창에 붙은 작은 패널 — 누를 수 없고 포커스 · 레이아웃을 건드리지 않는다)
@MainActor
final class SyncLiveHints {
    static let typingText = "다른 기기에서 쓰는 중"
    static let heldText = "다른 기기의 글이 있어요"
    /// 마지막 이벤트부터 보이는 시간
    static let typingSeconds: TimeInterval = 3

    private var panel: HintPanel?
    private var typingUntil: Date?
    private var typingWork: DispatchWorkItem?
    private var held = false
    private var announced = false

    /// 지금 보이는 글 (QA · 테스트)
    private(set) var shown: String?

    func showTyping(in window: NSWindow?) {
        typingUntil = Date().addingTimeInterval(Self.typingSeconds)
        typingWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.typingUntil = nil
                self?.refresh(in: window)
            }
        }
        typingWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingSeconds, execute: w)
        refresh(in: window)
    }

    func setHeld(_ on: Bool, in window: NSWindow?) {
        held = on
        refresh(in: window)
    }

    func hideAll() {
        typingWork?.cancel()
        typingWork = nil
        typingUntil = nil
        held = false
        refresh(in: nil)
    }

    private func refresh(in window: NSWindow?) {
        let text = typingUntil != nil ? Self.typingText : held ? Self.heldText : nil
        guard let text, let window, let field = Self.focusedField(in: window) else {
            hide()
            return
        }
        let p = panel ?? HintPanel()
        panel = p
        p.show(text, above: field, in: window)
        if shown == nil, !announced {
            // VoiceOver: 처음 보일 때 한 번 (이벤트마다 말하지 않는다)
            announced = true
            NSAccessibility.post(element: NSApplication.shared as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.low.rawValue])
        }
        shown = text
    }

    private func hide() {
        panel?.hide()
        shown = nil
        announced = false
    }

    /// 그 창에서 포커스가 있는 글 칸 (필드 편집기가 고치는 칸)
    static func focusedField(in window: NSWindow) -> NSView? {
        guard let tv = window.firstResponder as? NSTextView, tv.isFieldEditor else { return nil }
        return (tv.delegate as? NSView) ?? tv
    }

    /// 지금 패널 (QA 스냅샷이 종이 위에 겹쳐 그린다)
    var visiblePanel: NSWindow? { panel?.isVisible == true ? panel : nil }
}

/// 알림 패널: 누를 수 없고 키 창이 되지 않는다 (포커스 · 조합 · 되돌리기를 건드리지 않는다)
private final class HintPanel: NSPanel {
    private let label = NSHostingView(rootView: SyncLiveHintLabel(text: ""))

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .aqua)   // 종이는 늘 밝다
        contentView = label
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ text: String, above field: NSView, in window: NSWindow) {
        label.rootView = SyncLiveHintLabel(text: text)
        let size = label.fittingSize
        // 칸 오른쪽 위 (칸의 오른쪽 끝에 맞추고, 칸 위쪽 끝 바로 위)
        let r = window.convertToScreen(field.convert(field.bounds, to: nil))
        let origin = NSPoint(x: max(r.minX, r.maxX - size.width), y: r.maxY + 2)
        setFrame(NSRect(origin: origin, size: size), display: true)
        if parent !== window {
            parent?.removeChildWindow(self)
            window.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// 작은 회색 글 (종이 위에서 읽히게 옅은 종이색 바탕)
struct SyncLiveHintLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color(white: 0.42))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(white: 0.985).opacity(0.94)))
            .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
            .fixedSize()
            .accessibilityLabel(text)
    }
}
