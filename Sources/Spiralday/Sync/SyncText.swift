import Foundation
import SpiraldayKit
import SpiraldaySync

// ─────────────────────────────────────────────────────────────────────────────
// 동기화 화면이 하는 말 (짧은 해요체). Windows · iOS 앱의 설정 → 동기화와 같은 흐름 · 같은 말을 Mac 에 맞게
// (Windows 의 "이 컴퓨터", iOS 의 "이 기기" → "이 Mac"). 모두 순수 함수라 단위 테스트한다 (Tests/SpiraldayAppTests).
// ─────────────────────────────────────────────────────────────────────────────

enum SyncTone: Equatable {
    case off, ok, busy, offline, warn, error
}

struct SyncStatusLine: Equatable {
    let tone: SyncTone
    let title: String
    let detail: String
}

/// 엔진이 하는 일의 맥락 (같은 오류 코드라도 흐름마다 다른 말)
enum SyncFlowContext {
    /// launch: 앱을 켤 때 (키체인에서 읽기)
    case join, restore, pair, general, launch
}

enum SyncText {
    // MARK: 기기

    /// "Windows" → "Windows PC". 목록 밖은 "새 기기" (키를 받기 전 새 기기가 보낸 이름은 믿지 않는다 — 승인 화면에 말을 넣지 못하게)
    static func platformLabel(_ p: SyncPlatform?) -> String {
        switch p {
        case .windows: "Windows PC"
        case .mac: "Mac"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .android: "Android"
        case .web: "웹 브라우저"
        case nil: "새 기기"
        }
    }

    /// 기기 목록 아이콘 (SF Symbols)
    static func platformSymbol(_ p: SyncPlatform?) -> String {
        switch p {
        case .windows: "pc"
        case .mac: "laptopcomputer"
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .android: "candybarphone"
        case .web: "globe"
        case nil: "questionmark.square.dashed"
        }
    }

    /// 기기 줄 제목: 풀어 낸 이름, 없으면 플랫폼, 그것도 없으면 "알 수 없는 기기"
    static func deviceTitle(name: String?, platform: SyncPlatform?) -> String {
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        if let platform { return "\(platformLabel(platform)) (이름 정하는 중)" }
        return "알 수 없는 기기"
    }

    /// 기기 이름: 한 줄, 제어 문자 없이, 40자까지
    static func clampDeviceName(_ name: String) -> String {
        let printable = String(name.unicodeScalars.map { s -> Character in
            s.value < 32 || s.value == 127 ? " " : Character(s)
        })
        let one = printable.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(one.prefix(40))
    }

    // MARK: 시각

