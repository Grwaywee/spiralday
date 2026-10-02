import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreText

// ─────────────────────────────────────────────────────────────────────────────
// 책 맨 앞의 두 장 (일간 · 주간 모두): [표지] → [첫 장] → 책의 첫날 / 첫 주
//   표지   책 이름(손글씨) · 기간 · 표지 색 띠 · 워드마크. 이름은 설정에서만 바꾼다.
//   첫 장  엇갈린 두 줄 사이에 큰 따옴표와 하고 싶은 말 (prefs.motto). 누르면 그 자리에서 쓴다.
// 번호는 AppState 가 첫 장 바로 앞 두 칸으로 매긴다 (AppState.frontIndex / frontPage / showFront).
// 좌표는 모두 디자인 단위 (일간 1277 × 2000, 주간 2000 × 1277) × u.
// ─────────────────────────────────────────────────────────────────────────────

/// 책 맨 앞의 장 (순서대로)
public enum FrontPage: Int, CaseIterable, Sendable {
    case cover, motto

    /// 창 제목 등에 쓰는 이름
    public var title: String {
        switch self {
        case .cover: "표지"
        case .motto: "첫 장"
        }
    }

    /// 첫 장의 글 편집 키 (AppState.editingKey 에 넣으면 그 자리에서 쓰기 시작)
    public static let mottoKey = "motto"
}

/// 표지 / 첫 장의 내용 (종이 바탕은 PageView 가 먼저 깐다)
public struct FrontMatterPage: View {
    public let page: FrontPage
    public let kind: PageKind
    public let u: CGFloat

    public init(page: FrontPage, kind: PageKind, u: CGFloat) {
        self.page = page
        self.kind = kind
        self.u = u
    }

    public var body: some View {
        switch page {
        case .cover: CoverPage(kind: kind, u: u)
        case .motto: MottoPage(kind: kind, u: u)
        }
    }
}

/// 종이 바탕까지 한 장 (PDF 에 그릴 때). 크기는 부모가 정한다.
public struct FrontMatterSheet: View {
    public let page: FrontPage
    public let kind: PageKind

    public init(page: FrontPage, kind: PageKind) {
        self.page = page
        self.kind = kind
    }

