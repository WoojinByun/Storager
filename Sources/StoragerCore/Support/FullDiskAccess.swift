import Darwin
import Foundation

/// 전체 디스크 접근(Full Disk Access) 권한 상태 확인과, 권한이 없을 때 스캔이 들어가지 않을 보호 위치.
/// 앱은 이 권한을 직접 요청할 수 없고 상태를 확인해 시스템 설정을 열어 줄 수만 있다.
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
        /// 확인용 파일이 하나도 없어 판단하지 못했다. 안전하게 권한 없음과 같이 다룬다.
        case unknown

        public var isGranted: Bool { self == .granted }

        /// 이 상태에서 스캔·재스캔·정리가 들어가지 않을 보호 위치. 권한이 있으면 비어 있다(`PermissionSkip.none`).
        public func permissionSkip(homePath: String) -> PermissionSkip {
            isGranted ? .none : FullDiskAccess.permissionSkip(homePath: homePath)
        }
    }

    /// 보호 위치 하나: 홈 기준 상대 경로와 안내 창에 보여 줄 이름.
    public struct ProtectedFolder: Sendable, Equatable {
        public var relativePath: String
        public var displayName: String
    }

    /// 권한 없이 들어가면 macOS 가 동의 창을 띄우는 홈 아래 폴더. 권한이 없으면 스캔이 읽지 않고 건너뛴다.
    public static let protectedFolders: [ProtectedFolder] = [
        ProtectedFolder(relativePath: "Desktop", displayName: "데스크탑"),
        ProtectedFolder(relativePath: "Documents", displayName: "문서"),
        ProtectedFolder(relativePath: "Downloads", displayName: "다운로드"),
        ProtectedFolder(relativePath: "Library/Mobile Documents", displayName: "iCloud Drive"),
        ProtectedFolder(relativePath: "Library/Containers", displayName: "다른 앱의 데이터"),
        ProtectedFolder(relativePath: "Library/Group Containers", displayName: "다른 앱의 데이터"),
        ProtectedFolder(relativePath: "Library/CloudStorage", displayName: "클라우드 저장소"),
        ProtectedFolder(relativePath: "Library/Application Support/AddressBook", displayName: "연락처"),
        ProtectedFolder(relativePath: "Library/Calendars", displayName: "캘린더"),
    ]

    /// 위치와 상관없이 이름으로 건너뛰는 디렉터리(소문자 접미사). 사진 보관함은 어디에 두든 사진 접근 동의 창이 뜬다.
    public static let protectedDirectorySuffixes = [".photoslibrary"]
    public static let protectedDirectorySuffixDisplayName = "사진 보관함"

    /// 홈 아래 보호 폴더의 절대 경로. 홈만 `PathUtil.resolve` 로 풀고 나머지 이름은 적힌 그대로 붙인다.
    /// (`~/Documents` 가 보호되지 않는 다른 폴더로 가는 심볼릭 링크여도 그 대상까지 건너뛰지 않도록. 스캐너는 링크를 따라가지 않는다.)
    public static func protectedPaths(homePath: String) -> Set<String> {
        let home = PathUtil.resolve(homePath)
        return Set(protectedFolders.map { DirectoryNode.join(home, $0.relativePath) })
    }

    /// 권한이 없을 때의 건너뛰기 규칙 (보호 폴더 + 어디에 있든 사진 보관함).
    public static func permissionSkip(homePath: String) -> PermissionSkip {
        PermissionSkip(homePath: PathUtil.resolve(homePath), paths: protectedPaths(homePath: homePath),
                       directoryNameSuffixes: protectedDirectorySuffixes)
    }

    /// 실제 사용자 홈(getpwuid). `HOME` 을 바꿔 띄운 테스트에서도 실제 TCC 상태를 확인하도록 NSHomeDirectory 를 쓰지 않는다.
    public static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
    }

    /// 권한이 있어야만 열 수 있는 확인용 경로. 앞에서부터 확인한다(`Library/Mail` 은 디렉터리로 연다).
    public static func defaultProbePaths(home: String = realHomeDirectory) -> [String] {
        ["Library/Application Support/com.apple.TCC/TCC.db", "Library/Safari/Bookmarks.plist", "Library/Mail"]
            .map { DirectoryNode.join(home, $0) }
    }

    /// 확인용 경로를 차례로 읽기 전용으로 열었다 닫는다(쓰지 않는다).
    /// 열리면 `.granted`, EPERM·EACCES 면 `.denied`, 없으면(ENOENT 등) 다음 경로를 본다. 모두 판단하지 못하면 `.unknown`.
    public static func check(probePaths: [String] = defaultProbePaths()) -> Status {
        for path in probePaths {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            if descriptor >= 0 {
                close(descriptor)
                return .granted
            }
            switch errno {
            case EPERM, EACCES: return .denied
            default: continue
            }
        }
        return .unknown
    }
}

