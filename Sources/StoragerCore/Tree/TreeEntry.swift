import Foundation

/// 분석 윈도우 트리 뷰의 한 줄: 하위 디렉터리, 큰 파일, 또는 리프로 남지 않은 작은 파일 묶음("나머지 파일 N개").
/// 펼친 행의 자식만 `children(of:path:)` 로 만든다(트리 전체를 미리 펼치지 않는다).
public struct TreeEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case directory
        case file
        /// 디렉터리 바로 아래의 작은 파일들(트리에 리프로 남지 않은 파일)을 합친 줄. 실제 경로가 아니다.
        case remainder
    }

    /// 디렉터리·파일은 전체 경로, 나머지 줄은 `부모 경로 + "\0rest"` (실제 경로와 겹치지 않는다)
    public var id: String
    public var name: String
    /// 전체 경로 (나머지 줄은 부모 경로)
    public var path: String
    public var size: Int64
    public var kind: Kind
    /// 디렉터리는 하위 전체 파일 수(`DirectoryNode.fileCount`), 나머지 줄은 합친 파일 수, 파일은 nil
    public var fileCount: Int?
    public var modificationDate: Date?
    /// 부모 크기 대비 비율 (0...1)
    public var share: Double

    public init(id: String, name: String, path: String, size: Int64, kind: Kind, fileCount: Int?,
                modificationDate: Date?, share: Double) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.kind = kind
        self.fileCount = fileCount
        self.modificationDate = modificationDate
        self.share = share
    }

    /// 실제 파일 시스템 경로를 가리키는 줄인지 (우클릭 동작 대상).
    public var hasRealPath: Bool { kind != .remainder }

    /// `size / parentSize` 를 0...1 로 자른 값. 부모 크기가 0 이하면 0.
    public static func share(_ size: Int64, of parentSize: Int64) -> Double {
        guard parentSize > 0, size > 0 else { return 0 }
        return min(1, Double(size) / Double(parentSize))
    }

    /// 최상위 줄(홈·추가 루트). 비율은 1.
    public static func root(_ node: DirectoryNode, path: String, name: String) -> TreeEntry {
        TreeEntry(id: path, name: name, path: path, size: node.allocatedSize, kind: .directory,
                  fileCount: node.fileCount, modificationDate: node.newestModification, share: 1)
    }

    /// `node`(경로 `path`)의 직속 줄들. 크기 내림차순, 같은 크기는 이름 오름차순(디렉터리·파일 섞어서).
    /// 나머지 줄(작은 파일 묶음)은 크기나 파일 수가 있을 때만 붙고, 같은 규칙으로 크기 순 자리에 들어간다.
    ///
    /// `DirectoryNode` 의 `children`·`largeFiles` 는 이미 같은 순서로 정렬돼 있어 두 목록을 병합한다(O(n)).
    /// 자식이 수만 개인 디렉터리도 정렬 비용 없이 펼친다.
    public static func children(of node: DirectoryNode, path: String) -> [TreeEntry] {
        let parentSize = node.allocatedSize
        var entries: [TreeEntry] = []
        entries.reserveCapacity(node.children.count + node.largeFiles.count + 1)

        let leafTotal = node.largeFiles.reduce(0) { $0 + $1.allocatedSize }
        let remainderSize = max(0, node.directAllocatedSize - leafTotal)
        let remainderCount = max(0, node.directFileCount - node.largeFiles.count)
        var remainder: TreeEntry?
        if remainderSize > 0 || remainderCount > 0 {
            remainder = TreeEntry(id: path + "\0rest", name: "나머지 파일 \(remainderCount.formatted())개", path: path,
                                  size: remainderSize, kind: .remainder, fileCount: remainderCount,
                                  modificationDate: nil, share: share(remainderSize, of: parentSize))
        }

        func directory(_ child: DirectoryNode) -> TreeEntry {
            let childPath = DirectoryNode.join(path, child.name)
            return TreeEntry(id: childPath, name: child.name, path: childPath, size: child.allocatedSize,
                             kind: .directory, fileCount: child.fileCount, modificationDate: child.newestModification,
                             share: share(child.allocatedSize, of: parentSize))
        }
        func file(_ leaf: FileLeaf) -> TreeEntry {
            let leafPath = DirectoryNode.join(path, leaf.name)
            return TreeEntry(id: leafPath, name: leaf.name, path: leafPath, size: leaf.allocatedSize, kind: .file,
                             fileCount: nil, modificationDate: leaf.modificationDate,
                             share: share(leaf.allocatedSize, of: parentSize))
        }
        func append(_ entry: TreeEntry) {
            // 나머지 줄은 자기보다 작은 첫 줄 앞에 넣는다 (같은 크기면 실제 항목 뒤)
            if let pending = remainder, pending.size > entry.size {
                entries.append(pending)
                remainder = nil
            }
            entries.append(entry)
        }

        // `recomputeTotals()` 가 정렬해 두지만 `children`·`largeFiles` 는 공개 var 라, 어긋났을 때만 정렬한다(확인은 O(n))
        let dirs = isDescending(node.children, size: \.allocatedSize, name: \.name)
            ? node.children : node.children.sorted { ($0.allocatedSize, $1.name) > ($1.allocatedSize, $0.name) }
        let files = isDescending(node.largeFiles, size: \.allocatedSize, name: \.name)
            ? node.largeFiles : node.largeFiles.sorted { ($0.allocatedSize, $1.name) > ($1.allocatedSize, $0.name) }
        var d = dirs.startIndex
        var f = files.startIndex
        while d < dirs.endIndex || f < files.endIndex {
            let takeDirectory: Bool
            if d == dirs.endIndex {
                takeDirectory = false
            } else if f == files.endIndex {
                takeDirectory = true
            } else {
                let dir = dirs[d]
                let leaf = files[f]
                takeDirectory = dir.allocatedSize != leaf.allocatedSize
                    ? dir.allocatedSize > leaf.allocatedSize
                    : dir.name <= leaf.name
            }
            if takeDirectory {
                append(directory(dirs[d]))
                d += 1
            } else {
                append(file(files[f]))
                f += 1
            }
        }
        if let remainder { entries.append(remainder) }
        return entries
    }

    private static func isDescending<T>(_ items: [T], size: KeyPath<T, Int64>, name: KeyPath<T, String>) -> Bool {
        zip(items, items.dropFirst()).allSatisfy { a, b in
            a[keyPath: size] != b[keyPath: size] ? a[keyPath: size] > b[keyPath: size] : a[keyPath: name] <= b[keyPath: name]
        }
    }
}

extension TreeEntry {
    /// "트리맵에서 보기" 의 홈 기준 드릴다운 경로. 디렉터리는 자기 자신, 파일은 부모 폴더, 나머지 줄은 그 줄이 속한 폴더.
    /// 홈 밖(추가 루트)이면 nil (트리맵은 홈만 그린다).
    public func treemapComponents(homePath: String) -> [String]? {
        let folder = kind == .file ? Self.parentPath(of: path) : path
        return PathUtil.components(of: folder, relativeTo: homePath)
    }

    static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// 우클릭 메뉴의 대상 행. 우클릭한 행이 선택에 들어 있으면 선택 전체(행 순서), 아니면 그 행만. 우클릭한 행이 없으면(-1) 빈 배열.
    public static func menuTargetRows(clickedRow: Int, selectedRows: IndexSet) -> [Int] {
        guard clickedRow >= 0 else { return [] }
        return selectedRows.contains(clickedRow) ? Array(selectedRows) : [clickedRow]
    }
}
