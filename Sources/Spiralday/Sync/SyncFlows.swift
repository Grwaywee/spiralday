import AppKit
import SwiftUI
import SpiraldayKit
import SpiraldaySync

// ─────────────────────────────────────────────────────────────────────────────
// 동기화 흐름 (설정 → 동기화가 그 자리에서 그린다 — Windows · iOS 앱과 같은 단계 · 같은 말):
//   복구 코드(한 번만 · 복사 · 텍스트 파일 · 인쇄 → 두 묶음 다시 입력)
//   기기 추가(QR · 8자리 코드 + 남은 시간 → 새 기기의 숫자 4자리 입력 → [연결] / [아니에요])
//   합류(8자리 코드 · 연결 글 → 숫자 4자리 보여 주기 → 승인 기다리기 → 합치기 설명 · 백업 → 합치고 시작하기)
//   복구 코드로 되살리기(코드 → 합치기 설명 → 되살림)
// Mac 에는 QR 을 찍을 카메라를 쓰지 않는다 (Windows PC 와 같이 8자리 코드나 ‘연결 글 복사’로 받은 글을 붙여 넣는다).
// ─────────────────────────────────────────────────────────────────────────────

struct SyncFlowScreen: View {
    let flow: SyncFlow

    var body: some View {
        switch flow {
        case .recovery(let reason, let stage):
            SyncRecoveryStep(reason: reason, stage: stage)
        case .pair(let mode, let stage):
            SyncPairFlow(mode: mode, stage: stage)
        case .join(let stage, let books):
            SyncJoinFlow(stage: stage, localBooks: books)
        case .restore(let evicted, let backup):
            SyncRestoreDone(evicted: evicted, backup: backup)
        }
    }
}

private extension SyncController {
    func close() { Task { await endFlow() } }
}

// MARK: - 복구 코드 (한 번만)

struct SyncRecoveryStep: View {
    @EnvironmentObject private var sync: SyncController
    let reason: SyncFlow.RecoveryReason
    let stage: SyncFlow.RecoveryStage

    var body: some View {
        switch stage {
        case .working:
            Form {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("복구 코드를 만드는 중이에요…").foregroundStyle(.secondary)
                    }
                } header: {
                    SyncPaneHead(step: SyncStepHead(symbol: "key.fill",
                                                    title: reason == .rotate ? "새 복구 코드를 만드는 중이에요" : "동기화를 켜는 중이에요",
                                                    detail: reason == .rotate ? "예전 복구 코드는 곧 쓸 수 없게 돼요." : "그룹을 만들고 이 Mac 의 플래너를 암호화해서 올려요."))
                }
            }
        case .failed(let message):
            Form {
                Section {
                    SyncBanner(symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemRed), title: "다시 해 주세요", detail: message)
                } header: {
                    SyncPaneHead(step: SyncStepHead(symbol: "key.fill", title: "복구 코드를 만들지 못했어요",
                                                    detail: "동기화는 켜졌지만 복구 코드를 서버에 두지 못했어요. 복구 코드가 없으면 기기를 모두 잃었을 때 되살릴 수 없어요."))
                } footer: {
                    SyncActions {
                        Button("나중에") { sync.close() }
                        Button("다시 만들기") { Task { await sync.recoveryRetry() } }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        case .show(let code):
            SyncRecoveryShow(code: code, rotate: reason == .rotate)
        }
    }
}

struct SyncRecoveryShow: View {
    @EnvironmentObject private var sync: SyncController
    let code: String
    let rotate: Bool
    @State private var checking = false
    @State private var copied = false
    @State private var saved: (ok: Bool, text: String)?
    @State private var pair = SyncText.pickCheckGroups()
    @State private var typed = ["", ""]
    @State private var tried = false
    @State private var at = Date()
    @State private var asksLater = false

    private var groups: [String] { SyncText.recoveryGroups(code) }
    private func group(_ i: Int) -> String { groups.indices.contains(i) ? groups[i] : "" }
    private var okA: Bool { SyncText.groupMatches(typed[0], group(pair.0)) }
    private var okB: Bool { SyncText.groupMatches(typed[1], group(pair.1)) }
    private var deviceName: String { sync.deviceName.isEmpty ? sync.suggestedName : sync.deviceName }