    public var body: some View {
        GeometryReader { g in
            let u = g.size.width / kind.design.width
            ZStack(alignment: .topLeading) {
                PaperSurface(kind: kind, u: u)
                FrontMatterPage(page: page, kind: kind, u: u)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
    }
}

/// 앞 장에서 가리킬 자리 (디자인 단위, 튜토리얼 등에서 쓴다)
public enum FrontMatterLayout {
    /// 표지: 책 이름을 쓴 이름표
    public static func coverCard(_ kind: PageKind) -> CGRect { CoverGeo(kind: kind).card }
    /// 표지: 색 띠
    public static func coverBand(_ kind: PageKind) -> CGRect { CoverGeo(kind: kind).band }
    /// 첫 장: 하고 싶은 말을 쓰는 칸 (누르면 편집)
    public static func mottoText(_ kind: PageKind) -> CGRect { MottoGeo(kind: kind).textRect }
    /// 첫 장: 위 줄부터 아래 줄까지 (따옴표 포함)
    public static func mottoBlock(_ kind: PageKind) -> CGRect {
        let g = MottoGeo(kind: kind)
        return CGRect(x: g.topRule.lowerBound, y: g.top, width: g.bottomRule.upperBound - g.topRule.lowerBound,
                      height: g.bottom - g.top)
    }
}

// MARK: - 인쇄 글자 (Canvas)

private enum Print {
    /// 글자를 기준선에 맞춰 그린다. align: 0 = 왼쪽, 0.5 = 가운데, 1 = 오른쪽.
    /// tracking 은 마지막 글자 뒤에도 붙으므로 그 몫을 빼고 잉크 기준으로 맞춘다.
    @discardableResult
    static func text(_ ctx: GraphicsContext, _ t: Text, x: CGFloat, baseline: CGFloat,
                     align: CGFloat = 0, tracking: CGFloat = 0) -> CGFloat {
        let r = ctx.resolve(t)
        let box = CGSize(width: 4000, height: 800)
        let s = r.measure(in: box)
        let b = r.firstBaseline(in: box)
        let ink = s.width - tracking
        ctx.draw(r, in: CGRect(x: x - ink * align, y: baseline - b, width: s.width, height: s.height))
        return ink
    }

    static func capHeight(_ weight: Fonts.PrintWeight, _ size: CGFloat) -> CGFloat {
        PlatformFont(name: weight.postScriptName, size: size)?.capHeight ?? size * 0.708
    }

    static func hline(_ ctx: GraphicsContext, _ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat, _ width: CGFloat, _ color: Color) {
        ctx.fill(Path(CGRect(x: x0, y: y - width / 2, width: x1 - x0, height: width)), with: .color(color))
    }

    /// 글자 하나의 윤곽 (잉크 기준, 왼쪽 위가 원점). 큰 따옴표를 선명한 벡터로 그릴 때 쓴다.
    static func glyph(_ ch: Character, font name: String, size: CGFloat) -> Path {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        var chars = Array(String(ch).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count),
              let cg = CTFontCreatePathForGlyph(font, glyphs[0], nil) else { return Path() }
        // CoreText 는 y 가 위로 자란다 → 뒤집어서 잉크 왼쪽 위를 원점에
        let p = Path(cg).applying(CGAffineTransform(scaleX: 1, y: -1))
        let b = p.boundingRect
        return p.offsetBy(dx: -b.minX, dy: -b.minY)
    }
}

// MARK: - 표지

/// 표지 배치 (디자인 단위). 머리선·워드마크는 같은 쪽의 날짜 페이지와 같은 자리에 둔다.
private struct CoverGeo {
    let kind: PageKind
    var W: CGFloat { kind.design.width }
    var H: CGFloat { kind.design.height }
    var portrait: Bool { kind == .daily }

    /// 양식과 같은 좌우 여백 (일간: DailyForm, 주간: 42)
    var left: CGFloat { portrait ? DailyForm.left : 42 }
    var right: CGFloat { portrait ? DailyForm.wordmarkRight : W - 42 }
    var cx: CGFloat { (left + right) / 2 }
    /// 머리선: PLANNER ──── 2026
    var headY: CGFloat { portrait ? DailyForm.dateRuleY : WK.goalFrame.midY }  // 주간은 MY GOAL 칸 가운데 높이에 맞춘다
    /// 표지 색 띠 (스프링 구멍은 가리지 않는다)
    var band: CGRect {
        portrait ? CGRect(x: 36, y: 770, width: W - 36, height: 330)
                 : CGRect(x: 0, y: 450, width: W, height: 300)
    }
    /// 띠 위의 이름표
    var card: CGRect {
        let w: CGFloat = portrait ? 820 : 980, h: CGFloat = portrait ? 212 : 196
        return CGRect(x: cx - w / 2, y: band.midY - h / 2, width: w, height: h)
    }
    var nameFont: CGFloat { portrait ? 124 : 118 }
    var periodBaseline: CGFloat { band.maxY + (portrait ? 116 : 104) }
    /// 워드마크 오른쪽 끝 · 기준선
    var wordmark: CGPoint {
        portrait ? CGPoint(x: DailyForm.wordmarkRight, y: DailyForm.wordmarkBaseline) : CGPoint(x: W - 42, y: H - 70)
    }
}

private struct CoverPage: View {
    let kind: PageKind
    let u: CGFloat

    @EnvironmentObject private var store: PlannerStore
    @Environment(\.isPrinting) private var isPrinting

    var body: some View {
        let g = CoverGeo(kind: kind)
        let book = store.activeBook
        let name = book?.name ?? "Spiralday"
        let color = ColorConcept.of(book?.cover ?? 0).accent
        let c = g.card
        let sc = RuledText.fitScale(name, fontSize: g.nameFont, width: c.width - 90, height: c.height - 36, maxLines: 2)
        ZStack(alignment: .topLeading) {
            // 표지 색 띠 (화면에서는 종이 결이 비친다)
            ZStack {
                color
                if !isPrinting { NoiseLayer(opacity: 0.55).blendMode(.multiply) }
            }
            .frame(width: g.band.width * u, height: g.band.height * u)
            .offset(x: g.band.minX * u, y: g.band.minY * u)

            // 이름표
            RoundedRectangle(cornerRadius: 16 * u, style: .continuous)
                .fill(isPrinting ? Color.white : Ink.paper)
                .overlay(RoundedRectangle(cornerRadius: 10 * u, style: .continuous)
                    .stroke(color.opacity(0.55), lineWidth: max(0.6, 1.6 * u))
                    .padding(12 * u))
                .frame(width: c.width * u, height: c.height * u)
                .offset(x: c.minX * u, y: c.minY * u)

            Text(name)
                .font(Fonts.hand(g.nameFont * sc * u))
                .foregroundStyle(Ink.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: (c.width - 90) * u, height: (c.height - 24) * u)
                .offset(x: (c.minX + 45) * u, y: (c.minY + 16) * u)

            Canvas { ctx, _ in
                ctx.scaleBy(x: u, y: u)
                drawPrint(ctx, g, book)
            }
        }
        .frame(width: g.W * u, height: g.H * u, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func drawPrint(_ ctx: GraphicsContext, _ g: CoverGeo, _ book: BookInfo?) {
        // 머리선: 날짜 페이지의 "DATE ────" 와 같은 모양
        let size: CGFloat = 19.8, weight = Fonts.PrintWeight.demiBold, tr: CGFloat = 3.2
        let cap = Print.capHeight(weight, size)
        let base = g.headY + 0.5 + cap / 2
        let label = Text("PLANNER").font(Fonts.print(size, weight)).tracking(tr).foregroundStyle(Ink.print)
        let lw = Print.text(ctx, label, x: g.left + 0.7, baseline: base, tracking: tr)
        var ruleEnd = g.right
        if let book {
            let year = Text(Self.years(book)).font(Fonts.print(size, weight)).tracking(tr).foregroundStyle(Ink.print)
            let yw = Print.text(ctx, year, x: g.right, baseline: base, align: 1, tracking: tr)
            ruleEnd = g.right - yw - 13
        }
        Print.hline(ctx, g.left + 0.7 + lw + 13, ruleEnd, g.headY, DailyForm.heavy, Ink.print)

        // 기간
        if let book {
            let pt: CGFloat = 3
            let t = Text(Self.period(book)).font(Fonts.print(34, .medium)).tracking(pt).foregroundStyle(Ink.print)
            Print.text(ctx, t, x: g.cx, baseline: g.periodBaseline, align: 0.5, tracking: pt)
        }

        // 워드마크 (날짜 페이지와 같은 굵은 소문자)
        Print.text(ctx, Text(DailyForm.wordmark).font(.system(size: 31.5, weight: .bold)).tracking(0.78)
                    .foregroundStyle(Ink.print),
                   x: g.wordmark.x, baseline: g.wordmark.y, align: 1, tracking: 0.78)
    }

    /// "2026" 또는 "2026 – 2027"
    static func years(_ b: BookInfo) -> String {
        let a = Dates.comp(b.start).year!
        guard let e = b.end, Dates.comp(e).year! != a else { return String(a) }
        return "\(a) – \(Dates.comp(e).year!)"
    }

    /// "2026. 9. 1.  —  2026. 12. 31." (끝이 없으면 "2026. 9. 1.  —")
    static func period(_ b: BookInfo) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy. M. d."
        let s = f.string(from: b.start)
        return b.end.map { "\(s)  —  \(f.string(from: $0))" } ?? "\(s)  —"
    }
}

// MARK: - 첫 장 (하고 싶은 말)

/// 첫 장 배치 (디자인 단위). 두 줄은 서로 엇갈린다: 위 15%–75%, 아래 25%–88%.
private struct MottoGeo {
    let kind: PageKind
    var W: CGFloat { kind.design.width }
    var H: CGFloat { kind.design.height }
    var portrait: Bool { kind == .daily }

    var top: CGFloat { portrait ? 650 : 372 }
    var bottom: CGFloat { portrait ? 1290 : 900 }
    var topRule: ClosedRange<CGFloat> { (W * 0.15)...(W * 0.75) }
    var bottomRule: ClosedRange<CGFloat> { (W * 0.25)...(W * 0.88) }
    /// 큰 따옴표 글자 크기
    var quoteSize: CGFloat { 290 }
    /// 따옴표와 줄 사이
    var quoteGap: CGFloat { 30 }
    /// 글 칸: 두 줄 한가운데
    var textRect: CGRect {
        let w: CGFloat = portrait ? W * 0.6 : 1060
        let cx = (topRule.lowerBound + bottomRule.upperBound) / 2
        let inset: CGFloat = portrait ? 118 : 110
        return CGRect(x: cx - w / 2, y: top + inset, width: w, height: bottom - top - 2 * inset)
    }
    var font: CGFloat { 76 }
    var hintFont: CGFloat { 50 }
}

private struct MottoPage: View {
    let kind: PageKind
    let u: CGFloat

    @EnvironmentObject private var store: PlannerStore
    @Environment(\.isPrinting) private var isPrinting

    static let hint = "여기에 적고 싶은 말을 적어 보세요"

    var body: some View {
        let g = MottoGeo(kind: kind)
        let text = store.data.prefs.motto
        let r = g.textRect
        // 글이 길어지면 칸 안에 다 들어가도록 글자가 조금씩 작아진다 (가운데 정렬, 여러 줄)
        let sc = RuledText.fitScale(text, fontSize: g.font, width: r.width - 16, height: r.height - 6, maxLines: 99)
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                ctx.scaleBy(x: u, y: u)
                Self.drawPrint(ctx, g)
            }
            .allowsHitTesting(false)

            InlineField(text: Binding(get: { store.data.prefs.motto },
                                      set: { v in store.editPrefs { $0.motto = v } }),
                        // 빈 칸 안내는 화면에서만 (PDF 에는 찍지 않는다)
                        placeholder: isPrinting ? "" : Self.hint,
                        font: Fonts.hand((text.isEmpty ? g.hintFont : g.font * sc) * u),
                        key: FrontPage.mottoKey, lines: 14, alignment: .center)
                .frame(width: r.width * u, height: r.height * u)
                .offset(x: r.minX * u, y: r.minY * u)
                .help("첫 장 — 이 플래너에 적어 두고 싶은 말을 써 보세요 (⌥↩ 줄 바꿈 · Esc 나 바깥을 누르면 끝)")
        }
        .frame(width: g.W * u, height: g.H * u, alignment: .topLeading)
    }

    private static let quoteFont = "Georgia"

    private static func drawPrint(_ ctx: GraphicsContext, _ g: MottoGeo) {
        let rule = Ink.rule, w: CGFloat = 2
        Print.hline(ctx, g.topRule.lowerBound, g.topRule.upperBound, g.top, w, rule)
        Print.hline(ctx, g.bottomRule.lowerBound, g.bottomRule.upperBound, g.bottom, w, rule)

        // “ 는 위 줄 바로 아래 왼쪽, ” 는 아래 줄 바로 위 오른쪽
        let quote = Ink.dot
        let open = Print.glyph("\u{201C}", font: quoteFont, size: g.quoteSize)
        ctx.fill(open.offsetBy(dx: g.topRule.lowerBound, dy: g.top + g.quoteGap), with: .color(quote))
        let close = Print.glyph("\u{201D}", font: quoteFont, size: g.quoteSize)
        let cb = close.boundingRect
        ctx.fill(close.offsetBy(dx: g.bottomRule.upperBound - cb.width, dy: g.bottom - g.quoteGap - cb.height),
                 with: .color(quote))

        // 아래 줄 끝 아래의 작은 인사
        let tr: CGFloat = 3.6
        let t = Text("· HELLO? WELCOME! ·").font(Fonts.print(15, .medium)).tracking(tr).foregroundStyle(Ink.soft)
        Print.text(ctx, t, x: g.bottomRule.upperBound, baseline: g.bottom + 42, align: 1, tracking: tr)
    }
}
