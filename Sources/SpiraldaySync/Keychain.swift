// 기기 토큰 · 그룹 키를 Keychain 에 둔다 (서버 · 동기화 상태 파일에는 두지 않는다).
// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: 처음 잠금을 푼 뒤 (뒤에서 동기화할 때도) 읽을 수 있고,
// 백업 · 다른 기기로 옮겨 가지 않는다 (새 기기는 페어링이나 복구 코드로 들어온다).
import Foundation
import Security

/// 키체인에 항목은 있는데 읽을 수 없다 (손상 · 다른 형식). 조용히 "그룹 없음" 으로 보지 않고 앱이 안내하게 한다
public struct CredentialsUnreadable: Error, CustomStringConvertible, Sendable {
    /// 앱이 만든 CredentialStore (다른 보관 방법) · 테스트도 같은 뜻으로 던질 수 있게
    public init() {}
    public var description: String { "동기화 열쇠를 읽을 수 없어요 (키체인 항목이 손상됨)" }
}

public struct KeychainError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
    public var description: String {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? ""
        return "키체인 오류 \(status) \(msg)"
    }
}

public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public let account: String
    public let accessGroup: String?
    /// macOS 에서 데이터 보호 키체인을 쓸지 (앱은 true. 서명하지 않은 명령줄 도구는 false 여야 열린다)
    public let useDataProtectionKeychain: Bool

    /// - Parameters:
    ///   - service: 키체인 항목의 서비스 이름 (앱마다 하나)
    ///   - accessGroup: 앱 그룹 · 위젯과 나눠 쓸 때 (예: "<팀 id>.com.spiralday.app"). 보통 nil
    public init(service: String = "com.spiralday.sync", account: String = "group-credentials", accessGroup: String? = nil,
                useDataProtectionKeychain: Bool = true) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    private func base() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        if useDataProtectionKeychain { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return q
    }

    public func get() async throws -> Credentials? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let data = out as? Data else { throw KeychainError(status: st) }
        guard let c = Credentials(json: try? JSONValue.parse(data)) else { throw CredentialsUnreadable() }
        return c
    }

    public func set(_ c: Credentials?) async throws {
        guard let c else {
            let st = SecItemDelete(base() as CFDictionary)
            guard st == errSecSuccess || st == errSecItemNotFound else { throw KeychainError(status: st) }
            return
        }
        let data = c.json.jsonData()
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var st = SecItemUpdate(base() as CFDictionary, attrs as CFDictionary)
        if st == errSecItemNotFound {
            var add = base()
            for (k, v) in attrs { add[k] = v }
            add[kSecAttrSynchronizable as String] = false
            st = SecItemAdd(add as CFDictionary, nil)
        }
        guard st == errSecSuccess else { throw KeychainError(status: st) }
    }
}
