// 페어링 (보여 주는 쪽 · 들어오는 쪽) — 승인 게이트.
//
// 원래 기기 A                                   새 기기 B
//   offer = startPairing(mode:)  QR · 코드 표시
//                                                  join = joinGroup(QR 글 · 코드)    ← 그룹 키는 아직 오지 않는다
//   req = await offer.wait()                       join.confirmDigits 표시
//   "새 기기 화면의 숫자 4자리를 입력해 주세요"   ← A 는 숫자를 보여 주지 않는다 (옮겨 적어야 승인된다)
//   [연결] offer.approve(enteredDigits:) · [아니에요] offer.deny()
//                                                  r = await join.waitForApproval() → 승인되면 K 를 받아 풀고 그룹의 기기 이름
//                                                  [시작] join.accept() · [그만두기] join.reject()
import Foundation
import os

/// 원래 기기가 보여 주는 QR · 8자 코드 하나
public final class PairingOffer: Sendable {
    public let pairingId: String
    public let mode: PairingMode
    /// .code: "ABCD-EFGH"
    public let code: String?
    /// .qr: QR 에 담을 글
    public let qrText: String?
    /// ms
    public let expiresAt: Int

    let engine: SyncEngine
    let secret: PairingSecret
    let gid: String
    private let state = OSAllocatedUnfairLock<(cancelled: Bool, request: JoinRequest?, digits: String?, wrong: Int)>(initialState: (false, nil, nil, 0))

    init(engine: SyncEngine, secret: PairingSecret, gid: String, pairingId: String, mode: PairingMode, code: String?, qrText: String?, expiresAt: Int) {
        self.engine = engine
        self.secret = secret
        self.gid = gid
        self.pairingId = pairingId
        self.mode = mode
        self.code = code
        self.qrText = qrText
        self.expiresAt = expiresAt
    }

    /// 새 기기가 합류를 요청할 때까지 기다린다 → 들어오려는 기기와 확인 숫자.
    /// 만료 · 취소 · 거절되면 nil (Task 를 취소해도 nil). 네트워크가 잠깐 끊겨도 기한까지 다시 묻는다.
    public func wait(intervalMs: Int = 2000) async throws -> JoinRequest? {
        let st = try await engine.waitPairing(pairingId, expiresAt: expiresAt, intervalMs: intervalMs) { [state] in state.withLock { $0.cancelled } }
        guard let st, let dev = st.device, let nonce = st.nonce else { return nil }
        let req = JoinRequest(pairingId: pairingId, deviceId: dev.id, platform: platformOf(dev.name), expiresAt: st.expiresAt)
        let digits = secret.confirmDigits(gid: gid, pairingId: pairingId, deviceId: dev.id, nonce: nonce)
        state.withLock {
            $0.request = req
            $0.digits = digits
        }
        return req
    }

    /// 숫자를 더 틀릴 수 있는 횟수
    public var triesLeft: Int { state.withLock { max(0, MAX_DIGIT_TRIES - $0.wrong) } }

    /// [연결]: 사용자가 새 기기 화면에 보이는 확인 숫자 4자리를 입력했다 → 맞으면 서버가 그 기기에 그룹 키를 내준다.
    /// 다르면 .digitsMismatch (서버에는 아무것도 보내지 않는다). MAX_DIGIT_TRIES 번 틀리면 그 요청을 거절하고 .pairingDenied
    public func approve(enteredDigits: String) async throws {
        guard let (req, digits) = state.withLock({ s -> (JoinRequest, String)? in
            guard let r = s.request, let d = s.digits else { return nil }
            return (r, d)
        }) else {
            throw SyncEngineError(.invalidArgument, "먼저 wait() 로 들어오려는 기기를 받아야 해요")
        }
        let typed = String(enteredDigits.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) && $0 != "-" })
        if !sameDigits(typed, digits) {
            let wrong = state.withLock { s -> Int in
                s.wrong += 1
                return s.wrong
            }
            if wrong >= MAX_DIGIT_TRIES {
                try? await deny()
                throw SyncEngineError(.pairingDenied, "숫자가 여러 번 달라서 이 요청을 거절했어요. 새 기기에서 처음부터 다시 해 주세요.")
            }
            throw SyncEngineError(.digitsMismatch, "숫자가 달라요. 새 기기 화면의 숫자를 다시 확인해 주세요. (\(MAX_DIGIT_TRIES - wrong)번 더 넣을 수 있어요)")
        }
        try await engine.approvePairing(pairingId, deviceId: req.deviceId)
    }

    /// [아니에요]: 숫자가 다르거나 모르는 기기 → 거절 (그룹 키는 나가지 않는다)
    public func deny() async throws {
        state.withLock { $0.cancelled = true }
        try await engine.cancelPairing(pairingId)
    }

    /// 그만두기 (QR ↔ 코드 바꾸기 · 화면 닫기). 요청이 와 있었다면 거절과 같다
    public func cancel() async throws {
        state.withLock { $0.cancelled = true }
        try await engine.cancelPairing(pairingId)
    }
}

