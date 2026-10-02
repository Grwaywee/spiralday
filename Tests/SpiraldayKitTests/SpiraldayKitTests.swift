import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import SpiraldayKit

/// SpiraldayKit 을 macOS · iOS 에서 똑같이 쓸 수 있는지: 종이 그리기 · 넘김(Metal) · 저장 · 읽기 전용 읽기.
/// `TEST_RUNNER_SPIRALDAY_RENDER_DIR=<폴더>` (xcodebuild) 또는 `SPIRALDAY_RENDER_DIR` (swift test) 를 주면 그린 PNG 를 남긴다.
@MainActor
final class SpiraldayKitTests: XCTestCase {
    /// 저장소의 Resources/Fonts (테스트 번들에는 폰트가 없다)
    private static let repoFonts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Fonts")

    override func setUp() async throws {
        Fonts.extraFontDirectories = [Self.repoFonts]
        Fonts.register()
    }

    private var renderDir: URL? {
        ProcessInfo.processInfo.environment["SPIRALDAY_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private func write(_ img: CGImage, _ name: String) {
        guard let dir = renderDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    func testHandwritingFontIsRegistered() {
        XCTAssertNotNil(PlatformFont(name: Fonts.handName, size: 20), "PoorStory 손글씨 폰트가 등록되어야 한다")
        // 줄 나눔 계산이 손글씨 폰트 기준인지 (폰트가 없으면 다른 폭이 나온다)
        XCTAssertGreaterThan(RuledText.lineHeight(fontSize: 46), 30)
        XCTAssertEqual(RuledText.wrap("", fontSize: 46, width: 400), [""])
    }

    func testPagesRenderAtDesignSize() throws {
        let store = PlannerStore(inMemory: true)
        store.fillSample(around: Date())
        store.useDemoBook(start: Dates.add(days: -42, to: Dates.weekStart(Date())))
        for kind in [PageKind.daily, .weekly, .home] {
            let state = AppState(kind: kind)
            state.store = store
            if kind == .daily { state.dayIndex = Dates.daysBetween(state.baseDay, Dates.add(days: 1, to: state.baseWeek)) }
            let snap = PageSnapshotter(store: store, state: state)
            let img = try XCTUnwrap(snap.image(kind: kind, index: state.index, size: kind.design, scale: 1))
            XCTAssertEqual(img.width, Int(kind.design.width))
            XCTAssertEqual(img.height, Int(kind.design.height))
            write(img, "\(kind.rawValue).png")
            if kind.flips {
                for page in FrontPage.allCases {
                    let front = try XCTUnwrap(snap.image(kind: kind, index: state.frontIndex(page, kind), size: kind.design, scale: 1))
                    write(front, "\(page == .cover ? "cover" : "motto")_\(kind.rawValue).png")
                }
            }
        }
    }

    func testPageCurlRendersWithMetal() throws {
        let store = PlannerStore(inMemory: true)
        store.fillSample(around: Date())
        let state = AppState(kind: .daily)
        let half = CGSize(width: PageKind.daily.design.width / 2, height: PageKind.daily.design.height / 2)
        let snap = PageSnapshotter(store: store, state: state)
        let cur = try XCTUnwrap(snap.image(kind: .daily, index: 0, size: half, scale: 1))
        let next = try XCTUnwrap(snap.image(kind: .daily, index: 1, size: half, scale: 1))
        let frames = CurlController.renderTurnFrames(PageBitmaps(current: cur, neighbor: next), direction: .forward,
                                                     edge: .leading, pageSize: half, scale: 1, frameCount: 5)
        XCTAssertEqual(frames.count, 5, "Metal 넘김 엔진이 프레임을 그려야 한다")
        for (i, f) in frames.enumerated() { write(f, String(format: "curl_daily_%02d.png", i)) }
    }

    func testHomeSectionsCoverThePage() {
        for s in HomeSection.allCases {
            let r = s.rect
            XCTAssertGreaterThan(r.width, 100)
            XCTAssertTrue(CGRect(origin: .zero, size: PageKind.home.design).insetBy(dx: -40, dy: -40).contains(r), "\(s)")
            XCTAssertEqual(s.height(forWidth: r.width), r.height, accuracy: 0.001)
        }
    }

    /// 폰의 세로 대시보드: 홈의 부분마다 폭 390 에 맞춰 그린다
    func testHomeSectionsRenderAtPhoneWidth() throws {
        let store = PlannerStore(inMemory: true)
        store.fillSample(around: Date())
        for (i, s) in HomeSection.allCases.enumerated() {
            let view = HomeSectionView(s, width: 390).background(Ink.paper).environmentObject(store)
            let r = ImageRenderer(content: view)
            r.scale = 3
            let img = try XCTUnwrap(r.cgImage, "\(s)")
            XCTAssertEqual(img.width, 390 * 3)
            XCTAssertEqual(CGFloat(img.height), (s.height(forWidth: 390) * 3).rounded(), accuracy: 1.5)
            write(img, String(format: "home_section_%d_%@.png", i, "\(s)"))
        }
    }

    func testStoreSavesAndReaderReadsWithoutWriting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spiralday-kit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlannerStore(folder: dir)
        let id = store.createBook(name: "테스트 플래너", start: Dates.add(days: -3, to: Date()), end: nil)
        let today = Dates.day(Date())
        let task = store.addTask(today, row: 2, cat: 0)
        store.taskText(today, id: task).wrappedValue = "위젯에서 보일 할 일"
        store.editDay(today) { r in for s in 0..<12 { r.slots[s] = 0 } }
        store.addDDay(title: "런칭", date: Dates.add(days: 10, to: today), to: today)
        store.saveNow()

        let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(files.count, 2, "\(files)")   // library.json + books/<id>.json
        let before = try files.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        let snap = try XCTUnwrap(PlannerSnapshotReader.read(folder: dir))
        XCTAssertEqual(snap.book?.id, id)
        XCTAssertEqual(snap.data.record(on: today).tasks.first?.text, "위젯에서 보일 할 일")
        XCTAssertEqual(snap.data.minutes(on: today), 120)
        XCTAssertEqual(snap.data.record(on: today).ddays.first?.count(from: today), "D-10")
        let after = try files.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        XCTAssertEqual(before, after, "읽기 전용 읽기는 파일을 바꾸지 않는다")
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted(), files)
    }

    func testKeyShortcutsMatchTheMac() {
        XCTAssertEqual(AppState.KeyShortcut(character: "t"), .today)
        XCTAssertEqual(AppState.KeyShortcut(character: "ㅈ"), .weekly)
        XCTAssertEqual(AppState.KeyShortcut(character: "3"), .pen(2))
        XCTAssertNil(AppState.KeyShortcut(character: "x"))
    }

    func testSharedFolder() {
        let path = PlannerStore.sharedFolder.path
        XCTAssertTrue(path.hasSuffix("Application Support/Spiralday"), path)
    }
}
