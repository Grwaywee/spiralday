#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// PDF 로 뽑기
//   일간 · A4 세로   하루 한 장
//   일간 · A4 반쪽   A4 가로 한 장에 이틀 (가운데를 자르면 실물 크기 한 장씩)
//   주간 · A4 가로   한 주 한 장
//   홈   · A4 가로
// 일간 · 주간은 맨 앞에 표지와 첫 장을 넣을 수 있다 (A4 반쪽이면 첫 장에 둘이 나란히).
// 페이지는 SwiftUI 뷰를 그대로 PDF 에 그려서 글씨·선이 벡터로 선명하게 남는다.
// ─────────────────────────────────────────────────────────────────────────────

public enum PDFLayout: String, CaseIterable, Identifiable, Sendable {
    case dailyA4, dailyHalf, weekly, home

    public var id: String { rawValue }

    public var kind: PageKind {
        switch self {
        case .dailyA4, .dailyHalf: .daily
        case .weekly: .weekly
        case .home: .home
        }
    }

    public var title: String {
        switch self {
        case .dailyA4: "A4 세로 · 하루 한 장"
        case .dailyHalf: "A4 반쪽 · 두 장씩"
        case .weekly: "A4 가로 · 한 주 한 장"
        case .home: "A4 가로"
        }
    }

    public var detail: String {
        switch self {
        case .dailyA4: "A4 한 장 가득 하루를 뽑아요."
        case .dailyHalf: "A4 가로 한 장에 이틀을 나란히 놓아요. 가운데 선을 따라 자르면 실물 플래너 크기예요."
        case .weekly: "A4 가로 한 장에 한 주를 뽑아요."
        case .home: "지금 펼친 플래너의 통계를 A4 가로 한 장으로 뽑아요."
        }
    }

    /// 용지 크기 (pt, 1pt = 1/72 inch)
    public var sheet: CGSize {
        self == .dailyA4 ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 841.89, height: 595.28)
    }

    public var perSheet: Int { self == .dailyHalf ? 2 : 1 }
}

@MainActor
public enum PDFExporter {
    /// 프린터가 못 찍는 가장자리 여백 (pt)
    public static let margin: CGFloat = 16

    /// 뽑을 페이지들 (일간: 날짜, 주간: 그 주 월요일, 홈: 한 장)
    public static func pages(_ layout: PDFLayout, from: Date, to: Date) -> [Date] {
        switch layout.kind {
        case .home:
            return [Dates.day(Date())]
        case .daily:
            let a = Dates.day(min(from, to)), b = Dates.day(max(from, to))
            let n = Dates.daysBetween(a, b)
            return (0...n).map { Dates.add(days: $0, to: a) }
        case .weekly:
            let a = Dates.weekStart(min(from, to)), b = Dates.weekStart(max(from, to))
            let n = Dates.daysBetween(a, b) / 7
            return (0...n).map { Dates.add(days: 7 * $0, to: a) }
        }
    }

    public static func sheetCount(_ layout: PDFLayout, pageCount: Int) -> Int {
        (pageCount + layout.perSheet - 1) / layout.perSheet
    }

    /// 표지와 첫 장을 넣을 수 있는 용지인지 (일간 · 주간. 펼친 책이 있을 때)
    public static func canIncludeFront(_ layout: PDFLayout, store: PlannerStore) -> Bool {
        layout.kind.flips && store.activeBook != nil
    }

    /// PDF 한 장 한 장: 표지 · 첫 장 또는 날짜 페이지
    private enum Item {
        case front(FrontPage)
        case page(Date)
    }