/// 새 기기의 합류 요청 (승인을 기다리는 중)
public final class PendingJoin: Sendable {
    public let gid: String
    /// 승인되면 이 기기의 id
    public let deviceId: String
    public let pairingId: String
    public let mode: PairingMode
    /// 이 화면에 보일 확인 숫자 (원래 기기 화면과 같아야 한다). 그룹 키를 받기 전에 보여 줄 수 있다
    public let confirmDigits: String
    /// 이때까지 원래 기기가 승인해야 한다 (ms)
    public let expiresAt: Int

    let engine: SyncEngine
    let secret: PairingSecret
    let auth: Auth
    let token: String
    let deviceName: String

    struct State {
        var settled: JoinOutcome?
        var keys: GroupKeys?
        var inflight: Task<Result<JoinOutcome, any Error>, Never>?
        var stopped = false
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(engine: SyncEngine, secret: PairingSecret, res: ClaimRes, mode: PairingMode, confirmDigits: String, deviceName: String) {
        self.engine = engine
        self.secret = secret
        gid = res.gid
        deviceId = res.deviceId
        pairingId = res.pairingId
        self.mode = mode
        self.confirmDigits = confirmDigits
        expiresAt = res.expiresAt
        auth = Auth(gid: res.gid, token: res.token)
        token = res.token
        self.deviceName = deviceName
    }

    /// 원래 기기의 [연결] 을 기다린다 → 그룹 키를 받아 풀고, 들어갈 그룹의 기기들을 돌려준다.
    /// 이 기기에 플래너가 있으면 수락 화면에 "이 기기의 플래너 N권도 함께 동기화돼요" 를 꼭 보여 준다.
    /// 네트워크가 잠깐 끊겨도 기한까지 다시 묻는다. 여러 번 불러도 같은 결과. 기다리는 Task 를 취소하면 .cancelled (다시 기다릴 수 있다)
    public func waitForApproval(intervalMs: Int = 1500) async throws -> JoinOutcome {
        let (done, task) = state.withLock { s -> (JoinOutcome?, Task<Result<JoinOutcome, any Error>, Never>?) in
            if let o = s.settled { return (o, nil) }
            if let t = s.inflight { return (nil, t) }
            let t = Task<Result<JoinOutcome, any Error>, Never> {
                do { return .success(try await self.runWait(intervalMs: intervalMs)) } catch { return .failure(error) }
            }
            s.inflight = t
            return (nil, t)
        }
        if let done { return done }
        let r = await withTaskCancellationHandler { await task!.value } onCancel: { task!.cancel() }
        return try r.get()
    }

