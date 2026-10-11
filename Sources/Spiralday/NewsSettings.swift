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
                SettingsFootnote(text: "알림 · 배지는 띄우지 않아요. 꼭 알아야 할 소식만 앱을 열 때 종이 옆에 작은 카드로 한 번 보여 드려요.")
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
private struct NewsRowView: View {
    let row: NewsRow
    let unseen: Bool
    let today: String
    let lang: String
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: NewsRules.displayDate(row.date, today: today, lang: lang))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    Text(verbatim: NewsCopy.kind(row.kind, lang))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
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
                .padding(.leading, 146)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 3)
    }

    private var accessibilityTitle: String {
        let date = NewsRules.displayDate(row.date, today: today, lang: lang)
        return [unseen ? "안 본 소식" : nil, date, NewsCopy.kind(row.kind, lang), row.title].compactMap { $0 }.joined(separator: ", ")
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
                .accessibilityLabel("안 본 소식이 있어요")
        }
    }
}
