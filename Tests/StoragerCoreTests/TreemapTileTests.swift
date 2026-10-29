import Foundation
import Testing
@testable import StoragerCore

struct TreemapTileTests {
    @Test func directoriesFilesAndRemainderCoverNodeSize() {
        let node = DirectoryNode(
            name: "n", directAllocatedSize: 130, directFileCount: 5,
            children: [DirectoryNode(name: "big", directAllocatedSize: 500), DirectoryNode(name: "empty")],
            largeFiles: [FileLeaf(name: "movie.mov", allocatedSize: 100, modificationDate: .distantPast)])

        let tiles = TreemapTile.tiles(for: node, path: "/h/n")

        #expect(tiles.map(\.kind) == [.directory, .file, .remainder])
        #expect(tiles.map(\.path) == ["/h/n/big", "/h/n/movie.mov", "/h/n"])
        #expect(tiles.map(\.size) == [500, 100, 30])
        #expect(tiles[2].name == "나머지 4개")
        #expect(tiles.reduce(0) { $0 + $1.size } == node.allocatedSize)
    }

    @Test func overflowIsMergedIntoRemainder() {
        let children = (1...10).map { DirectoryNode(name: "d\($0)", directAllocatedSize: Int64($0)) }
        let node = DirectoryNode(name: "n", children: children)

        let tiles = TreemapTile.tiles(for: node, path: "/n", maxTiles: 4)

        #expect(tiles.count == 4)
        #expect(tiles.map(\.size) == [10, 9, 8, 28])
        #expect(tiles.last?.kind == .remainder)
        #expect(tiles.last?.name == "나머지 7개")
        #expect(tiles.reduce(0) { $0 + $1.size } == node.allocatedSize)
    }

    private func threeDirectories(directAllocatedSize: Int64 = 0, directFileCount: Int = 0) -> DirectoryNode {
        DirectoryNode(
            name: "n", directAllocatedSize: directAllocatedSize, directFileCount: directFileCount,
            children: [
                DirectoryNode(name: "a", directAllocatedSize: 3),
                DirectoryNode(name: "b", directAllocatedSize: 2),
                DirectoryNode(name: "c", directAllocatedSize: 1),
            ])
    }

    @Test func exactlyMaxTilesWithoutRemainderKeepsAllTiles() {
        let tiles = TreemapTile.tiles(for: threeDirectories(), path: "/n", maxTiles: 3)

        #expect(tiles.map(\.name) == ["a", "b", "c"])
        #expect(tiles.map(\.size) == [3, 2, 1])
        #expect(tiles.allSatisfy { $0.kind == .directory })
    }

    @Test func exactlyMaxTilesWithRemainderMergesLastTileIntoRemainder() {
        let node = threeDirectories(directAllocatedSize: 5, directFileCount: 2)

        let tiles = TreemapTile.tiles(for: node, path: "/n", maxTiles: 3)

        #expect(tiles.map(\.size) == [3, 2, 6])
        #expect(tiles.last?.kind == .remainder)
        #expect(tiles.last?.name == "나머지 3개")
        #expect(tiles.reduce(0) { $0 + $1.size } == node.allocatedSize)
    }

    @Test func maxTilesOneMergesEverythingIntoRemainder() {
        let tiles = TreemapTile.tiles(for: threeDirectories(), path: "/n", maxTiles: 1)

        #expect(tiles.count == 1)
        #expect(tiles[0].kind == .remainder)
        #expect(tiles[0].size == 6)
        #expect(tiles[0].name == "나머지 3개")
    }

    @Test func nonPositiveMaxTilesIsClampedToOne() {
        let tiles = TreemapTile.tiles(for: threeDirectories(), path: "/n", maxTiles: 0)

        #expect(tiles.map(\.kind) == [.remainder])
        #expect(tiles.map(\.size) == [6])
    }

    @Test func equalSizesSortByPathAndRootPathHasNoDoubleSlash() {
        let node = DirectoryNode(
            name: "/",
            children: [DirectoryNode(name: "b", directAllocatedSize: 10)],
            largeFiles: [FileLeaf(name: "a", allocatedSize: 10, modificationDate: .distantPast)])

        let tiles = TreemapTile.tiles(for: node, path: "/")

        #expect(tiles.map(\.path) == ["/a", "/b"])
        #expect(tiles.map(\.kind) == [.file, .directory])
    }
}
