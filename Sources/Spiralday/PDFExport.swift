import AppKit
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

enum PDFLayout: String, CaseIterable, Identifiable {
    case dailyA4, dailyHalf, weekly, home

    var id: String { rawValue }

    var kind: PageKind {
        switch self {
        case .dailyA4, .dailyHalf: .daily
        case .weekly: .weekly
        case .home: .home
        }
    }

    var title: String {
        switch self {
        case .dailyA4: "A4 세로 · 하루 한 장"
        case .dailyHalf: "A4 반쪽 · 두 장씩"
        case .weekly: "A4 가로 · 한 주 한 장"
        case .home: "A4 가로"
        }
    }

    var detail: String {
        switch self {
        case .dailyA4: "A4 한 장 가득 하루를 뽑아요."
        case .dailyHalf: "A4 가로 한 장에 이틀을 나란히 놓아요. 가운데 선을 따라 자르면 실물 플래너 크기예요."
        case .weekly: "A4 가로 한 장에 한 주를 뽑아요."
        case .home: "지금 펼친 플래너의 통계를 A4 가로 한 장으로 뽑아요."
        }
    }

    /// 용지 크기 (pt, 1pt = 1/72 inch)
    var sheet: CGSize {
        self == .dailyA4 ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 841.89, height: 595.28)
    }

    var perSheet: Int { self == .dailyHalf ? 2 : 1 }
}

@MainActor
enum PDFExporter {
    /// 프린터가 못 찍는 가장자리 여백 (pt)
    static let margin: CGFloat = 16

