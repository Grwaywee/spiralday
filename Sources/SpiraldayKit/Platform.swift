import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// ─────────────────────────────────────────────────────────────────────────────
// 플랫폼 차이를 여기 한곳에 모은다 (글꼴 · 색 · 그림 · 뷰 · 햅틱 · 붙여넣기 · 링크 · 커서).
// macOS 쪽은 1.0.7 까지 앱에 있던 코드와 똑같이 동작한다 (그림이 한 픽셀도 달라지지 않게).
// ─────────────────────────────────────────────────────────────────────────────

#if os(macOS)
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
public typealias PlatformView = NSView
#else
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
public typealias PlatformView = UIView
#endif

extension Image {
    /// NSImage / UIImage 를 그대로 쓰는 Image
    public init(platformImage img: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: img)
        #else
        self.init(uiImage: img)
        #endif
    }
}

// MARK: - Host hooks

/// 앱이 채워 넣는 일들. 위젯 같은 확장에서는 비워 둔다 (UIApplication.shared 를 이 라이브러리에서 부르지 않는다).
public enum PlatformServices {
    /// 링크 열기 (iOS 앱: `UIApplication.shared.open(url)`). nil 이면 Links.open 은 아무것도 하지 않는다.
    /// macOS 는 NSWorkspace 로 연다 (이 값은 쓰지 않는다).
    nonisolated(unsafe) public static var openURL: ((URL) -> Void)?
    /// 편집을 끝낼 때 키보드(첫 응답자)를 내린다 (iOS 앱이 넣는다. 보통은 편집 칸이 사라지면서 저절로 내려간다).
    nonisolated(unsafe) public static var endTextEditing: (() -> Void)?
}

// MARK: - Links

/// 밖으로 나가는 링크 (사이트 푸터와 같은 곳)
public enum Links {
    public static let website = URL(string: "https://spiralday.com")!
    public static let github = URL(string: "https://github.com/Grwaywee/spiralday")!
    public static let company = URL(string: "https://leanagilehungry.com")!
    public static let privacy = URL(string: "https://spiralday.com/privacy.html")!
    /// 버그 신고·기능 제안 (구글 설문지가 생기면 그 주소로 바꾼다)
    public static let feedback = URL(string: "mailto:contact@leanagilehungry.com?subject=%5BSpiralday%5D%20%EB%B2%84%EA%B7%B8%20%EC%8B%A0%EA%B3%A0%20%C2%B7%20%EA%B8%B0%EB%8A%A5%20%EC%A0%9C%EC%95%88")!

    public static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        PlatformServices.openURL?(url)
        #endif
    }
}

// MARK: - Haptics

/// 손끝 / 트랙패드 진동. macOS 는 넘길 수 없을 때의 트랙패드 진동(bump)만 쓴다.
@MainActor
public enum Haptics {
    /// 더 넘길 수 없을 때 (macOS: 트랙패드 .levelChange, iOS: 가벼운 경고)
    public static func bump() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #else
        notification.notificationOccurred(.warning)
        #endif
    }

    /// 가볍게 한 번 (확대 · 도구 고르기)
    public static func tap() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #else
        light.impactOccurred()
        #endif
    }

    /// 칸이 하나 바뀔 때 (10분)
    public static func tick() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #else
        selection.selectionChanged()
        #endif
    }

    /// 정시를 지날 때 (tick 보다 또렷하게)
    public static func strong() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #else
        medium.impactOccurred()
        #endif
    }

    /// 끝냈을 때 (채우기 · 저장)
    public static func success() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #else
        notification.notificationOccurred(.success)
        #endif
    }

    /// 곧 진동할 것을 미리 알린다 (iOS: 지연 없이 울리게). 끌기를 시작할 때 부른다.
    public static func prepare() {
        #if !os(macOS)
        selection.prepare()
        light.prepare()
        medium.prepare()
        #endif
    }

    #if !os(macOS)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()
    #endif
}

// MARK: - Pasteboard

public enum PlatformPasteboard {
    @MainActor public static var string: String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }

    @MainActor public static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Pointer cursor

/// 마우스 커서 모양 (macOS). iOS 에서는 아무것도 하지 않는다.
public enum PointerCursor {
    case arrow, pointingHand, iBeam, crosshair

    @MainActor public func set() {
        #if os(macOS)
        switch self {
        case .arrow: NSCursor.arrow.set()
        case .pointingHand: NSCursor.pointingHand.set()
        case .iBeam: NSCursor.iBeam.set()
        case .crosshair: NSCursor.crosshair.set()
        }
        #endif
    }
}

extension View {
    /// 마우스를 올리면 그 커서, 벗어나면 화살표 (macOS). iOS 에서는 그대로.
    @ViewBuilder
    public func pointerCursor(_ cursor: @escaping @autoclosure () -> PointerCursor) -> some View {
        #if os(macOS)
        onContinuousHover { phase in
            switch phase {
            case .active: cursor().set()
            case .ended: NSCursor.arrow.set()
            }
        }
        #else
        self
        #endif
    }
}
