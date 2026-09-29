import SwiftUI

/// 주간 페이지 (디자인 2000 × 1277). STUB — to be replaced.
struct WeeklyPage: View {
    let weekStart: Date
    let u: CGFloat

    var body: some View {
        Text("WEEKLY \(Dates.key(weekStart))")
            .font(Fonts.print(40 * u))
            .padding(200 * u)
    }
}
