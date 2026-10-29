import Foundation

/// 트리 뷰가 기억하는 펼친 폴더 경로. 새 결과(스캔·정리)로 줄을 다시 만든 뒤 같은 모양으로 되살리는 데 쓴다.
///
/// 모든 연산의 비용은 건드리는 경로 수(와 그 깊이)에만 비례한다. 전체 집합을 훑지 않는다.
/// Option-클릭으로 큰 서브트리를 펼치면 펼침 알림이 폴더마다 오는데, 알림마다 전체를 정리하면 O(n²) 이 되기 때문이다.
/// 부모 → 자식 간선 색인(기억한 경로와 그 조상들)을 두어, 자식 줄을 만든 폴더에서 사라진 자식과 그 아래만 그 자리에서 뺀다.
///
/// 기억하는 경로는 `limit` 개까지이고, 넘치면 가장 오래 쓰지 않은 경로부터 잊는다(LRU).
/// Option-클릭으로 수만 개 폴더를 펼친 상태를 다 기억하면 정리·스캔 뒤 다시 그릴 때마다 그만큼 다시 펼쳐야 하고,
/// 넘친 뒤 새 펼침을 거절하면 그 폴더를 접어도 숨은 자손이 자리를 차지해 이후 펼침을 영영 기억하지 못한다.
/// 경로를 기억할 때 기억 중인 조상도 함께 최근으로 올려, 펼친 폴더 아래로 내려가는 동안 그 위 폴더가 먼저 잊히지 않게 한다.
/// AppKit 이 Option-클릭에서 자식의 펼침 알림을 부모보다 먼저 보내도, 마지막에 온 부모가 가장 최근이라 남는다.
public struct TreeExpansionMemory: Sendable, Equatable {
    public static let defaultLimit = 2_000

    public let limit: Int
    /// 기억한 경로 → 마지막으로 쓴 순번
    private var stamps: [String: Int] = [:]
    /// (순번, 경로) 를 쓴 순서대로. 순번이 `stamps` 와 다른 항목은 지난 기록이라 건너뛴다(지연 삭제).
    private var order: [(stamp: Int, path: String)] = []
    private var orderHead = 0
    private var clock = 0
    /// 부모 → 자식 간선. 자식은 기억한 경로이거나 기억한 자손이 있는 경로다(접힌 부모 아래 펼친 자식도 사라지면 뺄 수 있도록).
    private var edges: [String: Set<String>] = [:]

    public init(limit: Int = Self.defaultLimit) {
        self.limit = max(0, limit)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.limit == rhs.limit && lhs.paths == rhs.paths
    }

    public var paths: Set<String> { Set(stamps.keys) }
    public var count: Int { stamps.count }

    /// LRU 순서 기록의 저장 길이 (지난 기록 포함). 테스트가 기록이 한도에 비례해 묶이는지 확인한다.
    var orderStorageCount: Int { order.count }

    public func contains(_ path: String) -> Bool {
        stamps[path] != nil
    }

    /// 펼친 경로를 기억하고, 기억 중인 조상과 함께 가장 최근으로 올린다. 한도를 넘으면 가장 오래 쓰지 않은 경로를 잊는다.
    public mutating func remember(_ path: String) {
        guard limit > 0 else { return }
        if stamps[path] == nil {
            // 이미 있는 간선을 만나면 그 위는 이어져 있다
            var child = path
            while true {
                let parent = TreeEntry.parentPath(of: child)
                guard parent != child, edges[parent, default: []].insert(child).inserted else { break }
                child = parent
            }
        }
        // 조상을 먼저, 자기 자신을 마지막에 올린다 (자기 자신이 가장 최근)
        var ancestors: [String] = []
        var current = path
        while true {
            let parent = TreeEntry.parentPath(of: current)
            guard parent != current else { break }
            if stamps[parent] != nil { ancestors.append(parent) }
            current = parent
        }
        for ancestor in ancestors.reversed() { touch(ancestor) }
        touch(path)
        while stamps.count > limit { evictOldest() }
        // 밀어낸 뒤에 압축 여부를 본다 (살아 있는 수가 limit 이하인 상태로 비교해 상한이 limit 기준이 되도록)
        compactIfNeeded()
    }