    /// "방금" · "3분 전" · "오늘 오후 2:05" · "어제 오전 9:10" · "9월 28일 오후 4:00" · "2025년 12월 3일"
    static func relativeTime(_ atMs: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        let at = Date(timeIntervalSince1970: TimeInterval(atMs) / 1000)
        let diff = now.timeIntervalSince(at)
        if diff < 45, diff > -60 { return "방금" }
        if diff >= 45, diff < 3600 { return "\(max(1, Int((diff / 60).rounded())))분 전" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: at), to: calendar.startOfDay(for: now)).day ?? 0
        let clock = Self.clock.string(from: at)
        if days == 0 { return "오늘 \(clock)" }
        if days == 1 { return "어제 \(clock)" }
        if calendar.component(.year, from: at) != calendar.component(.year, from: now) {
            return Self.longDay.string(from: at)
        }
        return "\(Self.monthDay.string(from: at)) \(clock)"
    }

    /// 이전 버전의 시각: 오늘이면 초까지 (몇 분 차이 버전이 같아 보이지 않게)
    static func versionTime(_ atMs: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        let at = Date(timeIntervalSince1970: TimeInterval(atMs) / 1000)
        if calendar.isDate(at, inSameDayAs: now) {
            return "오늘 \(Self.clockSeconds.string(from: at))"
        }
        return relativeTime(atMs, now: max(now, at.addingTimeInterval(3600)), calendar: calendar)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = format
        return f
    }

    private static let clock = formatter("a h:mm")
    private static let clockSeconds = formatter("a h:mm:ss")
    private static let monthDay = formatter("M월 d일")
    private static let longDay = formatter("yyyy년 M월 d일")
    private static let createdDay = formatter("yyyy. M. d.")

    /// 기기가 들어온 날 "2026. 9. 3."
    static func createdDate(_ ms: Int) -> String {
        createdDay.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    /// Retry-After 초 → "30초" · "5분" · "2시간"
    static func waitText(_ sec: Double?) -> String {
        let n = max(1, Int((sec ?? 60).rounded(.up)))
        if n < 60 { return "\(n)초" }
        if n < 3600 { return "\(Int((Double(n) / 60).rounded(.up)))분" }
        return "\(Int((Double(n) / 3600).rounded(.up)))시간"
    }

    /// 남은 시간 "9:41" (m:ss)
    static func countdown(_ deadline: Date, now: Date = Date()) -> String {
        let s = max(0, Int(deadline.timeIntervalSince(now)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// VoiceOver 가 읽을 남은 시간 ("9분 41초 남음")
    static func countdownSpoken(_ deadline: Date, now: Date = Date()) -> String {
        let s = max(0, Int(deadline.timeIntervalSince(now)))
        return "\(s / 60)분 \(s % 60)초 남음"
    }

    // MARK: 상태

    /// 상태 한 줄 (설정 맨 위 · 팔레트의 작은 표시)
    static func statusLine(state: SyncState?, pending: Int, lastSyncAt: Int?, error: String?, live: Bool,
                           now: Date = Date()) -> SyncStatusLine {
        let last = lastSyncAt.map { "마지막으로 맞춘 때: \(relativeTime($0, now: now))" } ?? "아직 한 번도 맞추지 않았어요"
        let waiting = pending > 0 ? " 이 Mac 에서 고친 기록 \(pending)개가 기다리고 있어요." : ""
        guard let state else {
            return SyncStatusLine(tone: .busy, title: "동기화를 준비하는 중이에요", detail: "")
        }
        switch state {
        case .off:
            return SyncStatusLine(tone: .off, title: "동기화 꺼짐", detail: "플래너는 이 Mac 에만 있어요.")
        case .idle:
            return SyncStatusLine(tone: .ok, title: "동기화됨", detail: live ? "다른 기기와 실시간으로 이어져 있어요 · \(last)" : last)
        case .syncing:
            return SyncStatusLine(tone: .busy, title: "맞추는 중…", detail: last)
        case .offline:
            return SyncStatusLine(tone: .offline, title: "오프라인", detail: "인터넷에 다시 연결되면 저절로 맞춰요." + waiting)
        case .error:
            let what = engineMessage(error) ?? "동기화 서버와 이야기하지 못했어요."
            return SyncStatusLine(tone: .warn, title: "잠깐 문제가 있어요", detail: what + " 저절로 다시 해 볼게요." + waiting)
        case .quota:
            let what = engineMessage(error) ?? "그룹 저장 공간을 다 썼어요."
            return SyncStatusLine(tone: .error, title: "동기화 공간이 가득 찼어요",
                                  detail: what + " 새 기록은 이 Mac 에만 저장되고, 공간이 나면 저절로 보내요. 다 쓴 플래너를 지우면 공간이 나요.")
        case .removed:
            return SyncStatusLine(tone: .error, title: "이 Mac 은 동기화에서 빠졌어요",
                                  detail: "그룹의 다른 기기에서 이 Mac 을 뺐거나, 복구 코드로 새 기기가 들어오면서 빠졌어요. 플래너는 이 Mac 에 그대로 있어요.")
        case .groupGone:
            return SyncStatusLine(tone: .error, title: "동기화 그룹을 찾지 못했어요",
                                  detail: "서버에 이 Mac 의 동기화 그룹이 없어요. 다른 기기에서 그룹을 지웠거나 13개월 동안 쓰지 않아 정리됐을 수 있어요. 플래너는 이 Mac 에 그대로 있어요.")
        }
    }

    /// 팔레트 · 메뉴의 짧은 상태: "동기화됨 · 오늘 오후 2:05"
    static func statusShort(state: SyncState?, pending: Int, lastSyncAt: Int?, now: Date = Date()) -> String {
        let l = statusLine(state: state, pending: pending, lastSyncAt: lastSyncAt, error: nil, live: false, now: now)
        if state == .idle, let lastSyncAt { return "\(l.title) · \(relativeTime(lastSyncAt, now: now))" }
        if state == .offline || state == .error, pending > 0 { return "\(l.title) · 기다리는 기록 \(pending)개" }
        return l.title
    }

    /// 엔진이 상태에 적어 둔 한국어 문구 → 앱 문구 (엔진의 말은 그대로 보여 줄 수 있는 한국어다)
    static func engineMessage(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw == "책장을 읽을 수 없어 동기화를 시작하지 못했어요." { return errorText(code: .libraryUnavailable, fallback: nil) }
        return raw
    }

    // MARK: 오류 (하던 일이 안 됐을 때)

    /// 엔진 오류 → 보여 줄 말. 맥락(합류 · 복구 · 기기 추가)마다 다르게
    static func errorText(_ error: Error, _ ctx: SyncFlowContext = .general) -> String {
        if let e = error as? SyncEngineError {
            let retry = (e.underlying as? SyncHTTPError)?.retryAfter
            return errorText(code: e.code, fallback: e.message, ctx, retryAfter: retry)
        }
        if error is CredentialsUnreadable { return "이 Mac 의 동기화 열쇠를 열 수 없어요." }
        if error is KeychainError {
            return ctx == .launch
                ? "키체인에서 동기화 열쇠를 읽지 못했어요. 잠시 뒤 다시 해 볼게요."
                : "키체인에 동기화 열쇠를 두지 못했어요. 키체인 접근을 허용했는지 확인하고 다시 해 주세요."
        }
        if error is NetworkError { return errorText(code: .offline, fallback: nil, ctx) }
        return "잘 되지 않았어요. 잠시 뒤 다시 해 주세요."
    }

    static func errorText(code: SyncEngineError.Code?, fallback: String?, _ ctx: SyncFlowContext = .general, retryAfter: Double? = nil) -> String {
        switch code {
        case .invalidCode:
            return ctx == .restore
                ? "복구 코드가 맞지 않아요. 글자를 다시 확인해 주세요."
                : "코드가 맞지 않거나 시간이 지났어요. 다른 기기에서 보이는 코드를 다시 확인해 주세요. 그 기기에 모르는 연결 요청이 와 있다면 [아니에요]를 눌러 주세요."
        case .pairingDenied:
            return ctx == .pair
                ? "숫자가 여러 번 달라서 이 요청을 거절했어요. 새 기기에서 처음부터 다시 해 주세요."
                : "다른 기기에서 연결을 거절했어요."
        case .pairingExpired:
            return ctx == .pair
                ? "새 기기가 요청을 거뒀거나 시간이 지났어요. 다시 연결해 주세요."
                : "시간이 지났어요. 다른 기기에서 새 코드를 만들어 다시 해 주세요."
        case .digitsMismatch:
            return "새 기기 화면의 숫자와 달라요. 새 기기에 보이는 숫자 4자리를 다시 확인해 주세요."
        case .rateLimited:
            return ctx == .join
                ? "이 네트워크에서 코드를 여러 번 틀려서 \(waitText(retryAfter)) 동안 코드로 연결할 수 없어요. 원래 기기에서 ‘QR 코드’를 고른 뒤 ‘연결 글 복사’로 받은 글을 붙여 넣어 주세요."
                : "요청이 너무 많아요. \(waitText(retryAfter)) 뒤에 다시 해 주세요."
        case .codeJoinPaused:
            return "지금은 여러 곳에서 코드 연결이 몰려서 코드 연결을 막아 두었어요 (\(waitText(retryAfter)) 뒤에 풀려요). 원래 기기에서 ‘QR 코드’를 고른 뒤 ‘연결 글 복사’로 받은 글을 붙여 넣어 주세요."
        case .deviceLimit:
            return "그룹에 기기가 10대 있어서 더 들일 수 없어요. 쓰지 않는 기기를 먼저 빼 주세요."
        case .pairingLimit:
            return "연결을 기다리는 기기가 너무 많아요. 잠시 뒤 다시 해 주세요."
        case .wrongKey:
            return ctx == .restore
                ? "복구 정보를 풀지 못했어요. 복구 코드를 다시 확인해 주세요."
                : "그룹 키를 풀지 못했어요. 새 코드로 다시 해 주세요."
        case .recoveryNotFound:
            return "이 복구 코드로 찾을 수 있는 그룹이 없어요. 가장 최근에 만든 복구 코드인지 확인해 주세요."
        case .libraryUnavailable:
            return "책장 파일(library.json)을 읽지 못해서 동기화를 시작할 수 없어요. 설정 → 데이터를 확인해 주세요."
        case .offline:
            return "인터넷에 연결되어 있지 않아요. 연결을 확인하고 다시 해 주세요."
        case .alreadyInGroup:
            return "이 Mac 은 이미 동기화 그룹에 들어 있어요."
        case .notInGroup:
            return "동기화가 꺼져 있어요."
        case .server:
            return "동기화 서버에서 문제가 생겼어요. 잠시 뒤 다시 해 주세요."
        case .notInitialized, .invalidArgument, nil:
            break
        }
        return engineMessage(fallback) ?? "잘 되지 않았어요. 잠시 뒤 다시 해 주세요."
    }

    /// 합치기 전 백업을 만들지 못했다 (합류 · 되살리기를 멈추고 묻는다)
    static func backupFailedText(_ error: Error) -> String {
        let ns = error as NSError
        let full = ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError
            || ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)
        return full ? "Mac 의 저장 공간이 부족해서 합치기 전 백업을 만들지 못했어요." : "합치기 전 백업 파일을 쓰지 못했어요."
    }

    /// 그룹 지우기 두 번째 확인: 앞뒤 빈칸 · 전각은 가리지 않는다
    static func wipeConfirmMatches(_ typed: String) -> Bool {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.compare("지우기", options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
    }

    /// 칠한 시간 "2시간 10분" · "20분" · "3시간"
    static func paintedText(minutes m: Int) -> String {
        if m < 60 { return "\(m)분" }
        if m % 60 == 0 { return "\(m / 60)시간" }
        return "\(m / 60)시간 \(m % 60)분"
    }

    // MARK: 경고 (엔진이 데이터를 지키려고 스스로 한 일)

    static func warningText(_ w: SyncWarning, bookName: String? = nil) -> (title: String, detail: String) {
        switch w {
        case .recordTooLarge:
            return ("하루 기록 하나가 너무 커요", "1MB 가 넘는 날이 있어서 그날만 보내지 못했어요. 글을 조금 줄이면 다시 보내요. 다른 기록은 계속 맞춰요.")
        case .massDeleteBooks:
            return ("플래너를 되살렸어요", "플래너 여러 권이 한꺼번에 책장에서 사라져서, 지우지 않고 동기화된 내용으로 되살렸어요. 정말 지우려면 한 권씩 지워 주세요.")
        case .bookUnlisted:
            return ("플래너를 책장에 되살렸어요", "책장에서 플래너가 사라졌는데 파일은 남아 있어서, 지운 것이 아니라고 보고 되살렸어요. 다른 기기에서도 그대로예요.")
        case .bookDeletedElsewhere:
            let detail = bookName.map { "‘\($0)’ 플래너는 다른 기기에서 지운 플래너라 동기화하지 않아요. 이 Mac 에만 남아 있어요." }
                ?? "다른 기기에서 지운 플래너라 동기화하지 않아요. 이 Mac 에만 남아 있어요."
            return ("다른 기기에서 지운 플래너예요", detail)
        case .clockSkew:
            return ("다른 기기의 시계가 앞서 있어요", "다른 기기의 날짜와 시간이 하루 넘게 앞서 있어요. 그 기기의 시계를 맞춰 주세요. 이 Mac 에서 고친 것은 그대로 맞춰요.")
        case .massDeleteDays:
            return ("하루 기록을 되살렸어요", "하루 기록이 한꺼번에 많이 사라져서, 지우지 않고 동기화된 내용으로 되살렸어요.")
        case .bookMissing:
            return ("플래너 파일을 되살렸어요", "플래너 파일이 사라져서 동기화된 내용으로 다시 만들었어요.")
        case .updateRequired:
            return ("앱을 업데이트해 주세요", "다른 기기의 새 버전 앱이 쓴 기록이 있어요. 업데이트한 뒤 처음 켤 때 그 기록까지 다시 받아 맞춰요.")
        case .undecryptable:
            return ("풀 수 없는 기록을 건너뛰었어요", "동기화 기록 하나를 풀지 못해서 그 기록은 건드리지 않았어요.")
        case .libraryUnreadable:
            return ("책장 파일을 읽지 못했어요", "library.json 을 읽을 수 없어서 동기화 비교를 잠시 쉬어요. 원본은 그대로 뒀어요.")
        }
    }

    // MARK: 코드 입력

    /// 8자 코드 칸: 대문자 · Crockford 글자만 · "ABCD-EFGH"
    static func formatCodeInput(_ raw: String) -> String {
        var clean = raw.uppercased().unicodeScalars.filter { CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ").contains($0) }
            .map(Character.init)
        clean = clean.compactMap { c in
            switch c {
            case "O": "0"
            case "I", "L": "1"
            case "U": nil
            default: c
            }
        }
        let s = String(clean.prefix(8))
        return s.count > 4 ? "\(s.prefix(4))-\(s.dropFirst(4))" : s
    }

    static func pairingCodeComplete(_ formatted: String) -> Bool { Codes.canonicalPairingCode(formatted) != nil }

    /// QR 이 담은 연결 글("SPIRALDAY-PAIR:1:…")을 붙여 넣었으면 그 글
    static func pastedPairingLink(_ raw: String) -> String? {
        guard let r = raw.range(of: #"SPIRALDAY-PAIR:1:[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])"#, options: .regularExpression) else { return nil }
        return String(raw[r])
    }

    /// 원래 기기에서 입력하는 확인 숫자: 숫자만 4자리까지
    static func digitsInput(_ raw: String) -> String {
        String(raw.filter(\.isASCII).filter(\.isNumber).prefix(4))
    }

    /// 복구 코드 칸 아래 안내
    static func recoveryInputHint(_ raw: String) -> (ok: Bool, text: String, problem: Bool) {
        let n = raw.filter { !" -‐‑–—\n\t".contains($0) }.count
        switch Codes.checkRecoveryCode(raw) {
        case .ok: return (true, "코드가 맞아요.", false)
        case .short: return (false, n == 0 ? "하이픈(-)은 없어도 돼요. 대소문자도 가리지 않아요." : "\(n)/\(Codes.recoveryCodeLength)", false)
        case .long: return (false, "25자보다 길어요. 다시 확인해 주세요.", true)
        case .invalidChar: return (false, "복구 코드에 쓰이지 않는 글자가 있어요.", true)
        case .checksum: return (false, "어딘가 한 글자가 틀린 것 같아요. 다시 확인해 주세요.", true)
        }
    }

    // MARK: 복구 코드 단계

    /// "ABCDE-FGHJK-…" → ["ABCDE", "FGHJK", …]
    static func recoveryGroups(_ code: String) -> [String] {
        let flat = code.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        var out: [String] = []
        var cur = ""
        for c in flat {
            cur.append(c)
            if cur.count == 5 { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 다시 입력할 두 묶음의 자리 (서로 다르게, 차례대로)
    static func pickCheckGroups(count: Int = 5, random: () -> Double = { Double.random(in: 0..<1) }) -> (Int, Int) {
        let a = min(count - 1, Int(random() * Double(count)))
        var b = min(count - 2, Int(random() * Double(count - 1)))
        if b >= a { b += 1 }
        return a < b ? (a, b) : (b, a)
    }

    /// 사용자가 친 묶음: 대소문자 · 빈칸 · 하이픈은 가리지 않고, O→0, I/L→1 (엔진이 코드를 읽는 방식)
    static func normalizeTyped(_ s: String) -> String {
        s.uppercased()
            .filter { !" -‐‑–—\n\t".contains($0) }
            .map { $0 == "O" ? "0" : ($0 == "I" || $0 == "L") ? "1" : $0 }
            .reduce(into: "") { $0.append($1) }
    }

    static func groupMatches(_ typed: String, _ expected: String) -> Bool {
        !expected.isEmpty && normalizeTyped(typed) == expected.uppercased()
    }

    /// "2번"
    static func ordinal(_ i: Int) -> String { "\(i + 1)번" }

    /// VoiceOver 가 한 글자씩 읽게 ("A B C D E")
    static func spelled(_ s: String) -> String { s.map(String.init).joined(separator: " ") }

    static func longDate(_ d: Date) -> String {
        "\(longDay.string(from: d)) \(clock.string(from: d))"
    }

    /// 저장하는 .txt (텍스트 편집기 · 메모 어디서나 보이게)
    static func recoveryFileText(_ code: String, deviceName: String, at: Date) -> String {
        [
            "Spiralday 동기화 복구 코드",
            "========================",
            "",
            "    \(recoveryGroups(code).joined(separator: "-"))",
            "",
            "만든 때: \(longDate(at))",
            "만든 기기: \(deviceName)",
            "",
            "- 기기를 모두 잃어버렸을 때 이 코드로 동기화된 플래너를 되살려요.",
            "  Spiralday → 설정 → 동기화 → 복구 코드로 되살리기",
            "- 이 코드를 가진 사람은 누구나 플래너를 볼 수 있어요. 남에게 보여 주지 말고 안전한 곳에 두세요.",
            "- 이 코드를 잃으면 아무도 되살릴 수 없어요. Spiralday 도 플래너를 볼 수 없어서 도와드릴 수 없어요.",
            "- 복구 코드를 새로 만들면 이 코드는 더 이상 쓸 수 없어요.",
            "",
        ].joined(separator: "\n")
    }

    /// "Spiralday 복구 코드 2026-10-02.txt"
    static func recoveryFileName(_ at: Date) -> String { "Spiralday 복구 코드 \(Dates.key(at)).txt" }

    /// 인쇄할 복구 카드 (HTML)
    static func recoveryPrintHTML(groups: [String], at: Date, deviceName: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <html><body style="font-family: -apple-system, 'Apple SD Gothic Neo', sans-serif; color: #2B2B2F;">
        <div style="border: 1.5px solid #3C3357; border-radius: 14px; padding: 22px 26px; width: 440px;">
        <div style="font-size: 13px; font-weight: 700; color: #3C3357; letter-spacing: 0.5px;">SPIRALDAY · 동기화 복구 카드</div>
        <div style="font-family: Menlo, monospace; font-size: 22px; font-weight: 700; letter-spacing: 2px; margin: 16px 0 10px;">\(esc(groups.joined(separator: "-")))</div>
        <div style="font-size: 11.5px; color: #6E6A73; line-height: 1.7;">
        만든 때: \(esc(longDate(at))) · 만든 기기: \(esc(deviceName))<br>
        기기를 모두 잃었을 때: Spiralday → 설정 → 동기화 → 복구 코드로 되살리기<br>
        이 코드를 가진 사람은 누구나 플래너를 볼 수 있어요. 안전한 곳에 보관하세요. 잃으면 아무도 되살릴 수 없어요.
        </div></div></body></html>
        """
    }

    // MARK: 합류 · 합치기

    /// "‘작은 iPad’, ‘iPhone’" — 들어갈 그룹에 이미 있는 기기
    static func groupNamesText(_ devices: [SyncGroupDeviceName]) -> String {
        let names = devices.map { d in
            if let n = d.name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
            return platformLabel(d.platform)
        }
        if names.isEmpty { return "" }
        if names.count <= 3 { return names.map { "‘\($0)’" }.joined(separator: ", ") }
        return "‘\(names[0])’, ‘\(names[1])’ 외 \(names.count - 2)대"
    }

    /// "플래너 2권(내 플래너, 회사)"
    static func localBooksText(_ books: [String]) -> String {
        if books.isEmpty { return "" }
        let shown = books.prefix(3).joined(separator: ", ") + (books.count > 3 ? " …" : "")
        return "플래너 \(books.count)권(\(shown))"
    }

    // MARK: 이전 버전

    struct VersionRow: Identifiable, Equatable {
        var id: Int { seq }
        let seq: Int
        let at: Int
        let current: Bool
        /// "할 일 4개 · 칠한 시간 2시간 10분 · 한 줄 평"
        let summary: String
        let preview: [String]
        let empty: Bool
    }

    static func versionRows(week: Bool, _ entries: [(seq: Int, at: Int, current: Bool, value: JSONValue?)]) -> [VersionRow] {
        entries.map { v in
            let s = week ? weekSummary(v.value) : daySummary(v.value)
            return VersionRow(seq: v.seq, at: v.at, current: v.current, summary: s.summary, preview: s.preview, empty: s.empty)
        }
    }

    /// 앱 파일과 같은 읽기 (PlannerStore.decodeFile 과 같은 .iso8601 — MainActor 밖에서도)
    private static var fileDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func daySummary(_ value: JSONValue?) -> (summary: String, preview: [String], empty: Bool) {
        guard let value, let d = try? fileDecoder.decode(DayRecord.self, from: value.jsonData()) else {
            return ("비어 있음", [], true)
        }
        var parts: [String] = []
        let tasks = d.tasks.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if !tasks.isEmpty { parts.append("할 일 \(tasks.count)개") }
        let painted = d.slots.filter { $0 >= 0 }.count * 10
        if painted > 0 { parts.append("칠한 시간 \(paintedText(minutes: painted))") }
        let memos = d.memos.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if memos > 0 { parts.append("메모 \(memos)개") }
        let comment = d.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty { parts.append("한 줄 평") }
        if d.dayOff { parts.append("DAY OFF") }
        let signs = ["", "○", "△", "×", "→"]
        var preview = tasks.prefix(4).map { t in
            let i = t.mark.rawValue
            return "\(i >= 0 && i < signs.count ? signs[i] : "") \(t.text)".trimmingCharacters(in: .whitespaces)
        }
        if !comment.isEmpty { preview.append("“\(comment)”") }
        return (parts.isEmpty ? "비어 있음" : parts.joined(separator: " · "), preview, parts.isEmpty)
    }

    static func weekSummary(_ value: JSONValue?) -> (summary: String, preview: [String], empty: Bool) {
        guard let value, let w = try? fileDecoder.decode(WeekRecord.self, from: value.jsonData()),
              !(w.goal.isEmpty && w.review.isEmpty && w.stars == 0) else {
            return ("비어 있음", [], true)
        }
        var parts: [String] = []
        if !w.goal.isEmpty { parts.append("목표") }
        if !w.review.isEmpty { parts.append("돌아보기") }
        if w.stars > 0 { parts.append("별 \(w.stars)개") }
        return (parts.joined(separator: " · "), [w.goal, w.review].filter { !$0.isEmpty }.map { String($0.prefix(80)) }, false)
    }

    // MARK: 받은 편집 안내 (플래너 위에 잠깐)

    /// 펼친 플래너가 다른 기기에서 지워져 다른 플래너를 폈다
    static let closedBookNotice = "다른 기기에서 지운 플래너라 다른 플래너를 펼쳤어요."

    /// 펼치지 않은 플래너가 다른 기기에서 지워졌다
    static func removedBooksNotice(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        if names.count == 1 { return "다른 기기에서 ‘\(first)’ 플래너를 지웠어요." }
        return "다른 기기에서 ‘\(first)’ 외 \(names.count - 1)권의 플래너를 지웠어요."
    }
}
