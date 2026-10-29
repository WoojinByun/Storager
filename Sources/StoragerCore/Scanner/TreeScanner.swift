import Darwin
import Foundation

/// 진행률: 루트 바로 아래 디렉터리 중 끝난 수 / 전체.
public struct ScanProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    public var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

/// 루트 하나의 전체 스캔 결과. 부분 재스캔(`TreeScanner.rescan(path:previous:)`)의 기준이 된다.
public struct TreeScan: Sendable, Equatable {
    /// 스캔한 루트의 실제 경로 (`PathUtil.resolve`)
    public var rootPath: String
    /// 루트의 st_dev. 부분 재스캔도 이 볼륨 안만 잰다.
    public var deviceID: Int32
    public var root: DirectoryNode
    /// 링크 수 > 1 인 inode → 크기를 귀속한 파일 경로 (그 inode 의 경로 중 사전순 최소)
    public var hardLinkOwners: [UInt64: String]
    /// 전체 디스크 접근 권한이 없어 들어가지 않은 보호 위치 중 스캔 중에 실제로 만난 디렉터리 (사전순).
    /// 사용자 제외 경로 아래·다른 볼륨에 있어 어차피 들어가지 않는 곳은 넣지 않는다. 부분 재스캔은 그 경로 아래 항목만 바꾼다.
    public var skippedForPermission: [String]

    public init(rootPath: String, deviceID: Int32, root: DirectoryNode, hardLinkOwners: [UInt64: String] = [:],
                skippedForPermission: [String] = []) {
        self.rootPath = rootPath
        self.deviceID = deviceID
        self.root = root
        self.hardLinkOwners = hardLinkOwners
        self.skippedForPermission = skippedForPermission
    }

    /// 부분 재스캔 결과를 트리와 귀속 맵에 반영한다. 귀속 맵은 재스캔 경로 안을 가리키던 항목을 지우고 새 조각으로 바꾼다.
    /// 다른 루트의 결과거나 루트 자신이거나 트리에 그 경로가 없어 반영하지 못하면 트리도 귀속 맵도 바꾸지 않고 false. 트리가 바뀌었으면 true.
    @discardableResult
    public mutating func apply(_ rescan: SubtreeRescan) -> Bool {
        // 트리 반영이 성공한 뒤에만 귀속 맵을 바꾼다 (실패하면 트리와 맵 모두 그대로)
        guard applyTree(rescan) else { return false }
        hardLinkOwners = hardLinkOwners.filter { !PathUtil.isSameOrDescendant($0.value, of: rescan.path) }
        hardLinkOwners.merge(rescan.hardLinkOwners) { _, new in new }
        return true
    }

    /// `apply(_:)` 중 귀속 맵을 뺀 부분: 트리와 권한 건너뛰기 목록만 바꾼다. 귀속 맵은 호출자가
    /// `HardLinkOwnerBatch` 로 모았다가 한 번에 반영한다(`ScanResult.rescanAndApply`).
    mutating func applyTree(_ rescan: SubtreeRescan) -> Bool {
        guard rescan.rootPath == rootPath,
              let components = PathUtil.components(of: rescan.path, relativeTo: rootPath), !components.isEmpty
        else { return false }
        guard root.replaceDescendant(at: components, with: rescan.node) else { return false }
        skippedForPermission = (skippedForPermission.filter { !PathUtil.isSameOrDescendant($0, of: rescan.path) }
            + rescan.skippedForPermission).sorted()
        return true
    }
}

/// 루트 하나에 차례로 반영하는 여러 부분 재스캔의 하드링크 귀속 맵 변경을 모은다.
///
/// `TreeScan.apply(_:)` 를 경로마다 부르면 매번 귀속 맵 전체(H 항목)를 걸러 P 개 경로에 P×H 가 든다(pnpm 이면 H 가
/// 10^5–10^6). 이 묶음은 기준 맵을 그대로 두고, 반영한 재스캔 경로(순번 포함)와 새 조각(덮어쓴 값, 순번 포함)만 기록한다.
/// 조회(`owner(of:in:)`)와 마지막 반영(`apply(to:)`)은 값의 조상 경로 중 반영한 재스캔 경로가 있는지만 본다.
/// 결과는 `apply(_:)` 를 같은 순서로 부른 것과 같다: 재스캔 k 를 반영하면 그 전에 있던 값 중 k 안을 가리키는 것이 지워지고
/// k 의 조각이 덮어쓴다. 그래서 값은 "자기가 기록된 뒤에 반영한 재스캔 경로" 안을 가리키면 지워진 것이다.
struct HardLinkOwnerBatch {
    /// 반영한 재스캔 경로 → 마지막으로 반영한 순번 (1부터)
    private var rescannedAt: [String: Int] = [:]
    /// `rescannedAt` 키들의 UTF-8 길이. 값의 조상 접두어 중 이 길이인 것만 사전에서 찾는다
    private var rescannedLengths: Set<Int> = []
    /// 이 묶음에서 병합한 귀속 경로와 기록 순번. 기준 맵보다 우선한다
    private var overlay: [UInt64: (path: String, sequence: Int)] = [:]
    private var sequence = 0

