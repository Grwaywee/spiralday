import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreText

// MARK: - Color

extension Color {
    /// sRGB "RRGGBB"
    public var hexString: String {
        #if os(macOS)
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
        #endif
    }

    public init(hex: String, alpha: Double = 1) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: alpha)
    }
}

public enum Ink {
    /// 종이
    public static let paper = Color(hex: "FCFBF7")
    public static let paperBack = Color(hex: "F2EFE8")
    /// 인쇄된 양식 (라벨, 굵은 구분선, 시간 숫자)
    public static let print = Color(hex: "2B2B2F")
    /// 인쇄된 얇은 줄
    public static let rule = Color(hex: "C9C6BF")
    /// 인쇄된 점선 (칸 구분, 체크 박스)
    public static let dot = Color(hex: "B5B1A9")
    /// 손글씨
    public static let text = Color(hex: "34333A")
    public static let soft = Color(hex: "9A96A0")
    public static let faint = Color(hex: "C9C5CB")
    /// 펜 표시 (주간: 핑크, 일간: 빨강)
    public static let pen = Color(hex: "E7728F")
    public static let red = Color(hex: "E0474C")
    public static let saturday = Color(hex: "5E86D6")
    /// 요일·D-day 같은 큰 인쇄 글자
    public static let plum = Color(hex: "3C3357")
}

// MARK: - Fonts

public enum Fonts {
    /// 손글씨 — Poor Story (윤디자인, SIL OFL 1.1). 볼펜으로 또박또박 쓴 느낌. 앱에 함께 들어 있다.
    public static let handName = "PoorStory-Regular"
    /// 페이지들의 크기 값은 가는 펜글씨 기준이라 이 폰트의 글자 몸에 맞게 줄여 쓴다.
    public static let handScale: CGFloat = 0.9
    public static func hand(_ size: CGFloat) -> Font { .custom(handName, size: size * handScale) }

    /// 양식에 인쇄된 글자 (기하학적 산세리프)
    public static func print(_ size: CGFloat, _ weight: PrintWeight = .medium) -> Font {
        .custom(weight.postScriptName, size: size)
    }

    public enum PrintWeight: Sendable {
        case regular, medium, demiBold, bold
        public var postScriptName: String {
            switch self {
            case .regular: "AvenirNext-Regular"
            case .medium: "AvenirNext-Medium"
            case .demiBold: "AvenirNext-DemiBold"
            case .bold: "AvenirNext-Bold"
            }
        }
    }

    public static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// 앱에 들어 있는 폰트(Resources/Fonts)를 이 프로세스에 등록한다.
    /// .app 에서는 Contents/Resources/Fonts, 디버그 빌드에서는 저장소의 Resources/Fonts 도 찾아본다.
    /// iOS 앱 · 위젯은 번들의 Fonts 폴더나 번들 맨 위(Copy Bundle Resources)에 PoorStory-Regular.ttf 를 넣는다.
    public static func activate(_ done: @escaping @Sendable () -> Void) {
        register()
        DispatchQueue.main.async { done() }
    }

    private static var registered = false

    /// 더 찾아볼 폰트 폴더 (register() 보다 먼저 넣는다). 앱 번들 밖에 폰트를 두는 호스트용.
    nonisolated(unsafe) public static var extraFontDirectories: [URL] = []

    /// 창을 그리기 전에 반드시 먼저 불러야 한다 (늦게 등록하면 첫 화면이 기본 글꼴로 그려진다)
    public static func register() {
        guard !registered else { return }
        registered = true
        var dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts")].compactMap { $0 }
        #if !os(macOS)
        // iOS 번들은 리소스가 번들 맨 위에 놓인다
        dirs.append(Bundle.main.bundleURL)
        #endif
        dirs += extraFontDirectories
        #if DEBUG
        // swift run 같은 디버그 빌드용. 배포판에는 소스 경로를 넣지 않는다
        dirs.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts"))
        #endif
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                  files.contains(where: { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }) else { continue }
            for f in files where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
            break
        }
    }
}

// MARK: - Color concept (날마다 고르는 색 테마)

/// 하루 페이지의 강조색 세트. TOTAL TIME, 날짜의 요일, D-day 숫자, ○△× 표시, 완료 줄긋기에 쓰이고
/// tint 는 날짜 밑 형광펜처럼 옅게 깔린다.
public struct ColorConcept: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let accent: Color
    public let tint: Color

    public init(id: Int, name: String, accent: Color, tint: Color) {
        self.id = id
        self.name = name
        self.accent = accent
        self.tint = tint
    }

    public static let all: [ColorConcept] = [
        ColorConcept(id: 0, name: "체리", accent: Color(hex: "E0474C"), tint: Color(hex: "F7C3C5")),
        ColorConcept(id: 1, name: "코랄", accent: Color(hex: "EE6F4F"), tint: Color(hex: "FAD0C2")),
        ColorConcept(id: 2, name: "머스타드", accent: Color(hex: "D39A12"), tint: Color(hex: "F5E2A0")),
        ColorConcept(id: 3, name: "민트", accent: Color(hex: "23A08A"), tint: Color(hex: "BDE8DD")),
        ColorConcept(id: 4, name: "스카이", accent: Color(hex: "3A86D4"), tint: Color(hex: "C6DCF5")),
        ColorConcept(id: 5, name: "네이비", accent: Color(hex: "2E3D7C"), tint: Color(hex: "C9CFE8")),
        ColorConcept(id: 6, name: "라벤더", accent: Color(hex: "8466CC"), tint: Color(hex: "DCD1F4")),
        ColorConcept(id: 7, name: "핑크", accent: Color(hex: "DE5C8A"), tint: Color(hex: "F8CADB")),
        ColorConcept(id: 8, name: "차콜", accent: Color(hex: "3A3940"), tint: Color(hex: "DAD8D2")),
    ]

    public static func of(_ id: Int) -> ColorConcept { all[min(max(id, 0), all.count - 1)] }
}