    private func runWait(intervalMs: Int) async throws -> JoinOutcome {
        defer { state.withLock { $0.inflight = nil } }
        if let s = state.withLock({ $0.settled }) { return s }
        let r = try await engine.pollJoin(auth, pairingId: pairingId, expiresAt: expiresAt, intervalMs: intervalMs) { [state] in
            state.withLock { $0.stopped }
        }
        // 그 사이 reject() 했다 (서버 쪽은 reject 가 거둔다)
        if state.withLock({ $0.stopped }) { return .cancelled }
        guard case let .approved(wrappedKey) = r else {
            let o: JoinOutcome
            switch r {
            case .denied: o = .denied
            case .expired: o = .expired
            default: o = .cancelled
            }
            // 그만둔 것(cancelled)은 다시 기다릴 수 있다 (서버의 요청은 남아 있다)
            if o != .cancelled { state.withLock { $0.settled = o } }
            return o
        }
        let keys: GroupKeys
        do {
            keys = try secret.unwrap(wrappedKey, gid: gid)
        } catch {
            // 다른 키를 받았다 (서버 · 코드가 다름) → 이 기기를 빼고 아무것도 남기지 않는다
            do { try await engine.transport.withdrawJoin(auth, pairingId: pairingId) } catch {
                try? await engine.transport.removeDevice(auth, deviceId: "me")
            }
            state.withLock { $0.settled = .denied }
            throw SyncEngineError(.wrongKey, "그룹 키를 풀지 못했어요. 새 코드로 다시 시도해 주세요.", underlying: error)
        }
        state.withLock { $0.keys = keys }
        var groupDevices: [GroupDevice] = []
        do {
            let list = try await engine.transport.devices(auth)
            groupDevices = list.devices.filter { $0.id != deviceId }.map { d in
                let n = describeDevice(d, keys: keys)
                return GroupDevice(id: d.id, name: n.name, platform: n.platform)
            }
        } catch {
            await engine.log(.warn, "그룹의 기기 목록을 받지 못함", error)
        }
        let o = JoinOutcome.approved(groupDevices: groupDevices, acceptBy: await engine.now() + ACCEPT_WINDOW_MS)
        state.withLock { $0.settled = o }
        return o
    }

    /// 승인된 뒤: 그룹에 들어가 동기화를 시작한다 (아직이면 승인을 기다린다. 거절 · 만료면 SyncEngineError)
    public func accept() async throws {
        if state.withLock({ $0.finished }) { return }
        let o = try await waitForApproval()
        switch o {
        case .denied: throw SyncEngineError(.pairingDenied, "원래 기기에서 연결을 거절했어요.")
        case .expired: throw SyncEngineError(.pairingExpired, "시간이 지나 연결하지 못했어요. 원래 기기에서 새 코드를 만들어 주세요.")
        case .cancelled: throw SyncEngineError(.pairingExpired, "연결을 그만뒀어요.")
        case let .approved(_, acceptBy):
            if await engine.now() > acceptBy {
                // 서버가 곧(또는 이미) 수락하지 않은 이 기기를 뺀다 → 들어가지 않는다
                let first = state.withLock { s -> Bool in
                    defer { s.finished = true }
                    return !s.finished
                }
                if first { try? await engine.transport.withdrawJoin(auth, pairingId: pairingId) }
                throw SyncEngineError(.pairingExpired, "시작하지 않은 채 시간이 지났어요. 원래 기기에서 다시 연결해 주세요.")
            }
        }
        enum Next { case done, missing, go(GroupKeys) }
        let next: Next = state.withLock { s in
            if s.finished { return .done }
            guard let k = s.keys else { return .missing }
            s.finished = true
            return .go(k)
        }
        let keys: GroupKeys
        switch next {
        case .done: return
        case .missing: throw SyncEngineError(.pairingExpired, "연결을 그만뒀어요.")
        case let .go(k): keys = k
        }
        try await engine.enterGroup(Credentials(gid: gid, deviceId: deviceId, token: token, key: keys.base64), keys, .zero)
        await engine.applyName(deviceName)
    }

    /// 숫자가 다르다 · 그만둔다: 승인 전이면 요청을 거두고, 승인 뒤면 서버에서 이 기기를 뺀다. 아무것도 남지 않는다
    public func reject() async throws {
        let (go, settled, keys, inflight) = state.withLock { s -> (Bool, JoinOutcome?, GroupKeys?, Task<Result<JoinOutcome, any Error>, Never>?) in
            if s.finished { return (false, nil, nil, nil) }
            s.finished = true
            s.stopped = true
            return (true, s.settled, s.keys, s.inflight)
        }
        guard go else { return }
        inflight?.cancel()
        var shouldWithdraw = settled == nil
        if case .approved? = settled { shouldWithdraw = true }
        if shouldWithdraw {
            // 승인 전: 요청을 거둔다 · 승인 뒤(키를 받았어도): 서버가 이 기기를 뺀다
            do {
                try await engine.transport.withdrawJoin(auth, pairingId: pairingId)
            } catch {
                if keys != nil {
                    do { try await engine.transport.removeDevice(auth, deviceId: "me") } catch {
                        await engine.log(.warn, "거절한 기기를 지우지 못함", error)
                    }
                } else {
                    await engine.log(.warn, "합류 요청을 거두지 못함", error)
                }
            }
        }
        state.withLock { $0.settled = .cancelled }
    }
}

extension SyncEngine {
    // MARK: 원래 기기