    /// 접은 경로를 잊는다. 그 아래 기억한 자손은 남긴다(부모를 다시 펼치면 함께 펼친다). 한도 때문에 오래된 것부터 밀려난다.
    public mutating func forget(_ path: String) {
        guard stamps.removeValue(forKey: path) != nil else { return }
        detachIfUnused(path)
    }

    /// `parent` 의 자식 줄을 만들었을 때, 기억한(또는 기억한 자손이 있는) 자식 중 `exists` 가 false 인 것과 그 아래를 뺀다.
    /// 확인한 자식 수를 돌려준다. 전체 기억 수와 무관하다.
    @discardableResult
    public mutating func pruneChildren(of parent: String, exists: (String) -> Bool) -> Int {
        guard let children = edges[parent] else { return 0 }
        for child in children where !exists(child) {
            removeSubtree(child)
        }
        return children.count
    }

    /// 루트들 밖의 경로(사라진 추가 루트 등)와 그 아래를 뺀다. 결과마다 한 번만 부른다(O(기억 수 × 루트 수)).
    public mutating func retainOnly(underRoots roots: [String]) {
        let outside = stamps.keys.filter { path in !roots.contains { PathUtil.isSameOrDescendant(path, of: $0) } }
        for path in outside where stamps[path] != nil { removeSubtree(path) }
    }

    // MARK: 내부

    private mutating func touch(_ path: String) {
        clock += 1
        stamps[path] = clock
        order.append((clock, path))
    }

    /// 배열 전체(이미 지나간 앞부분 포함)가 살아 있는 수의 2배 + 1,024 를 넘으면 살아 있는 기록만 남긴다.
    /// 압축 뒤 길이는 살아 있는 수 이하라 다음 압축까지 최소 (살아 있는 수 + 1,024) 번 덧붙여야 하므로,
    /// O(길이) 압축 비용을 그 덧붙임들이 나눠 내 분할 상환 O(1) 이다.
    /// `remember` 가 밀어낸 뒤 부르므로 어느 공개 연산이 끝난 뒤에도 저장 길이는 2 × limit + 1,024 이하다
    /// (`remember` 한 번 안에서는 기억 중인 조상 수 + 1 만큼 잠깐 더 길 수 있다. 잊기·정리는 덧붙이지 않는다).
    private mutating func compactIfNeeded() {
        guard order.count > 2 * stamps.count + 1_024 else { return }
        order = order[orderHead...].filter { stamps[$0.path] == $0.stamp }
        orderHead = 0
    }

    /// 가장 오래 쓰지 않은 경로 하나를 잊는다 (지난 기록은 건너뛴다, 분할 상환 O(1)).
    private mutating func evictOldest() {
        while orderHead < order.count {
            let (stamp, path) = order[orderHead]
            orderHead += 1
            if stamps[path] == stamp {
                forget(path)
                break
            }
        }
    }

    /// 경로와 그 아래 기억한 것을 모두 뺀다 (비용은 빠지는 경로 수에 비례).
    private mutating func removeSubtree(_ path: String) {
        var stack = [path]
        while let current = stack.popLast() {
            stamps.removeValue(forKey: current)
            if let children = edges.removeValue(forKey: current) { stack.append(contentsOf: children) }
        }
        detachIfUnused(path)
    }

    /// 기억하지도 않고 기억한 자손도 없는 경로의 간선을 부모 쪽으로 거슬러 올라가며 지운다 (O(깊이)).
    private mutating func detachIfUnused(_ path: String) {
        var node = path
        while stamps[node] == nil, edges[node] == nil {
            let parent = TreeEntry.parentPath(of: node)
            guard parent != node, edges[parent]?.remove(node) != nil else { return }
            guard edges[parent]?.isEmpty == true else { return }
            edges[parent] = nil
            node = parent
        }
    }
}
