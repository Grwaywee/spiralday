import XCTest
import SwiftUI
import AppKit
@testable import SpiraldayKit
@testable import Spiralday

/// 팔레트 그림 지킴이 (사장님 피드백 D · E). `--palette-test` 가 찍는 26장의 팔레트 자리를 골든 그림(Tests/Golden/palette/*.png)과
/// 화소로 견준다 — 필통 · 도구 그림(펜 아래 흰 주머니 없음, 피드백 D)과 지금 플래너의 책 모양(표지 색 · 책등, 피드백 E)이 바뀌면 빨개진다.
/// 이 골든은 Windows 팔레트(SNAP_PALETTE) · iPad / Android 레일 그림을 견줄 때의 기준 그림이기도 하다.
///
/// 책 메뉴는 점검용 그림에서도 실제 앱의 단추(Button + NSMenu) 를 그대로 그린다 — 예전처럼 Menu 로 바꾸면(macOS 가 label 의 그림을 지움)
/// 책 모양이 사라져서 testTheBookMenuDrawsTheCurrentPlannerAsABook 와 골든이 잡는다.
///
/// 골든을 새로 찍을 때 (팔레트를 일부러 바꿨을 때만): `SPIRALDAY_UPDATE_GOLDEN=1 swift test --filter PaletteGoldenTests`
@MainActor
final class PaletteGoldenTests: XCTestCase {
    static let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Golden/palette", isDirectory: true)
    /// 날을 정해 둔다 (오늘의 컬러 · 예시 데이터가 오늘에 따라 바뀌지 않게)
    static let today = Dates.parse("2026-10-07")!

    /// --palette-test 와 같은 예시 데이터 (메모리)
    private func demoStore() -> PlannerStore {
        let store = PlannerStore(inMemory: true)
        store.fillSample(around: Self.today)
        store.useDemoBook(start: Dates.add(days: -42, to: Dates.weekStart(Self.today)))
        return store
    }

    func testThePaletteLooksLikeTheGoldenImages() throws {
        let store = demoStore()
        let cases = PaletteTest.cases(store: store, today: Self.today)
        XCTAssertEqual(cases.count, 26, "네 자리 × (펼침 2 + 접힘 4) + 자리 고르기 2")
        let update = ProcessInfo.processInfo.environment["SPIRALDAY_UPDATE_GOLDEN"] == "1"
        if update { try FileManager.default.createDirectory(at: Self.golden, withIntermediateDirectories: true) }
        let actualDir = FileManager.default.temporaryDirectory.appendingPathComponent("spiralday-palette-actual", isDirectory: true)
        try? FileManager.default.removeItem(at: actualDir)
        var compared = 0
        for (name, make) in cases {
            let shot = try XCTUnwrap(make(), name)
            let crop = try XCTUnwrap(shot.image.cropping(to: shot.palette), name)
            let url = Self.golden.appendingPathComponent(name)
            if update {
                try write(crop, url)
                continue
            }
            guard let data = try? Data(contentsOf: url), let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let want = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                XCTFail("\(name): 골든 그림이 없어요 — SPIRALDAY_UPDATE_GOLDEN=1 로 찍어 두세요")
                continue
            }
            let d = Pixels(crop).difference(Pixels(want))
            if !d.sameSize || d.strongFraction > 0.002 || d.meanDiff > 1.5 {
                try? FileManager.default.createDirectory(at: actualDir, withIntermediateDirectories: true)
                try? write(crop, actualDir.appendingPathComponent(name))
                XCTFail("\(name): 팔레트 그림이 골든과 달라요 (크기 같음 \(d.sameSize), 많이 다른 화소 \(String(format: "%.3f", d.strongFraction * 100))%, " +
                        "평균 차이 \(String(format: "%.2f", d.meanDiff))) — 지금 그림: \(actualDir.appendingPathComponent(name).path)")
            }
            compared += 1
        }
        if update { throw XCTSkip("골든 그림을 새로 찍었어요 → \(Self.golden.path)") }
        XCTAssertEqual(compared, 26)
    }

    /// 지금 플래너가 책 모양(표지 색 · 책등)으로 보인다 — 실제 앱의 단추 그대로 (피드백 E: macOS Menu 는 label 그림을 지웠다)
    func testTheBookMenuDrawsTheCurrentPlannerAsABook() throws {
        for cover in [0, 3, 7] {
            let store = PlannerStore(inMemory: true)
            store.useDemoBook(start: Self.today)
            let id = try XCTUnwrap(store.activeBook?.id)
            store.updateBook(id) { $0.cover = cover }
            let state = AppState(kind: .daily, today: Self.today)
            state.store = store
            for compact in [false, true] {
                let view = BookMenu(compact: compact)
                    .frame(width: 80)
                    .environmentObject(store)
                    .environmentObject(state)
                    .environment(\.colorScheme, .light)
                let r = ImageRenderer(content: view)
                r.scale = 2
                let px = Pixels(try XCTUnwrap(r.cgImage))
                // 표지 색 화소 (책등 그림자 빼고 표지 면만): 22 × 28 pt (작으면 17 × 22) 의 대부분
                let accent = NSColor(ColorConcept.of(cover).accent).usingColorSpace(.sRGB)!
                let want = (Int(accent.redComponent * 255), Int(accent.greenComponent * 255), Int(accent.blueComponent * 255))
                let filled = px.count { p in p.3 > 250 && abs(p.0 - want.0) <= 6 && abs(p.1 - want.1) <= 6 && abs(p.2 - want.2) <= 6 }
                let area = compact ? 17.0 * 22 : 22.0 * 28
                XCTAssertGreaterThan(Double(filled), area * 4 * 0.6, "표지 \(cover) compact \(compact): 책 모양이 그려지지 않았다")
                // 이름도 함께
                XCTAssertGreaterThan(px.count { $0.3 > 128 && $0.0 < 120 && $0.1 < 120 && $0.2 < 120 }, 20, "이름 글자")
            }
        }
    }

    // MARK: 도우미

    private func write(_ img: CGImage, _ url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    struct Pixels {
        let width: Int, height: Int
        let data: [UInt8]

        init(_ img: CGImage) {
            let w = img.width, h = img.height
            width = w
            height = h
            var d = [UInt8](repeating: 0, count: w * h * 4)
            d.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setBlendMode(.copy)
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            data = d
        }

        func count(where f: ((Int, Int, Int, Int)) -> Bool) -> Int {
            var n = 0
            for i in stride(from: 0, to: data.count, by: 4) where f((Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))) {
                n += 1
            }
            return n
        }

        struct Difference {
            var sameSize: Bool
            /// 한 채널이라도 40 넘게 다른 화소의 비율
            var strongFraction: Double
            /// 채널 차이의 평균
            var meanDiff: Double
        }

        func difference(_ o: Pixels) -> Difference {
            guard width == o.width, height == o.height else { return Difference(sameSize: false, strongFraction: 1, meanDiff: 255) }
            var strong = 0, sum = 0
            for i in stride(from: 0, to: data.count, by: 4) {
                var m = 0
                for c in 0..<4 {
                    let d = abs(Int(data[i + c]) - Int(o.data[i + c]))
                    sum += d
                    m = max(m, d)
                }
                if m > 40 { strong += 1 }
            }
            let n = max(1, width * height)
            return Difference(sameSize: true, strongFraction: Double(strong) / Double(n), meanDiff: Double(sum) / Double(n * 4))
        }
    }
}
