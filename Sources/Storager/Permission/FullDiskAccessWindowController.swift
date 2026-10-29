import AppKit
import Observation
import StoragerCore
import SwiftUI

/// 전체 디스크 접근 안내 창 상태.
@MainActor
@Observable
final class FullDiskAccessGuide {
    /// "시스템 설정 열기" 를 누른 뒤인지. 그 뒤에는 켜는 방법과 "다시 시작" 을 보여 준다.
    var openedSettings = false
    let store: ScanStore

    init(store: ScanStore) {
        self.store = store
    }
}

/// 전체 디스크 접근 안내 창. 처음 실행 때 권한이 없으면 한 번 띄우고, 팝오버 배너의 "권한 허용…" 으로 다시 연다.
/// 스캔을 막거나 미루지 않는다(그동안은 보호 폴더를 건너뛰고 스캔한다).
@MainActor
final class FullDiskAccessWindowController {
    private let guide: FullDiskAccessGuide
    private let settings: StoragerSettings
    private var window: NSWindow?
    /// 창 닫힘 알림 구독 (deinit 에서 해제)
    private var closeObserver: (any NSObjectProtocol)?

    init(store: ScanStore, settings: StoragerSettings) {
        guide = FullDiskAccessGuide(store: store)
        self.settings = settings
    }

    isolated deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    /// 처음 실행 안내: 권한이 없고 아직 보여 주지 않았을 때만 연다.
    func showIfNeeded() {
        guard !guide.store.fullDiskAccess.isGranted, !settings.fullDiskAccessIntroShown else { return }
        show()
    }

    func show() {
        // 상태만 갱신한다 (허용 재스캔은 앱 활성화·스캔 시작 경로에서만)
        guide.store.refreshFullDiskAccess(rescanOnGrant: false)
        // 다시 열면 처음 안내부터 보여 준다 (이미 허용됐으면 허용 안내가 우선한다)
        guide.openedSettings = false
        let window = window ?? makeWindow()
        self.window = window
        settings.fullDiskAccessIntroShown = true
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let close: @MainActor () -> Void = { [weak self] in self?.window?.performClose(nil) }
        // 기본 sizingOptions 라 단계가 바뀌어 내용 높이가 달라지면 창도 따라 바뀐다
        let hosting = NSHostingController(rootView: FullDiskAccessView(guide: guide, close: close))
        let window = NSWindow(contentViewController: hosting)
        window.title = "전체 디스크 접근"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        // 창을 여는 동안 상태만 갱신해 미뤄 둔 권한 허용 재스캔을 닫을 때 한다 (앱이 활성 상태로 남는 경우)
        let store = guide.store
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak store] _ in
            MainActor.assumeIsolated { store?.runPendingGrantRescan() }
        }
        return window
    }
}

struct FullDiskAccessView: View {
    let guide: FullDiskAccessGuide
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: guide.store.fullDiskAccess.isGranted ? "checkmark.shield" : "lock.shield")
                    .font(.system(size: 32))
                    .foregroundStyle(guide.store.fullDiskAccess.isGranted ? Color.green : Color.accentColor)
                Text("전체 디스크 접근 권한").font(.title2.bold())
            }
            if guide.store.fullDiskAccess.isGranted {
                granted
            } else if guide.openedSettings {
                waitingForGrant
            } else {
                intro
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
    }

    // MARK: 처음 안내

    /// 보호 위치를 이름별로 묶은 행 (예: 다른 앱의 데이터 → Containers, Group Containers). 사진 보관함은 이름 규칙이다.
    static let protectedRows: [(name: String, paths: String)] = {
        var rows: [(name: String, paths: [String])] = []
        for folder in FullDiskAccess.protectedFolders {
            let path = "~/" + folder.relativePath
            if let index = rows.firstIndex(where: { $0.name == folder.displayName }) {
                rows[index].paths.append(path)
            } else {
                rows.append((folder.displayName, [path]))
            }
        }
        rows.append((FullDiskAccess.protectedDirectorySuffixDisplayName,
                     FullDiskAccess.protectedDirectorySuffixes.map { "*" + $0 }))
        return rows.map { ($0.name, $0.paths.joined(separator: "\n")) }
    }()

    @ViewBuilder private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storager는 홈 폴더 전체를 재서 용량을 보여 줍니다.")
            Text("권한이 없으면 아래 폴더는 건너뛰어 크기에 포함되지 않습니다. 허용하면 모든 폴더를 정확히 셉니다.")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(Self.protectedRows, id: \.name) { row in
                    GridRow {
                        Text(row.name)
                        Text(row.paths)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 8)
            Text("메일·Safari·메시지 같은 폴더도 권한이 있어야 크기를 셀 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("권한 없이 계속", action: close)
                .keyboardShortcut(.cancelAction)
            Button("시스템 설정 열기") {
                FullDiskAccessActions.openSystemSettings()
                guide.openedSettings = true
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: 시스템 설정을 연 뒤

    @ViewBuilder private var waitingForGrant: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("목록에서 \(FullDiskAccessActions.appName)를 켠 뒤 다시 시작하세요.")
            Text("목록에 없으면 + 버튼으로 \(Bundle.main.bundleURL.path)를 추가하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !FullDiskAccessActions.canRelaunch {
                Text("이 실행 환경에서는 다시 시작 버튼을 쓸 수 없습니다. 직접 다시 실행하세요.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("시스템 설정 열기") { FullDiskAccessActions.openSystemSettings() }
            Spacer()
            Button("닫기", action: close)
                .keyboardShortcut(.cancelAction)
            if FullDiskAccessActions.canRelaunch {
                Button("다시 시작") { FullDiskAccessActions.relaunch() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: 허용됨

    @ViewBuilder private var granted: some View {
        Text("전체 디스크 접근이 허용되었습니다. 바로 다시 스캔해 모든 폴더를 셉니다. 건너뛴 폴더가 남아 있으면 다시 시작하세요.")
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("닫기", action: close)
                .keyboardShortcut(.cancelAction)
            if FullDiskAccessActions.canRelaunch {
                Button("다시 시작") { FullDiskAccessActions.relaunch() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
