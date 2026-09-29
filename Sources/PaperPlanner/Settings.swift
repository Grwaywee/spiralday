import AppKit
import SwiftUI

/// 설정 창 (형광펜, 컬러 컨셉 기본값, D-day …). 팔레트의 톱니 버튼 / ⌘, 로 연다.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(store: PlannerStore, state: AppState) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "설정"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView().environmentObject(store).environmentObject(state))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// STUB — to be replaced.
struct SettingsView: View {
    @EnvironmentObject private var store: PlannerStore
    var body: some View {
        Text("설정").padding(40)
    }
}
