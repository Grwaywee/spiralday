import Foundation
import SpiraldayKit

// ─────────────────────────────────────────────────────────────────────────────
// 합치기 전 백업: 다른 기기에 합류하거나 복구 코드로 되살리기 직전에, 이 Mac 의 내 플래너를 한 권씩 백업 파일로 남긴다
// (Windows 앱의 데이터 폴더 backups/<yyyy-MM-dd_HHmmss> · iOS 의 SyncBackups 와 같은 뜻). 겹치는 칸은 그룹 쪽이 이기므로
// 그때의 내 기록을 따로 둔다.
//
//   ~/Library/Application Support/Spiralday/SyncBackups/<yyyy-MM-dd_HHmmss>/Spiralday 백업 - <이름> <날짜>.json
//
// 파일은 설정 → 데이터의 백업 내보내기와 같은 형식 · 이름이라 ‘백업 가져오기…’로 그대로 새 플래너로 되살릴 수 있다.
// 최근 10개만 남긴다.
// ─────────────────────────────────────────────────────────────────────────────

struct SyncBackupSnapshot: Identifiable, Equatable {
    var id: String { folder.lastPathComponent }
    let folder: URL
    let date: Date
    let files: [URL]
}

@MainActor
enum SyncBackups {
    static let keep = 10

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    /// "Spiralday 백업 - 내 플래너 2026-10-02.json" (설정 → 데이터의 백업 내보내기와 같은 이름 → 가져오기가 책 이름을 되찾는다)
    static func backupName(_ book: BookInfo, today: Date) -> String {
        let safe = book.name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "Spiralday 백업 - \(safe.isEmpty ? "플래너" : safe) \(Dates.key(today)).json"
    }

    /// 지금 내 플래너(예시 플래너 빼고)를 모두 백업한다. 백업할 것이 없으면 nil
    @discardableResult
    static func snapshot(_ store: PlannerStore, root: URL, now: Date = Date()) throws -> SyncBackupSnapshot? {
        let books = store.userBooks
        guard !books.isEmpty else { return nil }
        store.saveNow()
        let fm = FileManager.default
        var folder = root.appendingPathComponent(stamp.string(from: now), isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = root.appendingPathComponent("\(stamp.string(from: now))-\(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        var used = Set<String>()
        for book in books {
            guard case .data(let raw) = store.readBookRaw(book.id) else { continue }   // 아직 파일이 없거나 읽지 못한 책은 건너뛴다
            var name = backupName(book, today: now)
            if used.contains(name) { name = name.replacingOccurrences(of: ".json", with: " \(book.id.uuidString.prefix(4)).json") }
            used.insert(name)
            let url = folder.appendingPathComponent(name)
            try raw.write(to: url, options: .atomic)
            files.append(url)
        }
        if files.isEmpty {
            try? fm.removeItem(at: folder)
            return nil
        }
        prune(root: root)
        return SyncBackupSnapshot(folder: folder, date: now, files: files)
    }

    /// 남아 있는 백업 (최근 것부터)
    static func list(root: URL) -> [SyncBackupSnapshot] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted(by: >).compactMap { name in
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard let date = stamp.date(from: String(name.prefix(17))) else { return nil }
            let files = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasSuffix(".json") }
                .sorted()
                .map { folder.appendingPathComponent($0) }
            return files.isEmpty ? nil : SyncBackupSnapshot(folder: folder, date: date, files: files)
        }
    }

    static func prune(root: URL) {
        for old in list(root: root).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old.folder)
        }
    }
}
