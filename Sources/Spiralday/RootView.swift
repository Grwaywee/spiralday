import SwiftUI
import SpiraldayKit

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
                // 동기화 안내 (다른 기기에서 지운 플래너 등). 안내가 없으면 아무것도 그리지 않는다.
                SyncNoticeOverlay()
            }
            .frame(width: g.size.width, height: g.size.height)
            .onAppear { state.curl.pageSize = g.size }
            .onChange(of: g.size) { _, s in state.curl.pageSize = s }
        }
        .ignoresSafeArea()
    }
}
