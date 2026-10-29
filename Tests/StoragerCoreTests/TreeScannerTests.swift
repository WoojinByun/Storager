import Darwin
import Foundation
import Synchronization
import Testing
@testable import StoragerCore

struct TreeScannerTests {
    func scan(_ tree: TempTree, options: ScanOptions = ScanOptions()) async throws -> DirectoryNode {
        try await TreeScanner(rootPath: tree.path, options: options).scan().root
    }

    /// (경로, 크기) 를 모든 노드에 대해 모은다. 결정성 비교용.
    func sizes(of root: DirectoryNode) -> [String: Int64] {
        var all: [String: Int64] = [:]
        root.walk(path: "") { path, node in
            all[path] = node.allocatedSize
            return true
        }
        return all
    }

    @Test func sumsAllocatedAndLogicalSizesRecursively() async throws {
        let tree = try TempTree()
        try tree.file("top.bin", bytes: 5_000)
        try tree.file("a/one.bin", bytes: 70_000)
        try tree.file("a/b/two.bin", bytes: 300_000)
        try tree.file("c/three.bin", bytes: 1)

        let root = try await scan(tree)

        let expected = ["top.bin", "a/one.bin", "a/b/two.bin", "c/three.bin"].map(tree.allocated).reduce(0, +)
        #expect(root.allocatedSize == expected)
        #expect(root.logicalSize == 375_001)
        #expect(root.fileCount == 4)
        #expect(root.descendant(at: ["a"])?.allocatedSize == tree.allocated("a/one.bin") + tree.allocated("a/b/two.bin"))
        #expect(root.children.map(\.name) == ["a", "c"])
    }

    @Test func hardLinkedFileIsCountedOnce() async throws {
        let tree = try TempTree()
        try tree.file("b/orig.bin", bytes: 200_000)
        try tree.hardLink("a/link.bin", to: "b/orig.bin")

        let result = try await TreeScanner(rootPath: tree.path).scan()

        #expect(result.root.allocatedSize == tree.allocated("b/orig.bin"))
        #expect(result.root.logicalSize == 200_000)
        // 귀속은 사전순으로 가장 작은 경로(a/link.bin)의 부모. 파일 수는 링크마다 센다.
        #expect(result.root.child(named: "a")?.allocatedSize == tree.allocated("b/orig.bin"))
        #expect(result.root.child(named: "b")?.allocatedSize == 0)
        #expect(result.root.fileCount == 2)
        #expect(result.hardLinkOwners == [tree.fileID("b/orig.bin"): tree.path + "/a/link.bin"])
    }

    @Test func hardLinkAttributionIsDeterministicAndPicksSmallestPath() async throws {
        let tree = try TempTree()
        // 원본은 d, 링크는 c·b·top 에. 귀속은 사전순 최소 경로인 b/... 여야 한다.
        for index in 0..<40 {
            try tree.file("d/f\(index).bin", bytes: 8_192)
            for directory in ["c", "b/deep"] {
                try tree.hardLink("\(directory)/f\(index).bin", to: "d/f\(index).bin")
            }
        }
        try tree.file("d/big.bin", bytes: 300_000)
        try tree.hardLink("c/big.bin", to: "d/big.bin")
        let options = ScanOptions(leafThreshold: 200_000)
        let scanner = TreeScanner(rootPath: tree.path, options: options)

        let first = try await scanner.scan()
        for _ in 0..<9 {
            let again = try await scanner.scan()
            #expect(sizes(of: again.root) == sizes(of: first.root))
            #expect(again.hardLinkOwners == first.hardLinkOwners)
        }

        let small = (0..<40).map { tree.allocated("d/f\($0).bin") }.reduce(0, +)
        #expect(first.root.descendant(at: ["b", "deep"])?.allocatedSize == small)
        #expect(first.root.child(named: "c")?.allocatedSize == tree.allocated("d/big.bin"))
        #expect(first.root.child(named: "c")?.largeFiles.map(\.name) == ["big.bin"])
        #expect(first.root.child(named: "d")?.allocatedSize == 0)
        #expect(first.root.child(named: "d")?.largeFiles.isEmpty == true)
        #expect(first.root.child(named: "d")?.fileCount == 41)
        #expect(first.hardLinkOwners[tree.fileID("d/f7.bin")] == tree.path + "/b/deep/f7.bin")
        #expect(first.hardLinkOwners[tree.fileID("d/big.bin")] == tree.path + "/c/big.bin")
        #expect(first.hardLinkOwners.count == 41)
    }

    @Test func symbolicLinksAreNotFollowed() async throws {
        let outside = try TempTree()
        try outside.file("huge.bin", bytes: 500_000)
        let tree = try TempTree()
        try tree.file("small.bin", bytes: 10)
        try tree.symlink("linkdir", to: outside.path)
        try tree.symlink("linkfile", to: outside.path + "/huge.bin")

        let root = try await scan(tree)

        #expect(root.allocatedSize == tree.allocated("small.bin"))
        #expect(root.children.isEmpty)
    }

