import AppKit
import SwiftUI
import SpiraldayKit

// ─────────────────────────────────────────────────────────────────────────────
// 설정 › 소식 (Docs/InAppNews.md §1.2): 받은 소식과 이번 버전의 ‘달라진 점’을 모아 둔 목록 + ‘spiralday.com 에서 소식 받기’ 스위치.
//   · 줄: 날짜 · 종류(작은 글자 ‘알림’ · ‘업데이트’) · 제목. 안 본 줄은 제목 앞에 작은 점, 누르면 펼쳐 본문과 [자세히 보기]
//   · 목록을 열면 보이는 줄을 모두 본 것으로 적는다 — 이번에 보이는 점은 그대로 두고, 옆 목록 ‘소식’의 점은 바로 사라진다
//   · 비었을 때 (오프라인 · 받기 실패도): ‘아직 소식이 없어요.’ — 오류 문구는 보이지 않는다
// ─────────────────────────────────────────────────────────────────────────────

struct NewsSettingsPane: View {
    @ObservedObject var center: NewsCenter = .shared
    /// 펼친 줄
    @State private var open: Set<String> = []
    /// 스냅샷(QA): 처음부터 펼쳐 둘 줄 · 목록을 연 것으로 치지 않는다
    var initiallyOpen: Set<String> = []
    var snapshot = false

    var body: some View {
        let today = Dates.key(center.now())
        Form {
            Section {
                if center.rows.isEmpty {
                    Text(verbatim: NewsCopy.empty(center.lang))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(center.rows) { row in
                        NewsRowView(row: row, unseen: center.paneUnseen.contains(row.id), today: today, lang: center.lang,
                                    expanded: open.contains(row.id)) {
                            if open.contains(row.id) { open.remove(row.id) } else { open.insert(row.id) }
                        }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsPaneHeader(pane: .news)
                    SettingsSectionTitle(title: "소식", trailing: center.rows.isEmpty ? nil : "\(center.rows.count)개")
                }
            }

            Section {
                Toggle(isOn: Binding(get: { center.fetchEnabled }, set: { center.setFetchEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: NewsCopy.fetchToggle(center.lang))
                        Text(verbatim: center.fetchEnabled ? NewsCopy.fetchOnDetail(center.lang) : NewsCopy.fetchOffDetail(center.lang))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                SettingsSectionTitle(title: "받기")
            } footer: {
                // 모든 플랫폼이 같은 말 (Kit NewsCopy — Windows · Android 의 NEWS_COPY 와 같게)
                SettingsFootnote(text: NewsCopy.paneNote(center.lang))
            }
        }
        .onAppear {
            open = initiallyOpen
            if !snapshot { center.paneShown() }
        }
        .onDisappear { if !snapshot { center.paneHidden() } }
    }
}

/// 한 줄: 날짜 · 종류 · (점) 제목, 누르면 본문과 [자세히 보기]
struct NewsRowView: View {
    /// 날짜 칸: 가장 긴 날짜(‘2025년 12월 31일’ · ‘Sep 30, 2025’)도 한 줄에 들어가게 글꼴로 잰다 — 92pt 로 두었더니 작년의 두 자리 월 · 일이 꺾였다
    static let dateWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let widest = (["0000년 00월 00일"] + months.map { "\($0) 00, 0000" })
            .map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }
            .max() ?? 100
        return ceil(widest) + 2
    }()
    /// 종류 칸 (‘업데이트’ · ‘알림’ · Update · Notice 중 가장 긴 것, 적어도 44pt)
    static let kindWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let widest = [NewsKind.notice, .update].flatMap { [NewsCopy.kind($0, "ko"), NewsCopy.kind($0, "en")] }
            .map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }
            .max() ?? 44
        return max(44, ceil(widest) + 2)
    }()
    static let columnSpacing: CGFloat = 10
    /// 펼친 본문의 들여쓰기 (날짜 · 종류 칸 다음)
    static var bodyIndent: CGFloat { dateWidth + columnSpacing + kindWidth }

    let row: NewsRow
    let unseen: Bool
    let today: String
    let lang: String
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: Self.columnSpacing) {
                    Text(verbatim: NewsRules.displayDate(row.date, today: today, lang: lang))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: Self.dateWidth, alignment: .leading)
                    Text(verbatim: NewsCopy.kind(row.kind, lang))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: Self.kindWidth, alignment: .leading)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // 안 본 줄의 작은 점 (자리는 늘 비워 둬 제목이 흔들리지 않게)
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .opacity(unseen ? 1 : 0)
                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                        Text(verbatim: row.title)
                            .font(.system(size: 13, weight: unseen ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(expanded ? "펼침" : "접힘")
            .accessibilityHint(expanded ? "눌러서 접어요" : "눌러서 본문을 펼쳐요")
            .accessibilityAddTraits(.isButton)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: row.body)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(.primary.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    if let link = row.link, NewsRules.isAllowedLink(link), let url = URL(string: link) {
                        Button {
                            NewsCenter.openLink(url)
                        } label: {
                            Label(NewsCopy.learnMore(lang), systemImage: "arrow.up.right.square")
                        }
                        .help("spiralday.com 에서 자세히 봐요 (브라우저로 열려요)")
                    }
                }
                .padding(.leading, Self.bodyIndent)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 3)
    }

    private var accessibilityTitle: String {
        let date = NewsRules.displayDate(row.date, today: today, lang: lang)
        return [unseen ? NewsCopy.unseen(lang) : nil, date, NewsCopy.kind(row.kind, lang), row.title].compactMap { $0 }.joined(separator: ", ")
    }
}

/// 설정 창 옆 목록의 ‘소식’ 항목 끝의 작은 점 (안 본 줄이 있을 때만 — 다른 곳에는 아무것도 없다)
struct NewsSidebarDot: View {
    @ObservedObject var center: NewsCenter = .shared

    var body: some View {
        if center.dot {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel(NewsCopy.unseen(center.lang))
        }
    }
}
