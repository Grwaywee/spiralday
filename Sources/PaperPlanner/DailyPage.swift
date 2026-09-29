import SwiftUI

/// 일간 페이지 (디자인 1277 × 2000). STUB — to be replaced.
struct DailyPage: View {
    let date: Date
    let u: CGFloat

    var body: some View {
        Text("DAILY \(Dates.key(date))")
            .font(Fonts.print(40 * u))
            .padding(200 * u)
    }
}
