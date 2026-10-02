// 앱에서 쓰기 편하게: 기본 구성(서버 주소 · 파일 저장소 · Keychain) · 앱 수명(뒤로 · 앞으로) · os 로그
import Foundation
import os

extension SyncEngine {
    /// 앱의 기본 구성: 서버 주소는 SyncServerConfig.resolve(), 동기화 상태는 Application Support 아래 폴더, 비밀은 Keychain.
    /// - Parameters:
    ///   - platform: .iPhone · .iPad · .mac (들어오는 순간 다른 기기에 보이는 이름)
    ///   - storageDirectory: 동기화 상태 폴더 (기본: Application Support/Spiralday/SyncState)
    ///   - keychainService: 키체인 항목의 서비스 이름 (테스트 · QA 는 따로 된 이름을 쓴다)
    ///   - keychainAccessGroup: 앱 그룹 · 위젯과 나눠 쓸 때만
    ///   - useDataProtectionKeychain: macOS 에서 데이터 보호 키체인을 쓸지. 샌드박스 · keychain-access-groups 가 없는
    ///     Developer ID 앱은 false (로그인 키체인, 같은 접근성 값). iOS 에서는 보지 않는다
    public static func standard(host: any SyncHost, platform: SyncPlatform, storageDirectory: URL? = nil,
                                keychainService: String = "com.spiralday.sync", keychainAccessGroup: String? = nil,
                                useDataProtectionKeychain: Bool = true,
                                log: (@Sendable (SyncLogLevel, String) -> Void)? = nil) throws -> SyncEngine {
        let dir = try storageDirectory ?? FileSyncStorage.defaultDirectory()
        let server = SyncServerConfig.resolve()
        return SyncEngine(SyncEngineOptions(
            host: host,
            transport: HTTPTransport(baseURL: server.url),
            storage: FileSyncStorage(directory: dir),
            credentials: KeychainCredentialStore(service: keychainService, accessGroup: keychainAccessGroup,
                                                 useDataProtectionKeychain: useDataProtectionKeychain),
            platform: platform,
            log: log ?? SyncLog.os()))
    }

    /// 앱이 뒤로 갈 때 (iOS: sceneDidEnterBackground · beginBackgroundTask 안에서): 남은 편집을 비교해 올리고 연결을 닫는다.
    /// 오프라인이면 기다리지 않는다 (편집은 저장소에 남아 다음에 올라간다). 앞으로 오면 resume()
    /// 올리는 동안 resume() 이 불렸으면 (금방 앞으로 돌아왔다) 연결을 닫지 않는다 — 앞에 있는데 엔진이 멈춘 채로 남지 않게
    public func suspend() async {
        guard initialized, creds != nil, running else { return }
        lifeSeq += 1
        let seq = lifeSeq
        // 뒤로 간다 = 사용자가 치는 중이 아니다: 쓰던 칸 지키기를 끝낸다 (다음 입력이 다시 지킨다)
        liveBox.endTyping()
        // 실시간으로 친 · 받은 것을 먼저 (남은 liveEdit 비교 · 못 보낸 초안 · 저장소)
        await flushLive()
        // 쓰던 칸에 미뤄 둔 다른 기기의 글을 지금 넣는다 — 멈춘 동안은 지키는 시간을 잴 타이머가 없다. 그대로 두면 돌아와 같은 칸에
        // 바로 이어 친 글자가 옛 글과 함께 새 도장을 얻어 그 글을 모든 기기에서 덮는다
        await releaseAllHeld()
        scanTimer?.cancel()
        scanTimer = nil
        let hints = takeHints() ?? .all
        await locked { await cycle(scan: hints, pull: false, push: true) }
        guard seq == lifeSeq else { return }
        stop()
    }

    /// 앱이 앞으로 올 때: 다시 연결하고 받기 · 비교 · 보내기를 한 바퀴.
    /// suspend() 가 올리는 중이면 그 suspend 는 연결을 닫지 않고 끝난다 (이 resume 이 이긴다)
    public func resume() {
        lifeSeq += 1
        guard running else { return start() }
        // suspend 가 마무리하는 중이었다: 연결 · 주기 확인을 되살리고 한 바퀴 (밀린 비교도 모두)
        if socketOn { connectSocket() }
        if auto, pollTimer == nil { schedulePoll() }
        resumeHeld()
        kick(scan: .all, pull: true, push: true, delay: 0)
    }

    /// 복구 코드를 새로 만든다 (= setupRecovery). 예전 코드는 바로 못 쓰게 된다. 돌려준 코드는 한 번만 보여 준다
    public func rotateRecovery() async throws -> String {
        try await setupRecovery()
    }
}

public enum SyncLog {
    /// os.Logger 로 (Console 앱 · Xcode 에서 subsystem 으로 거른다). 내용(플래너 글)은 엔진이 로그에 넣지 않는다
    public static func os(subsystem: String = "com.spiralday.sync", category: String = "engine") -> @Sendable (SyncLogLevel, String) -> Void {
        let logger = Logger(subsystem: subsystem, category: category)
        return { level, msg in
            switch level {
            case .debug: logger.debug("\(msg, privacy: .public)")
            case .info: logger.info("\(msg, privacy: .public)")
            case .warn: logger.warning("\(msg, privacy: .public)")
            case .error: logger.error("\(msg, privacy: .public)")
            }
        }
    }
}
