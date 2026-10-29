import Foundation
import StoragerCore

/// 앱 전체가 공유하는 설정 · 저장소 · 스캔 상태.
@MainActor
final class AppEnvironment {
    /// 잠금 파일·스냅샷 DB 가 있는 폴더. 개발 빌드는 설치본과 다른 폴더를 써서 동시에 띄울 수 있고 기록이 섞이지 않는다.
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataFolderName(bundleIdentifier: Bundle.main.bundleIdentifier), isDirectory: true)
    }

    /// 설치본(`com.wjbyun.Storager`)은 "Storager", 개발 빌드(`….dev`, `make run`)와
    /// 번들 없이 `swift run` 한 경우(번들 ID 없음)는 "Storager.dev".
    /// 설정(UserDefaults.standard)·로그인 항목은 번들 ID 를 따르므로 따로 나누지 않아도 분리된다.
    static func dataFolderName(bundleIdentifier: String?) -> String {
        guard let bundleIdentifier, !bundleIdentifier.hasSuffix(".dev") else { return "Storager.dev" }
        return "Storager"
    }

    let settings: StoragerSettings
    let snapshots: SnapshotStore
    /// false 면 DB 를 열 수 없어 메모리 저장소로 대체한 것이다(이번 실행의 추세는 종료와 함께 사라진다)
    let isPersistent: Bool
    let scanStore: ScanStore
    /// 앱이 도는 동안 쥐고 있는 단일 인스턴스 잠금
    private let instanceLock: InstanceLock

    /// 다른 Storager 가 실행 중이면 `InstanceLock.Failure.alreadyRunning`, 잠금 파일을 쓸 수 없으면
    /// `InstanceLock.Failure.unavailable` 을 던진다. 디스크가 가득 차면 잠금 없이 시작하고,
    /// DB 를 열 수 없는 경우는 던지지 않고 메모리 저장소로 대체한다.
    init() throws {
        // 두 인스턴스가 같은 DB 를 쓰지 않도록 DB 를 열기 전에 잠근다
        instanceLock = try InstanceLock(directory: Self.supportDirectory)
        settings = StoragerSettings()
        (snapshots, isPersistent) = SnapshotStore.openOrFallback(directory: Self.supportDirectory)
        scanStore = ScanStore(settings: settings, snapshots: snapshots, isPersistent: isPersistent)
    }
}
