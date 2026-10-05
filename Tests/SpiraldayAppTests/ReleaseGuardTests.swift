import XCTest

/// 출시 지킴이 (묶음 R): build.sh 는 서명해 내보내는 빌드(SIGN_ID · RELEASE=1)에서 사장님이 알려 준 문제의 고친 커밋이
/// 모두 HEAD 의 조상일 때만 만든다. 이 시험은 그 목록이 살아 있는지 본다 — 목록이 비거나 줄었는지, 그리고 (git 저장소에서 돌 때)
/// 목록의 커밋이 정말 지금 HEAD 에 들어 있는지 (저장소를 다시 써서 해시가 바뀌면 여기서 먼저 빨개진다).
final class ReleaseGuardTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func requiredFixes() throws -> [String] {
        let script = try String(contentsOf: Self.root.appendingPathComponent("build.sh"), encoding: .utf8)
        guard let start = script.range(of: "REQUIRED_FIXES=("), let end = script.range(of: "\n)", range: start.upperBound..<script.endIndex) else {
            XCTFail("build.sh 에 REQUIRED_FIXES 가 없다")
            return []
        }
        return script[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\"") else { return nil }
            return String(t.dropFirst().prefix { $0 != " " })
        }
    }

    func testTheReleaseBuildRequiresEveryOwnerFix() throws {
        let fixes = try requiredFixes()
        // 형광펜 사고(A) 두 커밋 · 팔레트 책(E) · 넘김 위 고리(B) · 입력 · 팔레트(G H J E D) · 기본값(S) · 처음 안내 합류(I P O)
        for c in ["3f074d4", "63d21fc", "63ab4fb", "478e1de", "d43ba6c", "0331099", "cacdff6"] {
            XCTAssertTrue(fixes.contains(c), "build.sh 의 출시 지킴이에서 \(c) 가 빠졌다")
        }
        let script = try String(contentsOf: Self.root.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("merge-base --is-ancestor"), "조상인지 git 으로 확인한다")
        XCTAssertTrue(script.contains(#"[ -n "$SIGN_ID" ]"#), "서명한 출시 빌드는 늘 확인한다")
        let build = script.split(separator: "\n").first { $0.hasPrefix("BUILD=") }.flatMap { Int($0.dropFirst("BUILD=".count)) }
        XCTAssertGreaterThanOrEqual(build ?? 0, 10, "1.1.0 빌드 9 는 고침보다 먼저 만든 것이다")
    }

    /// git 저장소에서 돌면: 목록의 커밋이 모두 지금 HEAD 에 들어 있다 (출시 빌드가 멈추지 않는다)
    func testTheRequiredFixesAreInThisCheckout() throws {
        guard FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(".git").path) else {
            throw XCTSkip("git 저장소가 아님 (소스 묶음에서 빌드)")
        }
        for c in try requiredFixes() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", Self.root.path, "merge-base", "--is-ancestor", c, "HEAD"]
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(c) 가 HEAD 에 없다 — 출시 빌드가 멈춘다 (저장소를 다시 썼으면 build.sh 의 해시도 고칠 것)")
        }
    }
}
