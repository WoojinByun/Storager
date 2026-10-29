import Darwin
import Foundation

/// 정리 거부 사유.
public enum CleanupRejection: Sendable, Equatable {
    /// 홈·추가 프로젝트 루트 밖
    case outsideAllowedRoots
    /// 홈 자체, ~/Library 자체처럼 카탈로그가 가리키지 않는 상위 디렉터리
    case protectedDirectory
    case symbolicLink
    /// 표기가 실제 경로와 다르다 (중간 디렉터리가 링크이거나 대소문자가 다름). `~/library` 로 보호 검사를 우회하지 못하게 한다
    case pathMismatch
    /// 이미 없거나 디렉터리가 아님 (일반 파일 등)
    case missing
    /// 수동 확인 등급: Finder 에서 보기만
    case manualOnly
    /// 주의 등급·도구 명령 정리는 다음 버전
    case notYetSupported
    /// 전체 디스크 접근 권한이 없어 건너뛰는 위치 안 (확인하려고 들여다보기만 해도 동의 창이 뜬다)
    case permissionRequired
    /// 다시 계획: 카테고리 정리 요청의 이전 항목이 최근 스캔에서 다른 카테고리로 분류됐다 (`CleanupReplan`)
    case categoryChanged
    /// 다시 계획: 이전 항목이 디스크에는 있지만 최근 스캔에서 분류 항목이 아니다 (`CleanupReplan`)
    case notClassified

    public var message: String {
        switch self {
        case .outsideAllowedRoots: "홈 또는 추가 프로젝트 루트 밖이라 정리할 수 없습니다"
        case .protectedDirectory: "보호된 상위 디렉터리라 정리할 수 없습니다"
        case .symbolicLink: "심볼릭 링크는 정리하지 않습니다"
        case .pathMismatch: "경로가 실제 위치와 다릅니다(링크 또는 대소문자)"
        case .missing: "없거나 폴더가 아닙니다"
        case .manualOnly: "직접 확인해야 하는 항목입니다. Finder 에서 정리하세요"
        case .notYetSupported: "v0.2 에서 지원"
        case .permissionRequired: "전체 디스크 접근 권한이 없어 정리할 수 없습니다"
        case .categoryChanged: "최근 스캔에서 다른 카테고리로 분류되었습니다"
        case .notClassified: "최근 스캔에서 정리 대상으로 분류되지 않았습니다"
        }
    }
}

public struct RejectedItem: Sendable, Equatable {
    public var item: ClassifiedItem
    public var reason: CleanupRejection

    public init(item: ClassifiedItem, reason: CleanupRejection) {
        self.item = item
        self.reason = reason
    }
}

/// 정리 미리보기. 실행 전 사용자에게 그대로 보여 준다.
public struct CleanupPlan: Sendable, Equatable {
    public var accepted: [ClassifiedItem]
    public var rejected: [RejectedItem]
    public var warnings: [String]

    public var reclaimableBytes: Int64 { accepted.reduce(0) { $0 + $1.allocatedSize } }
    public var isEmpty: Bool { accepted.isEmpty }
}

/// 선택한 분류 항목으로 정리 계획을 만든다. v0.1 은 "재생성 가능 + 휴지통" 만 허용한다.
public struct CleanupPlanner: Sendable {
    /// 실행 중이면 경고할 앱: 카테고리 → (번들 ID, 이름)
    static let relatedApps: [Category: [(bundleID: String, name: String)]] = [
        .xcode: [("com.apple.dt.Xcode", "Xcode")],
        .simulator: [("com.apple.dt.Xcode", "Xcode"), ("com.apple.iphonesimulator", "Simulator")],
        .docker: [("com.docker.docker", "Docker")],
        .gradle: [("com.google.android.studio", "Android Studio")],
    ]

    public let homePath: String
    public let allowedRoots: [String]
    let protectedPaths: Set<String>
    let permissionSkip: PermissionSkip

