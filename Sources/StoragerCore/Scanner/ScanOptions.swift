import Darwin
import Foundation

/// 스캔 동작 설정. 설정 창 값으로 만든다.
public struct ScanOptions: Sendable, Equatable {
    public static let defaultLeafThreshold: Int64 = 10 * 1024 * 1024
    /// 분류 규칙의 표식 파일 조건("옆에 X 파일"·"안에 X 파일")이 보는 파일 이름. 이 이름의 파일만 그 파일이 있는
    /// 디렉터리 노드의 `markers` 에 기록한다.
    public static let defaultMarkerFileNames: Set<String> = [
        "package.json",
        "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
        "Package.swift", "Podfile", "Cargo.toml",
        "pyvenv.cfg",
        // 도구 구분용 잠금 파일 (`RuleCatalog.nodeModulesTool`·`venvTool`)
        "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "package-lock.json",
        "uv.lock", "poetry.lock",
        // 잠금 파일을 자손에게 물려줄 Python 프로젝트 루트 판별 (`RuleCatalog.venvTool`)
        "pyproject.toml",
    ]

    /// 이 크기(할당 바이트) 이상인 파일만 `FileLeaf` 로 남긴다
    public var leafThreshold: Int64
    /// 건너뛸 디렉터리 절대 경로 (설정의 제외 경로 + 무시 목록). `PathUtil.resolve` 로 심볼릭 링크를 푼 실제 경로다.
    /// 권한 때문에 건너뛰는 위치의 안쪽 경로는 넣지 않는다(아래 init 참고).
    public var excludedPaths: Set<String>
    /// 전체 디스크 접근 권한이 없어 들어가지 않을 위치 (`FullDiskAccess.Status.permissionSkip`).
    /// 제외 경로처럼 읽기 전에 건너뛰지만 사용자 설정이 아니라서 결과에 따로 보고한다(`TreeScan.skippedForPermission`).
    public var permissionSkip: PermissionSkip
    public var markerFileNames: Set<String>

    /// 제외 경로는 `PathUtil.resolve`(realpath) 로 푼다. 단 권한 때문에 건너뛰는 위치의 안쪽(예: `~/Downloads/VMs`)은
    /// realpath 가 보호 폴더 안을 lstat 해 동의 창을 띄우므로 풀지 않고 뺀다. 그 보호 폴더 자체를 건너뛰므로 결과는 같다.
    public init(
        leafThreshold: Int64 = ScanOptions.defaultLeafThreshold,
        excludedPaths: Set<String> = [],
        permissionSkip: PermissionSkip = .none,
        markerFileNames: Set<String> = ScanOptions.defaultMarkerFileNames
    ) {
        self.leafThreshold = leafThreshold
        self.excludedPaths = Set(excludedPaths.map(PathUtil.standardize)
            .filter { !permissionSkip.coversInside($0) }
            .map(PathUtil.resolve))
        self.permissionSkip = permissionSkip
        self.markerFileNames = markerFileNames
    }
}

public enum PathUtil {
    /// `~`·`.`·`..`·겹친 슬래시·끝 슬래시를 글자 단위로 정리한 절대 경로. 심볼릭 링크는 풀지 않는다.
    /// Foundation 의 `standardizedFileURL` 은 `/private/var/…` 를 `/var/…` 로 바꿔 realpath 결과와 어긋나므로 쓰지 않는다.
    public static func standardize(_ path: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            expanded = DirectoryNode.join(FileManager.default.currentDirectoryPath, expanded)
        }
        var parts: [Substring] = []
        for part in expanded.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `standardize` 한 뒤 realpath(3) 로 심볼릭 링크를 푼 실제 경로 (예: `/var/…` → `/private/var/…`).
    /// 경로가 없으면 존재하는 가장 가까운 조상까지만 풀고 나머지 이름은 그대로 붙인다(지워진 경로의 재스캔용).
    /// 풀 수 있는 조상이 없으면 `standardize` 결과와 같다.
    public static func resolve(_ path: String) -> String {
        let standardized = standardize(path)
        if let real = realPath(standardized) { return real }
        let parent = (standardized as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != standardized else { return standardized }
        return DirectoryNode.join(resolve(parent), (standardized as NSString).lastPathComponent)
    }

    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// `path` 가 `ancestor` 와 같거나 그 아래인지.
    public static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }

    /// `path` 를 `base` 기준 상대 이름 목록으로. base 밖이면 nil, 같으면 빈 배열.
    public static func components(of path: String, relativeTo base: String) -> [String]? {
        guard isSameOrDescendant(path, of: base) else { return nil }
        let rest = path.dropFirst(base.count)
        return rest.split(separator: "/").map(String.init)
    }
}