// MARK: - Page geometry

public enum BindingEdge: Sendable { case top, leading }

/// 창 = 종이 한 장. 모든 좌표는 "디자인 단위" (기준 레이아웃 좌표) 로 적고,
/// 실제 크기는 u = 창 너비 / 디자인 너비 를 곱해서 그린다.
public enum PageKind: String, Codable, Sendable {
    case home, weekly, daily

    /// 일간: 1277 × 2000 (세로)
    /// 주간: 같은 용지를 가로로 눕힌 2000 × 1277
    public var design: CGSize {
        switch self {
        case .daily: CGSize(width: 1277, height: 2000)
        case .weekly, .home: CGSize(width: 2000, height: 1277)
        }
    }

    /// 홈(통계)은 넘기는 페이지가 아니라 한 장짜리 표지
    public var flips: Bool { self != .home }

    public var aspect: CGFloat { design.width / design.height }

    /// 스프링이 달린 쪽
    public var edge: BindingEdge { self == .daily ? .leading : .top }
}

// MARK: - Paper texture

public enum Texture {
    public static let noise: PlatformImage = {
        let w = 180, h = 180
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<(w * h) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r = Int((seed >> 33) % 1000)
            let v = 200 + (r % 56)
            let a = r < 160 ? 18 + r % 40 : 0
            let pv = UInt8(v * a / 255)
            px[i * 4 + 0] = pv
            px[i * 4 + 1] = pv
            px[i * 4 + 2] = pv
            px[i * 4 + 3] = UInt8(a)
        }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        #if os(macOS)
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: w, height: h))
        #else
        return UIImage(cgImage: ctx.makeImage()!, scale: 1, orientation: .up)
        #endif
    }()
}

public struct NoiseLayer: View {
    public var opacity: Double = 1

    public init(opacity: Double = 1) {
        self.opacity = opacity
    }
    public var body: some View {
        Image(platformImage: Texture.noise)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}

// MARK: - Spiral binding (창 가장자리 = 스프링 쪽)

public enum SpiralBinding {
    /// 종이에 뚫린 구멍 (디자인 단위)
    public static func holes(_ kind: PageKind) -> [CGRect] {
        switch kind {
        case .daily:
            // 왼쪽 가장자리: 약 94px 간격, y≈120 부터 끝까지
            return stride(from: 120.0, through: 1890.0, by: 94.5).map {
                CGRect(x: 9, y: $0 - 8, width: 12, height: 16)
            }
        case .weekly, .home:
            // 왼쪽 위 모서리는 창 버튼(빨노초) 자리라 비워 둔다
            return stride(from: 170.0, through: 1965.0, by: 41.5).map {
                CGRect(x: $0 - 8, y: 9, width: 16, height: 12)
            }
        }
    }
}

/// 종이 바탕 + 결 + 스프링 구멍. 페이지 스냅샷에 함께 구워진다.
public struct PaperSurface: View {
    public let kind: PageKind
    public let u: CGFloat
    @Environment(\.isPrinting) private var isPrinting

    public init(kind: PageKind, u: CGFloat) {
        self.kind = kind
        self.u = u
    }

    public var body: some View {
        if isPrinting {
            Color.white.allowsHitTesting(false)
        } else {
            surface
        }
    }

    private var surface: some View {
        ZStack(alignment: .topLeading) {
            Ink.paper
            NoiseLayer(opacity: 0.5).blendMode(.multiply)
            LinearGradient(colors: [.black.opacity(0.05), .clear],
                           startPoint: kind.edge == .top ? .top : .leading,
                           endPoint: kind.edge == .top ? UnitPoint(x: 0.5, y: 0.05) : UnitPoint(x: 0.05, y: 0.5))
            Canvas { ctx, _ in
                ctx.scaleBy(x: u, y: u)
                for r in SpiralBinding.holes(kind) {
                    ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Color(hex: "4E5057").opacity(0.85)))
                    ctx.stroke(Path(roundedRect: r.insetBy(dx: -0.8, dy: -0.8), cornerRadius: 3.5),
                               with: .color(.black.opacity(0.07)), lineWidth: 1.2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Highlighter bar (손글씨 뒤 형광펜)

public struct HighlighterBar: View {
    public let color: Color

    public init(color: Color) {
        self.color = color
    }
    public var body: some View {
        GeometryReader { g in
            Path { p in
                let w = g.size.width, h = g.size.height
                p.move(to: CGPoint(x: 1, y: h * 0.18))
                p.addLine(to: CGPoint(x: w - 2, y: h * 0.10))
                p.addQuadCurve(to: CGPoint(x: w, y: h * 0.86), control: CGPoint(x: w + h * 0.12, y: h * 0.5))
                p.addLine(to: CGPoint(x: 2, y: h * 0.94))
                p.addQuadCurve(to: CGPoint(x: 1, y: h * 0.18), control: CGPoint(x: -h * 0.08, y: h * 0.55))
            }
            .fill(color.opacity(0.78))
        }
        .blendMode(.multiply)
        .allowsHitTesting(false)
    }
}

// MARK: - Environment

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
private struct PrintKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// 페이지 넘김용 스냅샷을 그리는 중이면 true (편집 필드 대신 글자만 그린다)
    public var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }

    /// PDF 로 뽑는 중이면 true (흰 종이, 종이 결·스프링 구멍 없이)
    public var isPrinting: Bool {
        get { self[PrintKey.self] }
        set { self[PrintKey.self] = newValue }
    }
}