    /// PDF 파일을 만든다. progress 는 0…1.
    /// frontMatter: 맨 앞에 표지와 첫 장을 넣는다 (일간 · 주간). A4 반쪽이면 첫 장에 둘이 나란히 들어간다.
    public static func export(_ layout: PDFLayout, from: Date, to: Date, cutGuides: Bool, frontMatter: Bool = true,
                       store: PlannerStore, state: AppState, to url: URL,
                       progress: @escaping (Double) -> Void) async throws {
        var items = pages(layout, from: from, to: to).map(Item.page)
        if frontMatter && canIncludeFront(layout, store: store) {
            items.insert(contentsOf: FrontPage.allCases.map(Item.front), at: 0)
        }
        var box = CGRect(origin: .zero, size: layout.sheet)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, [
            kCGPDFContextCreator as String: "Spiralday",
            kCGPDFContextTitle as String: "\(store.activeBook?.name ?? "Spiralday") — \(layout.title)",
        ] as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let sheets = stride(from: 0, to: items.count, by: layout.perSheet).map {
            Array(items[$0..<min($0 + layout.perSheet, items.count)])
        }
        for (n, group) in sheets.enumerated() {
            pdf.beginPDFPage(nil)
            for (slotIndex, item) in group.enumerated() {
                let r = slot(layout, slotIndex)
                switch item {
                case .page(let date): draw(layout, date: date, in: r, pdf: pdf, store: store, state: state)
                case .front(let page):
                    render(FrontMatterSheet(page: page, kind: layout.kind), kind: layout.kind, in: r, pdf: pdf,
                           store: store, state: state)
                }
            }
            if layout == .dailyHalf && cutGuides { drawCutGuide(pdf, layout.sheet) }
            pdf.endPDFPage()
            progress(Double(n + 1) / Double(sheets.count))
            await Task.yield()
        }
        pdf.closePDF()
    }

    /// 한 장 안에서 페이지가 들어갈 자리 (PDF 좌표: 왼쪽 아래가 원점)
    private static func slot(_ layout: PDFLayout, _ i: Int) -> CGRect {
        let s = layout.sheet
        switch layout {
        case .dailyHalf:
            let half = s.width / 2
            return CGRect(x: CGFloat(i) * half, y: 0, width: half, height: s.height).insetBy(dx: margin, dy: margin)
        default:
            return CGRect(origin: .zero, size: s).insetBy(dx: margin, dy: margin)
        }
    }

    private static func draw(_ layout: PDFLayout, date: Date, in slot: CGRect, pdf: CGContext,
                             store: PlannerStore, state: AppState) {
        let kind = layout.kind
        let index: Int
        switch kind {
        case .daily: index = Dates.daysBetween(state.baseDay, date)
        case .weekly: index = Dates.daysBetween(state.baseWeek, date) / 7
        case .home: index = 0
        }
        render(PageView(kind: kind, index: index), kind: kind, in: slot, pdf: pdf, store: store, state: state)
    }

    /// 한 페이지(디자인 크기)를 자리에 맞춰 벡터로 그린다
    private static func render(_ page: some View, kind: PageKind, in slot: CGRect, pdf: CGContext,
                               store: PlannerStore, state: AppState) {
        let size = kind.design
        let content = page
            .frame(width: size.width, height: size.height)
            .environment(\.isSnapshot, true)
            .environment(\.isPrinting, true)
            .environmentObject(store)
            .environmentObject(state)
        let renderer = ImageRenderer(content: content)
        renderer.render { rendered, drawInto in
            let scale = min(slot.width / rendered.width, slot.height / rendered.height)
            let w = rendered.width * scale, h = rendered.height * scale
            pdf.saveGState()
            pdf.translateBy(x: slot.midX - w / 2, y: slot.midY - h / 2)
            pdf.scaleBy(x: scale, y: scale)
            drawInto(pdf)
            pdf.restoreGState()
        }
    }

    /// A4 반쪽: 가운데 자르는 선 (점선) + 위아래 눈금
    private static func drawCutGuide(_ pdf: CGContext, _ sheet: CGSize) {
        let x = sheet.width / 2
        pdf.saveGState()
        #if os(macOS)
        pdf.setStrokeColor(NSColor(white: 0.72, alpha: 1).cgColor)
        #else
        pdf.setStrokeColor(UIColor(white: 0.72, alpha: 1).cgColor)
        #endif
        pdf.setLineWidth(0.5)
        pdf.setLineDash(phase: 0, lengths: [3, 3])
        pdf.move(to: CGPoint(x: x, y: 6))
        pdf.addLine(to: CGPoint(x: x, y: sheet.height - 6))
        pdf.strokePath()
        pdf.setLineDash(phase: 0, lengths: [])
        pdf.setLineWidth(0.8)
        for y in [CGFloat(0), sheet.height - 8] {
            pdf.move(to: CGPoint(x: x, y: y))
            pdf.addLine(to: CGPoint(x: x, y: y + 8))
        }
        pdf.strokePath()
        pdf.restoreGState()
    }
}
