import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 여러 줄 글 칸(일간 COMMENT)의 Return 규칙 — 순수 함수 (시험: CommentReturnTests, 공유 벡터 Tests/Fixtures/comment-return.json —
// Windows · Android 의 web 도 같은 파일로 같은 규칙을 시험한다).
//
// · Return · ⇧↩ · ⌥↩ · 숫자패드 Enter : 커서 자리에 줄 바꿈 (선택한 글이 있으면 그 글을 바꾼다). 그 뒤에도 계속 쓴다 — iPhone 과 같게
// · 줄을 더하면 가장 작은 글씨로도 상자를 넘칠 때: 그 Return 은 받지 않는다 (Mac 삑 · iOS 진동). 글자를 더 치는 것은 글씨를 줄여 받는다
// · ⌘↩ · ⌃↩ (Windows Ctrl+Enter · Meta+Enter) : 쓰기를 마친다
// · 한글 조합 중 Return : 조합하던 글자를 한 번만 확정하고 이어서 위 규칙대로 (Mac 은 키를 먼저 잡아 확정한다)
// · 할 일 · MEMO 는 이 규칙을 쓰지 않는다 (Return = 아랫줄로, 1.0.5)
// ─────────────────────────────────────────────────────────────────────────────

public enum MultilineReturn {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        /// ⌥ (Windows Alt)
        public static let option = Modifiers(rawValue: 2)
        /// ⌃ (Windows Ctrl)
        public static let control = Modifiers(rawValue: 4)
        /// ⌘ (Windows Meta)
        public static let command = Modifiers(rawValue: 8)
    }

    public enum Action: String, Sendable, Equatable {
        /// 커서 자리에 줄 바꿈을 넣고 계속 쓴다
        case newline
        /// 줄 바꿈을 넣지 않는다 (상자가 찼다) — 계속 쓴다
        case refuse
        /// 쓰기를 마친다
        case end
    }

    /// Return 을 눌렀을 때. fits: 줄 바꿈을 넣은 뒤의 글이 상자에 들어가는지 (필요할 때만 묻는다)
    public static func action(_ modifiers: Modifiers, fits: () -> Bool) -> Action {
        if !modifiers.isDisjoint(with: [.command, .control]) { return .end }
        return fits() ? .newline : .refuse
    }

    /// 커서 자리(선택 범위, NSString 단위)에 줄 바꿈을 넣은 글
    public static func inserting(into text: String, selection: NSRange) -> String {
        let ns = text as NSString
        let loc = min(max(selection.location, 0), ns.length)
        let len = min(max(selection.length, 0), ns.length - loc)
        return ns.replacingCharacters(in: NSRange(location: loc, length: len), with: "\n")
    }

    /// old → new 가 줄 바꿈만 넣은 편집인지 (Return 한 번, 선택한 글을 바꿨어도). 붙여넣기 · 다른 기기에서 온 글은 아니다.
    /// iOS 글상자는 Return 을 글에 바로 넣으므로, 넘치는 Return 을 되돌릴 때 이것으로 가른다
    public static func isNewlineInsertion(from old: String, to new: String) -> Bool {
        let a = Array(old), b = Array(new)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let inserted = b[p..<(b.count - s)]
        return !inserted.isEmpty && inserted.allSatisfy { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
    }
}
