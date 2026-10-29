import AppKit
import StoragerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var statusController: StatusItemController?
    private var analysisWindow: AnalysisWindowController?
    private var settingsWindow: SettingsWindowController?
    private var fullDiskAccessWindow: FullDiskAccessWindowController?
    private var scheduler: ScanScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment: AppEnvironment
        do {
            environment = try AppEnvironment()
        } catch InstanceLock.Failure.alreadyRunning {
            Log.app.error("다른 Storager 가 실행 중이라 종료")
            showFatalAlert(message: "Storager가 이미 실행 중입니다",
                           info: "다른 Storager가 실행 중이라 이 Storager는 종료합니다. 메뉴 막대의 Storager 아이콘을 확인하세요.")
            return
        } catch InstanceLock.Failure.unavailable(let error) {
            Log.app.fault("잠금 파일을 만들 수 없음: \(String(describing: error), privacy: .private)")
            showFatalAlert(message: "Storager를 시작할 수 없습니다",
                           info: "잠금 파일을 만들 수 없습니다. \(error.localizedDescription)")
            return
        } catch {
            // DB 를 열 수 없는 경우는 AppEnvironment 가 메모리 저장소로 대체하므로 여기까지 오지 않는다
            Log.app.fault("앱 환경을 만들 수 없음: \(String(describing: error), privacy: .private)")
            showFatalAlert(message: "Storager를 시작할 수 없습니다", info: error.localizedDescription)
            return
        }
        self.environment = environment
        installMainMenu()

        let analysisWindow = AnalysisWindowController(model: AnalysisModel(
            store: environment.scanStore, settings: environment.settings, snapshots: environment.snapshots))
        self.analysisWindow = analysisWindow

        let fullDiskAccessWindow = FullDiskAccessWindowController(store: environment.scanStore,
                                                                  settings: environment.settings)
        self.fullDiskAccessWindow = fullDiskAccessWindow

        let actions = PopoverActions(
            openAnalysis: { [weak analysisWindow] category in analysisWindow?.show(category: category) },
            cleanup: { [weak analysisWindow] category in analysisWindow?.showCleanup(category: category) },
            scanNow: { [weak environment] in environment?.scanStore.startScan() },
            openSettings: { [weak self] in self?.openSettings() },
            openFullDiskAccess: { [weak fullDiskAccessWindow] in fullDiskAccessWindow?.show() },
            quit: { NSApp.terminate(nil) })
        let statusController = StatusItemController(store: environment.scanStore, settings: environment.settings,
                                                    actions: actions)
        self.statusController = statusController

        settingsWindow = SettingsWindowController(settings: environment.settings,
                                                  store: environment.scanStore) { [weak statusController] in
            statusController?.render()
        }

        let scheduler = ScanScheduler(store: environment.scanStore, settings: environment.settings)
        scheduler.start()
        self.scheduler = scheduler

        // 처음 실행 때 권한이 없으면 안내한다. 예약된 첫 스캔은 기다리지 않고 보호 폴더를 건너뛰며 돈다.
        fullDiskAccessWindow.showIfNeeded()
    }

    /// 정리 실행 중에 종료하면 남은 항목은 옮기지 않으므로 먼저 묻는다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard analysisWindow?.model.isCleanupRunning == true else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "정리가 진행 중입니다"
        alert.informativeText = "지금 종료하면 남은 항목은 휴지통으로 옮기지 않습니다."
        alert.addButton(withTitle: "종료")
        alert.addButton(withTitle: "취소")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Finder·Spotlight 로 다시 열면(창이 없는 메뉴바 앱이라) 팝오버를 보여 준다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusController?.showPopover()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 미완료 스캔은 스냅샷을 남기지 않고 그냥 취소한다
        environment?.scanStore.cancelScan()
        // 안내 창의 "다시 시작" 으로 종료하는 경우 이 프로세스가 끝난 뒤 앱을 다시 연다
        FullDiskAccessActions.spawnRelaunchIfRequested()
    }

    /// 크래시 대신 알리고 종료한다.
    private func showFatalAlert(message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        // .accessory 앱이라 활성화하지 않으면 알림이 다른 창 뒤에 숨을 수 있다
        NSApp.activate()
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: 메인 메뉴

    /// .accessory 앱이라 화면에 보이지 않는 메인 메뉴. Storager 창이 키 창일 때 ⌘, · ⌘Q · ⌘W · 편집 단축키를 받는다.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "Storager")
        let settings = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Storager 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        mainMenu.addItem(submenuItem(appMenu))

        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenuItem(editMenu))

        let windowMenu = NSMenu(title: "윈도우")
        windowMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(submenuItem(windowMenu))

        NSApp.mainMenu = mainMenu
    }

    private func submenuItem(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func openSettings() {
        settingsWindow?.show()
    }
}
