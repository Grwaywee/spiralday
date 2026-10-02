import SwiftUI
import SpiraldayKit

// MARK: - Snapshot (QA)

/// `--snapshot <dir>` 에 cover_daily.png · motto_daily.png · cover_weekly.png · motto_weekly.png 를 더한다.
/// `--front-qa` 를 함께 주면 끝 없는 책 · 빈 첫 장 · 긴 글 · 첫 장 → 첫날 넘김 프레임도 그리고 번호 점검을 찍는다.
@MainActor
enum FrontMatterSnapshot {
    static let sampleMotto = "오늘의 작은 한 칸이\n내일의 나를 만든다"

    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let today = Dates.day(Date())
        let first = Dates.cal.date(from: Dates.cal.dateComponents([.year, .month], from: today)) ?? today
        let end = Dates.add(days: -1, to: Dates.cal.date(byAdding: .month, value: 4, to: first) ?? today)
        let book = BookInfo(name: "나의 플래너", start: first, end: end, cover: 4)
        render(dir, book: book, motto: sampleMotto, suffix: "")

        guard CommandLine.arguments.contains("--front-qa") else { return }
        render(dir, book: BookInfo(name: "2026 하루하루 기록장", start: first, end: nil, cover: 0), motto: "", suffix: "_empty")
        render(dir, book: BookInfo(name: "아주 긴 이름을 붙인 올해의 두 번째 공부 플래너", start: first, end: end, cover: 2),
               motto: "천천히 가도 괜찮아. 멈추지만 않으면 돼.\n매일 한 칸씩 채우다 보면 어느새 한 권이 된다.\n오늘도 수고했어, 나.",
               suffix: "_long")
        check(book, dir)
    }

    private static func store(_ book: BookInfo, motto: String) -> PlannerStore {
        var data = PlannerData()
        data.prefs.motto = motto
        let s = PlannerStore(inMemory: true)
        s.useBook(book, data: data)
        return s
    }

    private static func render(_ dir: URL, book: BookInfo, motto: String, suffix: String) {
        let s = store(book, motto: motto)
        for kind in [PageKind.daily, .weekly] {
            let state = AppState(kind: kind)
            state.store = s
            let snap = PageSnapshotter(store: s, state: state)
            for page in FrontPage.allCases {
                let name = "\(page == .cover ? "cover" : "motto")_\(kind.rawValue)\(suffix).png"
                if let img = snap.image(kind: kind, index: state.frontIndex(page, kind), size: kind.design, scale: 1) {
                    Snapshotter.write(img, dir.appendingPathComponent(name))
                }
            }
        }
    }

    /// 번호 · 넘기기 · 쪽 바꾸기 점검과 첫 장 → 첫날 넘김 프레임
    private static func check(_ book: BookInfo, _ dir: URL) {
        let s = store(book, motto: sampleMotto)
        var ok = true
        func expect(_ what: String, _ v: Bool) { print((v ? "✓ " : "✗ ") + what); ok = ok && v }

        let state = AppState(kind: .daily)
        state.store = s
        let cover = state.frontIndex(.cover, .daily), motto = state.frontIndex(.motto, .daily)
        expect("일간: 첫날 앞이 첫 장, 그 앞이 표지", motto == state.dayRange.lowerBound - 1 && cover == motto - 1)
        state.dayIndex = cover
        expect("표지: 앞으로 못 넘기고 뒤로는 넘긴다", !state.canStep(-1) && state.canStep(1) && state.front == .cover)
        expect("표지의 날짜는 책의 첫날", Dates.key(state.dayDate(state.dayIndex)) == Dates.key(book.start))
        state.dayIndex = motto
        expect("첫 장", state.front == .motto && state.canStep(-1) && state.canStep(2))
        state.switchKind(.weekly)
        expect("쪽을 바꿔도 첫 장", state.kind == .weekly && state.front == .motto
               && state.weekIndex == state.weekRange.lowerBound - 1)
        state.switchKind(.home)
        state.showFront(.cover)
        expect("홈에서 표지로: 마지막으로 보던 주간의 표지", state.kind == .weekly && state.front == .cover)
        state.switchKind(.daily)
        expect("주간 표지 → 일간 표지", state.kind == .daily && state.front == .cover)
        print(ok ? "앞 장 점검: 모두 통과" : "앞 장 점검: 실패가 있어요")

        // 첫 장 → 첫날 넘김 (절반 크기)
        for kind in [PageKind.daily, .weekly] {
            let st = AppState(kind: kind)
            st.store = s
            let size = CGSize(width: kind.design.width / 2, height: kind.design.height / 2)
            let snap = PageSnapshotter(store: s, state: st)
            let i = st.frontIndex(.motto, kind)
            guard let cur = snap.image(kind: kind, index: i, size: size, scale: 1),
                  let next = snap.image(kind: kind, index: i + 1, size: size, scale: 1) else { continue }
            let frames = CurlController.renderTurnFrames(PageBitmaps(current: cur, neighbor: next), direction: .forward,
                                                         edge: kind.edge, pageSize: size, scale: 1, frameCount: 8)
            for (n, f) in frames.enumerated() {
                Snapshotter.write(f, dir.appendingPathComponent(String(format: "curl_front_%@_%02d.png", kind.rawValue, n)))
            }
        }
    }
}