    /// - Parameter extraRoots: 사용자가 설정한 추가 프로젝트 루트. 그 아래 항목도 정리를 허용한다.
    ///   홈·추가 루트는 스캐너(`TreeScanner.rootPath`)와 같게 `PathUtil.resolve` 로 심볼릭 링크를 푼다(분류 항목 경로가 그 표기다).
    ///   홈 또는 다른 추가 루트와 겹치는 추가 루트는 스캔과 같은 규칙(`ExtraRootConflict.acceptedRoots`)으로 뺀다.
    /// - Parameter permissionSkip: 전체 디스크 접근 권한이 없을 때 건너뛰는 위치. 그 안의 항목은 lstat·realpath 없이 거부한다
    ///   (권한을 가진 스캔 뒤에 권한을 거둔 경우).
    public init(homePath: String, extraRoots: [String] = [], permissionSkip: PermissionSkip = .none) {
        let home = PathUtil.resolve(homePath)
        self.homePath = home
        self.permissionSkip = permissionSkip
        let extras = ExtraRootConflict.acceptedRoots(extraRoots, homePath: home, permissionSkip: permissionSkip,
                                                     logsSkipped: false)
        allowedRoots = [home] + extras
        let homeChildren = ["Library", "Library/Caches", "Library/Application Support", "Library/Containers",
                            "Library/Developer", "Library/Logs", "Documents", "Desktop", "Downloads", "Pictures",
                            "Movies", "Music", "Public"]
        protectedPaths = Set(["/", home] + extras + homeChildren.map { DirectoryNode.join(home, $0) })
    }

    public func plan(_ items: [ClassifiedItem], runningBundleIDs: Set<String> = []) -> CleanupPlan {
        var candidates: [ClassifiedItem] = []
        var rejected: [RejectedItem] = []
        var seen: Set<String> = []
        for item in items {
            let path = PathUtil.standardize(item.path)
            if let reason = rejection(for: item, path: path) {
                rejected.append(RejectedItem(item: item, reason: reason))
            } else if seen.insert(path).inserted {
                // 같은 경로가 여러 번 들어오면 첫 항목만 남긴다 (회수량을 두 번 세지 않도록)
                var item = item
                item.path = path
                candidates.append(item)
            }
        }
        // 허용된 조상이 함께 선택되면 자손은 빼서 두 번 세지 않는다. 부모를 거슬러 올라가며 찾아 O(항목 수 × 깊이)다.
        // 조상 후보가 다시 그 위 조상 때문에 빠져도 자손은 그 위 조상으로 덮이므로, 후보 집합으로 판정해도 결과가 같다.
        // 거부된 조상은 후보가 아니라서 자손을 빼지 않는다.
        let accepted = candidates.filter { !Self.hasProperAncestor($0.path, in: seen) }
        return CleanupPlan(accepted: accepted, rejected: rejected,
                           warnings: warnings(for: accepted, runningBundleIDs: runningBundleIDs))
    }

    /// `path`(정규화된 절대 경로)의 조상 중 하나가 `paths` 에 있으면 true. 자기 자신은 보지 않는다.
    static func hasProperAncestor(_ path: String, in paths: Set<String>) -> Bool {
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/"), !current.isEmpty, current != "/" {
            current = slash == current.startIndex ? "/" : current[..<slash]
            if paths.contains(String(current)) { return true }
        }
        return false
    }

    private func rejection(for item: ClassifiedItem, path: String) -> CleanupRejection? {
        guard allowedRoots.contains(where: { PathUtil.isSameOrDescendant(path, of: $0) }) else { return .outsideAllowedRoots }
        guard !protectedPaths.contains(path) else { return .protectedDirectory }
        // 아래 lstat·realpath 가 보호 위치 안을 건드리기 전에 글자 비교로 거른다
        guard !permissionSkip.covers(path) else { return .permissionRequired }
        switch (item.tag.level, item.tag.method) {
        case (.manual, _), (_, .revealOnly): return .manualOnly
        case (.caution, _), (_, .command): return .notYetSupported
        case (.regenerable, .trash): break
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .symbolicLink
        case S_IFDIR: break
        default: return .missing
        }
        // 중간 디렉터리가 링크이거나 대소문자만 다른 표기면 보호·허용 루트 검사를 글자 비교로 우회할 수 있다
        guard PathUtil.resolve(path) == path else { return .pathMismatch }
        return nil
    }

    private func warnings(for items: [ClassifiedItem], runningBundleIDs: Set<String>) -> [String] {
        let categories = Set(items.map(\.tag.category))
        var names: [String] = []
        for category in Category.allCases where categories.contains(category) {
            for app in Self.relatedApps[category] ?? [] where runningBundleIDs.contains(app.bundleID) && !names.contains(app.name) {
                names.append(app.name)
            }
        }
        return names.map { "\($0) 가 실행 중입니다. 정리 후 \($0) 를 다시 시작하는 것이 안전합니다." }
    }
}