    /// 새 기기를 들일 QR 이나 8자 코드를 만든다 (10분). QR 이 기본 — 코드는 카메라가 없을 때만
    public func startPairing(mode: PairingMode = .qr, ttlSec: Int = 600) async throws -> PairingOffer {
        let a = try authOrThrow()
        let keys = self.keys!
        var attempt = 0
        while true {
            var code: String?
            var qrText: String?
            let secret: PairingSecret
            if mode == .code {
                let c = Codes.newPairingCode()
                code = c
                secret = try await Task.detached { try PairingSecret.fromCode(c) }.value
            } else {
                let q = Pairing.newQrSecret()
                qrText = q.text
                secret = try PairingSecret.fromQrSecret(q.secret)
            }
            do {
                let wrapped = secret.wrap(keys, gid: a.gid)
                let res = try await transport.createPairing(a, codeHash: secret.codeHash, wrappedKey: wrapped, expiresIn: ttlSec, mode: mode)
                return PairingOffer(engine: self, secret: secret, gid: a.gid, pairingId: res.pairingId, mode: mode,
                                    code: code.map(Codes.formatPairingCode), qrText: qrText, expiresAt: res.expiresAt)
            } catch let e as SyncHTTPError where e.code == "code_in_use" && attempt < 3 {
                attempt += 1
                continue
            } catch {
                throw wrap(error)
            }
        }
    }

    /// 페어링이 요청(claimed)되거나 승인(approved)될 때까지 묻는다. 만료 · 거절 · 취소면 nil.
    /// WebSocket {pairing} 알림이 오면 바로 다시 묻는다. 네트워크 · 5xx · 429 는 기한까지 다시.
    func waitPairing(_ pairingId: String, expiresAt: Int, intervalMs: Int, cancelled: @Sendable () -> Bool) async throws -> PairingStatusRes? {
        let a = try authOrThrow()
        var deadline = expiresAt
        var pause = intervalMs
        while true {
            if cancelled() || Task.isCancelled { return nil }
            var st: PairingStatusRes?
            do {
                st = try await transport.pairingStatus(a, pairingId: pairingId)
                pause = intervalMs
            } catch let e as SyncHTTPError where e.status == 404 && e.code == "pairing_not_found" {
                return nil
            } catch {
                if !isTransient(error) { throw wrap(error) }
                if now() > deadline + CLOCK_GRACE_MS { return nil }
                pause = retryPause(error, intervalMs)
            }
            if let st {
                if st.status == "claimed" || st.status == "approved" { return st }
                if st.status != "pending" { return nil }
                deadline = st.expiresAt
            }
            if cancelled() || Task.isCancelled { return nil }
            await sleepOrWake(ms: max(10, min(pause, deadline + CLOCK_GRACE_MS - now())), pairingId: pairingId)
        }
    }

    /// 원래 기기의 승인
    func approvePairing(_ pairingId: String, deviceId: String) async throws {
        let a = try authOrThrow()
        do {
            try await transport.approvePairing(a, pairingId: pairingId, deviceId: deviceId)
        } catch let e as SyncHTTPError where e.status == 404 && e.code == "pairing_not_found" {
            throw SyncEngineError(.pairingExpired, "새 기기가 요청을 거뒀거나 시간이 지났어요. 다시 연결해 주세요.", underlying: e)
        } catch {
            throw wrap(error)
        }
    }

    func cancelPairing(_ pairingId: String) async throws {
        let a = try authOrThrow()
        do {
            try await transport.cancelPairing(a, pairingId: pairingId)
        } catch let e as SyncHTTPError where e.status == 404 {
        } catch {
            throw wrap(error)
        }
    }

    // MARK: 새 기기

