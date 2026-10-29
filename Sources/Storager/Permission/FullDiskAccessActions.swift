import AppKit
import StoragerCore

/// 전체 디스크 접근 안내에서 쓰는 시스템 설정 열기와 앱 다시 시작.
@MainActor
enum FullDiskAccessActions {
    /// 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근. 새 설정 앱 주소가 안 열리면 예전 주소로 연다.
    private static let settingsURLs = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
    ]

    static func openSystemSettings() {
        for string in settingsURLs {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
        Log.app.error("전체 디스크 접근 설정을 열 수 없음")
    }

    /// 시스템 설정 목록에 보이는 이 앱 이름 (개발 빌드는 "Storager Dev").
    static var appName: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? "Storager"
    }

    /// .app 번들로, 실제 홈으로 실행 중일 때만 다시 시작할 수 있다. `swift run` 은 번들이 없고,
    /// HOME 을 바꿔 띄운 경우(가짜 홈 확인)는 `open` 이 그 환경을 넘기지 않아 실제 홈으로 뜨기 때문이다.
    static var canRelaunch: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && PathUtil.resolve(NSHomeDirectory()) == PathUtil.resolve(FullDiskAccess.realHomeDirectory)
    }

    /// 다시 시작을 요청했는지. 종료가 실제로 확정된 뒤(applicationWillTerminate)에만 다시 여는 셸을 띄운다.
    /// 정리 중이라 종료를 취소하면 셸이 남아 나중의 종료 뒤에 앱을 다시 여는 일이 없도록 하기 위해서다.
    private static var relaunchRequested = false

    /// 앱을 종료하고 다시 연다. 종료를 취소하면(정리 진행 중 알림) 요청도 거둔다.
    static func relaunch() {
        guard canRelaunch else { return }
        relaunchRequested = true
        NSApp.terminate(nil)
        // terminate 가 돌아왔다면 종료가 취소된 것이다
        relaunchRequested = false
    }

    /// AppDelegate.applicationWillTerminate 가 부른다. 요청이 있으면 이 프로세스가 끝날 때까지 기다렸다가
    /// 번들을 다시 여는 셸을 띄운다. 이전 프로세스가 사라진 뒤 열므로 단일 인스턴스 잠금에 걸리지 않는다.
    /// `open -n` 으로 LaunchServices 가 아직 끝나지 않은 이전 인스턴스를 앞으로 가져오기만 하는 일을 막는다
    /// (혹시 겹쳐 뜨더라도 잠금 때문에 하나만 남는다).
    static func spawnRelaunchIfRequested() {
        guard relaunchRequested else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // pid·경로는 따옴표 문제 없이 위치 인자로 넘긴다
        process.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$2\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.app.error("다시 시작 실패: \(String(describing: error), privacy: .public)")
        }
    }
}