    @Test func symlinkedRootIsResolved() async throws {
        let tree = try TempTree()
        try tree.file("a/x.bin", bytes: 30_000)
        let holder = try TempTree()
        try holder.symlink("home-link", to: tree.path)

        let scanner = TreeScanner(rootPath: holder.path + "/home-link")
        let result = try await scanner.scan()

        #expect(scanner.rootPath == tree.path)
        #expect(result.rootPath == tree.path)
        #expect(result.root.allocatedSize == tree.allocated("a/x.bin"))
    }

    @Test func onlyFilesAtOrAboveThresholdBecomeLeaves() async throws {
        let tree = try TempTree()
        try tree.file("d/big.bin", bytes: 2_000_000)
        try tree.file("d/small.bin", bytes: 100_000)

        let root = try await scan(tree, options: ScanOptions(leafThreshold: 1_000_000))

        let leaves = try #require(root.child(named: "d")).largeFiles
        #expect(leaves.map(\.name) == ["big.bin"])
        #expect(leaves.first?.allocatedSize == tree.allocated("d/big.bin"))
    }

    @Test func excludedPathsAreSkipped() async throws {
        let tree = try TempTree()
        try tree.file("keep/a.bin", bytes: 1_000)
        try tree.file("skip/b.bin", bytes: 900_000)
        try tree.file("keep/inner-skip/c.bin", bytes: 900_000)

        let options = ScanOptions(excludedPaths: [tree.path + "/skip", tree.path + "/keep/inner-skip/"])
        let root = try await scan(tree, options: options)

        #expect(root.child(named: "skip") == nil)
        #expect(root.descendant(at: ["keep", "inner-skip"]) == nil)
        #expect(root.allocatedSize == tree.allocated("keep/a.bin"))
    }

    @Test func excludedPathsMatchThroughSymlinkedAncestors() async throws {
        let tree = try TempTree()
        try tree.file("keep/a.bin", bytes: 1_000)
        try tree.file("skip/b.bin", bytes: 900_000)
        let holder = try TempTree()
        try holder.symlink("alias", to: tree.path)

        // 제외 경로는 심볼릭 링크(alias)를 거친 표기, 루트는 실제 경로
        let options = ScanOptions(excludedPaths: [holder.path + "/alias/skip"])
        let root = try await scan(tree, options: options)

        #expect(options.excludedPaths == [tree.path + "/skip"])
        #expect(root.child(named: "skip") == nil)
    }

    @Test func accessDeniedDirectoryIsMarkedAndScanContinues() async throws {
        let tree = try TempTree()
        try tree.file("locked/secret.bin", bytes: 1_000)
        try tree.file("open/ok.bin", bytes: 1_000)
        chmod(tree.path + "/locked", 0o000)

        let root = try await scan(tree)

        #expect(root.child(named: "locked")?.accessDenied == true)
        #expect(root.child(named: "locked")?.readFailed == false)
        #expect(root.child(named: "open")?.allocatedSize == tree.allocated("open/ok.bin"))
        #expect(root.accessDeniedCount == 1)
    }

