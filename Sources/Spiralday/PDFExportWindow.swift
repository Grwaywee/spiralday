import AppKit
import SwiftUI
import SpiraldayKit

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
