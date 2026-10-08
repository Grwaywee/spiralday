import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 여러 줄 글 칸(일간 COMMENT)의 Return 규칙 — 순수 함수 (시험: CommentReturnTests, 공유 벡터 Tests/Fixtures/comment-return.json —
// Windows · Android 의 web 도 같은 파일로 같은 규칙을 시험한다).
//
// · Return · ⇧↩ · ⌥↩ · 숫자패드 Enter : 커서 자리에 줄 바꿈 (선택한 글이 있으면 그 글을 바꾼다). 그 뒤에도 계속 쓴다 — iPhone 과 같게
// · 줄을 더하면 가장 작은 글씨로도 상자를 넘칠 때: 그 Return 은 받지 않는다 (Mac 삑 · iOS 진동). 글자를 더 치는 것은 글씨를 줄여 받는다
// · ⌘↩ · ⌃↩ (Windows Ctrl+Enter · Meta+Enter) : 쓰기를 마친다
// · 입력기가 먼저 본다: 한글 조합 중 Return 은 입력기가 조합하던 글자를 한 번 확정하고 넘긴 Return 이 위 규칙대로 줄을 바꾼다.
//   한자 후보 · 일본어 변환을 고르는 Return 은 입력기가 먹는다 (줄을 바꾸지 않는다). Mac 의 ⌥↩ 는 한글 입력기의 한자 변환 키라서
//   입력기에 먼저 넘기고, 입력기가 쓰지 않을 때만 줄을 바꾼다 (Mac — Components.swift ReturnNewlineMonitorView)
// · 확정한 글자와 줄 바꿈이 한 번에 들어와 상자를 넘치면 줄 바꿈만 뺀다 (refusingTypedNewline — 확정한 글자는 남는다)
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

    /// old → new 가 Return 한 번으로 생긴 편집일 때, 그 줄 바꿈을 받지 않은 글 (상자를 넘칠 때 되돌리는 값). 그런 편집이 아니면 nil.
    /// · 줄 바꿈만 넣었으면 (선택한 글을 바꿨어도) old 그대로
    /// · 조합하던 글자를 확정하면서 Return 이 함께 들어왔으면 (old '오늘' → new '오늘한\n' — 입력기가 확정하고 넘긴 Return,
    ///   iOS 처럼 조합 중 글자가 바인딩에 없던 때) 확정한 글자는 두고 끝의 줄 바꿈만 뺀다 → '오늘한'
    /// · 줄이 여럿 든 붙여넣기 · 다른 기기에서 온 글 · 글자만 친 편집은 nil (줄 바꿈을 넣은 Return 이 아니다)
    public static func refusingTypedNewline(from old: String, to new: String) -> String? {
        if isNewlineInsertion(from: old, to: new) { return old }
        let a = Array(old), b = Array(new)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        // 바뀐 자리: old 에서 지운 글 a[p..<a.count-s] 는 조합 중이던 글자(확정되며 다른 글자로 바뀌었을 수 있다)
        let inserted = b[p..<(b.count - s)]
        guard let last = inserted.last, last.isNewline else { return nil }
        let typed = inserted.dropLast()
        guard !typed.isEmpty, !typed.contains(where: \.isNewline) else { return nil }
        return String(b[..<p]) + String(typed) + String(b[(b.count - s)...])
    }
}
