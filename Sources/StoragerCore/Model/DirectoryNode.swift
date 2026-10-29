import Foundation

/// 임계치 이상인 파일 하나. 경로는 부모 노드 경로 + name 으로 만든다 (메모리 절약).
public struct FileLeaf: Sendable, Equatable, Hashable {
    public var name: String
    public var allocatedSize: Int64
    public var modificationDate: Date

    public init(name: String, allocatedSize: Int64, modificationDate: Date) {
        self.name = name
        self.allocatedSize = allocatedSize
        self.modificationDate = modificationDate
    }
}

/// 스캔 트리의 디렉터리 노드. 디렉터리는 전부 노드, 파일은 임계치 이상만 `largeFiles` 에 남는다.
/// 노드는 전체 URL 대신 이름만 가진다 (홈 300만 파일 기준 메모리 목표). 경로는 순회하며 만든다.
public struct DirectoryNode: Sendable, Equatable {
    public var name: String
    /// 이 디렉터리 바로 아래 파일들의 합 (하위 디렉터리 제외). 부분 재스캔 뒤 합계를 다시 낼 때 쓴다.
    public var directAllocatedSize: Int64
    public var directLogicalSize: Int64
    public var directFileCount: Int
    public var directNewestModification: Date
    /// 하위 전체 합 (`recomputeTotals()` 가 채운다)
    public private(set) var allocatedSize: Int64
    public private(set) var logicalSize: Int64
    public private(set) var fileCount: Int
    public private(set) var newestModification: Date
    /// 크기 내림차순, 같은 크기는 이름 오름차순
    public var children: [DirectoryNode]
    /// 크기 내림차순, 같은 크기는 이름 오름차순
    public var largeFiles: [FileLeaf]
    /// 이 디렉터리에 바로 들어 있는 표식 파일 이름 (예: package.json). 분류 규칙의 "옆에 X 파일"(자식 쪽에서 본 부모 표식)과
    /// "안에 X 파일"(예: venv 의 pyvenv.cfg) 조건에 쓴다.
    public var markers: Set<String>
    /// 읽기 거부(EPERM/EACCES)된 디렉터리
    public var accessDenied: Bool
    /// 접근 거부가 아닌 오류(EIO 등)로 읽지 못한 디렉터리. 진짜 빈 디렉터리와 구분한다.
    public var readFailed: Bool

    public init(
        name: String,
        directAllocatedSize: Int64 = 0,
        directLogicalSize: Int64 = 0,
        directFileCount: Int = 0,
        directNewestModification: Date = .distantPast,
        children: [DirectoryNode] = [],
        largeFiles: [FileLeaf] = [],
        markers: Set<String> = [],
        accessDenied: Bool = false,
        readFailed: Bool = false
    ) {
        self.name = name
        self.directAllocatedSize = directAllocatedSize
        self.directLogicalSize = directLogicalSize
        self.directFileCount = directFileCount
        self.directNewestModification = directNewestModification
        self.children = children
        self.largeFiles = largeFiles
        self.markers = markers
        self.accessDenied = accessDenied
        self.readFailed = readFailed
        allocatedSize = 0
        logicalSize = 0
        fileCount = 0
        newestModification = .distantPast
        recomputeTotals()
    }

    /// 자식 합계로 이 노드의 합계를 다시 계산하고 자식·큰 파일을 크기 내림차순으로 정렬한다. 자식은 이미 계산돼 있어야 한다.
    public mutating func recomputeTotals() {
        children.sort { ($0.allocatedSize, $1.name) > ($1.allocatedSize, $0.name) }
        largeFiles.sort { ($0.allocatedSize, $1.name) > ($1.allocatedSize, $0.name) }
        allocatedSize = directAllocatedSize + children.reduce(0) { $0 + $1.allocatedSize }
        logicalSize = directLogicalSize + children.reduce(0) { $0 + $1.logicalSize }
        fileCount = directFileCount + children.reduce(0) { $0 + $1.fileCount }
        newestModification = children.reduce(directNewestModification) { max($0, $1.newestModification) }
    }

    public func child(named name: String) -> DirectoryNode? {
        children.first { $0.name == name }
    }

    /// `components` 경로(이 노드 기준 상대 이름 목록)의 자손. 빈 배열이면 자기 자신.
    public func descendant(at components: [String]) -> DirectoryNode? {
        var node = self
        for name in components {
            guard let next = node.child(named: name) else { return nil }
            node = next
        }
        return node
    }

    /// `components` 위치의 자손을 `replacement` 로 바꾸고(nil 이면 제거) 조상 합계를 다시 계산한다.
    /// 마지막 이름이 없고 replacement 가 있으면 새 자식으로 붙인다.
    /// 실제로 교체·제거·추가가 일어났을 때만 true. 경로 중간이 없거나, `replacement.name` 이 마지막 이름과 다르거나,
    /// 지울 노드가 없거나, `components` 가 비었으면 아무것도 바꾸지 않고 false 를 돌려준다.
    @discardableResult
    public mutating func replaceDescendant(at components: [String], with replacement: DirectoryNode?) -> Bool {
        guard let first = components.first else { return false }
        if components.count == 1 {
            if let replacement, replacement.name != first { return false }
            let existed = children.contains { $0.name == first }
            if replacement == nil, !existed { return false }
            children.removeAll { $0.name == first }
            if let replacement { children.append(replacement) }
            recomputeTotals()
            return true
        }
        guard let index = children.firstIndex(where: { $0.name == first }) else { return false }
        let changed = children[index].replaceDescendant(at: Array(components.dropFirst()), with: replacement)
        if changed { recomputeTotals() }
        return changed
    }

