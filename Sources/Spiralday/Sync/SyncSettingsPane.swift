import AppKit
import SwiftUI
import SpiraldayKit
import SpiraldaySync

// ─────────────────────────────────────────────────────────────────────────────
// 설정 → 동기화 (Spiralday Sync): 내 기기끼리 종단간 암호화로 맞춘다. 계정 없음.
// Windows · iOS 앱의 설정 → 동기화와 같은 흐름 · 같은 말을 Mac 설정 창의 모양(Form .grouped)으로. 흐름은 Windows 처럼
// 이 자리에서 바뀐다 (시트를 겹치지 않는다):
//   꺼짐(설명 · 시작하기 · 합류하기 · 복구) → 시작 · 합류 · 복구 코드 입력 → 흐름(복구 코드 · 기기 추가 · 합류 · 되살림)
//   → 켜짐(상태 · 기기 · 이전 버전 · 복구 코드 · 끄기) · 빠짐/그룹 없음(정리하기)
// ─────────────────────────────────────────────────────────────────────────────

struct SyncSettingsPane: View {
    @EnvironmentObject private var sync: SyncController
    @EnvironmentObject private var store: PlannerStore
    @State private var history: SyncHistoryRequest?
    @State private var dev = false

    var body: some View {
        Group {
            if !sync.ready {
                Form {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("동기화를 준비하는 중이에요…").foregroundStyle(.secondary)
                        }
                    } header: { SyncPaneHead() }
                }
            } else if let flow = sync.flow {
                SyncFlowScreen(flow: flow)
            } else if let step = sync.localStep, !sync.inGroup, sync.available {
                switch step {
                case .start: SyncStartStep()
                case .join: SyncJoinInput()
                case .restore: SyncRestoreInput()
                }
            } else if sync.inGroup && sync.status == nil && sync.startProblem != nil {
                // 그룹에 들어 있는데 엔진을 띄우지 못했다 (다른 서버에 있는 그룹 · 오프라인으로 켜기 실패)
                SyncProblemScreen()
            } else if sync.inGroup && (sync.status?.state == .removed || sync.status?.state == .groupGone) {
                SyncGoneScreen()
            } else if sync.inGroup {
                SyncStatusScreen(onHistory: {
                    // 지금 보는 장(일간 · 주간)부터, 아니면 오늘
                    history = sync.historyRequestForCurrentPage() ?? SyncHistoryRequest(book: defaultBook(), kind: .day, date: Dates.day(Date()))
                })
            } else if sync.startProblem != nil {
                SyncProblemScreen()
            } else {
                SyncOffScreen()
            }
        }
        .sheet(item: $history) { req in
            SyncHistorySheet(initial: req)
                .environmentObject(sync)
                .environmentObject(store)
        }
        .onAppear {
            sync.refreshStatus()
            openRequestedHistory()
        }
        .onChange(of: sync.historyRequest) { _, _ in openRequestedHistory() }
        .task {
            // 화면이 열려 있는 동안 "기다리는 기록" · "마지막으로 맞춘 때" 를 새로
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                sync.refreshStatus()
            }
        }
    }

    /// 메뉴의 ‘이 장의 이전 버전…’
    private func openRequestedHistory() {
        guard let r = sync.historyRequest, sync.inGroup else { return }
        sync.historyRequest = nil
        history = r
    }

    /// 이전 버전 창이 처음 열 플래너 (펼친 내 플래너, 아니면 첫 내 플래너)
    private func defaultBook() -> UUID {
        let active = store.library.activeID
        if let a = active, store.userBooks.contains(where: { $0.id == a }) { return a }
        return store.userBooks.first?.id ?? UUID()
    }
}

// MARK: - 꺼짐

struct SyncOffScreen: View {
    @EnvironmentObject private var sync: SyncController

