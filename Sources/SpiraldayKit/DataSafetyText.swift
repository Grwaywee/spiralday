import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 읽지 못한 저장 파일 알림의 글 (데이터 안전, 1.0.7). 무엇을 지켰는지 · 어떻게 하면 되는지를 한국어로.
// 알림 창은 플랫폼마다 따로 띄운다 (macOS: DataSafetyAlert / NSAlert, iOS: 앱의 알림).
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
public enum DataSafetyText {
    /// 켤 때 알림의 제목과 본문 (알릴 것이 없으면 nil). freshBook: 읽을 수 있는 책이 없어서 새로 만들어 편 책.
    public static func launchText(_ store: PlannerStore, freshBook: UUID?) -> (title: String, body: String)? {
        let notes = store.launchNotices
        guard !notes.isEmpty else { return nil }
        let title: String
        if notes.count == 1, let n = notes.first {
            title = n.kind == .library ? "플래너 목록 파일을 열지 못했어요" : "\(quoted(n.name, "을", "를")) 열지 못했어요"
        } else {
            title = "플래너 파일 \(notes.count)개를 열지 못했어요"
        }
        var parts = [notes.map { describe($0, folder: store.folder) }.joined(separator: "\n\n"), promise]
        if store.libraryUnreadable {
            let n = store.books.count
            parts.append(n > 0
                ? "그래서 books 폴더의 플래너 파일 \(n)개로 책장을 임시로 꾸몄어요 (이름은 ‘되찾은 플래너’). "
                    + "기록은 플래너마다 그대로 저장되지만, 이번에 플래너 이름 · 표지 · 기간을 바꾼 것은 저장되지 않아요."
                : "books 폴더에서 읽을 수 있는 플래너를 찾지 못했어요. 새로 만드는 플래너는 books 폴더에 따로 저장돼요.")
        }
        if let id = freshBook, let b = store.books.first(where: { $0.id == id }) {
            parts.append("읽을 수 있는 플래너가 없어서 새 플래너 ‘\(b.name)’\(Josa.pick(b.name, "을", "를")) 만들어 펼쳤어요. "
                         + "여기에 쓰는 것은 새 파일에 저장돼요.")
        } else if notes.contains(where: { $0.kind != .library }), let b = store.activeBook {
            parts.append("대신 ‘\(b.name)’\(Josa.pick(b.name, "을", "를")) 펼쳤어요.")
        }
        parts.append(advice)
        return (title, parts.joined(separator: "\n\n"))
    }

    /// 앱을 쓰다가 읽지 못하는 책을 펼치려 했을 때의 제목과 본문
    public static func refusedText(_ note: UnreadableFile, store: PlannerStore) -> (title: String, body: String) {
        var parts = [describe(note, folder: store.folder), promise]
        if let b = store.activeBook { parts.append("지금 펼친 ‘\(b.name)’ 그대로예요.") }
        parts.append(advice)
        return ("\(quoted(note.name, "을", "를")) 열 수 없어요", parts.joined(separator: "\n\n"))
    }

    private static let promise = "원본 파일은 손대지 않았고, 아무것도 덮어쓰지 않았어요. 앱을 쓰는 동안 그 파일에는 저장하지 않아요."
    private static let advice = "‘폴더 열기’로 파일이 있는 곳을 볼 수 있어요. 파일이 고쳐지면 다음에 열 때 그대로 열려요. "
        + "도움이 필요하면 도움말 → 버그 신고로 알려 주세요."

    private static func describe(_ n: UnreadableFile, folder: URL?) -> String {
        let what = n.kind == .library ? "플래너 목록 (library.json)" : "‘\(n.name ?? "이름 없는 플래너")’ 파일"
        var lines = ["\(what): \(n.reason)", "원본: \(relative(n.url, folder))"]
        lines.append(n.copy.map { "복사본: \(relative($0, folder))" } ?? "복사본은 만들지 못했어요 (원본은 그대로 있어요).")
        return lines.joined(separator: "\n")
    }

    /// ‘회사 플래너’를 · 이름을 모르면 플래너 파일을
    private static func quoted(_ name: String?, _ withBatchim: String, _ without: String) -> String {
        guard let name, !name.isEmpty else { return "플래너 파일\(withBatchim)" }
        return "‘\(name)’\(Josa.pick(name, withBatchim, without))"
    }

    /// 데이터 폴더 안이면 그 안의 경로로 (books/….json)
    private static func relative(_ url: URL, _ folder: URL?) -> String {
        guard let folder else { return url.path }
        let base = folder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

/// 받침에 따라 ‘을/를’, ‘으로/로’ 같은 조사를 고른다 (한글·숫자로 끝나지 않으면 둘 다 적는다)
public enum Josa {
    /// 0–9 를 읽었을 때의 받침 (영 ㅇ, 일 ㄹ, 이, 삼 ㅁ, 사, 오, 육 ㄱ, 칠 ㄹ, 팔 ㄹ, 구)
    private static let digitBatchim: [Character: UInt32] = ["0": 21, "1": 8, "2": 0, "3": 16, "4": 0,
                                                            "5": 0, "6": 1, "7": 8, "8": 8, "9": 0]

    public static func pick(_ word: String, _ withBatchim: String, _ without: String) -> String {
        switch batchim(word) {
        case .some(0): without
        case .some: withBatchim
        case .none: "\(withBatchim)(\(without))"
        }
    }

    /// ‘으로/로’ (ㄹ 받침 뒤에도 ‘로’)
    public static func ro(_ word: String) -> String {
        switch batchim(word) {
        case .some(0), .some(8): "로"
        case .some: "으로"
        case .none: "(으)로"
        }
    }

    /// 마지막 글자의 받침 번호 (0 = 없음, 8 = ㄹ). 한글·숫자가 아니면 nil
    private static func batchim(_ word: String) -> UInt32? {
        guard let last = word.trimmingCharacters(in: .whitespaces).last else { return 0 }
        if let d = digitBatchim[last] { return d }
        guard let s = last.unicodeScalars.first, (0xAC00...0xD7A3).contains(s.value) else { return nil }
        return (s.value - 0xAC00) % 28
    }
}
