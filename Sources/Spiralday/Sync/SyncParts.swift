import AppKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import SpiraldaySync

// 동기화 화면 조각 (설정 창의 모양 그대로 — Form .grouped 의 칸 · 머리 · 꼬리):
// 상태 점 · 단계 머리 · 알림 줄 · 배너 · 아래 단추 줄 · 코드 글자 · 큰 숫자 · 남은 시간 · QR 그림 · 클립보드

extension SyncTone {
    var color: Color {
        switch self {
        case .off: Color(nsColor: .tertiaryLabelColor)
        case .ok: Color(nsColor: .systemGreen)
        case .busy: Color(nsColor: .systemBlue)
        case .offline: Color(nsColor: .systemGray)
        case .warn: Color(nsColor: .systemOrange)
        case .error: Color(nsColor: .systemRed)
        }
    }
}

struct SyncStatusDot: View {
    let tone: SyncTone
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// 흐름 한 단계의 머리: 기호 + 제목 + 설명 (칸 위 — Section 의 머리)
struct SyncStepHead: View {
    let symbol: String
    var tint: Color = Color(hex: "2B8FBF")
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, alignment: .center)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }
}

/// 설정 → 동기화의 첫 칸 머리: 설정 창의 머리 + (있으면) 단계 머리
struct SyncPaneHead: View {
    var step: SyncStepHead?
    var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPaneHeader(pane: .sync)
            if let step { step }
            if let title { SettingsSectionTitle(title: title) }
        }
    }
}

/// 오류 · 확인 한 줄
struct SyncNote: View {
    enum Tone { case ok, error, info, warn }
    let tone: Tone
    let text: String

    var body: some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
        }
        .font(.callout)
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch tone {
        case .ok: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .warn: "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .ok: Color(nsColor: .systemGreen)
        case .error: Color(nsColor: .systemRed)
        case .info: .secondary
        case .warn: Color(nsColor: .systemOrange)
        }
    }
}

/// 배너 (경고 · 안내) — 칸 하나
struct SyncBanner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                Text(verbatim: detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            HStack(spacing: 8) { actions() }
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}

extension SyncBanner where Actions == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail) { EmptyView() }
    }
}

/// 칸 아래 단추 줄 (오른쪽 정렬: 보조 · 주 단추. 왼쪽에 '뒤로' 같은 것을 둘 수 있다)
struct SyncActions<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.top, 10)
    }
}

extension SyncActions where Leading == EmptyView {
    init(@ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(leading: { EmptyView() }, trailing: trailing)
    }
}

/// 한 줄 설명 (제목 + 회색 설명) — 칸 안의 줄
struct SyncRowText: View {
    let title: String
    var detail: String?
    var tone: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
            if let detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.callout)
                    .foregroundStyle(tone)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 첫 화면의 장점 한 줄
struct SyncPoint: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIconTile(symbol: symbol, tint: SettingsPane.sync.tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                Text(verbatim: detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// 코드 글자 (복구 코드 묶음 · 8자 코드): 고정 폭
struct SyncCodeText: View {
    let text: String
    var size: CGFloat = 19

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .tracking(1.5)
            .textSelection(.disabled)
    }
}

/// 이 Mac 화면의 확인 숫자 4자리 (크게 — 다른 기기에 입력한다)
struct SyncBigDigits: View {
    let digits: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(digits.enumerated()), id: \.offset) { _, c in
                Text(String(c))
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .frame(minWidth: 42, minHeight: 54)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("확인 숫자"))
        .accessibilityValue(Text(verbatim: SyncText.spelled(digits)))
    }
}

/// "새 기기를 기다리는 중 · 9:41 남음"
struct SyncCountdown: View {
    let deadline: Date
    let label: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(verbatim: "\(label) · \(SyncText.countdown(deadline, now: ctx.date)) 남음")
                    .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(Text(verbatim: SyncText.countdownSpoken(deadline, now: ctx.date)))
        }
    }
}

/// QR 그림 (CoreImage, 오류 정정 M, 픽셀 그대로 키움). 종이처럼 늘 흰 바탕
struct SyncQRCode: View {
    let text: String
    var side: CGFloat = 180

    var body: some View {
        Group {
            if let img = Self.image(text) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement()
        .accessibilityLabel(Text("새 기기의 카메라로 찍을 연결 QR 코드"))
        .accessibilityAddTraits(.isImage)
    }

    static func image(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// 코드 · 숫자 칸 (이름표는 보통 글꼴, 칸 안의 글만 고정 폭)
struct SyncCodeField: View {
    let label: String
    let text: Binding<String>
    var prompt: String?
    var size: CGFloat = 15
    /// 처음부터 이 칸에 포커스 (확인 숫자 칸)
    var focus: FocusState<Bool>.Binding?
    var onSubmit: () -> Void = {}

    var body: some View {
        LabeledContent {
            let field = TextField(text: text, prompt: prompt.map { Text(verbatim: $0) }) { Text(verbatim: label) }
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.system(size: size, weight: .semibold, design: .monospaced))
                .onSubmit(onSubmit)
            if let focus { field.focused(focus) } else { field }
        } label: {
            Text(verbatim: label)
        }
    }
}

/// 이름 칸 (설정 창의 칸 한 줄)
struct SyncNameField: View {
    let title: String
    @Binding var name: String
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(text: $name) { Text(verbatim: title) }
            .onSubmit(onSubmit)
            .onChange(of: name) { _, v in if v.count > 40 { name = String(v.prefix(40)) } }
    }
}

// MARK: - 클립보드 (비밀은 이 Mac 에만 · 잠깐만)

@MainActor
enum SyncClipboard {
    /// 클립보드 기록 앱(Raycast · Alfred · Paste · Maccy 등)이 기록에 남기지 않는 비밀 표시 (nspasteboard.org 의 약속)
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// 잠깐만 쓰는 값 표시 (기록 앱이 건너뛴다)
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// 이 Mac 의 클립보드에만 둔다 (Handoff 의 공용 클립보드로 다른 Apple 기기에 가지 않게).
    /// 비밀 · 잠깐 표시를 같이 넣어 클립보드 기록 앱이 보관하지 않게 하고, after 초 뒤에 그대로 남아 있으면 지운다
    static func copySecret(_ text: String, clearAfter seconds: TimeInterval) {
        let pb = NSPasteboard.general
        pb.prepareForNewContents(with: .currentHostOnly)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: concealedType)
        pb.setData(Data(), forType: transientType)
        let count = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, seconds)) {
            if pb.changeCount == count, pb.string(forType: .string) == text { pb.clearContents() }
        }
    }
}
