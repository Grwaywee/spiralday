import SwiftUI
import AppKit

/// 종이 한 장 = 창 전체. 종이 바탕과 구멍 위에 주간/일간 내용을 그린다.
/// 크기는 부모가 정한다 (창 크기, 스냅샷 크기). u = 너비 / 디자인 너비.
struct PageView: View {
    let kind: PageKind
    let index: Int
    @EnvironmentObject private var state: AppState

    var body: some View {
        GeometryReader { g in
            let u = g.size.width / kind.design.width
            ZStack(alignment: .topLeading) {
                PaperSurface(kind: kind, u: u)
                    .contentShape(Rectangle())
                    .onTapGesture { state.endEditing() }
                // 책의 첫 장 앞: 표지 · 첫 장
                if let front = state.frontPage(kind: kind, index: index) {
                    FrontMatterPage(page: front, kind: kind, u: u)
                } else {
                    switch kind {
                    case .daily:
                        DailyPage(date: state.dayDate(index), u: u)
                    case .weekly:
                        WeeklyPage(weekStart: state.weekStart(index), u: u)
                    case .home:
                        HomePage(u: u)
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
    }
}

// MARK: - Snapshots for the page curl

/// 페이지를 비트맵으로 그려 캐시한다. 넘김이 시작되는 순간 바로 쓸 수 있게
/// 현재 페이지와 앞뒤 페이지를 한가할 때 미리 그려 둔다.
@MainActor
final class PageSnapshotter {
    private let store: PlannerStore
    private let state: AppState
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []
    private var prewarmWork: DispatchWorkItem?
    private let capacity = 10

    init(store: PlannerStore, state: AppState) {
        self.store = store
        self.state = state
    }

    private func key(_ kind: PageKind, _ index: Int, _ size: CGSize, _ scale: CGFloat) -> String {
        "\(kind.rawValue)|\(index)|\(store.version)|\(Int(size.width.rounded()))x\(Int(size.height.rounded()))@\(scale)"
    }

    func image(kind: PageKind, index: Int, size: CGSize, scale: CGFloat) -> CGImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        let k = key(kind, index, size, scale)
        if let img = cache[k] {
            order.removeAll { $0 == k }
            order.append(k)
            return img
        }
        let content = PageView(kind: kind, index: index)
            .frame(width: size.width, height: size.height)
            .environment(\.isSnapshot, true)
            .environmentObject(store)
            .environmentObject(state)
        let r = ImageRenderer(content: content)
        r.scale = scale
        r.isOpaque = true
        guard let img = r.cgImage else { return nil }
        cache[k] = img
        order.append(k)
        while order.count > capacity { cache.removeValue(forKey: order.removeFirst()) }
        return img
    }

    /// 현재 페이지 기준 앞뒤 페이지를 조금씩 나눠서 미리 그린다.
    func schedulePrewarm(delay: TimeInterval = 0.45) {
        prewarmWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.prewarm(step: 0) }
        prewarmWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func prewarm(step: Int) {
        let offsets = [0, 1, -1]
        guard step < offsets.count, state.kind.flips, state.curl.isIdle, !state.morphing,
              state.editingKey == nil else { return }
        let size = state.curl.pageSize
        // 책 밖(표지 앞, 마지막 장 뒤)은 넘어갈 수 없으니 그리지 않는다
        if step == 0 || state.canStep(offsets[step]) {
            _ = image(kind: state.kind, index: state.index + offsets[step], size: size, scale: state.curl.backingScale)
        }
        let w = DispatchWorkItem { [weak self] in self?.prewarm(step: step + 1) }
        prewarmWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: w)
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                // 창 비율이 바뀌는 동안에도 종이는 계속 보인다
                PaperSurface(kind: state.kind, u: g.size.width / state.kind.design.width)
                PageView(kind: state.kind, index: state.index)
                    .opacity(state.morphing ? 0 : 1)
                CurlOverlay(controller: state.curl)
                    .allowsHitTesting(false)
                if !state.morphing && state.kind.flips {
                    CornerZones(size: g.size, kind: state.kind)
                }
                // 플래너 둘러보기 (코치 마크). 둘러보는 중이 아니면 아무것도 그리지 않는다.
                TourOverlay(size: g.size)
            }
            .frame(width: g.size.width, height: g.size.height)
            .onAppear { state.curl.pageSize = g.size }
            .onChange(of: g.size) { _, s in state.curl.pageSize = s }
        }
        .ignoresSafeArea()
    }
}

/// 종이 아래쪽 두 모서리: 마우스를 올리면 살짝 들리고, 클릭하면 넘어가고, 잡고 끌면 따라 넘어간다.
struct CornerZones: View {
    let size: CGSize
    let kind: PageKind
    @EnvironmentObject private var state: AppState

    var body: some View {
        let u = size.width / kind.design.width
        // 양식 바깥 여백 안에만 둔다 (일간: 아래 여백 ~108, 주간: ~40 디자인 단위)
        let w = (kind == .daily ? 150 : 150) * u
        let h = (kind == .daily ? 104 : 58) * u
        ZStack {
            zone(.backward, w: w, h: h)
                .position(x: w / 2 + (kind == .daily ? 28 * u : 0), y: size.height - h / 2)
            zone(.forward, w: w, h: h)
                .position(x: size.width - w / 2, y: size.height - h / 2)
        }
        .frame(width: size.width, height: size.height)
    }

    private func zone(_ dir: FlipDirection, w: CGFloat, h: CGFloat) -> some View {
        Color.clear
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .onHover { inside in state.curl.hover(dir, inside: inside) }
            .onTapGesture { state.flip(dir) }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { v in
                        if !dragging {
                            dragging = true
                            state.curl.dragBegan(dir, at: v.startLocation)
                        }
                        state.curl.dragChanged(to: v.location)
                    }
                    .onEnded { v in
                        if dragging {
                            state.curl.dragEnded(at: v.location, predictedEnd: v.predictedEndLocation)
                        }
                        dragging = false
                    }
            )
            .help(dir == .forward ? "다음 장 (→)" : "이전 장 (←)")
    }

    @State private var dragging = false
}