    @Test func otherReadErrorsAreMarkedReadFailed() throws {
        let tree = try TempTree()
        try tree.file("bad/x.bin", bytes: 1_000)
        try tree.file("empty/.keep", bytes: 0)
        try FileManager.default.removeItem(atPath: tree.path + "/empty/.keep")
        let badPath = tree.path + "/bad"
        let scanner = DirectoryScanner(options: ScanOptions(), deviceID: 0) { path throws(DirectoryReadError) in
            if path == badPath { throw .posix(EIO) }
            return try BulkDirectoryReader.read(directoryPath: path)
        }
        var hardLinks: [HardLinkFile] = []
        var skipped: [String] = []

        let bad = try #require(try scanner.scan(path: badPath, name: "bad", ownModification: .distantPast,
                                                hardLinks: &hardLinks, permissionSkipped: &skipped))
        let empty = try #require(try scanner.scan(path: tree.path + "/empty", name: "empty",
                                                  ownModification: .distantPast, hardLinks: &hardLinks,
                                                  permissionSkipped: &skipped))

        #expect(bad.readFailed)
        #expect(bad.accessDenied == false)
        #expect(empty.readFailed == false)
    }

    @Test func markerFilesAreRecorded() async throws {
        let tree = try TempTree()
        try tree.file("proj/package.json", bytes: 2)
        try tree.file("proj/README.md", bytes: 2)

        let root = try await scan(tree)

        #expect(root.child(named: "proj")?.markers == ["package.json"])
    }

    @Test func ownMarkerFileIsRecordedOnTheDirectoryItself() async throws {
        let tree = try TempTree()
        try tree.file("proj/venv/pyvenv.cfg", bytes: 2)

        let root = try await scan(tree)

        #expect(root.child(named: "proj")?.markers == [])
        #expect(root.child(named: "proj")?.child(named: "venv")?.markers == ["pyvenv.cfg"])
    }

    @Test func progressCountsTopLevelDirectories() async throws {
        let tree = try TempTree()
        for name in ["a", "b", "c", "d", "e", "f"] {
            try tree.file("\(name)/x.bin", bytes: 10)
        }
        let reports = Mutex<[ScanProgress]>([])

        _ = try await TreeScanner(rootPath: tree.path).scan { progress in
            reports.withLock { $0.append(progress) }
        }

        let all = reports.withLock { $0 }
        #expect(all.first == ScanProgress(completed: 0, total: 6))
        #expect(all.last == ScanProgress(completed: 6, total: 6))
        #expect(all.count == 7)
    }

    @Test func cancelledScanThrowsCancellationError() async throws {
        let tree = try TempTree()
        try tree.file("a/x.bin", bytes: 10)
        let scanner = TreeScanner(rootPath: tree.path)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scanner.scan()
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func rescanMeasuresOneSubtreeOrReturnsNilWhenGone() async throws {
        let tree = try TempTree()
        try tree.file("a/x.bin", bytes: 50_000)
        let scanner = TreeScanner(rootPath: tree.path)
        let full = try await scanner.scan()

        try tree.file("a/y.bin", bytes: 50_000)
        let rescanned = try scanner.rescan(path: tree.path + "/a", previous: full)
        let node = try #require(rescanned.node)
        #expect(rescanned.path == tree.path + "/a")
        #expect(node.name == "a")
        #expect(node.allocatedSize == tree.allocated("a/x.bin") + tree.allocated("a/y.bin"))

        try FileManager.default.removeItem(atPath: tree.path + "/a")
        #expect(try scanner.rescan(path: tree.path + "/a", previous: full).node == nil)
    }

    @Test func rescanDoesNotDoubleCountHardLinkOwnedOutsideSubtree() async throws {
        let tree = try TempTree()
        try tree.file("a/orig", bytes: 1_000_000)
        try tree.hardLink("b/link", to: "a/orig")
        let scanner = TreeScanner(rootPath: tree.path)
        let full = try await scanner.scan()
        let size = tree.allocated("a/orig")
        #expect(full.root.allocatedSize == size)

        for name in ["b", "a"] {
            var copy = full
            #expect(copy.apply(try scanner.rescan(path: tree.path + "/" + name, previous: full)))
            #expect(copy.root.allocatedSize == size)
            #expect(sizes(of: copy.root) == sizes(of: full.root))
            #expect(copy.hardLinkOwners == full.hardLinkOwners)
        }
    }

    @Test func rescanAfterOwnerIsDeletedIsApproximateUntilNextFullScan() async throws {
        let tree = try TempTree()
        try tree.file("a/orig", bytes: 1_000_000)
        try tree.hardLink("b/link", to: "a/orig")
        let scanner = TreeScanner(rootPath: tree.path)
        var scan = try await scanner.scan()
        let id = tree.fileID("a/orig")
        #expect(scan.hardLinkOwners[id] == tree.path + "/a/orig")

        try FileManager.default.removeItem(atPath: tree.path + "/a/orig")
        scan.apply(try scanner.rescan(path: tree.path + "/a", previous: scan))

        // 귀속 쪽(a/orig)이 지워져 서브트리 밖 짝(b/link)은 다음 전체 스캔까지 어디에도 세지 않는다 (문서화한 근사)
        #expect(scan.root.allocatedSize == 0)
        #expect(scan.hardLinkOwners[id] == nil)
        let fresh = try await scanner.scan()
        #expect(fresh.root.allocatedSize == tree.allocated("b/link"))
    }

    @Test func rescanAttributesLinksWhollyInsideSubtree() async throws {
        let tree = try TempTree()
        try tree.file("a/x/orig", bytes: 100_000)
        let scanner = TreeScanner(rootPath: tree.path)
        var scan = try await scanner.scan()

        // 전체 스캔 뒤 서브트리 안에 새 하드링크가 생겼다: 맵에 없으므로 서브트리 안 사전순 최소 경로에 귀속한다
        try tree.hardLink("a/w/link", to: "a/x/orig")
        scan.apply(try scanner.rescan(path: tree.path + "/a", previous: scan))

        #expect(scan.root.allocatedSize == tree.allocated("a/x/orig"))
        #expect(scan.root.descendant(at: ["a", "w"])?.allocatedSize == tree.allocated("a/x/orig"))
        #expect(scan.hardLinkOwners == [tree.fileID("a/x/orig"): tree.path + "/a/w/link"])
    }

    @Test func failedApplyKeepsTreeAndHardLinkOwners() async throws {
        let tree = try TempTree()
        try tree.file("a/orig", bytes: 1_000_000)
        try tree.hardLink("b/link", to: "a/orig")
        let scanner = TreeScanner(rootPath: tree.path)
        var scan = try await scanner.scan()
        let before = scan
        let id = tree.fileID("a/orig")
        #expect(scan.hardLinkOwners[id] == tree.path + "/a/orig")

        // 트리에 없는 경로(대소문자 불일치)와 이름이 다른 노드: 새 귀속 조각을 담아 와도 반영하지 않는다.
        // 두 번째는 기존 귀속(a/orig)이 서브트리 안을 가리키는 경로라, 먼저 필터하면 항목이 사라진다.
        let missing = SubtreeRescan(rootPath: scan.rootPath, path: tree.path + "/A", node: nil,
                                    hardLinkOwners: [999: tree.path + "/A/x"])
        let mismatched = SubtreeRescan(rootPath: scan.rootPath, path: tree.path + "/a", node: DirectoryNode(name: "other"),
                                       hardLinkOwners: [999: tree.path + "/a/x"])
        #expect(scan.apply(missing) == false)
        #expect(scan.apply(mismatched) == false)

        #expect(scan == before)
        #expect(scan.hardLinkOwners[id] == tree.path + "/a/orig")
    }

    @Test func rescanRejectsPathsOutsideRootOrExcluded() async throws {
        let tree = try TempTree()
        try tree.file("a/x.bin", bytes: 10)
        try tree.file("skip/y.bin", bytes: 10)
        let other = try TempTree()
        try other.file("z/z.bin", bytes: 10)
        let scanner = TreeScanner(rootPath: tree.path, options: ScanOptions(excludedPaths: [tree.path + "/skip"]))
        let full = try await scanner.scan()

        #expect(throws: RescanError.outsideRoot(other.path + "/z")) {
            try scanner.rescan(path: other.path + "/z", previous: full)
        }
        #expect(throws: RescanError.outsideRoot(tree.path)) {
            try scanner.rescan(path: tree.path, previous: full)
        }
        #expect(throws: RescanError.excluded(tree.path + "/skip/inner")) {
            try scanner.rescan(path: tree.path + "/skip/inner", previous: full)
        }
    }

    @Test func excludedPathsEqualToOrAboveRootAreIgnored() async throws {
        let tree = try TempTree()
        try tree.file("a/x.bin", bytes: 10_000)
        try tree.file("skip/y.bin", bytes: 10_000)
        let parent = (tree.path as NSString).deletingLastPathComponent
        // 루트 자신·루트의 조상·루트 안쪽 제외 경로를 함께 넣는다 (설정 창이 막지만 이미 저장된 값일 수 있다)
        let options = ScanOptions(excludedPaths: [tree.path, parent, "/", tree.path + "/skip"])
        let scanner = TreeScanner(rootPath: tree.path, options: options)
        #expect(scanner.options.excludedPaths == [tree.path + "/skip"])

        var scan = try await scanner.scan()
        #expect(scan.root.child(named: "skip") == nil)
        #expect(scan.root.allocatedSize == tree.allocated("a/x.bin"))

        // 전체 스캔과 같은 의미로 부분 재스캔도 동작한다: 안쪽 제외 경로만 거부된다
        try FileManager.default.removeItem(atPath: tree.path + "/a/x.bin")
        let rescanned = try scanner.rescan(path: tree.path + "/a", previous: scan)
        let didApply = scan.apply(rescanned)
        #expect(didApply)
        #expect(scan.root.allocatedSize == 0)
        #expect(throws: RescanError.excluded(tree.path + "/skip")) {
            try scanner.rescan(path: tree.path + "/skip", previous: scan)
        }
    }

    @Test func rescanResolvesSymlinkedAncestorsOfPath() async throws {
        let tree = try TempTree()
        try tree.file("a/x.bin", bytes: 10_000)
        let holder = try TempTree()
        try holder.symlink("alias", to: tree.path)
        let scanner = TreeScanner(rootPath: tree.path)
        let full = try await scanner.scan()

        let rescanned = try scanner.rescan(path: holder.path + "/alias/a", previous: full)
        #expect(rescanned.path == tree.path + "/a")
        #expect(rescanned.node?.allocatedSize == tree.allocated("a/x.bin"))

        try FileManager.default.removeItem(atPath: tree.path + "/a")
        let gone = try scanner.rescan(path: holder.path + "/alias/a", previous: full)
        #expect(gone.path == tree.path + "/a")
        #expect(gone.node == nil)
    }
}
