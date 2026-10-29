import Foundation

/// 트리맵 한 칸: 하위 디렉터리, 큰 파일, 또는 나머지 묶음.
public struct TreemapTile: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case directory
        case file
        /// 리프로 남지 않은 작은 파일들 + 개수 제한으로 합친 항목
        case remainder
    }

    public var id: String
    public var name: String
    /// 전체 경로 (remainder 는 부모 경로)
    public var path: String
    public var size: Int64
    public var kind: Kind
    public var modificationDate: Date?

    /// `node`(경로 `path`) 의 직속 칸들. 크기 내림차순(같은 크기는 경로 오름차순), 최대 `maxTiles` 개(1 미만이면 1).
    /// 나머지 크기가 0 이고 칸이 `maxTiles` 개 이하면 그대로 두고, 나머지 크기가 있거나 칸이 넘치면
    /// `maxTiles - 1` 칸까지만 남기고 나머지 칸 하나에 합친다.
    /// "나머지 N개" 의 N 은 디렉터리·큰 파일로 남지 않은 모든 직속 파일 수라서,
    /// 크기가 0 이라 공간을 차지하지 않는 파일(iCloud 미다운로드, 다른 경로에 귀속된 하드링크)도 센다.
    public static func tiles(for node: DirectoryNode, path: String, maxTiles: Int = 150) -> [TreemapTile] {
        let maxTiles = max(1, maxTiles)
        var tiles: [TreemapTile] = node.children.map {
            TreemapTile(id: "d:" + $0.name, name: $0.name, path: DirectoryNode.join(path, $0.name), size: $0.allocatedSize,
                        kind: .directory, modificationDate: $0.newestModification)
        }
        tiles += node.largeFiles.map {
            TreemapTile(id: "f:" + $0.name, name: $0.name, path: DirectoryNode.join(path, $0.name), size: $0.allocatedSize,
                        kind: .file, modificationDate: $0.modificationDate)
        }
        let leafTotal = node.largeFiles.reduce(0) { $0 + $1.allocatedSize }
        var remainder = max(0, node.directAllocatedSize - leafTotal)
        tiles = tiles.filter { $0.size > 0 }.sorted { ($0.size, $1.path) > ($1.size, $0.path) }
        var mergedCount = node.directFileCount - node.largeFiles.count
        let keepCount = (remainder > 0 || tiles.count > maxTiles) ? maxTiles - 1 : tiles.count
        if tiles.count > keepCount {
            let overflow = tiles[keepCount...]
            remainder += overflow.reduce(0) { $0 + $1.size }
            mergedCount += overflow.count
            tiles.removeLast(overflow.count)
        }
        if remainder > 0 {
            tiles.append(TreemapTile(id: "rest", name: "나머지 \(mergedCount)개", path: path, size: remainder,
                                     kind: .remainder, modificationDate: nil))
        }
        return tiles
    }
}
