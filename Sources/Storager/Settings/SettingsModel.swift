import AppKit
import Observation
import ServiceManagement
import StoragerCore

/// 설정 창 상태. 값은 바로 StoragerSettings(UserDefaults) 에 저장한다.
@MainActor
@Observable
final class SettingsModel {
    /// 로그인 항목 상태. 토글·안내는 모두 이 값에서 파생한다.
    private(set) var loginStatus: SMAppService.Status = .notRegistered
    /// 켜짐으로 보일 상태. 승인 대기도 등록은 된 상태라 켜짐으로 보이고, 끄면 `unregister` 한다.
    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }
    /// 로그인 항목 승인이 필요한 상태. 안내와 "시스템 설정 열기" 버튼을 보여 준다.
    var needsLoginApproval: Bool { loginStatus == .requiresApproval }
    /// 번들이 없는 실행(`swift run` 등)이라 로그인 항목을 다룰 수 없는 상태.
    var loginUnavailable: Bool { loginStatus == .notFound }
    /// 로그인 토글을 다시 그리게 하는 값. 등록·해제가 실패해 상태가 그대로여도 토글이 실제 상태로 돌아가게 한다.
    private(set) var loginToggleRevision = 0
    var loginError: String?

    /// 전체 디스크 접근 허용 여부. ScanStore 가 앱 활성화마다 다시 확인하므로 시스템 설정에서 돌아오면 바뀐다.
    var fullDiskAccessGranted: Bool { store.fullDiskAccess.isGranted }

    /// 메뉴바 표시 템플릿. 저장하면서 다듬은 값(줄바꿈 → 공백, 최대 길이)으로 맞추고, 맞는 프리셋으로 피커를 옮긴다.
    var menuBarTemplate: String {
        didSet {
            guard menuBarTemplate != oldValue else { return }
            settings.menuBarTemplate = menuBarTemplate
            let stored = settings.menuBarTemplate
            // @Observable 이 만든 setter 를 거치므로 다시 대입하면 didSet 이 한 번 더 불린다. 다듬은 값이 다를 때만
            // 대입하고, 그 호출이 프리셋 맞추기·메뉴바 갱신을 하므로 여기서는 끝낸다(갱신은 한 번).
            if stored != menuBarTemplate {
                menuBarTemplate = stored
                return
            }
            let preset = MenuBarPreset.matching(menuBarTemplate)
            if preset != menuBarPreset { menuBarPreset = preset }
            onMenuBarChanged()
        }
    }
    /// 피커에 보이는 프리셋. 프리셋을 고르면 그 템플릿을 채운다. "직접 입력" 을 고르면 글자는 그대로 두고, 글자가 프리셋과
    /// 같아도 글자를 고치거나 설정 창을 다시 열 때(`refresh`)까지 "직접 입력" 으로 둔다(누른 선택을 바로 되돌리지 않는다).
    var menuBarPreset: MenuBarPreset {
        didSet {
            guard menuBarPreset != oldValue, let template = menuBarPreset.template else { return }
            menuBarTemplate = template
        }
    }
    /// 메뉴바 글자·아이콘 크기(%)
    var menuBarScalePercent: Int {
        didSet {
            guard menuBarScalePercent != oldValue else { return }
            settings.menuBarScalePercent = menuBarScalePercent
            let stored = settings.menuBarScalePercent
            // 허용 값이 아니면 저장된 값으로 되돌린다. 다시 대입하면 didSet 이 한 번 더 불려 메뉴바를 다시 그리므로 여기서 끝낸다.
            if stored != menuBarScalePercent {
                menuBarScalePercent = stored
                return
            }
            onMenuBarChanged()
        }
    }
    /// 메뉴바 라벨을 템플릿 이미지(메뉴바 색에 맞춘 단색)로 그릴지. 끄면 이모지가 원래 색으로 보인다.
    var menuBarUsesTemplateImage: Bool {
        didSet {
            guard menuBarUsesTemplateImage != oldValue else { return }
            settings.menuBarUsesTemplateImage = menuBarUsesTemplateImage
            onMenuBarChanged()
        }
    }
    /// 템플릿 이미지로 그리는데 메뉴바 글꼴로 그린 템플릿에 색 글리프(이모지)가 있을 때 (단색으로 보인다는 안내)
    var menuBarShowsEmojiHint: Bool {
        menuBarUsesTemplateImage && MenuBarLabel.containsColorGlyphs(MenuBarTemplate.plainText(menuBarPreview))
    }
    /// 템플릿의 모르는 토큰 (설정 창 주황 경고)
    var menuBarUnknownTokens: [String] { MenuBarTemplate.parse(menuBarTemplate).unknownTokens }
    /// 지금 볼륨 값으로 그린 미리보기 조각
    var menuBarPreview: [MenuBarTemplate.Piece] { MenuBarTemplate.render(menuBarTemplate, stats: store.volume) }
    /// 도움말 표의 예시 값 (지금 볼륨 값)
    func menuBarExample(_ token: MenuBarTemplate.Token) -> String { token.value(for: store.volume) }
    var scanIntervalHours: Int {
        didSet { settings.scanIntervalHours = scanIntervalHours }
    }
    var leafThresholdMB: Int {
        didSet { settings.leafThresholdMB = leafThresholdMB }
    }
    private(set) var excludedPaths: [String] = []
    private(set) var ignoredPaths: [String] = []
    private(set) var extraProjectRoots: [String] = []
    /// 이미 저장된 제외 경로 중 스캔이 무시하는 경로(홈·추가 루트 자신이거나 그 조상) → 이유 (목록 행 옆에 보여 준다)
    private(set) var excludedWarnings: [String: String] = [:]
    /// 이미 저장된 추가 루트 중 홈이나 다른 추가 루트와 겹쳐 스캔·정리에서 빠지는 경로 → 이유 (목록 행 옆에 보여 준다)
    private(set) var extraRootWarnings: [String: String] = [:]
    /// 목록별 추가 거부 사유. 그 목록의 "추가…" 버튼 아래에 보여 준다.
    private(set) var listErrors: [PathList: String] = [:]

    @ObservationIgnored private let settings: StoragerSettings
    @ObservationIgnored private let store: ScanStore
    @ObservationIgnored private let onMenuBarChanged: () -> Void
    /// 폴더 선택 패널을 시트로 붙일 설정 창
    @ObservationIgnored weak var hostWindow: NSWindow?
    /// 목록·오류가 바뀌어 내용 높이가 달라졌을 때 (창이 내용에 맞춰 커지도록)
    @ObservationIgnored var onContentChange: (() -> Void)?
    /// 앱 활성화 알림 구독 (deinit 에서 해제)
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    init(settings: StoragerSettings, store: ScanStore, onMenuBarChanged: @escaping () -> Void) {
        self.settings = settings
        self.store = store
        self.onMenuBarChanged = onMenuBarChanged
        let template = settings.menuBarTemplate
        menuBarTemplate = template
        menuBarPreset = MenuBarPreset.matching(template)
        menuBarScalePercent = settings.menuBarScalePercent
        menuBarUsesTemplateImage = settings.menuBarUsesTemplateImage
        scanIntervalHours = settings.scanIntervalHours
        leafThresholdMB = settings.leafThresholdMB
        refresh()
        // 시스템 설정에서 로그인 항목을 허용하고 돌아오면 상태를 다시 읽는다 (오류 문구는 지우지 않는다).
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncLaunchAtLogin() }
        }
    }

    isolated deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// 창을 열 때마다 저장된 값·시스템 상태와 다시 맞춘다 (트리맵에서 무시 목록이 늘었을 수 있다).
    func refresh() {
        loginError = nil
        // "직접 입력" 을 골라 둔 채 닫았어도 다시 열면 글자에 맞는 프리셋을 보인다
        menuBarPreset = MenuBarPreset.matching(menuBarTemplate)
        listErrors = [:]
        // 제외 경로 경고가 현재 권한 상태로 계산되도록 먼저 확인한다 (상태만. 허용 재스캔은 앱 활성화 경로가 한다)
        store.refreshFullDiskAccess(rescanOnGrant: false)
        reloadLists()
        syncLaunchAtLogin()
    }

    private func reloadLists() {
        excludedPaths = settings.excludedPaths
        ignoredPaths = settings.ignoredPaths
        extraProjectRoots = settings.extraProjectRoots
        excludedWarnings = Self.excludedWarnings(excludedPaths, extraRoots: acceptedExtraRoots(),
                                                 permissionSkip: store.permissionSkip)
        extraRootWarnings = Self.overlapWarnings(extraProjectRoots, permissionSkip: store.permissionSkip)
    }

    /// 스캔(`ScanResult.scan`)이 실제로 쓰는 추가 루트. 겹쳐서 빠지는 저장 루트는 스캔 루트가 아니므로
    /// 제외 경로 검사(`excludedPathProblem`)도 이 목록 기준으로 한다.
    private func acceptedExtraRoots() -> [String] {
        ExtraRootConflict.acceptedRoots(settings.extraProjectRoots, homePath: NSHomeDirectory(),
                                        permissionSkip: store.permissionSkip, logsSkipped: false)
    }

    /// 스캔(`ScanResult.scan`)·정리 계획이 쓰는 `ExtraRootConflict.acceptedRoots` 결과에 없는 저장 루트의 이유.
    /// 예전 설정이나 직접 고친 값에 겹치는 루트가 남아 있어도 설정 화면에서 보이게 한다(로그는 스캔 쪽이 이미 남기므로 `logsSkipped: false`).
    /// 심볼릭 링크 때문에 풀면 같은 경로가 되는 항목은 첫 번째만 받아들여지므로 두 번째부터 중복으로 표시한다.
    /// 권한이 없을 때 건너뛰는 위치 안쪽 루트는 realpath 하지 않고 이유만 보여 준다(`ExtraRootConflict.check` 참고).
    private static func overlapWarnings(_ roots: [String], permissionSkip: PermissionSkip) -> [String: String] {
        let home = NSHomeDirectory()
        let accepted = ExtraRootConflict.acceptedRoots(roots, homePath: home, permissionSkip: permissionSkip,
                                                       logsSkipped: false)
        var seen: Set<String> = []
        var warnings: [String: String] = [:]
        for root in roots {
            let standardized = PathUtil.standardize(root)
            let resolved = permissionSkip.coversInside(standardized) ? standardized : PathUtil.resolve(standardized)
            if accepted.contains(resolved) {
                if !seen.insert(resolved).inserted { warnings[root] = ExtraRootConflict.duplicate.message }
            } else if let conflict = ExtraRootConflict.check(root, homePath: home, otherRoots: accepted,
                                                            permissionSkip: permissionSkip) {
                warnings[root] = conflict.storedRootMessage
            }
        }
        return warnings
    }

    /// 제외 경로로 쓸 수 없는 이유: 홈 자신·홈의 조상·추가 루트 자신·추가 루트의 조상이면 스캔 루트 전체를 빼는 것이라
    /// `TreeScanner` 가 무시한다. 설정 창은 처음부터 받지 않는다. 쓸 수 있으면 nil.
    /// 전체 디스크 접근 권한이 없을 때 보호 위치 안쪽 경로(예: `~/Downloads/VMs`)는 realpath 가 그 안을 lstat 해
    /// 동의 창을 띄우므로 풀지 않는다. 그런 경로는 홈 안이라 홈·추가 루트(홈 밖) 자신이나 조상일 수 없어 문제가 없다.
    static func excludedPathProblem(_ path: String, homePath: String, extraRoots: [String],
                                    permissionSkip: PermissionSkip = .none) -> String? {
        if permissionSkip.coversInside(PathUtil.standardize(path)) { return nil }
        let path = PathUtil.resolve(path)
        let home = PathUtil.resolve(homePath)
        if path == home { return "홈 폴더 자체는 제외할 수 없습니다. 그 안의 폴더를 고르세요." }
        if PathUtil.isSameOrDescendant(home, of: path) {
            return "홈을 포함하는 폴더는 제외할 수 없습니다. 홈 안의 폴더를 고르세요."
        }
        for root in extraRoots.map(PathUtil.resolve) {
            if path == root { return "추가 프로젝트 루트 자체는 제외할 수 없습니다. 그 안의 폴더를 고르거나 추가 루트 목록에서 지우세요." }
            if PathUtil.isSameOrDescendant(root, of: path) {
                return "추가 프로젝트 루트를 포함하는 폴더는 제외할 수 없습니다. 루트 안의 폴더를 고르세요."
            }
        }
        return nil
    }

    private static func excludedWarnings(_ paths: [String], extraRoots: [String],
                                         permissionSkip: PermissionSkip) -> [String: String] {
        var warnings: [String: String] = [:]
        for path in paths {
            if let problem = excludedPathProblem(path, homePath: NSHomeDirectory(), extraRoots: extraRoots,
                                                 permissionSkip: permissionSkip) {
                warnings[path] = "스캔에서 무시됩니다. " + problem
            }
        }
        return warnings
    }

    // MARK: 로그인 시 실행

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            loginError = nil
            syncLaunchAtLogin()
        } catch {
            Log.app.error("로그인 시 실행 설정 실패: \(String(describing: error), privacy: .public)")
            loginError = "로그인 시 실행을 설정하지 못했습니다: \(error.localizedDescription)"
            syncLaunchAtLogin()
            // 실패해 상태가 그대로면 값이 안 바뀌어 토글이 다시 그려지지 않으므로 강제로 다시 만든다
            loginToggleRevision += 1
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func openFullDiskAccessSettings() {
        FullDiskAccessActions.openSystemSettings()
    }

    private func syncLaunchAtLogin() {
        loginStatus = SMAppService.mainApp.status
    }

    // MARK: 경로 목록

    enum PathList: Hashable {
        case excluded, ignored, extraRoots
    }

    func addPaths(to list: PathList) {
        let panel = NSOpenPanel()
        panel.title = list == .extraRoots ? "추가 프로젝트 루트 선택" : "제외할 폴더 선택"
        panel.prompt = "추가"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        // 추가 루트는 홈 밖 폴더라 /Volumes (없으면 /) 에서 연다. 제외 경로는 홈에서 연다.
        if list == .extraRoots {
            let volumes = "/Volumes"
            panel.directoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: volumes) ? volumes : "/")
        } else {
            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        }
        let add: ([URL]) -> Void = { [weak self] urls in
            self?.add(urls.map(\.path), to: list)
        }
        if let window = hostWindow, window.isVisible {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK else { return }
                MainActor.assumeIsolated { add(panel.urls) }
            }
        } else if panel.runModal() == .OK {
            add(panel.urls)
        }
    }

    /// 추가 프로젝트 루트는 홈과 겹치거나(조상·자신·자손) 기존 추가 루트와 겹치면(같음·그 안·그것을 포함) 넣지 않고 이유를 보여 준다.
    /// 같은 디렉터리를 두 번 세지 않도록 기존 루트를 자동으로 바꾸지 않는다. 여러 개를 한꺼번에 고르면 앞에서 받아들인 것과도 비교한다.
    /// 제외 경로는 홈·추가 루트 자신이나 그 조상이면 넣지 않는다 (스캔 루트 전체를 빼는 값이라 의미가 없다).
    private func add(_ paths: [String], to list: PathList) {
        var accepted = paths
        var reasons: [String] = []
        switch list {
        case .extraRoots:
            accepted = []
            var roots = settings.extraProjectRoots
            for path in paths {
                if let conflict = ExtraRootConflict.check(path, homePath: NSHomeDirectory(), otherRoots: roots,
                                                          permissionSkip: store.permissionSkip) {
                    reasons.append("\(FileActions.displayPath(path)): \(conflict.message)")
                } else {
                    accepted.append(path)
                    roots.append(path)
                }
            }
        case .excluded:
            accepted = []
            for path in paths {
                if let problem = Self.excludedPathProblem(path, homePath: NSHomeDirectory(),
                                                          extraRoots: acceptedExtraRoots(),
                                                          permissionSkip: store.permissionSkip) {
                    reasons.append("\(FileActions.displayPath(path)): \(problem)")
                } else {
                    accepted.append(path)
                }
            }
        case .ignored:
            break
        }
        update(list) { $0 + accepted }
        // 기존 오류는 update 에서 지워지므로 그 뒤에 설정한다
        if !reasons.isEmpty {
            listErrors[list] = "추가하지 않았습니다. " + reasons.joined(separator: " ")
        }
        onContentChange?()
    }

    func remove(_ path: String, from list: PathList) {
        update(list) { $0.filter { $0 != path } }
        onContentChange?()
    }

    private func update(_ list: PathList, _ change: ([String]) -> [String]) {
        switch list {
        case .excluded: settings.excludedPaths = change(settings.excludedPaths)
        case .ignored: settings.ignoredPaths = change(settings.ignoredPaths)
        case .extraRoots: settings.extraProjectRoots = change(settings.extraProjectRoots)
        }
        listErrors[list] = nil
        reloadLists()
    }
}