    var body: some View {
        Group {
            if checking { check } else { show }
        }
        .alert("복구 코드를 적지 않고 닫을까요?", isPresented: $asksLater) {
            Button("돌아가기", role: .cancel) {}
            Button("닫기", role: .destructive) { sync.close() }
        } message: {
            Text("이 코드는 다시 볼 수 없어요. 복구 코드가 없으면 기기를 모두 잃었을 때 되살릴 수 없어요. 나중에 설정 → 동기화에서 새로 만들어 적어 둘 수 있어요.")
        }
        .onAppear {
            // 스크린샷 (--sync-qa recovery-check): 확인 단계부터
            if sync.qaMode, sync.qaInput["checking"] != nil {
                pair = (1, 3)
                checking = true
                typed = [group(1), String(group(3).prefix(3))]
                tried = true
            }
        }
    }

    private var show: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    HStack(spacing: 8) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                            VStack(spacing: 4) {
                                SyncCodeText(text: g)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                                Text(verbatim: "\(i + 1)").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("복구 코드"))
                    .accessibilityValue(Text(verbatim: groups.map(SyncText.spelled).joined(separator: ", ")))
                    HStack(spacing: 8) {
                        Button { copy() } label: { Label(copied ? "복사했어요" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        Button { save() } label: { Label("텍스트 파일로 저장…", systemImage: "square.and.arrow.down") }
                        Button { printCard() } label: { Label("인쇄…", systemImage: "printer") }
                    }
                    if let saved { SyncNote(tone: saved.ok ? .ok : .error, text: saved.text) }
                    Text("복사한 코드는 1분 뒤 클립보드에서 지워요. 파일로 저장할 때는 iCloud Drive 처럼 인터넷에 올라가는 폴더는 피하고, 인쇄해서 보관하는 것이 가장 안전해요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } header: {
                SyncPaneHead(step: SyncStepHead(symbol: "key.fill", tint: Color(nsColor: .systemOrange),
                                                title: rotate ? "새 복구 코드를 적어 두세요" : "복구 코드를 적어 두세요",
                                                detail: "기기를 모두 잃어버렸을 때 이 코드로 동기화된 플래너를 되살려요. 지금 한 번만 보여 드려요."
                                                    + (rotate ? " 예전 복구 코드는 이제 쓸 수 없어요." : "")))
            }
            Section {
                SyncBanner(symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemOrange), title: "이 코드를 잃으면 아무도 되살릴 수 없어요",
                           detail: "Spiralday 도 플래너를 볼 수 없어서 대신 되살려 드릴 수 없어요. 이 코드를 가진 사람은 누구나 플래너를 볼 수 있으니 남에게 보여 주지 마세요.")
            } footer: {
                SyncActions {
                    Button("나중에…") { asksLater = true }
                    Button("적어 뒀어요") { withAnimation(.snappy(duration: 0.2)) { checking = true } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var check: some View {
        Form {
            Section {
                ForEach(0..<2, id: \.self) { k in
                    SyncCodeField(label: "\(SyncText.ordinal(k == 0 ? pair.0 : pair.1)) 묶음",
                                  text: Binding(get: { typed[k] }, set: { typed[k] = String($0.uppercased().prefix(7)) }),
                                  prompt: "XXXXX", size: 14, onSubmit: done)
                }
                if tried && !(okA && okB) {
                    SyncNote(tone: .error, text: "적어 둔 코드와 달라요. 다시 확인해 주세요. (대소문자 · 하이픈은 가리지 않아요)")
                }
                if okA && okB { SyncNote(tone: .ok, text: "맞아요. 잘 적어 두셨어요.") }
            } header: {
                SyncPaneHead(step: SyncStepHead(symbol: "checkmark.shield.fill", title: "적어 둔 코드를 확인할게요",
                                                detail: "적어 둔 복구 코드에서 \(SyncText.ordinal(pair.0))과 \(SyncText.ordinal(pair.1)) 묶음(5자씩)을 입력해 주세요."))
            } footer: {
                SyncActions {
                    Button { withAnimation(.snappy(duration: 0.2)) { checking = false } } label: { Label("코드 다시 보기", systemImage: "chevron.left") }
                } trailing: {
                    Button("확인했어요", action: done)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func done() {
        tried = true
        guard okA && okB else { return }
        sync.recoveryConfirmed()
    }

    private func copy() {
        SyncClipboard.copySecret(groups.joined(separator: "-"), clearAfter: 60)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { copied = false }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.title = "복구 코드 저장"
        panel.nameFieldStringValue = SyncText.recoveryFileName(at)
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let text = SyncText.recoveryFileText(code, deviceName: deviceName, at: at)
        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                saved = (true, "\(url.lastPathComponent) 로 저장했어요. USB 나 인쇄물처럼 이 Mac 밖에도 보관해 두세요.")
            } catch {
                saved = (false, "저장하지 못했어요: \(error.localizedDescription)")
            }
        }
        if let w = SettingsWindowController.shared.window, w.isVisible {
            panel.beginSheetModal(for: w) { r in MainActor.assumeIsolated { finish(r) } }
        } else {
            finish(panel.runModal())
        }
    }

    private func printCard() {
        let html = SyncText.recoveryPrintHTML(groups: groups, at: at, deviceName: deviceName)
        guard let data = html.data(using: .utf8),
              let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                     .characterEncoding: String.Encoding.utf8.rawValue],
                                                 documentAttributes: nil) else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .spool
        let size = info.paperSize
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: size.width - info.leftMargin - info.rightMargin, height: 400))
        view.textStorage?.setAttributedString(attr)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = "Spiralday 복구 코드"
        if let w = SettingsWindowController.shared.window, w.isVisible {
            op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }
}

// MARK: - 기기 추가 (이 Mac 이 그룹에 있을 때)

struct SyncPairFlow: View {
    @EnvironmentObject private var sync: SyncController
    let mode: PairingMode
    let stage: SyncFlow.PairStage

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch stage {
        case .waiting(_, _, let deadline) where now >= deadline:
            expired(wasRequest: false)
        case .expired(let wasRequest):
            expired(wasRequest: wasRequest)
        case .opening:
            Form {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("연결 코드를 만드는 중이에요…").foregroundStyle(.secondary)
                    }
                } header: { SyncPaneHead(step: head) } footer: {
                    SyncActions { Button("그만두기") { sync.close() } }
                }
            }
        case .waiting(let qrText, let code, let deadline):
            SyncPairWaiting(mode: mode, qrText: qrText, code: code, deadline: deadline, head: head)
        case .request(let info), .approving(let info):
            SyncPairRequest(info: info, busy: { if case .approving = stage { return true } else { return false } }(), now: now)
        case .approved(let platform):
            Form {
                Section {} header: {
                    SyncPaneHead(step: SyncStepHead(symbol: "checkmark.circle.fill", tint: Color(nsColor: .systemGreen), title: "연결했어요",
                                                    detail: "새 기기(\(SyncText.platformLabel(platform)))에서 [합치고 시작하기]를 누르면 동기화가 시작돼요. 기기 목록에서 이름을 확인할 수 있어요."))
                } footer: {
                    SyncActions { Button("닫기") { sync.close() }.keyboardShortcut(.defaultAction) }
                }
            }
        case .denied, .withdrawn:
            Form {
                Section {} header: {
                    SyncPaneHead(step: SyncStepHead(symbol: "lock.fill", title: stage == .withdrawn ? "새 기기에서 연결을 그만뒀어요" : "연결하지 않았어요",
                                                    detail: "그 기기에는 그룹의 열쇠가 가지 않았어요. 내 기기가 맞다면 처음부터 다시 연결해 주세요."))
                } footer: {
                    SyncActions {
                        Button("닫기") { sync.close() }
                        Button("다시 연결하기") { Task { await sync.pairStart(mode) } }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        case .error(let message):
            Form {
                Section {
                    SyncBanner(symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemRed), title: "연결 코드를 만들지 못했어요", detail: message)
                } header: { SyncPaneHead(step: head) } footer: {
                    SyncActions {
                        Button("닫기") { sync.close() }
                        Button("다시 해 보기") { Task { await sync.pairStart(mode) } }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }

    private var head: SyncStepHead {
        SyncStepHead(symbol: "qrcode", title: "기기 추가",
                     detail: "새 기기에서 이 코드를 쓰면 이 그룹에 들어와요. 들어온 기기와 플래너가 서로 맞춰져요.")
    }

    private func expired(wasRequest: Bool) -> some View {
        Form {
            Section {} header: {
                SyncPaneHead(step: SyncStepHead(symbol: "clock.badge.exclamationmark", title: "시간이 지났어요",
                                                detail: (wasRequest ? "승인할 수 있는 시간이 지났어요." : "QR 코드와 8자리 코드는 10분 동안만 쓸 수 있어요.")
                                                    + " 새로 만들어 다시 연결해 주세요."))
            } footer: {
                SyncActions {
                    Button("닫기") { sync.close() }
                    Button("새로 만들기") { Task { await sync.pairStart(mode) } }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

struct SyncPairWaiting: View {
    @EnvironmentObject private var sync: SyncController
    let mode: PairingMode
    let qrText: String?
    let code: String?
    let deadline: Date
    let head: SyncStepHead
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { mode }, set: { m in if m != mode { Task { await sync.pairStart(m) } } })) {
                    Text("QR 코드").tag(PairingMode.qr)
                    Text("8자리 코드").tag(PairingMode.code)
                } label: {
                    Text("연결 방법")
                }
                .pickerStyle(.segmented)
                HStack(alignment: .center, spacing: 20) {
                    if mode == .qr, let qrText {
                        SyncQRCode(text: qrText)
                    } else if let code {
                        SyncCodeText(text: code, size: 30)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                            .frame(minWidth: 200)
                            .accessibilityElement()
                            .accessibilityLabel(Text("연결 코드"))
                            .accessibilityValue(Text(verbatim: SyncText.spelled(code.replacingOccurrences(of: "-", with: ""))))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        step(1, "새 기기에서 Spiralday 를 열고 설정 → 동기화 → 다른 기기에 합류하기를 눌러요.")
                        step(2, mode == .qr ? "카메라로 이 QR 코드를 찍어요." : "8자리 코드 \(code ?? "") 를 입력해요.")
                        step(3, "새 기기 화면에 뜬 숫자 4자리를 여기에 입력하고 [연결]을 눌러요.")
                        SyncCountdown(deadline: deadline, label: "새 기기를 기다리는 중")
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 8)
                if mode == .qr, let qrText {
                    HStack(spacing: 12) {
                        Text("새 기기가 카메라 없는 PC 라면 ‘연결 글 복사’를 눌러 그 PC 의 입력 칸에 붙여 넣어도 돼요. 메신저로 보낼 때는 내 대화방에만 보내 주세요. (또는 ‘8자리 코드’)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button {
                            SyncClipboard.copySecret(qrText, clearAfter: max(5, deadline.timeIntervalSinceNow))
                            copied = true
                        } label: {
                            Label(copied ? "복사했어요" : "연결 글 복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                }
            } header: {
                SyncPaneHead(step: head)
            } footer: {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsFootnote(text: mode == .qr ? "휴대폰 · 태블릿은 카메라로 찍어요. 카메라가 없는 기기(PC)는 ‘8자리 코드’를 골라 주세요."
                                     : "카메라가 없는 기기(다른 PC)는 코드를 입력해요.")
                    SyncActions { Button("그만두기") { sync.close() }.keyboardShortcut(.cancelAction) }
                }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(n)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(Circle().fill(SettingsPane.sync.tint))
                .accessibilityHidden(true)
            Text(verbatim: text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 새 기기가 요청했다: 그 기기 화면의 숫자 4자리를 입력한다 ([연결] 에 처음부터 포커스를 두지 않는다 · 빈칸이면 아무것도 안 함)
struct SyncPairRequest: View {
    @EnvironmentObject private var sync: SyncController
    let info: SyncRequestInfo
    let busy: Bool
    let now: Date
    @State private var digits = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let who = SyncText.platformLabel(info.platform)
        Form {
            Section {
                SyncCodeField(label: "새 기기에 보이는 숫자", text: Binding(get: { digits }, set: { v in
                    digits = SyncText.digitsInput(v)
                    error = nil
                }), prompt: "0000", size: 17, focus: $focused, onSubmit: approve)
                if let error { SyncNote(tone: .error, text: error) }
                else if info.wrong { SyncNote(tone: .error, text: "숫자가 달라요. \(info.triesLeft)번 더 넣을 수 있어요.") }
            } header: {
                SyncPaneHead(step: SyncStepHead(symbol: "lock.shield.fill", title: "새 기기(\(who))가 연결을 요청했어요",
                                                detail: "내가 연결하려는 기기라면, 그 기기 화면에 보이는 숫자 4자리를 아래에 입력해 주세요. 맞으면 이 그룹의 열쇠가 그 기기로 가요."))
            } footer: {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsFootnote(text: "모르는 기기이거나 새 기기에 숫자가 없다면 [아니에요]를 눌러 주세요. \(SyncText.countdown(info.deadline, now: now)) 안에 정해 주세요.")
                        .monospacedDigit()
                    SyncActions {
                        Button("아니에요") { Task { await sync.pairDeny() } }
                            .disabled(busy)
                            .help("이 기기를 들이지 않아요")
                        Button(busy ? "연결하는 중…" : "연결", action: approve)
                            .disabled(busy || digits.count != 4)
                            .help("이 그룹의 열쇠를 새 기기로 보내요")
                    }
                }
            }
        }
        .onAppear {
            focused = true
            if sync.qaMode, let d = sync.qaInput["digits"] { digits = d }
        }
    }

    private func approve() {
        guard digits.count == 4, !busy else { return }
        error = nil
        let d = digits
        Task {
            let r = await sync.pairApprove(digits: d)
            if !r.ok, r.code == .digitsMismatch {
                digits = ""
                error = r.message
            }
        }
    }
}

// MARK: - 다른 기기에 합류하기

struct SyncJoinInput: View {
    @EnvironmentObject private var sync: SyncController
    @State private var code = ""
    /// 붙여 넣은 QR 의 연결 글 (원래 기기의 ‘연결 글 복사’)
    @State private var link: String?
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?

    private var complete: Bool { link != nil || SyncText.pairingCodeComplete(code) }

    var body: some View {
        Form {
            Section {
                if link != nil {
                    HStack {
                        Label("연결 글을 붙여 넣었어요", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color(nsColor: .systemGreen))
                        Spacer()
                        Button("지우기") { link = nil; error = nil }
                    }
                } else {
                    SyncCodeField(label: "8자리 코드", text: Binding(get: { code }, set: { v in
                        if let pasted = SyncText.pastedPairingLink(v) {
                            link = pasted
                            code = ""
                        } else {
                            code = SyncText.formatCodeInput(v)
                        }
                        error = nil
                    }), prompt: "ABCD-EFGH", onSubmit: submit)
                }
                SyncNameField(title: "이 Mac 이름", name: $name) { submit() }
                if let error { SyncNote(tone: .error, text: error) }
            } header: {
                SyncPaneHead(step: SyncStepHead(symbol: "link", title: "다른 기기에 합류하기",
                                                detail: "이미 동기화를 쓰는 기기에서 설정 → 동기화 → 기기 추가를 누르고 ‘8자리 코드’를 골라 주세요. 그 기기에 보이는 코드를 여기에 입력해요. 그 기기에서 ‘연결 글 복사’를 했다면 여기에 붙여 넣어도 돼요."))
            } footer: {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsFootnote(text: "대소문자와 하이픈은 가리지 않아요. 이름은 내 기기 목록에만 보이고 암호화돼요.")
                    SyncActions {
                        Button("취소") { sync.localStep = nil }
                            .keyboardShortcut(.cancelAction)
                            .disabled(busy)
                        Button(busy ? "확인하는 중…" : "연결 요청", action: submit)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!complete || busy)
                    }
                }
            }
        }
        .onAppear {
            if name.isEmpty { name = sync.suggestedName }
            if sync.qaMode {
                if let c = sync.qaInput["code"] { code = SyncText.formatCodeInput(c) }
                if let l = sync.qaInput["link"] { link = l }
                if let e = sync.qaInput["error"] { error = e }
            }
        }
    }

    private func submit() {
        guard complete, !busy else { return }
        busy = true
        error = nil
        let input = link ?? code
        Task {
            let r = await sync.joinStart(input, deviceName: name)
            busy = false
            if !r.ok, let m = r.message, !m.isEmpty {
                error = m
                link = nil
            }
        }
    }
}

struct SyncJoinFlow: View {
    @EnvironmentObject private var sync: SyncController
    let stage: SyncFlow.JoinStage
    let localBooks: [String]
    /// 합치기 전 백업을 만들지 못했다 (까닭)
    @State private var noBackup: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            content(now: ctx.date)
        }
        .alert("합치기 전 백업을 만들지 못했어요", isPresented: Binding(get: { noBackup != nil }, set: { if !$0 { noBackup = nil } })) {
            Button("돌아가기", role: .cancel) {}
            Button("백업 없이 합치기", role: .destructive) {
                Task { _ = await sync.joinAccept(withoutBackup: true) }
            }
        } message: {
            Text(verbatim: (noBackup ?? "") + " 겹치는 칸은 그룹 쪽이 이겨서, 백업 없이 합치면 이 Mac 의 그 칸 기록은 되찾을 수 없어요. 설정 → 데이터의 ‘백업 내보내기…’로 먼저 따로 보관해 둘 수도 있어요.")
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch stage {
        case .waiting(let digits, let deadline) where now < deadline:
            Form {
                Section {
                    HStack(spacing: 18) {
                        SyncBigDigits(digits: digits)
                        SyncCountdown(deadline: deadline, label: "승인을 기다리는 중")
                    }
                    .padding(.vertical, 8)
                } header: {
                    SyncPaneHead(step: SyncStepHead(symbol: "lock.shield.fill", title: "다른 기기에 이 숫자를 입력해 주세요",
                                                    detail: "다른 기기 화면에 연결 요청이 떠요. 거기에 아래 숫자 4자리를 넣고 [연결]을 누르면 이어져요. 요청이 뜨지 않으면 여기서 그만두세요."))
                } footer: {
                    SyncActions { Button("그만두기") { sync.close() }.keyboardShortcut(.cancelAction) }
                }
            }
        case .approved(let devices, let deadline) where now < deadline, .accepting(let devices, let deadline):
            let accepting = { if case .accepting = stage { return true } else { return false } }()
            let names = SyncText.groupNamesText(devices)
            Form {
                SyncMergeNotice(localBooks: localBooks,
                                head: SyncStepHead(symbol: "checkmark.circle.fill", tint: Color(nsColor: .systemGreen), title: "다른 기기에서 승인했어요",
                                                   detail: (names.isEmpty ? "" : "들어갈 그룹의 기기: \(names). ")
                                                    + "시작하기 전에 어떻게 합쳐지는지 확인해 주세요."
                                                    + " (\(SyncText.countdown(deadline, now: now)) 안에 시작해 주세요)")) {
                    SyncActions {
                        Button("그만두기") { sync.close() }
                            .disabled(accepting)
                        Button(accepting ? "합치는 중…" : "합치고 시작하기") {
                            Task {
                                let r = await sync.joinAccept()
                                if r.backupFailed { noBackup = r.message }
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(accepting)
                    }
                }
            }
        case .waiting, .approved, .expired:
            let after: Bool = {
                if case .approved = stage { return true }
                if case .expired(let a) = stage { return a }
                return false
            }()
            Form {
                Section {} header: {
                    SyncPaneHead(step: SyncStepHead(symbol: "clock.badge.exclamationmark", title: "시간이 지났어요",
                                                    detail: after ? "승인된 뒤 시작하지 않은 채 시간이 지나서, 이 Mac 은 그룹에 들어가지 않았어요. 그 기기에서 처음부터 다시 연결해 주세요."
                                                        : "다른 기기에서 승인하지 않은 채 시간이 지났어요. 그 기기에서 새 코드를 만들어 다시 해 주세요."))
                } footer: {
                    SyncActions { Button("처음으로") { sync.close() }.keyboardShortcut(.defaultAction) }
                }
            }
        case .done(let backup):
            Form {
                Section {
                    if let backup { SyncBackupNote(backup: backup) }
                } header: {
                    SyncPaneHead(step: SyncStepHead(symbol: "checkmark.circle.fill", tint: Color(nsColor: .systemGreen), title: "연결됐어요",
                                                    detail: "이제 이 Mac 도 같은 플래너를 써요. 그룹의 기록을 받아 오는 동안 잠깐 기다려 주세요."))
                } footer: {
                    SyncActions { Button("확인") { sync.close() }.keyboardShortcut(.defaultAction) }
                }
            }
        case .denied:
            Form {
                Section {} header: {
                    SyncPaneHead(step: SyncStepHead(symbol: "lock.fill", title: "연결하지 않았어요",
                                                    detail: "다른 기기에서 [아니에요]를 눌렀거나 연결을 그만뒀어요. 이 Mac 은 그룹에 들어가지 않았어요."))
                } footer: {
                    SyncActions { Button("처음으로") { sync.close() }.keyboardShortcut(.defaultAction) }
                }
            }
        case .error(let message):
            Form {
                Section {
                    SyncBanner(symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemRed), title: "다시 해 주세요", detail: message)
                } header: {
                    SyncPaneHead(step: SyncStepHead(symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemOrange), title: "연결하지 못했어요"))
                } footer: {
                    SyncActions { Button("처음으로") { sync.close() }.keyboardShortcut(.defaultAction) }
                }
            }
        }
    }
}

/// "이 Mac 의 기록과 합쳐요" (합류 · 복구 모두). 백업은 합치기 직전에 저절로 만든다
struct SyncMergeNotice<Actions: View>: View {
    let localBooks: [String]
    let head: SyncStepHead
    @ViewBuilder var actions: () -> Actions
    @EnvironmentObject private var sync: SyncController

    var body: some View {
        // 막 만든 그대로인 내 플래너 (처음 켤 때 만든 빈 '내 플래너'): 빼기를 켜 두면 합칠 책에서 뺀다
        let untouched = sync.untouchedLocalBooks.map(\.name)
        let dropping = sync.dropUntouchedBooks ? Set(sync.untouchedLocalBooks.map(\.name)) : []
        let books = SyncText.localBooksText(localBooks.filter { !dropping.contains($0) })
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("이 Mac 의 기록과 합쳐요 — 겹치는 칸은 그룹 쪽이 이겨요")
                    .font(.system(size: 13, weight: .semibold))
                bullet(books.isEmpty ? "이 Mac 에는 아직 내 플래너가 없어요. 그룹의 플래너를 받아 와요."
                       : "이 Mac 의 \(books)도 함께 동기화돼요. 그룹의 다른 기기에도 보여요.")
                bullet("같은 플래너의 같은 날 · 같은 칸에 두 쪽 기록이 다르면 그룹에 있던 것이 남아요. 겹치지 않는 기록은 모두 남아요.")
                bullet("예시 플래너는 기기마다 따로라 동기화하지 않아요.")
            }
            .padding(.vertical, 4)
            if !untouched.isEmpty {
                Toggle(isOn: $sync.dropUntouchedBooks) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: SyncText.dropUntouchedTitle(untouched))
                        Text(verbatim: SyncText.dropUntouchedDetail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("sync.merge.dropUntouched")
            }
            Text("합치기 직전에 이 Mac 의 플래너를 저절로 백업해 둬요 (데이터 폴더의 SyncBackups). 나중에 설정 → 데이터의 ‘백업 가져오기…’로 그때의 플래너를 새 플래너로 따로 꺼내 볼 수 있어요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            SyncPaneHead(step: head)
        } footer: {
            actions()
        }
        .onAppear { sync.refreshUntouchedLocalBooks() }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(.secondary).frame(width: 4, height: 4).offset(y: -3)
            Text(verbatim: s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SyncBackupNote: View {
    let backup: SyncBackupSnapshot

    var body: some View {
        SyncBanner(symbol: "archivebox.fill", tint: Color(nsColor: .systemBlue), title: "합치기 전 상태를 백업해 두었어요",
                   detail: "설정 → 데이터의 ‘백업 가져오기…’로 그때의 플래너를 새 플래너로 따로 꺼내 볼 수 있어요.") {
            Button("백업 폴더 열기") { NSWorkspace.shared.activateFileViewerSelecting(backup.files.isEmpty ? [backup.folder] : backup.files) }
        }
    }
}

// MARK: - 복구 코드로 되살리기

struct SyncRestoreInput: View {
    @EnvironmentObject private var sync: SyncController
    @State private var code = ""
    @State private var name = ""
    @State private var merge = false
    @State private var busy = false
    @State private var error: String?
    /// 합치기 전 백업을 만들지 못했다 (까닭)
    @State private var noBackup: String?

    var body: some View {
        let hint = SyncText.recoveryInputHint(code)
        Group {
            if merge {
                Form {
                    SyncMergeNotice(localBooks: sync.localBooks,
                                    head: SyncStepHead(symbol: "key.fill", title: "복구 코드로 되살리기",
                                                       detail: "그룹에 다시 들어가 동기화된 플래너를 받아 와요.")) {
                        VStack(alignment: .leading, spacing: 0) {
                            if let error { SyncNote(tone: .error, text: error).padding(.top, 8) }
                            SyncActions {
                                Button { merge = false } label: { Label("뒤로", systemImage: "chevron.left") }
                                    .disabled(busy)
                            } trailing: {
                                Button("취소") { sync.localStep = nil }
                                    .keyboardShortcut(.cancelAction)
                                    .disabled(busy)
                                Button(busy ? "되살리는 중…" : "합치고 되살리기") { go() }
                                    .keyboardShortcut(.defaultAction)
                                    .disabled(busy)
                            }
                        }
                    }
                }
            } else {
                Form {
                    Section {
                        SyncCodeField(label: "복구 코드 (25자)", text: Binding(get: { code }, set: { v in
                            code = String(v.uppercased().prefix(40))
                            error = nil
                        }), prompt: "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", size: 13, onSubmit: { if hint.ok { merge = true } })
                        Text(verbatim: hint.text)
                            .font(.callout)
                            .foregroundStyle(hint.ok ? Color(nsColor: .systemGreen) : hint.problem ? Color(nsColor: .systemRed) : .secondary)
                        SyncNameField(title: "이 Mac 이름", name: $name)
                        if let error { SyncNote(tone: .error, text: error) }
                    } header: {
                        SyncPaneHead(step: SyncStepHead(symbol: "key.fill", title: "복구 코드로 되살리기",
                                                        detail: "기기를 모두 잃어버렸을 때 쓰는 방법이에요. 동기화를 처음 켤 때 적어 둔 25자 복구 코드를 입력해 주세요. 쓰던 기기가 하나라도 남아 있다면 그 기기에서 ‘기기 추가’로 연결하는 편이 쉬워요."))
                    } footer: {
                        SyncActions {
                            Button("취소") { sync.localStep = nil }
                                .keyboardShortcut(.cancelAction)
                            Button("다음") { merge = true }
                                .keyboardShortcut(.defaultAction)
                                .disabled(!hint.ok)
                        }
                    }
                }
            }
        }
        .onAppear {
            if name.isEmpty { name = sync.suggestedName }
            if sync.qaMode {
                if let c = sync.qaInput["restore"] { code = c }
                if sync.qaInput["merge"] != nil { merge = true }
            }
        }
        .alert("합치기 전 백업을 만들지 못했어요", isPresented: Binding(get: { noBackup != nil }, set: { if !$0 { noBackup = nil } })) {
            Button("돌아가기", role: .cancel) {}
            Button("백업 없이 되살리기", role: .destructive) { go(withoutBackup: true) }
        } message: {
            Text(verbatim: (noBackup ?? "") + " 겹치는 칸은 그룹 쪽이 이겨서, 백업 없이 합치면 이 Mac 의 그 칸 기록은 되찾을 수 없어요. 설정 → 데이터의 ‘백업 내보내기…’로 먼저 따로 보관해 둘 수도 있어요.")
        }
    }

    private func go(withoutBackup: Bool = false) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            let r = await sync.restore(code: code, deviceName: name, withoutBackup: withoutBackup)
            busy = false
            if r.backupFailed {
                noBackup = r.message
            } else if !r.ok {
                error = r.message ?? "되살리지 못했어요."
                merge = false
            }
        }
    }
}

struct SyncRestoreDone: View {
    @EnvironmentObject private var sync: SyncController
    let evicted: Bool
    let backup: SyncBackupSnapshot?

    var body: some View {
        Form {
            Section {
                if let backup { SyncBackupNote(backup: backup) }
                SyncBanner(symbol: "key.fill", tint: Color(nsColor: .systemBlue), title: "복구 코드를 새로 만드는 것도 생각해 보세요",
                           detail: "잃어버린 기기에서 복구 코드가 보였을 수 있다면, 기기 목록에서 그 기기를 빼고 복구 코드를 새로 만들어 두세요.")
            } header: {
                SyncPaneHead(step: SyncStepHead(symbol: "checkmark.circle.fill", tint: Color(nsColor: .systemGreen), title: "되살렸어요",
                                                detail: "그룹에 다시 들어왔어요. 동기화된 플래너를 받아 오는 동안 잠깐 기다려 주세요."
                                                    + (evicted ? " 그룹에 기기가 10대 있어서 가장 오래 쓰지 않은 기기 하나를 뺐어요." : "")))
            } footer: {
                SyncActions { Button("확인") { sync.close() }.keyboardShortcut(.defaultAction) }
            }
        }
    }
}
