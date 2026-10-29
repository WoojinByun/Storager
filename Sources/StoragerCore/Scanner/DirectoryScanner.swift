import Darwin
import Foundation

/// 링크 수 > 1 인 파일 하나. 스캔 중에는 합산하지 않고 모아 두었다가 `HardLinkAttribution` 이 한 경로에만 더한다.
struct HardLinkFile: Sendable, Equatable {
    var fileID: UInt64
    /// 파일이 든 디렉터리의 전체 경로
    var directoryPath: String
    var name: String
    var allocatedSize: Int64
    var logicalSize: Int64
    var modificationDate: Date

    var path: String { DirectoryNode.join(directoryPath, name) }
}

/// 하드링크 귀속 규칙: 링크 수 > 1 인 inode 는 그 inode 를 가리키는 파일 경로 중 사전순으로 가장 작은 경로의
/// 부모 디렉터리 노드에만 크기(할당·논리)와 큰 파일 항목을 더한다. 병렬 스캔 순서와 관계없이 결과가 같다.
/// 파일 수(`directFileCount`)와 최근 수정 시각은 링크마다 그 디렉터리에서 센다.
enum HardLinkAttribution {
    /// `files` 를 inode 마다 귀속해 `root`(전체 경로 `rootPath`) 아래 해당 디렉터리 노드에 더하고, 바뀐 노드와 그 조상의
    /// 합계를 다시 계산한다. `existingOwner` 로 찾은 귀속 경로가 `rootPath` 밖인 inode 는 건너뛴다(부분 재스캔 때 서브트리
    /// 밖 짝이 이미 센 것). 이번에 귀속한 inode → 귀속 파일 경로 맵을 돌려준다.
    static func attribute(
        _ files: [HardLinkFile],
        to root: inout DirectoryNode,
        rootPath: String,
        leafThreshold: Int64,
        existingOwner: (UInt64) -> String? = { _ in nil }
    ) -> [UInt64: String] {
        var chosen: [UInt64: HardLinkFile] = [:]
        for file in files {
            if let owner = existingOwner(file.fileID), !PathUtil.isSameOrDescendant(owner, of: rootPath) { continue }
            if let current = chosen[file.fileID], current.path <= file.path { continue }
            chosen[file.fileID] = file
        }
        guard !chosen.isEmpty else { return [:] }

        var owners: [UInt64: String] = [:]
        var byDirectory: [String: [HardLinkFile]] = [:]
        var affected: Set<String> = []
        for (fileID, file) in chosen {
            owners[fileID] = file.path
            byDirectory[file.directoryPath, default: []].append(file)
            // 귀속 디렉터리와 rootPath 까지의 조상을 표시한다 (이미 표시된 곳에서 멈춘다)
            var directory = file.directoryPath
            while PathUtil.isSameOrDescendant(directory, of: rootPath), affected.insert(directory).inserted,
                  directory != rootPath {
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        apply(byDirectory, to: &root, path: rootPath, affected: affected, leafThreshold: leafThreshold)
        return owners
    }

    private static func apply(_ byDirectory: [String: [HardLinkFile]], to node: inout DirectoryNode, path: String,
                              affected: Set<String>, leafThreshold: Int64) {
        for index in node.children.indices {
            let childPath = DirectoryNode.join(path, node.children[index].name)
            if affected.contains(childPath) {
                apply(byDirectory, to: &node.children[index], path: childPath, affected: affected,
                      leafThreshold: leafThreshold)
            }
        }
        for file in byDirectory[path] ?? [] {
            node.directAllocatedSize += file.allocatedSize
            node.directLogicalSize += file.logicalSize
            if file.allocatedSize >= leafThreshold {
                node.largeFiles.append(FileLeaf(name: file.name, allocatedSize: file.allocatedSize,
                                                modificationDate: file.modificationDate))
            }
        }
        node.recomputeTotals()
    }
}

/// 디렉터리 하나를 재귀로 스캔해 `DirectoryNode` 를 만든다 (동기). 병렬화는 `TreeScanner` 가 한다.
struct DirectoryScanner: Sendable {
    typealias Reader = @Sendable (String) throws(DirectoryReadError) -> [RawEntry]

    let options: ScanOptions
    /// 이 장치(볼륨)를 벗어나는 디렉터리는 들어가지 않는다 (스캔 루트의 st_dev)
    let deviceID: Int32
    /// 디렉터리 읽기. 테스트가 읽기 오류를 흉내 낼 때만 바꾼다.
    let read: Reader

    init(options: ScanOptions, deviceID: Int32,
         read: @escaping Reader = { path throws(DirectoryReadError) in
             try BulkDirectoryReader.read(directoryPath: path)
         }) {
        self.options = options
        self.deviceID = deviceID
        self.read = read
    }

    /// `path` 를 스캔한다. 스캔 중 사라졌으면 nil. 취소되면 `CancellationError` 를 던진다.
    /// 링크 수 > 1 인 파일은 합산하지 않고 `hardLinks` 에 모은다 (호출 측이 `HardLinkAttribution` 으로 귀속).
    /// 권한이 없어 들어가지 않은 디렉터리 경로는 `permissionSkipped` 에 모은다.
    func scan(path: String, name: String, ownModification: Date, hardLinks: inout [HardLinkFile],
              permissionSkipped: inout [String]) throws -> DirectoryNode? {
        try Task.checkCancellation()
        let entries: [RawEntry]
        do {
            entries = try read(path)
        } catch {
            if error.isMissing { return nil }
            if error.isAccessDenied {
                return DirectoryNode(name: name, directNewestModification: ownModification, accessDenied: true)
            }
            Log.scan.error("디렉터리 읽기 실패 \(path, privacy: .private): \(String(describing: error), privacy: .public)")
            return DirectoryNode(name: name, directNewestModification: ownModification, readFailed: true)
        }

        var node = DirectoryNode(name: name, directNewestModification: ownModification)
        var children: [DirectoryNode] = []
        for entry in entries where entry.errorCode == 0 {
            switch entry.kind {
            case .file:
                add(entry, to: &node, directoryPath: path, hardLinks: &hardLinks)
            case .directory:
                let childPath = DirectoryNode.join(path, entry.name)
                switch descent(into: entry, path: childPath) {
                case .skip:
                    continue
                case .skipForPermission:
                    permissionSkipped.append(childPath)
                    continue
                case .enter:
                    break
                }
                if let child = try scan(path: childPath, name: entry.name, ownModification: entry.modificationDate,
                                        hardLinks: &hardLinks, permissionSkipped: &permissionSkipped) {
                    children.append(child)
                }
            case .symlink, .other:
                // 심볼릭 링크는 따라가지 않는다
                continue
            }
        }
        node.children = children
        node.recomputeTotals()
        return node
    }

    enum Descent {
        case enter
        /// 다른 볼륨·마운트 지점·제외 경로
        case skip
        /// 전체 디스크 접근 권한이 없어 건너뛰는 보호 위치 (결과에 따로 보고한다)
        case skipForPermission
    }

    func descent(into entry: RawEntry, path: String) -> Descent {
        // 마운트 지점 항목의 deviceID 는 덮인 부모 볼륨 값이라 deviceID 비교만으로는 경계를 못 잡는다. isMountPoint 로 막는다.
        // 다른 볼륨·제외 경로는 권한과 상관없이 들어가지 않으므로 권한 건너뛰기로 보고하지 않는다.
        guard !entry.isMountPoint, entry.deviceID == deviceID, !options.excludedPaths.contains(path) else { return .skip }
        return options.permissionSkip.skips(path) ? .skipForPermission : .enter
    }

    /// 파일 하나를 노드의 직접 합계에 더한다. 링크 수 > 1 이면 크기는 더하지 않고 `hardLinks` 에 모은다.
    func add(_ entry: RawEntry, to node: inout DirectoryNode, directoryPath: String, hardLinks: inout [HardLinkFile]) {
        if options.markerFileNames.contains(entry.name) {
            node.markers.insert(entry.name)
        }
        node.directFileCount += 1
        node.directNewestModification = max(node.directNewestModification, entry.modificationDate)
        // iCloud 미다운로드 파일은 디스크를 차지하지 않으므로 0 으로 센다
        if entry.isDataless { return }
        if entry.linkCount > 1 {
            hardLinks.append(HardLinkFile(fileID: entry.fileID, directoryPath: directoryPath, name: entry.name,
                                          allocatedSize: entry.allocatedSize, logicalSize: entry.logicalSize,
                                          modificationDate: entry.modificationDate))
            return
        }
        node.directAllocatedSize += entry.allocatedSize
        node.directLogicalSize += entry.logicalSize
        if entry.allocatedSize >= options.leafThreshold {
            node.largeFiles.append(FileLeaf(name: entry.name, allocatedSize: entry.allocatedSize,
                                            modificationDate: entry.modificationDate))
        }
    }
}
