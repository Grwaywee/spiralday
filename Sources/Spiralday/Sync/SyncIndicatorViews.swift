import AppKit
import SwiftUI
import SpiraldayKit

// ─────────────────────────────────────────────────────────────────────────────
// 동기화를 켰을 때만 보이는 작은 표시 (꺼져 있으면 아무것도 그리지 않는다 — 팔레트 · 플래너는 예전 그대로):
//   · 팔레트의 설정(톱니) 단추 귀퉁이: 상태 색 (동기화됨 초록 · 맞추는 중 파랑 · 오프라인 회색 · 잠깐 문제 주황 ·
//     빠짐/가득 참 빨강, 복구 코드를 확인하지 않았으면 주황). 손볼 것이 있으면 톱니 단추가 설정 → 동기화로 바로 연다
//   · 플래너 위의 안내: "다른 기기에서 지운 플래너라 다른 플래너를 펼쳤어요." (4초 뒤 사라진다)
// ─────────────────────────────────────────────────────────────────────────────

struct SyncGearBadge: ViewModifier {
    @ObservedObject private var indicator = SyncIndicator.shared

    func body(content: Content) -> some View {
        let info = indicator.gear
        content
            .overlay(alignment: .center) {
                if let info {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 6.5, weight: .heavy))
                        .foregroundStyle(info.tone.color)
                        .frame(width: 12, height: 12)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                        .offset(x: 8, y: 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .accessibilityValue(Text(verbatim: info?.spoken ?? ""))
            .animation(.easeOut(duration: 0.2), value: info?.tone)
    }
}

/// 설정 단추의 도움말: 동기화를 켰으면 상태를, 아니면 원래 도움말을
struct SyncSettingsHelp: ViewModifier {
    @ObservedObject private var indicator = SyncIndicator.shared
    let fallback: String

    func body(content: Content) -> some View {
        content.help(indicator.gear.map { "설정 (⌘,) — \($0.spoken)" } ?? fallback)
    }
}

extension View {
    /// 팔레트의 설정 단추에: 동기화 상태 표시 (꺼져 있으면 아무것도 없다)
    func syncGearBadge() -> some View { modifier(SyncGearBadge()) }
    func syncSettingsHelp(_ fallback: String) -> some View { modifier(SyncSettingsHelp(fallback: fallback)) }
}

/// 플래너 위에 잠깐 뜨는 동기화 안내. 눌러서 닫는다
struct SyncNoticeOverlay: View {
    @ObservedObject private var indicator = SyncIndicator.shared

    var body: some View {
        VStack {
            if let n = indicator.notice {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").accessibilityHidden(true)
                    Text(verbatim: n.text).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(white: 0.16))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color(white: 0.985)))
                .overlay(Capsule().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.14), radius: 9, y: 2)
                .padding(.top, 44)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { withAnimation { indicator.notice = nil } }
                .help("눌러서 닫아요")
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .task(id: n.id) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if indicator.notice?.id == n.id { withAnimation { indicator.notice = nil } }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.3), value: indicator.notice)
        .allowsHitTesting(indicator.notice != nil)
    }
}

// MARK: - 메뉴 (플래너 메뉴의 동기화 항목)

struct SyncMenuItems: View {
    @ObservedObject var sync: SyncController
    let store: PlannerStore
    @ObservedObject var state: AppState
    let blocked: () -> Bool

    var body: some View {
        Divider()
        Button("지금 맞추기") { Task { await sync.syncNow() } }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!sync.inGroup || sync.status == nil)
        Button(sync.historyRequestForCurrentPage()?.kind == .week ? "이 주의 이전 버전…" : "이 날의 이전 버전…") {
            guard !blocked(), let r = sync.historyRequestForCurrentPage() else { return }
            sync.historyRequest = r
            SettingsWindowController.shared.showSync(store: store, state: state)
        }
        .disabled(!sync.inGroup)
        Button("동기화 설정…") {
            guard !blocked() else { NSSound.beep(); return }
            SettingsWindowController.shared.showSync(store: store, state: state)
        }
    }
}