    var body: some View {
        let disabled = !sync.available
        Form {
            if !sync.available {
                Section {
                    SyncBanner(symbol: "info.circle.fill", tint: .secondary, title: "이 실행에서는 동기화를 쓸 수 없어요",
                               detail: "데모 데이터로 실행 중이라 파일에 저장하지 않아서 동기화할 수 없어요.")
                } header: { SyncPaneHead() }
            } else if sync.credsUnreadable {
                Section {
                    SyncBanner(symbol: "lock.trianglebadge.exclamationmark.fill", tint: Color(nsColor: .systemOrange),
                               title: "이 Mac 의 동기화 열쇠를 열 수 없어요",
                               detail: "키체인 항목이 손상된 것 같아요. 플래너는 그대로예요. 정리한 뒤 다른 기기에 다시 합류하거나 복구 코드로 되살려 주세요.") {
                        Button("정리하고 다시 시작하기") { Task { _ = await sync.forget() } }
                    }
                } header: { SyncPaneHead() }
            }
            Section {
                SyncPoint(symbol: "lock.fill", title: "종단간 암호화",
                          detail: "기록은 이 Mac 에서 암호화된 뒤에 보내져요. 열쇠는 내 기기에만 있어서 서버도, Spiralday 회사도 플래너를 읽을 수 없어요.")
                SyncPoint(symbol: "key.fill", title: "계정이 필요 없어요",
                          detail: "이메일도 비밀번호도 받지 않아요. QR 코드나 8자리 코드로 내 기기를 서로 연결해요.")
                SyncPoint(symbol: "arrow.triangle.2.circlepath", title: "겹쳐 써도 괜찮아요",
                          detail: "여러 기기에서 고쳐도 칸마다 마지막에 쓴 것이 남고, 지운 것은 되살아나지 않아요. 인터넷이 없어도 쓰다가 연결되면 맞춰요.")
            } header: {
                if sync.available && !sync.credsUnreadable {
                    SyncPaneHead(title: "내 기기끼리 플래너 맞추기")
                } else {
                    SettingsSectionTitle(title: "내 기기끼리 플래너 맞추기")
                }
            }

            Section {
                SyncChoiceRow(symbol: "laptopcomputer", title: "이 Mac 에서 시작하기",
                              detail: "처음으로 동기화를 켜요. 이 Mac 의 플래너가 그룹의 시작이 돼요.", button: "시작하기…") {
                    sync.localStep = .start
                }
                SyncChoiceRow(symbol: "link", title: "다른 기기에 합류하기",
                              detail: "이미 동기화를 쓰는 기기가 있어요. 그 기기에 보이는 8자리 코드를 입력해요.", button: "합류하기…") {
                    sync.localStep = .join
                }
            } header: {
                SettingsSectionTitle(title: "시작하기")
            }
            .disabled(disabled)

            Section {
                SyncChoiceRow(symbol: "key", title: "복구 코드로 되살리기",
                              detail: "기기를 모두 잃어버렸을 때 동기화를 처음 켤 때 적어 둔 25자 복구 코드로 되살려요.", button: "되살리기…") {
                    sync.localStep = .restore
                }
            } header: {
                SettingsSectionTitle(title: "기기를 모두 잃어버렸나요?")
            } footer: {
                SettingsFootnote(text: "동기화는 켜기 전까지 아무것도 보내지 않아요. 서버에는 암호문만 남고, 서버의 사본은 켠 뒤 언제든 ‘그룹 지우기’로 바로 지울 수 있어요.")
            }
            .disabled(disabled)

            #if DEBUG
            if !sync.qaMode { SyncDeveloperSection() }
            #endif
        }
    }
}