    var isEmpty: Bool { rescannedAt.isEmpty }

    /// 트리에 반영한 재스캔 하나를 기록한다 (`TreeScan.applyTree` 가 성공한 뒤에만 부른다).
    mutating func record(_ rescan: SubtreeRescan) {
        sequence += 1
        rescannedAt[rescan.path] = sequence
        rescannedLengths.insert(rescan.path.utf8.count)
        for (id, path) in rescan.hardLinkOwners {
            overlay[id] = (path, sequence)
        }
    }

    /// 지금까지 기록한 재스캔을 `base` 에 `apply(_:)` 로 차례로 반영했을 때의 `id` 귀속 경로.
    func owner(of id: UInt64, in base: [UInt64: String]) -> String? {
        if let entry = overlay[id] {
            return isRemoved(entry.path, after: entry.sequence) ? nil : entry.path
        }
        guard let path = base[id], !isRemoved(path, after: 0) else { return nil }
        return path
    }

    /// 기록한 변경을 `owners` 에 반영한다. 기준 맵을 한 번만 훑는다(항목마다 조상 접두어 길이 확인).
    func apply(to owners: inout [UInt64: String]) {
        guard !isEmpty else { return }
        var removed: [UInt64] = []
        for (id, path) in owners where overlay[id] == nil && isRemoved(path, after: 0) {
            removed.append(id)
        }
        for id in removed {
            owners[id] = nil
        }
        for (id, entry) in overlay {
            owners[id] = isRemoved(entry.path, after: entry.sequence) ? nil : entry.path
        }
    }

    /// `path` 자신이나 조상 중 순번 `sequence` 보다 뒤에 반영한 재스캔 경로가 있는지 (`PathUtil.isSameOrDescendant` 기준).
    private func isRemoved(_ path: String, after sequence: Int) -> Bool {
        let utf8 = path.utf8
        var index = utf8.startIndex
        var length = 0
        while index != utf8.endIndex {
            if utf8[index] == UInt8(ascii: "/"), length > 0, rescannedLengths.contains(length),
               let at = rescannedAt[String(path[..<index])], at > sequence {
                return true
            }
            index = utf8.index(after: index)
            length += 1
        }
        if rescannedLengths.contains(length), let at = rescannedAt[path], at > sequence { return true }
        return false
    }
}

/// 부분 재스캔 결과 하나.
public struct SubtreeRescan: Sendable, Equatable {
    /// 기준 스캔의 루트 경로
    public var rootPath: String
    /// 다시 잰 디렉터리의 실제 경로
    public var path: String
    /// nil 이면 그 경로가 사라졌거나 디렉터리가 아니다
    public var node: DirectoryNode?
    /// 이 서브트리 안에 귀속한 하드링크 inode → 파일 경로 (`TreeScan.apply` 가 병합한다)
    public var hardLinkOwners: [UInt64: String]
    /// 이 서브트리 안에서 권한이 없어 건너뛴 보호 위치 (`TreeScan.apply` 가 바꿔 넣는다)
    public var skippedForPermission: [String]

    public init(rootPath: String, path: String, node: DirectoryNode?, hardLinkOwners: [UInt64: String] = [:],
                skippedForPermission: [String] = []) {
        self.rootPath = rootPath
        self.path = path
        self.node = node
        self.hardLinkOwners = hardLinkOwners
        self.skippedForPermission = skippedForPermission
    }
}

/// 부분 재스캔을 할 수 없는 경로.
public enum RescanError: Error, Equatable, Sendable {
    /// 루트 자신이거나 루트 아래가 아니다 (또는 기준 스캔이 다른 루트의 것이다)
    case outsideRoot(String)
    /// 제외 경로이거나 그 아래다
    case excluded(String)
    /// 전체 디스크 접근 권한이 없어 건너뛰는 보호 폴더이거나 그 아래다 (`ScanOptions.permissionSkip`)
    case permissionRequired(String)
    /// 루트와 다른 볼륨이다 (전체 스캔도 들어가지 않는 곳)
    case otherVolume(String)
}