/// 전체 디스크 접근 권한이 없어 들어가지 않을 위치: 정확한 보호 폴더 경로 + 이름 접미사로 가리는 디렉터리(홈·추가 루트 어디서든).
/// 모든 판정은 글자 비교만 한다(lstat·realpath 를 하지 않는다). 보호 폴더 안을 건드리기만 해도 동의 창이 뜨기 때문이다.
public struct PermissionSkip: Sendable, Equatable {
    /// 건너뛰지 않음 (권한이 있을 때)
    public static let none = PermissionSkip(homePath: "", paths: [], directoryNameSuffixes: [])

    /// 홈 (실제 경로). 홈 자신은 이름 규칙으로 건너뛰지 않는다.
    public var homePath: String
    /// 건너뛸 디렉터리 절대 경로 (홈 + 적힌 이름, 링크를 풀지 않는다)
    public var paths: Set<String>
    /// 이 접미사(소문자)로 끝나는 이름의 디렉터리는 위치와 상관없이 건너뛴다. 외장 볼륨의 추가 루트 안에 있는
    /// 사진 보관함도 들어가면 사진 접근 동의 창이 뜨기 때문이다(홈 안으로 한정하지 않는다).
    public var directoryNameSuffixes: [String]

    public init(homePath: String, paths: Set<String>, directoryNameSuffixes: [String]) {
        self.homePath = homePath
        self.paths = paths
        self.directoryNameSuffixes = directoryNameSuffixes.map { $0.lowercased() }
    }

    public var isEmpty: Bool { paths.isEmpty && directoryNameSuffixes.isEmpty }

    /// 스캔 중 이 디렉터리 자체를 건너뛰는지 (경로는 정확히, 이름은 대소문자 무시).
    public func skips(_ path: String) -> Bool {
        if paths.contains(path) { return true }
        guard !directoryNameSuffixes.isEmpty, path != homePath else { return false }
        return hasProtectedName((path as NSString).lastPathComponent)
    }

    /// `path` 가 건너뛰는 위치이거나 그 아래인지 (부분 재스캔·정리·제외 경로 정리용). 사용자가 적은 경로도 받으므로
    /// 대소문자를 무시하고 비교한다(APFS 기본 볼륨은 대소문자를 구분하지 않는다). 넓게 걸리면 덜 읽을 뿐이라 안전하다.
    public func covers(_ path: String) -> Bool {
        let lower = path.lowercased()
        if paths.contains(where: { PathUtil.isSameOrDescendant(lower, of: $0.lowercased()) }) { return true }
        guard !directoryNameSuffixes.isEmpty else { return false }
        return lower.split(separator: "/").contains { hasProtectedName(String($0)) }
    }

    /// 건너뛰는 위치의 안쪽인지 (위치 자신은 아니다). 보호 폴더 자신의 lstat 은 부모 디렉터리 정보라 동의 창이 뜨지 않지만,
    /// 그 안의 경로를 lstat·realpath 하면 뜬다. 부모가 `covers` 에 걸리면 안쪽이다.
    public func coversInside(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return parent != path && covers(parent)
    }

    /// 루트(홈·추가 루트) 자신이거나 루트의 조상인 경로는 뺀 규칙 (루트 전체를 건너뛰지 않는다).
    /// 루트 자신이 이름 규칙에 걸리면(사진 보관함을 루트로 고른 경우) 이름 규칙도 뺀다.
    func excludingRoot(_ rootPath: String) -> PermissionSkip {
        var copy = self
        copy.paths = paths.filter { !PathUtil.isSameOrDescendant(rootPath, of: $0) }
        if covers(rootPath) { copy.directoryNameSuffixes = [] }
        return copy
    }

    /// `path`(글자 단위로 정리한 절대 경로)가 `homePath` 안인지 글자로만 판정한다 (대소문자 무시).
    func isInsideHomeTextually(_ path: String) -> Bool {
        !homePath.isEmpty && PathUtil.isSameOrDescendant(path.lowercased(), of: homePath.lowercased())
    }

    private func hasProtectedName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return directoryNameSuffixes.contains { lower.hasSuffix($0) }
    }
}
