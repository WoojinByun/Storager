import Foundation
import Testing
@testable import StoragerCore

struct DirectoryNodeTests {
    let early = Date(timeIntervalSince1970: 1_000)
    let late = Date(timeIntervalSince1970: 2_000)

    func sample() -> DirectoryNode {
        let a = DirectoryNode(name: "a", directAllocatedSize: 100, directLogicalSize: 90, directFileCount: 2,
                              directNewestModification: early)
        let b = DirectoryNode(name: "b", directAllocatedSize: 300, directLogicalSize: 250, directFileCount: 1,
                              directNewestModification: late,
                              largeFiles: [FileLeaf(name: "big", allocatedSize: 300, modificationDate: late)])
        return DirectoryNode(name: "root", directAllocatedSize: 10, directLogicalSize: 10, directFileCount: 1,
                             directNewestModification: early, children: [a, b])
    }

    @Test func totalsIncludeChildrenAndSortBySize() {
        let root = sample()
        #expect(root.allocatedSize == 410)
        #expect(root.logicalSize == 350)
        #expect(root.fileCount == 4)
        #expect(root.newestModification == late)
        #expect(root.children.map(\.name) == ["b", "a"])
    }

    @Test func descendantFindsByComponents() {
        let root = sample()
        #expect(root.descendant(at: [])?.name == "root")
        #expect(root.descendant(at: ["a"])?.allocatedSize == 100)
        #expect(root.descendant(at: ["missing"]) == nil)
    }

    @Test func replacingDescendantUpdatesAncestorTotals() {
        var root = DirectoryNode(name: "root", children: [sample()])
        let smaller = DirectoryNode(name: "b", directAllocatedSize: 30, directLogicalSize: 30, directFileCount: 1)

        let changed = root.replaceDescendant(at: ["root", "b"], with: smaller)

        #expect(changed)

        #expect(root.allocatedSize == 140)
        #expect(root.children[0].allocatedSize == 140)
        #expect(root.descendant(at: ["root", "b"])?.allocatedSize == 30)
    }

    @Test func replacingWithNilRemovesNode() {
        var root = sample()
        let changed = root.replaceDescendant(at: ["b"], with: nil)
        #expect(changed)
        #expect(root.allocatedSize == 110)
        #expect(root.child(named: "b") == nil)
    }

    @Test func replacingMissingIntermediateDoesNothing() {
        var root = sample()
        let changed = root.replaceDescendant(at: ["zzz", "b"], with: nil)
        #expect(changed == false)
        #expect(root.allocatedSize == 410)
    }

    @Test func walkBuildsPathsAndCanSkipSubtrees() {
        var root = sample()
        root.children[0].children = [DirectoryNode(name: "deep")]
        var seen: [String] = []
        root.walk(path: "/r") { path, node in
            seen.append(path)
            return node.name != "b"
        }
        #expect(seen == ["/r", "/r/b", "/r/a"])
    }

    @Test func largestFilesAndDirectoriesCarryFullPaths() {
        let root = sample()
        #expect(root.largestFiles(path: "/r", limit: 10).map(\.path) == ["/r/b/big"])
        #expect(root.largestDirectories(path: "/r", limit: 1).map(\.path) == ["/r/b"])
    }

    @Test func accessDeniedCountIsRecursive() {
        let denied = DirectoryNode(name: "x", accessDenied: true)
        let root = DirectoryNode(name: "r", children: [DirectoryNode(name: "y", children: [denied]), denied])
        #expect(root.accessDeniedCount == 2)
    }

    @Test func walkFromFilesystemRootDoesNotDoubleSlash() {
        let root = DirectoryNode(name: "/", children: [DirectoryNode(name: "a", children: [DirectoryNode(name: "b")])])
        var seen: [String] = []
        root.walk(path: "/") { path, _ in
            seen.append(path)
            return true
        }
        #expect(seen == ["/", "/a", "/a/b"])
    }

