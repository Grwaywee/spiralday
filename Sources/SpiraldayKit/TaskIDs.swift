import CryptoKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// → (미룸) 으로 다음 날에 넘긴 할 일의 id
//
//   carryTaskId(원래 id) = UUIDv5(이름공간 = 원래 할 일의 UUID, 이름 = "carry")   (RFC 9562, SHA-1)
//
// 같은 할 일을 넘기면 늘 같은 id 가 나온다. 그래서 같은 플래너를 쓰는 두 곳(두 기기, 백업에서 되살린 책 …)이
// 같은 할 일을 따로 넘겨도 사본이 같은 id 를 가져서, 두 기록을 합치면 할 일이 둘이 아니라 하나가 된다.
// → 를 뗐다가 다시 붙이면 같은 id 로 다시 생기고, 넘긴 사본을 또 넘기면 carryTaskId(사본 id) 다.
// 이 규칙은 Spiralday 의 모든 앱(macOS · iOS · Windows · Android)이 같아야 한다.
// ─────────────────────────────────────────────────────────────────────────────

extension UUID {
    /// RFC 9562 이름 기반 UUID 버전 5 (SHA-1): SHA-1(이름공간 16바이트 ‖ 이름의 UTF-8) 의 앞 16바이트에
    /// 버전(5) · 변형(RFC) 비트를 넣는다.
    public init(v5Namespace namespace: UUID, name: String) {
        var msg = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        msg.append(contentsOf: Array(name.utf8))
        var h = Array(Insecure.SHA1.hash(data: msg).prefix(16))
        h[6] = h[6] & 0x0F | 0x50
        h[8] = h[8] & 0x3F | 0x80
        self.init(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
    }
}

extension PlanTask {
    /// → 로 다음 날에 넘긴 할 일(사본)의 id: UUIDv5(이름공간 = 원래 할 일의 id, 이름 = "carry").
    /// 예: 3F2504E0-4F89-11D3-9A0C-0305E82C3301 → 0D594A5F-8FD8-50CA-803B-6260FFD0478F
    public static func carryTaskId(_ originalId: UUID) -> UUID {
        UUID(v5Namespace: originalId, name: "carry")
    }
}
