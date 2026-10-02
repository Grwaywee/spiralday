import SwiftUI
import SpiraldayKit
import SpiraldaySync

// 이전 버전: 서버는 하루(와 한 주)의 이전 버전을 바뀐 때부터 30일 동안 보관한다. 플래너와 날을 고르고, 버전을 보고,
// 하나로 되돌린다 (새로 고친 것으로 기록되어 다른 기기로 퍼지고, 그때의 지금 내용도 이전 버전으로 남는다).
// 설정 → 동기화의 [이전 버전 보기…] 는 오늘로, 플래너 메뉴의 ‘이 장의 이전 버전…’ 은 지금 보는 장으로 열린다.

struct SyncHistorySheet: View {
    @EnvironmentObject private var sync: SyncController
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let initial: SyncHistoryRequest
    @State private var bookID: UUID?
    @State private var kind: SyncController.HistoryKind = .day
    @State private var date = Dates.day(Date())
    @State private var rows: [SyncText.VersionRow]?
    @State private var error: String?
    @State private var done: String?
    @State private var open: Int?
    @State private var confirm: SyncText.VersionRow?

    private var books: [BookInfo] { store.userBooks }
    private var label: String {
        kind == .week ? "\(Dates.key(Dates.weekStart(date))) 주" : Dates.key(date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("플래너", selection: $bookID) {
                        ForEach(books) { b in Text(verbatim: b.name).tag(Optional(b.id)) }
                    }
                    Picker("무엇의 이전 버전", selection: $kind) {
                        Text("하루").tag(SyncController.HistoryKind.day)
                        Text("한 주").tag(SyncController.HistoryKind.week)
                    }
                    .pickerStyle(.segmented)
                    DatePicker(kind == .week ? "주 (그 주의 아무 날)" : "날짜", selection: $date, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "ko_KR"))
                } header: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("이전 버전").font(.system(size: 15, weight: .bold)).foregroundStyle(.primary)
                        SettingsFootnote(text: "동기화 서버는 이전 버전을 새 버전으로 바뀐 때부터 30일 동안 보관해요. 되돌리면 새로 고친 것으로 기록돼서 다른 기기에도 퍼지고, 그때의 지금 내용도 이전 버전으로 남아요.")
                    }
                }

                Section {
                    if rows == nil && error == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(verbatim: "\(label)의 이전 버전을 찾는 중이에요…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let rows, rows.isEmpty, error == nil {
                        SyncRowText(title: "이전 버전이 없어요", detail: "\(label)에는 동기화된 기록이 없거나, 30일이 지나 지워졌어요.")
                    }
                    ForEach(rows ?? []) { v in versionRow(v) }
                    if let error {
                        HStack {
                            SyncNote(tone: .error, text: error)
                            Spacer()
                            if rows == nil { Button("다시") { Task { await load() } } }
                        }
                    }
                    if let done { SyncNote(tone: .ok, text: done) }
                } header: {
                    SettingsSectionTitle(title: label)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 540, height: 560)
        .task(id: "\(bookID?.uuidString ?? "")|\(kind == .week)|\(Dates.key(date))") { await load() }
        .alert(confirm.map { "\(SyncText.versionTime($0.at)) 버전으로 되돌릴까요?" } ?? "",
               isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { v in
            Button("취소", role: .cancel) {}
            Button("되돌리기") { Task { await restore(v) } }
        } message: { v in
            Text(verbatim: "\(label)의 지금 내용이 이 버전(\(v.summary))으로 바뀌어요. 지금 내용은 이전 버전으로 30일 동안 남아요.")
        }
        .onAppear(perform: start)
    }

    private func versionRow(_ v: SyncText.VersionRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { open = open == v.seq ? nil : v.seq }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open == v.seq ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 10)
                            .opacity(v.preview.isEmpty ? 0 : 1)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: SyncText.versionTime(v.at)).foregroundStyle(.primary).monospacedDigit()
                                if v.current {
                                    Text("지금")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Color(nsColor: .systemGreen))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color(nsColor: .systemGreen).opacity(0.14)))
                                }
                            }
                            Text(verbatim: v.summary).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(v.preview.isEmpty)
                Spacer()
                if !v.current {
                    Button("되돌리기") { confirm = v }
                        .help("이 버전으로 되돌려요 (지금 내용은 새 이전 버전으로 남아요)")
                }
            }
            if open == v.seq {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(v.preview.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 26)
            }
        }
    }

    private func start() {
        guard bookID == nil else { return }
        bookID = books.contains { $0.id == initial.book } ? initial.book : books.first?.id
        kind = initial.kind
        date = Dates.day(initial.date)
    }

    private func load() async {
        guard let bookID else { return }
        rows = nil
        error = nil
        do {
            rows = try await sync.history(book: bookID, kind: kind, date: date)
        } catch {
            // 받지 못했다: '이전 버전이 없어요' 와 함께 보이지 않게 목록은 비워 두지 않는다
            self.error = SyncText.errorText(error)
            rows = nil
        }
    }

    private func restore(_ v: SyncText.VersionRow) async {
        guard let bookID else { return }
        done = nil
        let r = await sync.restoreVersion(book: bookID, kind: kind, date: date, seq: v.seq)
        if r.ok {
            done = "\(SyncText.versionTime(v.at)) 버전으로 되돌렸어요. 다른 기기에도 곧 반영돼요."
            await load()
        } else {
            error = r.message ?? "되돌리지 못했어요."
        }
    }
}