    @Test func largestEntriesFromFilesystemRootDoNotDoubleSlash() {
        let leaf = FileLeaf(name: "big", allocatedSize: 5, modificationDate: late)
        let a = DirectoryNode(name: "a", directAllocatedSize: 5, largeFiles: [leaf])
        let root = DirectoryNode(name: "/", children: [a])
        #expect(root.largestFiles(path: "/", limit: 10).map(\.path) == ["/a/big"])
        #expect(root.largestDirectories(path: "/", limit: 10).map(\.path) == ["/a"])
    }

    @Test func replacingWithMismatchedNameDoesNothing() {
        var root = sample()
        let before = root
        let changed = root.replaceDescendant(at: ["b"], with: DirectoryNode(name: "other", directAllocatedSize: 1))
        #expect(changed == false)
        #expect(root == before)
    }

    @Test func removingMissingLeafDoesNothing() {
        var root = sample()
        let before = root
        let changed = root.replaceDescendant(at: ["missing"], with: nil)
        #expect(changed == false)
        #expect(root == before)
    }

    @Test func emptyComponentsDoNothing() {
        var root = sample()
        let before = root
        #expect(root.replaceDescendant(at: [], with: DirectoryNode(name: "root")) == false)
        #expect(root == before)
    }

    @Test func addingNewChildUpdatesAncestorTotalsAndOrder() {
        var root = DirectoryNode(name: "root", children: [sample()])
        let added = DirectoryNode(name: "c", directAllocatedSize: 1_000, directLogicalSize: 900, directFileCount: 3,
                                  directNewestModification: Date(timeIntervalSince1970: 3_000))

        let changed = root.replaceDescendant(at: ["root", "c"], with: added)

        #expect(changed)
        let inner = root.children[0]
        #expect(inner.children.map(\.name) == ["c", "b", "a"])
        #expect(inner.allocatedSize == 1_410)
        #expect(inner.logicalSize == 1_250)
        #expect(inner.fileCount == 7)
        #expect(inner.newestModification == Date(timeIntervalSince1970: 3_000))
        #expect(root.allocatedSize == 1_410)
        #expect(root.logicalSize == 1_250)
        #expect(root.fileCount == 7)
        #expect(root.newestModification == Date(timeIntervalSince1970: 3_000))
    }

    @Test func equalSizesSortByName() {
        let node = DirectoryNode(
            name: "r",
            children: ["c", "a", "b"].map { DirectoryNode(name: $0, directAllocatedSize: 50) },
            largeFiles: ["z", "x", "y"].map { FileLeaf(name: $0, allocatedSize: 7, modificationDate: early) })
        #expect(node.children.map(\.name) == ["a", "b", "c"])
        #expect(node.largeFiles.map(\.name) == ["x", "y", "z"])
    }

    @Test func joinDoesNotDuplicateSlashForRootParent() {
        #expect(DirectoryNode.join("/", "a") == "/a")
    }

    @Test func joinAddsSeparatorForNonRootParent() {
        #expect(DirectoryNode.join("/x", "a") == "/x/a")
    }

    @Test func equalSizeLargestEntriesSortByPath() {
        // 순회 순서(루트 파일 → 자식)와 경로 순서가 다르도록 짠다: "/r/a/x" < "/r/z", "/r/a-b" < "/r/a/x"
        let inner = DirectoryNode(name: "a", children: [DirectoryNode(
            name: "x", largeFiles: [FileLeaf(name: "f", allocatedSize: 7, modificationDate: early)])])
        let root = DirectoryNode(
            name: "r", children: [inner],
            largeFiles: [FileLeaf(name: "z", allocatedSize: 7, modificationDate: early)])
        #expect(root.largestFiles(path: "/r", limit: 10).map(\.path) == ["/r/a/x/f", "/r/z"])

        let dirs = DirectoryNode(name: "r", children: [
            DirectoryNode(name: "a", children: [DirectoryNode(name: "x", directAllocatedSize: 50)]),
            DirectoryNode(name: "a-b", directAllocatedSize: 50)])
        #expect(dirs.largestDirectories(path: "/r", limit: 10).map(\.path) == ["/r/a", "/r/a-b", "/r/a/x"])
    }