/// 루트(보통 홈) 아래 전체를 스캔한다. 루트 바로 아래 디렉터리를 동시에 최대 4개씩 병렬로 잰다.
public struct TreeScanner: Sendable {
    public static let maxConcurrency = 4

    /// 심볼릭 링크를 푼 실제 루트 경로 (`PathUtil.resolve`). 결과 경로는 모두 이 경로 기준이다.
    public let rootPath: String
    /// 실제로 쓰는 옵션. 루트 자신이거나 루트의 조상인 제외 경로는 뺀다(루트 전체를 빼는 값은 의미가 없다).
    /// 전체 스캔은 루트의 자식 경로만 제외 경로와 비교해 원래 영향이 없지만, 부분 재스캔은 접두어로 비교하므로
    /// 그대로 두면 모든 재스캔이 `RescanError.excluded` 로 실패한다. 이 정리로 두 경로의 의미를 맞춘다.
    /// 권한 때문에 건너뛰는 보호 폴더도 같은 규칙으로 정리한다.
    public let options: ScanOptions

    public init(rootPath: String, options: ScanOptions = ScanOptions()) {
        let rootPath = PathUtil.resolve(rootPath)
        var options = options
        options.excludedPaths = options.excludedPaths.filter { !PathUtil.isSameOrDescendant(rootPath, of: $0) }
        options.permissionSkip = options.permissionSkip.excludingRoot(rootPath)
        self.rootPath = rootPath
        self.options = options
    }

