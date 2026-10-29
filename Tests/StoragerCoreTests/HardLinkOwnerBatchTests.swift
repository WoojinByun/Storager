import Foundation
import Testing
@testable import StoragerCore

struct HardLinkOwnerBatchTests {
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

    /// 예전 `TreeScan.apply` 의 귀속 맵 갱신: 재스캔 경로 안을 가리키는 항목을 지우고 조각을 병합한다
    func referenceApply(_ owners: inout [UInt64: String], _ rescan: SubtreeRescan) {
        owners = owners.filter { !PathUtil.isSameOrDescendant($0.value, of: rescan.path) }
        owners.merge(rescan.hardLinkOwners) { _, new in new }
    }

    @Test func matchesSequentialApplyOnRandomSequences() {
        // 접두어가 겹치는 이름(`a`, `ab`, `a-b`)과 조상·자손·같은 경로를 섞어 반복 재스캔한다
        let directories = ["/r/a", "/r/ab", "/r/a-b", "/r/a/b", "/r/a/b/c", "/r/b", "/r/b/a", "/r/c"]
        var generator = SeededGenerator(state: 42)
        for _ in 0..<200 {
            var base: [UInt64: String] = [:]
            for id in UInt64(0)..<40 {
                if Bool.random(using: &generator) {
                    base[id] = directories.randomElement(using: &generator)! + "/f\(id)"
                }
            }
            var reference = base
            var batch = HardLinkOwnerBatch()
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                let path = directories.randomElement(using: &generator)!
                var fragment: [UInt64: String] = [:]
                for _ in 0..<Int.random(in: 0...5, using: &generator) {
                    let inside = directories.filter { PathUtil.isSameOrDescendant($0, of: path) }
                    fragment[UInt64.random(in: 0..<40, using: &generator)] =
                        inside.randomElement(using: &generator)! + "/g\(Int.random(in: 0..<9, using: &generator))"
                }
                let rescan = SubtreeRescan(rootPath: "/r", path: path, node: nil, hardLinkOwners: fragment)
                referenceApply(&reference, rescan)
                batch.record(rescan)
                for id in UInt64(0)..<40 {
                    #expect(batch.owner(of: id, in: base) == reference[id])
                }
            }
            var applied = base
            batch.apply(to: &applied)
            #expect(applied == reference)
        }
    }

    @Test func emptyBatchLeavesOwnersUntouched() {
        var owners: [UInt64: String] = [1: "/r/a/f"]
        HardLinkOwnerBatch().apply(to: &owners)
        #expect(owners == [1: "/r/a/f"])
    }

    @Test func rescanAndApplyMatchesSequentialApply() async throws {
        // inode X 를 a1·a2·a3 이 함께 가리킨다 (귀속은 사전순 최소 a1/l). a1 을 지우고 a1, a2, a3 을 차례로 재면
        // a1 재스캔이 귀속을 지우므로 a2 재스캔이 X 를 a2/l 에 새로 귀속해야 한다 (묶음 조회가 앞 변경을 봐야 한다)
        let home = try TempTree()
        try home.file("store/x", bytes: 200_000)
        try home.file("store/y", bytes: 100_000)
        for name in ["a1", "a2", "a3"] {
            try home.hardLink("\(name)/l", to: "store/x")
        }
        try home.hardLink("a2/m", to: "store/y")
        try home.hardLink("b/m", to: "store/y")
        let scanned = try await ScanResult.scan(homePath: home.path, extraRootPaths: [], options: ScanOptions())
        #expect(scanned.homeScan.hardLinkOwners[home.fileID("store/x")] == home.path + "/a1/l")

        try FileManager.default.removeItem(atPath: home.path + "/a1")
        try FileManager.default.removeItem(atPath: home.path + "/a2/m")
        let paths = ["a1", "a2", "a3", "b", "a2"].map { home.path + "/" + $0 } + ["/nonexistent-root/x"]

        var sequential = scanned
        var sequentialCount = 0
        for path in paths {
            if let rescan = try? sequential.rescan(path: path, options: ScanOptions()), sequential.apply(rescan) {
                sequentialCount += 1
            }
        }
        var batched = scanned
        let batchedCount = batched.rescanAndApply(paths: paths, options: ScanOptions())

        #expect(batchedCount == sequentialCount)
        #expect(batchedCount == 5)
        #expect(batched.homeScan == sequential.homeScan)
        #expect(batched.classification.items == sequential.classification.items)
        #expect(batched.homeScan.hardLinkOwners[home.fileID("store/x")] == home.path + "/a2/l")
        #expect(batched.home.descendant(at: ["a2"])?.allocatedSize == home.allocated("store/x"))
    }

    @Test func rescanAndApplyKeepsOwnersWhenApplyFails() async throws {
        // 트리에 없는 경로(스캔 뒤 새로 만든 폴더)는 반영하지 못하므로 귀속 맵도 그대로다
        let home = try TempTree()
        try home.file("store/x", bytes: 200_000)
        try home.hardLink("a/l", to: "store/x")
        var result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [], options: ScanOptions())
        let before = result.homeScan
        try home.dir("new/inner")

        #expect(result.rescanAndApply(paths: [home.path + "/new/inner"], options: ScanOptions()) == 0)
        #expect(result.homeScan == before)
    }

    @Test func rescanAndApplyScalesWithPathsPlusOwners() async throws {
        // 예전에는 경로마다 귀속 맵 전체를 걸러 경로 P × 맵 H 였다. P 와 H 를 함께 4배로 늘리면
        // 묶음 처리는 약 4배, 예전 방식은 약 16배다. 판정식은 plansManyItemsInLinearTime 과 같다 (비율 10배 + 절대 0.5초).
        let home = try TempTree()
        func makeResult(paths count: Int, owners ownerCount: Int) -> (ScanResult, [String]) {
            let children = (0..<count).map { DirectoryNode(name: "p\($0)", directAllocatedSize: 1) }
            let root = DirectoryNode(name: (home.path as NSString).lastPathComponent, children: children)
            var owners: [UInt64: String] = [:]
            for id in 0..<ownerCount {
                // 대부분은 정리 경로 밖(store)을, 일부는 정리 경로 안을 가리킨다
                owners[UInt64(id)] = id % 10 == 0 ? home.path + "/p\(id % count)/f\(id)"
                    : home.path + "/store/\(id % 97)/f\(id)"
            }
            let scan = TreeScan(rootPath: home.path, deviceID: 0, root: root, hardLinkOwners: owners)
            // 디스크에는 p* 가 없으므로 재스캔은 모두 "사라짐" 이다
            return (ScanResult(homeScan: scan, extraRoots: [], classification: .empty, finishedAt: Date()),
                    (0..<count).map { home.path + "/p\($0)" })
        }
        var (small, smallPaths) = makeResult(paths: 300, owners: 30_000)
        var (large, largePaths) = makeResult(paths: 1_200, owners: 120_000)

        let clock = ContinuousClock()
        var smallApplied = 0
        var largeApplied = 0
        let smallElapsed = clock.measure { smallApplied = small.rescanAndApply(paths: smallPaths, options: ScanOptions()) }
        let largeElapsed = clock.measure { largeApplied = large.rescanAndApply(paths: largePaths, options: ScanOptions()) }

        #expect(smallApplied == 300)
        #expect(largeApplied == 1_200)
        #expect(large.home.children.isEmpty)
        #expect(large.homeScan.hardLinkOwners.count == 120_000 - 12_000)
        #expect(large.homeScan.hardLinkOwners.values.allSatisfy { $0.hasPrefix(home.path + "/store/") })
        #expect(largeElapsed < smallElapsed * 10 + .milliseconds(500))
    }
}
