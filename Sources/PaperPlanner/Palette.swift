import AppKit
import SwiftUI

/// 창 오른쪽 옆에 떠 있는 도구 팔레트 (child panel). STUB — full UI comes later.
@MainActor
final class PaletteController {
    private let panel: NSPanel
    private weak var parent: NSWindow?

    init(parent: NSWindow, store: PlannerStore, state: AppState) {
        self.parent = parent
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: MainWindowController.paletteWidth, height: 400),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: Color.clear.environmentObject(store).environmentObject(state))
    }

    func attach() {
        parent?.addChildWindow(panel, ordered: .above)
        reposition()
    }

    func reposition() {
        guard let parent else { return }
        let f = parent.frame
        let h = panel.frame.height
        panel.setFrameOrigin(NSPoint(x: f.maxX + MainWindowController.paletteGap, y: f.midY - h / 2))
    }
}
