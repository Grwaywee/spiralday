// → (미룸) 으로 넘긴 할 일의 id 를 정하는 규칙 (모든 앱이 같아야 한다 — SpiraldayKit PlanTask.carryTaskId 와 같은 값).
//   carryTaskId(원래 id) = UUIDv5(이름공간 = 원래 할 일의 UUID, 이름 = "carry"), 대문자 (RFC 9562).
// 두 기기가 같은 할 일을 따로 넘겨도 같은 id 가 나와서, 합치면 하나가 된다.
import CryptoKit
import Foundation

public enum CarryID {
    /// RFC 9562 UUIDv5 (SHA-1). namespace 가 UUID 가 아니면 nil
    public static func uuidV5(namespace: String, name: String) -> String? {
        guard let ns = UUID(uuidString: namespace) else { return nil }
        return uuidV5(namespace: ns, name: name).uuidString
    }

    public static func uuidV5(namespace: UUID, name: String) -> UUID {
        var msg = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        msg.append(contentsOf: Array(name.utf8))
        var h = Array(Insecure.SHA1.hash(data: msg)).prefix(16).map { $0 }
        h[6] = h[6] & 0x0F | 0x50
        h[8] = h[8] & 0x3F | 0x80
        let t = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15])
        return UUID(uuid: t)
    }

    /// → 로 다음 날에 넘긴 할 일의 id (대문자 UUID 문자열). 원래 id 가 UUID 가 아니면 nil (앱은 새 UUID 를 쓴다)
    public static func carryTaskId(_ originalId: String) -> String? {
        uuidV5(namespace: originalId, name: "carry")
    }

    /// 앱 모델(UUID)용
    public static func carryTaskId(_ originalId: UUID) -> UUID {
        uuidV5(namespace: originalId, name: "carry")
    }
}
