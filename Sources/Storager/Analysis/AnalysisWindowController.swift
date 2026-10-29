import AppKit
import StoragerCore
import SwiftUI

/// 분석 윈도우 (일반 윈도우, 기본 1000×680).
@MainActor
final class AnalysisWindowController {
    private static let frameName = "AnalysisWindow"

    let model: AnalysisModel
    private var window: NSWindow?

    init(model: AnalysisModel) {
        self.model = model
    }

    func show(category: StoragerCore.Category? = nil) {
        model.show(category: category)
        present()
    }

    func showCleanup(category: StoragerCore.Category) {
        model.requestCleanup(category: category)
        present()
    }

    private func present() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Storager"
        window.contentViewController = NSHostingController(rootView: AnalysisView(model: model, store: model.store))
        window.setContentSize(NSSize(width: 1000, height: 680))
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        // 저장된 위치가 있으면 그대로, 없을 때만 가운데로
        let restored = window.setFrameUsingName(Self.frameName)
        window.setFrameAutosaveName(Self.frameName)
        if !restored { window.center() }
        return window
    }
}