    /// 부모 경로와 자식 이름을 이어 붙인다. 부모가 `/` 처럼 이미 `/` 로 끝나면 구분자를 더하지 않는다.
    /// 부모 끝의 `/` 하나만 처리한다 (`//` 처럼 여러 개가 겹친 부모는 정규화하지 않는다).
    public static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    /// 깊이 우선으로 모든 노드를 (전체 경로, 노드) 로 방문한다. `visit` 이 false 를 돌려주면 그 노드의 자식은 건너뛴다.
    public func walk(path: String, _ visit: (String, DirectoryNode) -> Bool) {
        guard visit(path, self) else { return }
        for child in children {
            child.walk(path: Self.join(path, child.name), visit)
        }
    }

    /// 접근 거부된 디렉터리 수 (자기 포함).
    public var accessDeniedCount: Int {
        children.reduce(accessDenied ? 1 : 0) { $0 + $1.accessDeniedCount }
    }
}

/// 큰 파일 목록 한 줄 (전체 경로 포함).
public struct LargeFileEntry: Sendable, Equatable, Hashable, Identifiable {
    public var path: String
    public var allocatedSize: Int64
    public var modificationDate: Date
    public var id: String { path }
}

extension DirectoryNode {
    /// 트리 전체에서 가장 큰 파일 `limit` 개 (크기 내림차순, 같은 크기는 경로 오름차순).
    /// 전체를 모아 정렬하지 않고 상위 `limit` 개만 유지하며, 전체 경로는 상위에 들어갈 수 있는 파일만 만든다.
    public func largestFiles(path: String, limit: Int) -> [LargeFileEntry] {
        guard limit > 0 else { return [] }
        var top = TopK<LargeFileEntry>(limit: limit, size: \.allocatedSize, path: \.path)
        var components: [String] = []
        func visit(_ node: DirectoryNode) {
            for leaf in node.largeFiles where top.mayAccept(size: leaf.allocatedSize) {
                let nodePath = components.reduce(path) { Self.join($0, $1) }
                top.insert(LargeFileEntry(path: Self.join(nodePath, leaf.name), allocatedSize: leaf.allocatedSize,
                                          modificationDate: leaf.modificationDate))
            }
            for child in node.children {
                components.append(child.name)
                visit(child)
                components.removeLast()
            }
        }
        visit(self)
        return top.elements
    }

    /// 루트를 뺀 모든 디렉터리 중 가장 큰 `limit` 개 (크기 내림차순, 같은 크기는 경로 오름차순). 스냅샷의 상위 디렉터리 기록에 쓴다.
    /// 전체를 모아 정렬하지 않고 상위 `limit` 개만 유지한다. 자손은 조상보다 크지 않으므로(`allocatedSize` 는 하위 합계)
    /// 이미 찬 상위 목록의 마지막보다 작은 노드는 그 아래를 보지 않고, 전체 경로는 상위에 들어갈 수 있는 노드만 만든다.
    public func largestDirectories(path: String, limit: Int) -> [(path: String, size: Int64)] {
        guard limit > 0 else { return [] }
        var top = TopK<DirectorySize>(limit: limit, size: \.size, path: \.path)
        var components: [String] = []
        func visit(_ node: DirectoryNode) {
            for child in node.children where top.mayAccept(size: child.allocatedSize) {
                components.append(child.name)
                top.insert(DirectorySize(path: components.reduce(path) { Self.join($0, $1) }, size: child.allocatedSize))
                visit(child)
                components.removeLast()
            }
        }
        visit(self)
        return top.elements.map { ($0.path, $0.size) }
    }
}

/// 크기 내림차순(같은 크기는 경로 오름차순) 상위 `limit` 개를 유지한다. 결과(`elements`)는 전체를 같은 순서로 정렬한 뒤
/// 앞 `limit` 개를 자른 것과 같다. 크기만 보고 거를 수 있으면(`mayAccept`) 호출자가 경로 문자열을 만들지 않아도 된다.
struct TopK<Element> {
    let limit: Int
    let size: (Element) -> Int64
    let path: (Element) -> String
    /// 순서대로 정렬된 상위 원소
    private(set) var elements: [Element] = []

    init(limit: Int, size: @escaping (Element) -> Int64, path: @escaping (Element) -> String) {
        self.limit = max(0, limit)
        self.size = size
        self.path = path
        elements.reserveCapacity(self.limit)
    }

    /// 크기가 `size` 인 원소가 들어갈 수 있는지. 가득 찼고 마지막 원소보다 작으면 false.
    /// 크기가 같으면 경로를 비교해야 하므로 true 다.
    func mayAccept(size candidate: Int64) -> Bool {
        guard limit > 0 else { return false }
        guard elements.count == limit, let last = elements.last else { return true }
        return candidate >= size(last)
    }

    mutating func insert(_ element: Element) {
        guard limit > 0 else { return }
        if elements.count == limit {
            guard let last = elements.last, isBetter(element, last) else { return }
            elements.removeLast()
        }
        var low = 0
        var high = elements.count
        while low < high {
            let middle = (low + high) / 2
            if isBetter(element, elements[middle]) { high = middle } else { low = middle + 1 }
        }
        elements.insert(element, at: low)
    }

    /// 예전 전체 정렬의 비교식과 같다: 크기가 크거나, 같으면 경로가 작은 쪽이 앞이다
    private func isBetter(_ lhs: Element, _ rhs: Element) -> Bool {
        (size(lhs), path(rhs)) > (size(rhs), path(lhs))
    }
}