    /// 뽑을 페이지들 (일간: 날짜, 주간: 그 주 월요일, 홈: 한 장)
    static func pages(_ layout: PDFLayout, from: Date, to: Date) -> [Date] {
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

    static func sheetCount(_ layout: PDFLayout, pageCount: Int) -> Int {
        (pageCount + layout.perSheet - 1) / layout.perSheet
    }

    /// 표지와 첫 장을 넣을 수 있는 용지인지 (일간 · 주간. 펼친 책이 있을 때)
    static func canIncludeFront(_ layout: PDFLayout, store: PlannerStore) -> Bool {
        layout.kind.flips && store.activeBook != nil
    }

    /// PDF 한 장 한 장: 표지 · 첫 장 또는 날짜 페이지
    private enum Item {
        case front(FrontPage)
        case page(Date)
    }

    /// PDF 파일을 만든다. progress 는 0…1.
    /// frontMatter: 맨 앞에 표지와 첫 장을 넣는다 (일간 · 주간). A4 반쪽이면 첫 장에 둘이 나란히 들어간다.
    static func export(_ layout: PDFLayout, from: Date, to: Date, cutGuides: Bool, frontMatter: Bool = true,
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
        pdf.setStrokeColor(NSColor(white: 0.72, alpha: 1).cgColor)
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

// MARK: - Window

@MainActor
final class PDFExportWindowController {
    static let shared = PDFExportWindowController()
    private var window: NSWindow?

    func show(store: PlannerStore, state: AppState) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "PDF로 내보내기"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PDFExportView().environmentObject(store).environmentObject(state)
                .padding(.top, 20))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Form

/// PDF 내보내기 화면 (전용 창과 설정 창에서 같이 쓴다)
struct PDFExportView: View {
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState

    @State private var kind: PageKind = .daily
    @State private var dailyLayout: PDFLayout = .dailyHalf
    @State private var from = Dates.day(Date())
    @State private var to = Dates.day(Date())
    @State private var cutGuides = true
    /// 맨 앞에 표지와 첫 장 넣기 (일간 · 주간)
    @State private var frontMatter = true
    @State private var progress: Double? = nil
    @State private var error: String? = nil
    @State private var prepared = false

    private var layout: PDFLayout {
        switch kind {
        case .daily: dailyLayout
        case .weekly: .weekly
        case .home: .home
        }
    }

    /// 펼친 플래너의 기간 (종료일이 없으면 넉넉히 1년 뒤까지)
    private var bookRange: ClosedRange<Date> {
        guard let b = store.activeBook else {
            return Dates.add(days: -3650, to: Dates.day(Date()))...Dates.add(days: 3650, to: Dates.day(Date()))
        }
        return Dates.day(b.start)...Dates.day(b.end ?? Dates.add(days: 365, to: max(Date(), b.start)))
    }

    var body: some View {
        let pages = PDFExporter.pages(layout, from: from, to: to)
        let front = includesFront ? FrontPage.allCases.count : 0
        let sheets = PDFExporter.sheetCount(layout, pageCount: pages.count + front)
        Form {
            Section {
                Picker("무엇을", selection: $kind) {
                    Text("일간").tag(PageKind.daily)
                    Text("주간").tag(PageKind.weekly)
                    Text("홈").tag(PageKind.home)
                }
                .pickerStyle(.segmented)

                if kind == .daily {
                    Picker("용지", selection: $dailyLayout) {
                        Text(PDFLayout.dailyHalf.title).tag(PDFLayout.dailyHalf)
                        Text(PDFLayout.dailyA4.title).tag(PDFLayout.dailyA4)
                    }
                    .pickerStyle(.radioGroup)
                    if dailyLayout == .dailyHalf {
                        Toggle("가운데 자르는 선 넣기", isOn: $cutGuides)
                    }
                }
                if PDFExporter.canIncludeFront(layout, store: store) {
                    Toggle(isOn: $frontMatter) {
                        Text("표지와 첫 장 넣기")
                        Text(layout == .dailyHalf ? "첫 장에 표지와 첫 장이 나란히 들어가요. 실제 책처럼 묶을 수 있어요."
                                                  : "맨 앞에 표지, 그다음 장에 첫 장(적어 둔 말)이 들어가요.")
                    }
                }
                Text(layout.detail).font(.callout).foregroundStyle(.secondary)
            } header: {
                Text(store.activeBook.map { "‘\($0.name)’ 플래너" } ?? "플래너")
            }

            if kind != .home {
                Section("기간") {
                    DatePicker("부터", selection: $from, in: bookRange, displayedComponents: .date)
                    DatePicker("까지", selection: $to, in: bookRange, displayedComponents: .date)
                    HStack(spacing: 8) {
                        quick("지금 페이지") { current() }
                        quick(kind == .daily ? "이번 주" : "이번 달") { thisSpan() }
                        quick("기록한 날 전체") { recorded() }
                    }
                    if kind == .weekly {
                        Text("\(label(pages.first)) 주부터 \(label(pages.last)) 주까지 · 한 주에 한 장")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary(pages.count, sheets)).font(.headline)
                        Text("기록이 없는 날은 빈 양식으로 나와요. 인쇄해서 종이로도 쓸 수 있어요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await make(pages.count) }
                    } label: {
                        Label("PDF 만들기…", systemImage: "doc.richtext")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(progress != nil)
                }
                if let progress {
                    ProgressView(value: progress) { Text("만드는 중…").font(.caption) }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !prepared else { return }
            prepared = true
            kind = state.kind == .home ? .home : state.kind
            current()
        }
    }

    private func quick(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.bordered).controlSize(.small)
    }

    private func clamp(_ d: Date) -> Date { min(max(Dates.day(d), bookRange.lowerBound), bookRange.upperBound) }

    private func current() {
        let d = kind == .weekly ? state.weekStart(state.weekIndex) : state.dayDate(state.dayIndex)
        from = clamp(d)
        to = clamp(kind == .weekly ? Dates.add(days: 6, to: d) : d)
    }

    private func thisSpan() {
        let today = Dates.day(Date())
        if kind == .daily {
            let ws = Dates.weekStart(today)
            from = clamp(ws)
            to = clamp(Dates.add(days: 6, to: ws))
        } else {
            let c = Dates.cal.dateComponents([.year, .month], from: today)
            let first = Dates.cal.date(from: c) ?? today
            from = clamp(first)
            to = clamp(Dates.add(days: -1, to: Dates.cal.date(byAdding: .month, value: 1, to: first) ?? today))
        }
    }

    private func recorded() {
        // D-day 만 붙인 날은 기록한 날이 아니다
        let keys = store.data.days.filter(\.value.hasRecord).keys.sorted()
        guard let a = keys.first.flatMap(Dates.parse), let b = keys.last.flatMap(Dates.parse) else { return }
        from = clamp(a)
        to = clamp(b)
    }

    private func label(_ d: Date?) -> String {
        guard let d else { return "" }
        let c = Dates.comp(d)
        return "\(c.month!)/\(c.day!)"
    }

    /// 이번 PDF 에 표지와 첫 장이 들어가는지
    private var includesFront: Bool { frontMatter && PDFExporter.canIncludeFront(layout, store: store) }

    private func summary(_ pages: Int, _ sheets: Int) -> String {
        let front = includesFront ? "표지·첫 장 + " : ""
        switch kind {
        case .home: return "A4 가로 1장"
        case .weekly: return "\(front)\(pages)주 · A4 가로 \(sheets)장"
        case .daily: return layout == .dailyHalf ? "\(front)\(pages)일 · A4 가로 \(sheets)장 (두 장씩)" : "\(front)\(pages)일 · A4 세로 \(sheets)장"
        }
    }

    private func fileName() -> String {
        let book = store.activeBook?.name ?? "Spiralday"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        switch kind {
        case .home: return "\(book) 홈.pdf"
        case .weekly: return "\(book) 주간 \(f.string(from: min(from, to)))-\(f.string(from: max(from, to))).pdf"
        case .daily:
            let tag = layout == .dailyHalf ? "일간(A4 반쪽)" : "일간"
            return "\(book) \(tag) \(f.string(from: min(from, to)))-\(f.string(from: max(from, to))).pdf"
        }
    }

    private func make(_ pageCount: Int) async {
        error = nil
        state.endEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileName()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        progress = 0
        do {
            try await PDFExporter.export(layout, from: from, to: to, cutGuides: cutGuides, frontMatter: frontMatter,
                                         store: store, state: state, to: url) { p in progress = p }
            progress = nil
            NSWorkspace.shared.open(url)
        } catch {
            progress = nil
            self.error = "PDF를 만들지 못했어요: \(error.localizedDescription)"
        }
    }
}
