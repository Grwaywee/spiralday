import SwiftUI

/// 홈 (디자인 2000 × 1277, 위쪽 스프링). 전체 통계를 보여주는 한 장짜리 표지. STUB — to be replaced.
struct HomePage: View {
    let u: CGFloat

    var body: some View {
        Text("HOME")
            .font(Fonts.print(60 * u, .bold))
            .foregroundStyle(Ink.print)
            .padding(200 * u)
    }
}