    /// QR 글이나 8자 코드로 그룹에 합류를 요청한다. 확인 숫자를 바로 보여 줄 수 있다 (그룹 키는 아직 오지 않는다).
    /// 원래 기기가 승인하면 waitForApproval() 이 그룹 키를 받아 오고, accept() 로 들어간다.
    public func joinGroup(_ input: String, deviceName: String) async throws -> PendingJoin {
        try assertInit()
        if creds != nil { throw SyncEngineError(.alreadyInGroup, "이미 동기화 그룹에 들어 있어요. 먼저 나와야 해요.") }
        guard let parsed = Pairing.parseInput(input) else {
            throw SyncEngineError(.invalidCode, "코드 형식이 맞지 않아요. 8자리 코드를 다시 확인해 주세요.")
        }
        let secret: PairingSecret
        let mode: PairingMode
        switch parsed {
        case let .qr(s):
            secret = try PairingSecret.fromQrSecret(s)
            mode = .qr
        case let .code(c):
            secret = try await Task.detached { try PairingSecret.fromCode(c) }.value
            mode = .code
        }
        let nonce = Pairing.newNonce()
        let res: ClaimRes
        do {
            // 아직 K 가 없어 이름을 암호화하지 못한다 → 플랫폼 이름만 ("p.iPhone"). 들어간 뒤 e1. 로 바꾼다
            res = try await transport.claimPairing(codeHash: secret.codeHash, deviceName: "p." + platform.rawValue, mode: mode, nonce: nonce)
        } catch let e as SyncHTTPError where e.status == 404 {
            throw SyncEngineError(.invalidCode, "코드가 맞지 않거나 시간이 지났어요. 원래 기기에 다른 요청이 와 있다면 그 기기에서 [아니에요]를 눌러 주세요.", underlying: e)
        } catch let e as SyncHTTPError where e.status == 429 && e.code == "code_join_paused" {
            throw SyncEngineError(.codeJoinPaused, "지금은 코드로 연결하는 요청이 너무 많아 막아 두었어요. \(waitText(e.retryAfter)) 뒤에 다시 해 주세요.", underlying: e)
        } catch let e as SyncHTTPError where e.status == 429 && mode == .code {
            throw SyncEngineError(.rateLimited, "이 네트워크에서 코드를 여러 번 틀렸어요. \(waitText(e.retryAfter)) 뒤에 다시 하거나 QR 코드로 연결해 주세요.", underlying: e)
        } catch {
            throw wrap(error)
        }
        let digits = secret.confirmDigits(gid: res.gid, pairingId: res.pairingId, deviceId: res.deviceId, nonce: nonce)
        return PendingJoin(engine: self, secret: secret, res: res, mode: mode, confirmDigits: digits, deviceName: deviceName)
    }

    enum PollJoinResult: Sendable {
        case approved(wrappedKey: String)
        case denied
        case expired
        case cancelled
    }

    /// 새 기기: 승인 · 거절 · 만료까지 묻는다
    func pollJoin(_ auth: Auth, pairingId: String, expiresAt: Int, intervalMs: Int, aborted: @Sendable () -> Bool) async throws -> PollJoinResult {
        var deadline = expiresAt
        var pause = intervalMs
        while true {
            if aborted() || Task.isCancelled { return .cancelled }
            var r: JoinPollRes?
            do {
                r = try await transport.pollJoin(auth, pairingId: pairingId)
                pause = intervalMs
            } catch let e as SyncHTTPError where e.status == 404 || e.status == 401 {
                // 404: 요청이 사라짐 (만료 뒤 지워짐 · 이미 받음) · 401: 그룹이 없거나 토큰이 다름.
                // 서버에 이 기기가 승인된 채 남아 있을 수 있다 (응답을 잃은 뒤 다시 줄 시간이 지남) → 거둬서 빼 달라고 한다
                if e.status == 404 { try? await transport.withdrawJoin(auth, pairingId: pairingId) }
                return .expired
            } catch {
                if Task.isCancelled { return .cancelled }
                if !isTransient(error) { throw wrap(error) }
                if now() > deadline + CLOCK_GRACE_MS { return .expired }
                pause = retryPause(error, intervalMs)
            }
            if let r {
                switch r {
                case let .approved(wk):
                    guard let wk else { return .expired }
                    return .approved(wrappedKey: wk)
                case .denied: return .denied
                case .expired: return .expired
                case let .waiting(exp): if let exp { deadline = exp }
                case .other: break
                }
            }
            if aborted() || Task.isCancelled { return .cancelled }
            await sleepMs(max(10, min(pause, deadline + CLOCK_GRACE_MS - now())))
        }
    }
}