    /// 전체 스캔. 루트를 읽을 수 없으면 `DirectoryReadError`, 취소되면 `CancellationError` 를 던진다.
    /// 하드링크(링크 수 > 1)는 모든 경로를 모은 뒤 사전순 최소 경로의 부모 디렉터리에만 크기를 더한다(결정적).
    public func scan(progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> TreeScan {
        var info = stat()
        guard lstat(rootPath, &info) == 0 else { throw DirectoryReadError.posix(errno) }
        let scanner = DirectoryScanner(options: options, deviceID: info.st_dev)
        let entries = try BulkDirectoryReader.read(directoryPath: rootPath)

        var root = DirectoryNode(name: (rootPath as NSString).lastPathComponent,
                                 directNewestModification: Self.modificationDate(of: info))
        var hardLinks: [HardLinkFile] = []
        var permissionSkipped: [String] = []
        var subdirectories: [RawEntry] = []
        for entry in entries where entry.errorCode == 0 {
            switch entry.kind {
            case .file:
                scanner.add(entry, to: &root, directoryPath: rootPath, hardLinks: &hardLinks)
            case .directory:
                let path = DirectoryNode.join(rootPath, entry.name)
                switch scanner.descent(into: entry, path: path) {
                case .enter: subdirectories.append(entry)
                case .skipForPermission: permissionSkipped.append(path)
                case .skip: break
                }
            case .symlink, .other:
                continue
            }
        }

        let total = subdirectories.count
        progress(ScanProgress(completed: 0, total: total))
        let rootPath = rootPath
        // 각 작업은 자기 하드링크·권한 건너뛰기 목록을 돌려준다 (공유 상태 없음). 귀속은 모두 끝난 뒤 한 번에 한다.
        let (children, childHardLinks, childSkipped) = try await withThrowingTaskGroup(
            of: (DirectoryNode?, [HardLinkFile], [String]).self
        ) { group in
            var pending = subdirectories[...]
            func enqueue(_ entry: RawEntry) {
                group.addTask(priority: .utility) {
                    var links: [HardLinkFile] = []
                    var skipped: [String] = []
                    let node = try scanner.scan(path: DirectoryNode.join(rootPath, entry.name), name: entry.name,
                                                ownModification: entry.modificationDate, hardLinks: &links,
                                                permissionSkipped: &skipped)
                    return (node, links, skipped)
                }
            }
            for _ in 0..<min(Self.maxConcurrency, pending.count) {
                enqueue(pending.removeFirst())
            }
            var results: [DirectoryNode] = []
            var links: [HardLinkFile] = []
            var skipped: [String] = []
            var completed = 0
            while let (node, nodeLinks, nodeSkipped) = try await group.next() {
                if let node { results.append(node) }
                links += nodeLinks
                skipped += nodeSkipped
                completed += 1
                progress(ScanProgress(completed: completed, total: total))
                if let next = pending.popFirst() { enqueue(next) }
            }
            return (results, links, skipped)
        }
        try Task.checkCancellation()
        root.children = children
        root.recomputeTotals()
        hardLinks += childHardLinks
        let owners = HardLinkAttribution.attribute(hardLinks, to: &root, rootPath: rootPath,
                                                   leafThreshold: options.leafThreshold)
        return TreeScan(rootPath: rootPath, deviceID: info.st_dev, root: root, hardLinkOwners: owners,
                        skippedForPermission: (permissionSkipped + childSkipped).sorted())
    }

    /// 부분 재스캔: `path` 디렉터리 하나만 다시 잰다 (동기). `previous` 는 이 스캐너 루트의 기준 스캔이다.
    ///
    /// - 사라졌거나 디렉터리가 아니면 `node` 가 nil 인 결과를 돌려준다.
    /// - 루트 자신·루트 밖·제외 경로·권한 없이 건너뛰는 보호 폴더·다른 볼륨이면 `RescanError` 를 던진다. 볼륨 비교는 `previous.deviceID`(루트 st_dev)로 한다.
    /// - 하드링크: `previous.hardLinkOwners` 의 귀속 경로가 서브트리 밖인 inode 는 건너뛴다(밖에서 이미 셌다).
    ///   귀속 경로가 서브트리 안이거나 맵에 없으면 서브트리 안에서 사전순 최소 경로에 귀속한다.
    /// - 근사: 귀속 쪽 파일이 서브트리에서 지워지면 서브트리 밖 짝은 다음 전체 스캔까지 어디에도 세지 않는다.
    ///   새 귀속이 서브트리 밖의 더 작은 경로를 고려하지 않는 것도 다음 전체 스캔에서 바로잡힌다.
    public func rescan(path: String, previous: TreeScan) throws -> SubtreeRescan {
        try rescan(path: path, previous: previous, existingOwner: { previous.hardLinkOwners[$0] })
    }

    /// `rescan(path:previous:)` 와 같되 기존 귀속 경로를 `existingOwner` 로 찾는다
    /// (`ScanResult.rescanAndApply` 가 `HardLinkOwnerBatch` 로 아직 맵에 반영하지 않은 변경까지 보도록).
    func rescan(path: String, previous: TreeScan, existingOwner: (UInt64) -> String?) throws -> SubtreeRescan {
        // 보호 위치 안의 경로는 realpath 도 그 안을 lstat 해 동의 창을 띄우므로 풀기 전에 글자로 먼저 거부한다
        let standardized = PathUtil.standardize(path)
        guard !options.permissionSkip.covers(standardized) else { throw RescanError.permissionRequired(standardized) }
        let path = PathUtil.resolve(standardized)
        guard previous.rootPath == rootPath, path != rootPath, PathUtil.isSameOrDescendant(path, of: rootPath) else {
            throw RescanError.outsideRoot(path)
        }
        guard !options.excludedPaths.contains(where: { PathUtil.isSameOrDescendant(path, of: $0) }) else {
            throw RescanError.excluded(path)
        }
        // 권한 없이 보호 폴더에 들어가면 동의 창이 뜨므로 전체 스캔과 같이 읽기 전에 거부한다 (조상을 재스캔하면 그 안에서 건너뛴다)
        guard !options.permissionSkip.covers(path) else {
            throw RescanError.permissionRequired(path)
        }
        let gone = SubtreeRescan(rootPath: rootPath, path: path, node: nil)
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return gone }
            throw DirectoryReadError.posix(errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return gone }
        guard info.st_dev == previous.deviceID else { throw RescanError.otherVolume(path) }

        let scanner = DirectoryScanner(options: options, deviceID: previous.deviceID)
        var hardLinks: [HardLinkFile] = []
        var permissionSkipped: [String] = []
        guard var node = try scanner.scan(path: path, name: (path as NSString).lastPathComponent,
                                          ownModification: Self.modificationDate(of: info), hardLinks: &hardLinks,
                                          permissionSkipped: &permissionSkipped)
        else { return gone }
        let owners = HardLinkAttribution.attribute(hardLinks, to: &node, rootPath: path,
                                                   leafThreshold: options.leafThreshold,
                                                   existingOwner: existingOwner)
        return SubtreeRescan(rootPath: rootPath, path: path, node: node, hardLinkOwners: owners,
                             skippedForPermission: permissionSkipped.sorted())
    }

    static func modificationDate(of info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}