/// 고를 수 있는 길 한 줄: 아이콘 · 이름 · 설명 · 단추
struct SyncChoiceRow: View {
    let symbol: String
    let title: String
    let detail: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsIconTile(symbol: symbol, tint: SettingsPane.sync.tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                Text(verbatim: detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(button, action: action)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 이 Mac 에서 시작하기

struct SyncStartStep: View {
    @EnvironmentObject private var sync: SyncController
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let books = SyncText.localBooksText(sync.localBooks)
        Form {
            Section {
                SyncNameField(title: "이 Mac 이름", name: $name) { go() }
                if let error { SyncNote(tone: .error, text: error) }
            } header: {
                SyncPaneHead(step: SyncStepHead(symbol: "laptopcomputer", title: "이 Mac 에서 시작하기",
                                                detail: "동기화 그룹을 새로 만들어요. "
                                                    + (books.isEmpty ? "이 Mac 에는 아직 내 플래너가 없어요. 만들면 함께 맞춰요."
                                                       : "이 Mac 의 \(books)부터 암호화해서 올려요.")
                                                    + " 다음 단계에서 복구 코드를 적어 두게 돼요."))
            } footer: {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsFootnote(text: "내 기기 목록에만 보이고, 이름도 암호화돼요.")
                    SyncActions {
                        Button("취소") { sync.localStep = nil }
                            .keyboardShortcut(.cancelAction)
                            .disabled(busy)
                        Button(busy ? "켜는 중…" : "동기화 켜기") { go() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(busy)
                    }
                }
            }
        }
        .onAppear { if name.isEmpty { name = sync.suggestedName } }
    }

    private func go() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            let r = await sync.create(deviceName: name)
            busy = false
            if !r.ok { error = r.message ?? "동기화를 켜지 못했어요." }
        }
    }
}

// MARK: - 시작하지 못함 (키체인을 열지 못함 · 다른 서버)

struct SyncProblemScreen: View {
    @EnvironmentObject private var sync: SyncController
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                SyncBanner(symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemOrange),
                           title: "동기화를 시작하지 못했어요", detail: sync.startProblem ?? "")
            } header: { SyncPaneHead() } footer: {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsFootnote(text: "플래너는 이 Mac 에 그대로 있어요. [다시 해 보기]로 안 되면 [정리하기]로 이 Mac 의 동기화 정보만 정리한 뒤 다른 기기에 다시 합류하거나 복구 코드로 되살려 주세요.")
                    SyncActions {
                        Button("정리하기") {
                            busy = true
                            Task { _ = await sync.forget(); busy = false }
                        }
                        .disabled(busy)
                        Button("다시 해 보기") {
                            busy = true
                            Task { await sync.retryStart(); busy = false }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                    }
                }
            }
        }
    }
}

// MARK: - 빠짐 · 그룹 없음

struct SyncGoneScreen: View {
    @EnvironmentObject private var sync: SyncController
    @State private var busy = false
    @State private var note: (ok: Bool, text: String)?

