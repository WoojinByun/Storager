import AppKit
import StoragerCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let model: SettingsModel
    private let store: ScanStore
    private var window: NSWindow?
    /// 창 닫힘 알림 구독 (deinit 에서 해제)
    private var closeObserver: (any NSObjectProtocol)?

    init(settings: StoragerSettings, store: ScanStore, onMenuBarChanged: @escaping () -> Void) {
        self.store = store
        model = SettingsModel(settings: settings, store: store, onMenuBarChanged: onMenuBarChanged)
        model.onContentChange = { [weak self] in self?.growToFitContent() }
    }

    isolated deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        model.refresh()
        growToFitContent()
        // 메뉴바 앱이라 직접 활성화해야 창이 앞으로 나온다
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // 활성화가 거절돼도 창은 다른 앱 창 앞에 보이게 한다
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Storager 설정"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        // grouped Form 은 최소 높이가 0 이라 내용 높이(fittingSize)로 열되 화면보다 크면 화면에 맞춘다
        let fitting = hostingController.view.fittingSize
        let visibleHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? fitting.height
        window.setContentSize(NSSize(width: fitting.width, height: min(fitting.height, visibleHeight - 80)))
        window.center()
        model.hostWindow = window
        // 창을 여는 동안 상태만 갱신해 미뤄 둔 권한 허용 재스캔을 닫을 때 한다 (앱이 활성 상태로 남는 경우)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.runPendingGrantRescan() }
        }
        return window
    }

    /// 목록이 늘거나 거부 사유가 나타나 내용이 창보다 커지면 창을 위쪽 가장자리를 고정한 채 키운다(줄이지는 않는다).
    /// SwiftUI 가 상태를 반영한 뒤의 크기를 재도록 잠깐 기다린다. 화면보다 커지면 Form 이 스크롤한다.
    private func growToFitContent() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let window = self?.window, let view = window.contentViewController?.view else { return }
            let fitting = view.fittingSize
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            let maxContentHeight = (visible?.height ?? fitting.height) - 80
            let targetHeight = min(fitting.height, maxContentHeight)
            let currentHeight = window.contentRect(forFrameRect: window.frame).height
            guard targetHeight > currentHeight + 1 else { return }
            var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: fitting.width, height: targetHeight))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            if let visible, frame.minY < visible.minY { frame.origin.y = visible.minY }
            window.setFrame(frame, display: true)
        }
    }
}
