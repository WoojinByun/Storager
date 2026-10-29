import AppKit

/// 트리맵·목록의 공통 동작.
@MainActor
enum FileActions {
    /// Finder 에서 경로들을 선택해 보여 준다 (여러 행 선택 시 전부).
    /// `URL(fileURLWithPath:)` 는 디렉터리인지 알아내려고 경로를 stat 한다. 보호 위치 안이면 그 stat 이 동의 창을 띄울 수
    /// 있으므로 스캔 결과가 이미 아는 종류(`isDirectory`)를 넘겨 파일 시스템을 건드리지 않고 URL 을 만든다.
    static func revealInFinder(_ targets: [(path: String, isDirectory: Bool)]) {
        guard !targets.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(targets.map {
            URL(fileURLWithPath: $0.path, isDirectory: $0.isDirectory)
        })
    }

    /// 모두 같은 종류(디렉터리 또는 파일)인 경로들을 Finder 에서 보여 준다.
    static func revealInFinder(_ paths: [String], isDirectory: Bool) {
        revealInFinder(paths.map { (path: $0, isDirectory: isDirectory) })
    }

    /// 경로들을 한 줄에 하나씩 복사한다.
    static func copyPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// 홈 아래 경로는 `~/…` 로 줄여 보여 준다.
    static func displayPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// 지금 실행 중인 앱의 번들 ID (정리 경고용).
    static var runningBundleIDs: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}