    var body: some View {
        let s = sync.status
        let line = SyncText.statusLine(state: s?.state, pending: 0, lastSyncAt: s?.lastSyncAt, error: s?.error, live: false)
        Form {
            Section {
                Text("[정리하기]를 누르면 서버에 한 번 더 물어본 뒤 이 Mac 의 동기화 정보를 정리해요. 플래너는 지우지 않아요. 다시 동기화하려면 그룹에 있는 다른 기기에서 ‘기기 추가’로 연결하거나 새로 시작해 주세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note { SyncNote(tone: note.ok ? .ok : .error, text: note.text) }
            } header: {
                SyncPaneHead(step: SyncStepHead(symbol: "exclamationmark.icloud.fill", tint: Color(nsColor: .systemRed),
                                                title: line.title, detail: line.detail))
            } footer: {
                SyncActions {
                    Button(busy ? "서버에 확인하는 중…" : "정리하기") {
                        busy = true
                        note = nil
                        Task {
                            let r = await sync.forget()
                            busy = false
                            if let m = r.message, !m.isEmpty { note = (r.ok, m) }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
                }
            }
        }
    }
}

// MARK: - 켜짐

struct SyncStatusScreen: View {
    @EnvironmentObject private var sync: SyncController
    @EnvironmentObject private var store: PlannerStore
    let onHistory: () -> Void
    @State private var syncing = false
    @State private var ask: Ask?
    /// 이 Mac 이 그룹의 마지막 기기인지 (nil = 기기 목록을 받지 못해 모름)
    @State private var lastDevice: Bool?
    /// '끄기…' 를 누르고 기기 목록을 받는 중
    @State private var checkingLeave = false
    @State private var wipeTyping = false
    @State private var error: String?

    enum Ask: Identifiable {
        case rotate, leave, wipe
        var id: Self { self }
    }

    var body: some View {
        let s = sync.status
        Form {
            Section {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    let line = SyncText.statusLine(state: s?.state, pending: s?.pending ?? 0, lastSyncAt: s?.lastSyncAt,
                                                   error: s?.error, live: s?.live ?? false, now: ctx.date)
                    HStack(alignment: .center, spacing: 12) {
                        SyncStatusDot(tone: line.tone, size: 12)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: line.title).font(.system(size: 13, weight: .semibold))
                            Text(verbatim: line.detail)
                                .font(.callout)
                                .foregroundStyle(line.tone == .error ? Color(nsColor: .systemRed)
                                                 : line.tone == .warn ? Color(nsColor: .systemOrange) : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 12)
                        Button {
                            syncing = true
                            Task {
                                await sync.syncNow()
                                syncing = false
                            }
                        } label: {
                            Label(syncing || s?.state == .syncing ? "맞추는 중…" : "지금 맞추기", systemImage: "arrow.clockwise")
                        }
                        .disabled(syncing || s?.state == .syncing)
                        .help("지금 바로 다른 기기와 맞춰요")
                    }
                }
                HStack(spacing: 12) {
                    SyncRowText(title: "이 Mac",
                                detail: "\(sync.deviceName.isEmpty ? "이름 없음" : sync.deviceName) · \(s?.live == true && s?.state != .offline && s?.state != .error ? "실시간으로 연결돼 있어요" : "주기적으로 확인해요")")
                    Spacer(minLength: 12)
                    Label("종단간 암호화", systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("기록은 이 Mac 에서 암호화된 뒤에 보내져요. 열쇠는 내 기기에만 있어서 서버도, Spiralday 회사도 플래너를 읽을 수 없어요.")
                }
                if let error { SyncNote(tone: .error, text: error) }
                if let p = sync.startProblem {
                    SyncNote(tone: .warn, text: p)
                }
            } header: {
                SyncPaneHead(title: "상태")
            }

            if sync.recoveryPending {
                Section {
                    SyncBanner(symbol: "key.fill", tint: Color(nsColor: .systemOrange), title: "복구 코드를 적어 두었는지 확인하지 못했어요",
                               detail: "복구 코드가 없으면 기기를 모두 잃었을 때 되살릴 수 없어요. 새로 만들어 적어 두세요 (예전 코드는 쓸 수 없게 돼요).") {
                        Button("복구 코드 새로 만들기") { ask = .rotate }
                    }
                }
            }
            ForEach(sync.warnings) { w in
                let t = SyncText.warningText(w.warning, bookName: w.bookName)
                Section {
                    SyncBanner(symbol: w.warning == .updateRequired ? "arrow.down.app.fill" : "info.circle.fill",
                               tint: w.warning == .recordTooLarge || w.warning == .updateRequired ? Color(nsColor: .systemOrange) : Color(nsColor: .systemBlue),
                               title: t.title, detail: t.detail) {
                        if w.warning == .updateRequired && sync.canCheckForUpdates {
                            Button("업데이트 확인") { sync.checkForUpdates() }
                        }
                        Button("닫기") { sync.dismissWarning(w.id) }
                    }
                }
            }

            SyncDevicesSection()

            Section {
                HStack(spacing: 12) {
                    SyncRowText(title: "하루 · 한 주의 이전 버전",
                                detail: "잘못 고치거나 지웠을 때 30일 안의 버전으로 되돌려요. 플래너 메뉴의 ‘이 장의 이전 버전…’으로도 열 수 있어요.")
                    Spacer(minLength: 12)
                    Button("이전 버전 보기…", action: onHistory)
                        .disabled(store.userBooks.isEmpty)
                }
            } header: {
                SettingsSectionTitle(title: "이전 버전")
            }

            Section {
                HStack(spacing: 12) {
                    SyncRowText(title: "복구 코드 새로 만들기",
                                detail: "코드를 잃어버렸거나 남이 봤을 수 있을 때 새로 만들어요. 예전 코드는 바로 쓸 수 없게 돼요.")
                    Spacer(minLength: 12)
                    Button("새로 만들기…") { ask = .rotate }
                }
            } header: {
                SettingsSectionTitle(title: "복구 코드")
            }

            Section {
                HStack(spacing: 12) {
                    SyncRowText(title: "이 Mac 에서 끄기", detail: "이 Mac 만 그룹에서 나와요. 플래너는 이 Mac 에 그대로 남고, 다른 기기는 계속 맞춰요.")
                    Spacer(minLength: 12)
                    Button(checkingLeave ? "기기 목록을 확인하는 중…" : "끄기…") { askLeave() }
                        .disabled(checkingLeave)
                }
                HStack(spacing: 12) {
                    SyncRowText(title: "그룹 지우기", detail: "서버의 암호화된 사본을 바로 지우고 모든 기기의 동기화를 끊어요. 각 기기의 플래너는 그대로 남아요.")
                    Spacer(minLength: 12)
                    Button(role: .destructive) { ask = .wipe } label: { Text("지우기…") }
                }
            } header: {
                SettingsSectionTitle(title: "동기화 끄기")
            } footer: {
                SettingsFootnote(text: "서버: \(SyncServer.display(sync.server.url))\(serverSourceNote) · 서버는 내용을 읽을 수 없어요. 기록의 크기와 쓴 때, 기기 수와 접속한 때는 알지만 날짜도 플래너 이름도 모르게 가려 보내요. IP 는 요청 제한에만 하루 동안 알아볼 수 없게 바꿔 둬요.")
            }

            #if DEBUG
            if !sync.qaMode { SyncDeveloperSection() }
            #endif
        }
        .alert(item: $ask) { a in alert(a) }
        .sheet(isPresented: $wipeTyping) {
            SyncWipeConfirm(onCancel: { wipeTyping = false }, onConfirm: {
                wipeTyping = false
                act { await sync.wipe() }
            })
        }
    }

    private var serverSourceNote: String {
        switch sync.server.source {
        case .developerOverride: " (개발자 설정)"
        case .environment: " (환경 변수)"
        default: ""
        }
    }

    private func askLeave() {
        checkingLeave = true
        Task {
            let n = try? await sync.listDevices().devices.count
            lastDevice = n.map { $0 == 1 }
            checkingLeave = false
            ask = .leave
        }
    }

    private func alert(_ a: Ask) -> Alert {
        switch a {
        case .rotate:
            return Alert(title: Text("복구 코드를 새로 만들까요?"),
                         message: Text("새 코드를 만들면 예전 복구 코드는 바로 쓸 수 없게 돼요.\n새 코드는 한 번만 보여 드리니 적어 둘 준비를 해 주세요."),
                         primaryButton: .default(Text("새로 만들기")) { Task { await sync.makeRecovery(.rotate) } },
                         secondaryButton: .cancel(Text("취소")))
        case .leave:
            let message: String
            switch lastDevice {
            case true?:
                message = "이 Mac 이 그룹의 마지막 기기예요. 끄면 서버의 암호화된 사본은 복구 코드로 되살릴 수 있게 13개월 동안 남아요.\n남기고 싶지 않으면 ‘그룹 지우기’를 써 주세요. 플래너는 이 Mac 에 그대로 남아요."
            case false?:
                message = "이 Mac 만 그룹에서 나와요. 플래너는 이 Mac 에 그대로 남아요.\n다시 켜려면 다른 기기에서 ‘기기 추가’로 연결해야 해요."
            case nil:
                message = "이 Mac 만 그룹에서 나와요. 플래너는 이 Mac 에 그대로 남아요.\n다른 기기가 남아 있으면 그 기기는 계속 맞춰요. 이 Mac 이 마지막 기기라면 서버의 암호화된 사본은 13개월 동안 남으니, 남기고 싶지 않으면 ‘그룹 지우기’를 써 주세요."
            }
            return Alert(title: Text("이 Mac 에서 동기화를 끌까요?"), message: Text(message),
                         primaryButton: .destructive(Text("끄기")) { act { await sync.leave() } },
                         secondaryButton: .cancel(Text("취소")))
        case .wipe:
            return Alert(title: Text("그룹을 지울까요?"),
                         message: Text("서버에 있는 암호화된 사본과 30일치 이전 버전이 모두 지워지고, 그룹의 모든 기기에서 동기화가 꺼져요.\n각 기기의 플래너는 그대로 남아요."),
                         primaryButton: .destructive(Text("계속")) {
                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { wipeTyping = true }
                         },
                         secondaryButton: .cancel(Text("취소")))
        }
    }

    private func act(_ body: @escaping () async -> SyncActionResult) {
        error = nil
        Task {
            let r = await body()
            if !r.ok { error = r.message }
        }
    }
}

/// 그룹 지우기의 두 번째 확인: ‘지우기’를 입력한다
struct SyncWipeConfirm: View {
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var typed = ""

    var body: some View {
        let ok = SyncText.wipeConfirmMatches(typed)
        VStack(alignment: .leading, spacing: 12) {
            Text("정말 지울까요?").font(.system(size: 15, weight: .bold))
            Text("되돌릴 수 없어요. 지우려면 아래에 ‘지우기’를 입력해 주세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(text: $typed) { Text(verbatim: "지우기") }
                .textFieldStyle(.roundedBorder)
                .onSubmit { if ok { onConfirm() } }
            HStack {
                Spacer()
                Button("취소", action: onCancel).keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: onConfirm) { Text("그룹 지우기") }
                    .disabled(!ok)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - 기기

struct SyncDevicesSection: View {
    @EnvironmentObject private var sync: SyncController
    @State private var list: (devices: [SyncDeviceRow], maxDevices: Int)?
    @State private var error: String?
    @State private var renaming: String?
    @State private var removing: SyncDeviceRow?
    @State private var busy = false

    var body: some View {
        Section {
            if list == nil && error == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("기기 목록을 받는 중이에요…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if list == nil, let error {
                HStack(spacing: 12) {
                    SyncRowText(title: "기기 목록을 받지 못했어요", detail: error, tone: Color(nsColor: .systemOrange))
                    Spacer(minLength: 12)
                    Button("다시") { Task { await load() } }
                }
            }
            ForEach(list?.devices ?? [], id: \.id) { d in
                row(d)
            }
            if list != nil, let error { SyncNote(tone: .error, text: error) }
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SettingsSectionTitle(title: "기기", trailing: list.map { "\($0.devices.count) / \($0.maxDevices)대" })
                Button { Task { await sync.pairStart(.qr) } } label: { Label("기기 추가", systemImage: "plus") }
                    .controlSize(.small)
                    .disabled(list.map { $0.devices.count >= $0.maxDevices } ?? false)
                    .help("QR 코드나 8자리 코드로 새 기기를 들여요")
            }
        }
        .task(id: sync.devicesRev) { await load() }
        .alert(removing.map { "‘\(SyncText.deviceTitle(name: $0.name, platform: $0.platform))’ 빼기" } ?? "",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { d in
            Button("취소", role: .cancel) {}
            Button("빼기", role: .destructive) { Task { await remove(d) } }
        } message: { _ in
            Text("이 기기는 더 이상 동기화하지 못해요. 그 기기의 플래너는 그 기기에 그대로 남아요.\n\n잃어버린 기기라면 빼고 나서 복구 코드도 새로 만들어 두세요. 이미 그 기기에 받아 둔 기록은 지울 수 없어요.")
        }
    }

    @ViewBuilder
    private func row(_ d: SyncDeviceRow) -> some View {
        let title = d.current ? (d.name ?? (sync.deviceName.isEmpty ? SyncText.deviceTitle(name: nil, platform: d.platform) : sync.deviceName))
            : SyncText.deviceTitle(name: d.name, platform: d.platform)
        if d.current, let current = renaming {
            HStack(spacing: 8) {
                TextField(text: Binding(get: { current }, set: { renaming = String($0.prefix(40)) })) { Text("이 Mac 이름") }
                    .onSubmit { Task { await rename() } }
                Button("취소") { renaming = nil }
                Button("저장") { Task { await rename() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || current.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: SyncText.platformSymbol(d.platform))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(d.current ? SettingsPane.sync.tint : .secondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(d.current ? SettingsPane.sync.tint.opacity(0.14) : Color.primary.opacity(0.06)))
                    .help(SyncText.platformLabel(d.platform))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: title).lineLimit(1)
                        if d.current {
                            Text("이 Mac")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(SettingsPane.sync.tint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(SettingsPane.sync.tint.opacity(0.14)))
                        }
                    }
                    Text(verbatim: d.current ? "지금 쓰는 Mac"
                         : "마지막으로 본 때: \(SyncText.relativeTime(d.lastSeen)) · 들어온 날: \(SyncText.createdDate(d.created))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if d.current {
                    Button("이름 바꾸기") { renaming = title }
                        .help("다른 기기 목록에 보이는 이 Mac 이름을 바꿔요")
                } else {
                    Button("빼기") { removing = d }
                        .disabled(busy)
                        .help("이 기기를 동기화 그룹에서 빼요")
                }
            }
        }
    }

    private func load() async {
        do {
            list = try await sync.listDevices()
            error = nil
        } catch {
            self.error = SyncText.errorText(error)
        }
    }

    private func rename() async {
        guard let name = renaming else { return }
        busy = true
        let r = await sync.renameDevice(name)
        busy = false
        if r.ok {
            renaming = nil
            await load()
        } else {
            error = r.message ?? "이름을 바꾸지 못했어요."
        }
    }

    private func remove(_ d: SyncDeviceRow) async {
        busy = true
        let r = await sync.removeDevice(d.id)
        busy = false
        if !r.ok { error = r.message ?? "기기를 빼지 못했어요." }
        await load()
    }
}

// MARK: - 개발자 설정 (디버그 빌드만)

#if DEBUG
struct SyncDeveloperSection: View {
    @EnvironmentObject private var sync: SyncController
    @State private var url = UserDefaults.standard.string(forKey: SyncServer.overrideKey) ?? ""
    @State private var msg: String?

    var body: some View {
        Section {
            LabeledContent("지금 서버") {
                Text(verbatim: "\(sync.server.url.absoluteString) (\(sync.server.source.rawValue))")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField(text: $url) { Text(verbatim: "http://127.0.0.1:<포트>") }
                    .font(.callout.monospaced())
                Button("적용") {
                    let r = sync.setServerOverride(url)
                    msg = r.ok ? "서버: \(sync.server.url.absoluteString)" : r.message
                }
                Button("기본값") {
                    url = ""
                    let r = sync.setServerOverride(nil)
                    msg = r.ok ? "서버: \(sync.server.url.absoluteString)" : r.message
                }
            }
            .disabled(sync.inGroup)
            if let msg { Text(verbatim: msg).font(.caption).foregroundStyle(.secondary) }
        } header: {
            SettingsSectionTitle(title: "개발자 설정 (디버그 빌드)")
        } footer: {
            SettingsFootnote(text: "동기화가 꺼져 있을 때만 바꿀 수 있어요. 실행 인수 -SpiraldaySyncServerURLOverride 로도 줄 수 있어요.")
        }
    }
}
#endif