    @Test func negativeLimitReturnsEmpty() {
        let root = sample()
        #expect(root.largestFiles(path: "/r", limit: -1).isEmpty)
        #expect(root.largestDirectories(path: "/r", limit: -1).isEmpty)
    }
}

struct TopKSelectionTests {
    /// 결정적 의사 난수 (SplitMix64)
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 크기를 작은 값 몇 개에서 골라 같은 크기(동점)가 많은 무작위 트리. 이름도 접두어가 겹치게(`a`, `a-b`, `ab`) 고른다
    func randomTree(_ generator: inout SeededGenerator, depth: Int, name: String) -> DirectoryNode {
        let names = ["a", "a-b", "ab", "b", "B", "c", "é", "e\u{301}x", "z"]
        let sizes: [Int64] = [0, 0, 4_096, 4_096, 8_192, 1_000_000]
        let childCount = depth == 0 ? 0 : Int.random(in: 0...4, using: &generator)
        let childNames = Array(Set((0..<childCount).map { _ in names.randomElement(using: &generator)! })).sorted()
        let children = childNames.map { randomTree(&generator, depth: depth - 1, name: $0) }
        let fileNames = Array(Set((0..<Int.random(in: 0...3, using: &generator)).map { _ in
            names.randomElement(using: &generator)! + ".bin"
        })).sorted()
        let files = fileNames.map {
            FileLeaf(name: $0, allocatedSize: sizes.randomElement(using: &generator)!,
                     modificationDate: Date(timeIntervalSince1970: 0))
        }
        return DirectoryNode(name: name, directAllocatedSize: sizes.randomElement(using: &generator)!,
                             children: children, largeFiles: files)
    }

    /// 예전 구현: 모든 경로를 만들어 전체 정렬한 뒤 앞 `limit` 개
    func fullSortDirectories(_ root: DirectoryNode, path: String, limit: Int) -> [(path: String, size: Int64)] {
        var all: [(path: String, size: Int64)] = []
        root.walk(path: path) { nodePath, node in
            if nodePath != path { all.append((nodePath, node.allocatedSize)) }
            return true
        }
        all.sort { ($0.size, $1.path) > ($1.size, $0.path) }
        return Array(all.prefix(max(0, limit)))
    }

    func fullSortFiles(_ root: DirectoryNode, path: String, limit: Int) -> [LargeFileEntry] {
        var all: [LargeFileEntry] = []
        root.walk(path: path) { nodePath, node in
            for leaf in node.largeFiles {
                all.append(LargeFileEntry(path: DirectoryNode.join(nodePath, leaf.name),
                                          allocatedSize: leaf.allocatedSize, modificationDate: leaf.modificationDate))
            }
            return true
        }
        all.sort { ($0.allocatedSize, $1.path) > ($1.allocatedSize, $0.path) }
        return Array(all.prefix(max(0, limit)))
    }

    @Test func matchesFullSortOnRandomTreesIncludingTies() {
        var generator = SeededGenerator(state: 7)
        for _ in 0..<100 {
            let root = randomTree(&generator, depth: 5, name: "r")
            for limit in [0, 1, 3, 10, 100, 10_000] {
                for path in ["/r", "/"] {
                    let expected = fullSortDirectories(root, path: path, limit: limit)
                    let actual = root.largestDirectories(path: path, limit: limit)
                    #expect(actual.map(\.path) == expected.map(\.path))
                    #expect(actual.map(\.size) == expected.map(\.size))
                    #expect(root.largestFiles(path: path, limit: limit) == fullSortFiles(root, path: path, limit: limit))
                }
            }
        }
    }

    @Test func topKKeepsBestInOrder() {
        var top = TopK<DirectorySize>(limit: 3, size: \.size, path: \.path)
        let input: [(String, Int64)] = [("/d", 5), ("/a", 5), ("/c", 9), ("/b", 1), ("/e", 5), ("/0", 5)]
        for (path, size) in input where top.mayAccept(size: size) {
            top.insert(DirectorySize(path: path, size: size))
        }
        #expect(top.elements.map(\.path) == ["/c", "/0", "/a"])
        #expect(top.mayAccept(size: 4) == false)
        #expect(top.mayAccept(size: 5))
    }
}
