import AppKit
import Observation
import StoragerCore
import SwiftUI

/// 메뉴바 아이콘(internaldrive + 여유 용량 텍스트)과 팝오버.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: ScanStore
    private let settings: StoragerSettings
    /// 스캔 중 아이콘 표시 상태
    private enum ScanIndicator { case idle, pulse, dim }
    private var indicator = ScanIndicator.idle
    /// 동작 줄이기 설정 변경 알림 구독 (deinit 에서 해제)
    private var displayOptionsObserver: (any NSObjectProtocol)?
    /// 버튼 프레임 변경 알림 구독 (메뉴바 높이가 바뀌면 라벨 이미지를 다시 그린다, deinit 에서 해제)
    private var frameObserver: (any NSObjectProtocol)?
    /// 라벨 이미지를 그린 버튼 높이. 이미지 방식이 아니면 nil.
    private var renderedHeight: CGFloat?
    /// 버튼 모양새 변경 구독 (어두운·밝은 메뉴바가 바뀌면 템플릿이 아닌 라벨 이미지를 새 색으로 다시 그린다, deinit 에서 해제)
    private var appearanceObservation: NSKeyValueObservation?
    /// 템플릿이 아닌 라벨 이미지를 그린 모양새 이름. 템플릿 방식이면 nil.
    private var renderedAppearance: NSAppearance.Name?
    /// 팝오버가 닫히기 시작한 시각(systemUptime). `.transient` 팝오버는 아이콘을 누르는 mouse-down 에 먼저 닫히고
    /// 이어서 버튼 동작이 불리므로, 닫힌 직후의 토글은 무시해 다시 열리지 않게 한다.
    /// 닫힘 애니메이션이 끝나기 전에 mouse-up 이 올 수 있어 popoverWillClose 에서 기록한다.
    private var popoverClosedAt: TimeInterval = 0

    init(store: ScanStore, settings: StoragerSettings, actions: PopoverActions) {
        self.store = store
        self.settings = settings
        super.init()

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            // 크게 그린 라벨 이미지를 버튼 높이에 맞춰 줄이지 않는다 (가운데에 두고 넘치는 위아래는 잘린다)
            button.imageScaling = .scaleNone
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.wantsLayer = true
        }

        var actions = actions
        let close: @MainActor () -> Void = { [weak popover] in popover?.performClose(nil) }
        actions.wrap(before: close)
        let hosting = NSHostingController(rootView: PopoverView(store: store, actions: actions))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        // 바깥 클릭·포커스 이동 시 닫힘
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        // 스캔 중에 동작 줄이기를 켜고 끄면 깜빡임·흐림을 바로 바꾼다
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScanIndicator() }
        }

        // 처음 배치나 노치가 있는 화면으로 옮겨 버튼 높이가 바뀌면 라벨 이미지를 새 높이로 다시 그린다.
        // 폭만 바뀐 경우(라벨 내용이 바뀐 결과)는 다시 그리지 않는다.
        if let button = statusItem.button {
            button.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let renderedHeight = self.renderedHeight, let button = self.statusItem.button,
                          Self.labelHeight(button) != renderedHeight else { return }
                    self.render()
                }
            }
            // 템플릿이 아닌 이미지는 시스템이 색을 입히지 않으므로 어두운·밝은 메뉴바(배경 화면·시스템 모양새)가 바뀌면
            // 새 모양새의 글자 색으로 다시 그린다. 같은 모양새로의 알림은 무시한다.
            // 모양새는 메인 스레드에서 바뀌므로 곧바로 다시 그린다.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let renderedAppearance = self.renderedAppearance, let button = self.statusItem.button,
                          button.effectiveAppearance.name != renderedAppearance else { return }
                    self.render()
                }
            }
        }

        observe()
    }

    isolated deinit {
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
        }
        appearanceObservation?.invalidate()
    }

    /// 설정(메뉴바 표시 템플릿·크기·템플릿 이미지 여부)이 바뀌었을 때 SettingsModel 이 부른다.
    func render() {
        guard let button = statusItem.button else { return }
        let pieces = MenuBarTemplate.render(settings.menuBarTemplate, stats: store.volume)
        let scale = CGFloat(settings.menuBarScalePercent) / 100
        let text = MenuBarTemplate.plainText(pieces)
        let accessibility = text.isEmpty ? "Storager" : "Storager \(text)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let usesTemplateImage = settings.menuBarUsesTemplateImage
        if usesTemplateImage, scale == 1, pieces == [.icon] || pieces == [.icon, .text(text)] {
            // 100% 의 아이콘만·아이콘+글자(프리셋 모양)는 예전과 똑같이 버튼의 이미지+제목으로 그린다
            let image = NSImage(systemSymbolName: MenuBarLabel.symbolName, accessibilityDescription: accessibility)
            image?.isTemplate = true
            button.image = image
            button.font = font
            button.title = text
            renderedHeight = nil
            renderedAppearance = nil
        } else {
            // 아직 배치 전(높이 0)이면 메뉴바 두께로 그리고, 배치되어 높이가 정해지면 프레임 알림이 다시 그린다.
            // 그 밖은 MenuBarLabel 이 같은 자리(오프스크린 측정)에 그려 100% 의 직접 입력도 프리셋과 같아 보인다.
            // 템플릿 이미지 설정을 끄면 프리셋도 여기서 지금 모양새의 글자 색으로 그린다(이모지는 원래 색).
            let height = Self.labelHeight(button)
            let appearance = usesTemplateImage ? nil : button.effectiveAppearance
            button.image = MenuBarLabel.image(pieces, scale: scale, height: height, accessibility: accessibility,
                                              appearance: appearance)
            button.title = ""
            renderedHeight = height
            renderedAppearance = appearance?.name
        }
        updateScanIndicator()
    }

    /// 라벨 이미지 높이: 버튼 높이(배치 전이면 메뉴바 두께). 이미지가 버튼의 자연 높이를 키워 다시 그리는 고리가 생기지
    /// 않도록 메뉴바 두께의 두 배로 묶는다.
    private static func labelHeight(_ button: NSStatusBarButton) -> CGFloat {
        let thickness = NSStatusBar.system.thickness
        return min(button.bounds.height > 0 ? button.bounds.height : thickness, thickness * 2)
    }

    /// ScanStore 의 volume·isScanning 이 바뀔 때마다 다시 그린다.
    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    /// 스캔 중에는 아이콘이 은은하게 깜빡인다. 동작 줄이기 설정이면 깜빡이지 않고 흐리게만 둔다.
    /// 상태가 바뀔 때마다 이전 표시(애니메이션·흐림)를 모두 지운 뒤 새 표시를 건다.
    private func updateScanIndicator() {
        guard let button = statusItem.button else { return }
        let target: ScanIndicator = !store.isScanning ? .idle
            : NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .dim : .pulse
        guard target != indicator else { return }
        indicator = target
        button.layer?.removeAnimation(forKey: "pulse")
        button.alphaValue = 1
        switch target {
        case .idle:
            break
        case .dim:
            button.alphaValue = 0.5
        case .pulse:
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1.0
            animation.toValue = 0.35
            animation.duration = 0.9
            animation.autoreverses = true
            animation.repeatCount = .infinity
            button.layer?.add(animation, forKey: "pulse")
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else if ProcessInfo.processInfo.systemUptime - popoverClosedAt > 0.3 {
            showPopover()
        }
    }

    /// 팝오버를 연다. Finder·Spotlight 로 앱을 다시 열 때(AppDelegate 의 reopen)도 부른다.
    func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        store.refreshVolume()
        // 설정·안내 창에서 권한 허용을 확인만 하고 미뤄 둔 재스캔이 있으면 지금 시작한다
        store.runPendingGrantRescan()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // 팝오버가 떠 있는 동안 아이콘을 눌린 상태로 둔다. 클릭 추적 중에는 동작이 끝난 뒤 버튼이
        // 강조를 스스로 풀므로 다음 메인 actor 차례에 건다(그 사이 닫혔으면 걸지 않는다).
        Task { @MainActor [weak self, weak button] in
            guard self?.popover.isShown == true else { return }
            button?.highlight(true)
        }
    }

    func popoverWillClose(_ notification: Notification) {
        popoverClosedAt = ProcessInfo.processInfo.systemUptime
        statusItem.button?.highlight(false)
    }
}
