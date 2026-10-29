import Foundation
import Testing
@testable import StoragerCore

struct TreeEntryTests {
    private let date = Date(timeIntervalSince1970: 1_000)

    @Test func childrenMergeDirectoriesFilesAndRemainderBySizeDescending() {
        let node = DirectoryNode(
            name: "n", directAllocatedSize: 330, directFileCount: 6,
            children: [DirectoryNode(name: "big", directAllocatedSize: 500, directFileCount: 3),
                       DirectoryNode(name: "small", directAllocatedSize: 10, directFileCount: 1)],
            largeFiles: [FileLeaf(name: "movie.mov", allocatedSize: 200, modificationDate: date),
                         FileLeaf(name: "a.bin", allocatedSize: 80, modificationDate: date)])

        let entries = TreeEntry.children(of: node, path: "/h/n")

        #expect(entries.map(\.name) == ["big", "movie.mov", "a.bin", "나머지 파일 4개", "small"])
        #expect(entries.map(\.kind) == [.directory, .file, .file, .remainder, .directory])
        #expect(entries.map(\.size) == [500, 200, 80, 50, 10])
        #expect(entries.map(\.path) == ["/h/n/big", "/h/n/movie.mov", "/h/n/a.bin", "/h/n", "/h/n/small"])
        #expect(entries.map(\.fileCount) == [3, nil, nil, 4, 1])
        #expect(entries.reduce(0) { $0 + $1.size } == node.allocatedSize)
        // 나머지 줄의 id 는 부모 경로(실제 경로)와 겹치지 않는다
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(entries[3].id != "/h/n")
        #expect(!entries[3].hasRealPath)
    }

    @Test func equalSizesAreOrderedByNameAcrossDirectoriesAndFiles() {
        let node = DirectoryNode(
            name: "n", directAllocatedSize: 20, directFileCount: 2,
            children: [DirectoryNode(name: "b", directAllocatedSize: 10), DirectoryNode(name: "d", directAllocatedSize: 10)],
            largeFiles: [FileLeaf(name: "a", allocatedSize: 10, modificationDate: date),
                         FileLeaf(name: "c", allocatedSize: 10, modificationDate: date)])

        #expect(TreeEntry.children(of: node, path: "/n").map(\.name) == ["a", "b", "c", "d"])
    }

    @Test func remainderWithSameSizeGoesAfterRealEntries() {
        let node = DirectoryNode(name: "n", directAllocatedSize: 5, directFileCount: 2,
                                 children: [DirectoryNode(name: "x", directAllocatedSize: 5)])

        #expect(TreeEntry.children(of: node, path: "/n").map(\.kind) == [.directory, .remainder])
    }

    @Test func remainderIsOmittedWithoutSmallFiles() {
        let node = DirectoryNode(name: "n", directAllocatedSize: 100, directFileCount: 1,
                                 largeFiles: [FileLeaf(name: "f", allocatedSize: 100, modificationDate: date)])

        #expect(TreeEntry.children(of: node, path: "/n").map(\.kind) == [.file])
    }

    @Test func zeroSizeSmallFilesStillGetARemainderRow() {
        // iCloud 미다운로드 파일처럼 크기 0 인 파일도 개수로는 보여 준다
        let node = DirectoryNode(name: "n", directFileCount: 3)

        let entries = TreeEntry.children(of: node, path: "/n")
        #expect(entries.map(\.name) == ["나머지 파일 3개"])
        #expect(entries.first?.share == 0)
    }

    @Test func unsortedChildrenAreSortedDefensively() {
        var node = DirectoryNode(name: "n", children: [DirectoryNode(name: "a", directAllocatedSize: 1),
                                                       DirectoryNode(name: "b", directAllocatedSize: 9)])
        node.children.reverse()  // [a(1), b(9)]: 내림차순이 아니다

        #expect(TreeEntry.children(of: node, path: "/n").map(\.name) == ["b", "a"])
    }

    @Test func sharesAreRelativeToParentAndClamped() {
        let node = DirectoryNode(name: "n", children: [DirectoryNode(name: "a", directAllocatedSize: 75),
                                                       DirectoryNode(name: "b", directAllocatedSize: 25)])

        #expect(TreeEntry.children(of: node, path: "/n").map(\.share) == [0.75, 0.25])
        #expect(TreeEntry.share(10, of: 0) == 0)
        #expect(TreeEntry.share(-1, of: 10) == 0)
        #expect(TreeEntry.share(20, of: 10) == 1)
        #expect(TreeEntry.root(node, path: "/n", name: "홈").share == 1)
        #expect(TreeEntry.root(node, path: "/n", name: "홈").fileCount == node.fileCount)
    }

    @Test func rootPathDoesNotDoubleSlash() {
        let node = DirectoryNode(name: "/", children: [DirectoryNode(name: "a", directAllocatedSize: 1)])

        #expect(TreeEntry.children(of: node, path: "/").map(\.path) == ["/a"])
    }

    @Test func manyChildrenStayLinear() {
        // 수만 개의 자식도 이미 정렬된 두 목록의 병합이라 바로 끝난다
        let children = (0..<50_000).map { DirectoryNode(name: String(format: "d%05d", $0), directAllocatedSize: Int64(50_000 - $0)) }
        let node = DirectoryNode(name: "n", children: children)

        let entries = TreeEntry.children(of: node, path: "/n")
        #expect(entries.count == 50_000)
        #expect(entries.first?.name == "d00000")
        #expect(entries.last?.name == "d49999")
    }

    @Test func treemapComponentsPointAtTheFolder() {
        let dir = TreeEntry(id: "/h/a/b", name: "b", path: "/h/a/b", size: 1, kind: .directory, fileCount: 0,
                            modificationDate: nil, share: 0)
        let file = TreeEntry(id: "/h/a/f", name: "f", path: "/h/a/f", size: 1, kind: .file, fileCount: nil,
                             modificationDate: nil, share: 0)
        let rest = TreeEntry(id: "/h/a\0rest", name: "나머지 파일 1개", path: "/h/a", size: 1, kind: .remainder,
                             fileCount: 1, modificationDate: nil, share: 0)
        let outside = TreeEntry(id: "/x/y", name: "y", path: "/x/y", size: 1, kind: .directory, fileCount: 0,
                                modificationDate: nil, share: 0)
        let topFile = TreeEntry(id: "/h/f", name: "f", path: "/h/f", size: 1, kind: .file, fileCount: nil,
                                modificationDate: nil, share: 0)

        #expect(dir.treemapComponents(homePath: "/h") == ["a", "b"])
        #expect(file.treemapComponents(homePath: "/h") == ["a"])
        #expect(rest.treemapComponents(homePath: "/h") == ["a"])
        #expect(topFile.treemapComponents(homePath: "/h") == [])
        #expect(outside.treemapComponents(homePath: "/h") == nil)
        #expect(TreeEntry.parentPath(of: "/a") == "/")
    }

    @Test func menuTargetsFollowSelectionOnlyWhenClickedRowIsSelected() {
        let selected = IndexSet([1, 3, 4])

        #expect(TreeEntry.menuTargetRows(clickedRow: 3, selectedRows: selected) == [1, 3, 4])
        #expect(TreeEntry.menuTargetRows(clickedRow: 2, selectedRows: selected) == [2])
        #expect(TreeEntry.menuTargetRows(clickedRow: -1, selectedRows: selected) == [])
        #expect(TreeEntry.menuTargetRows(clickedRow: 0, selectedRows: []) == [0])
    }
}
