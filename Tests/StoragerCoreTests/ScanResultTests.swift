import Foundation
import Testing
@testable import StoragerCore

struct ScanResultTests {
    @Test func scansHomeAndExtraRootsAndClassifies() async throws {
        let home = try TempTree()
        try home.file("dev/web/package.json", bytes: 2)
        try home.file("dev/web/node_modules/lib/index.js", bytes: 40_000)
        let extra = try TempTree()
        try extra.file("Cargo.toml", bytes: 2)
        try extra.file("target/debug/app", bytes: 60_000)

        let result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [extra.path, "/nonexistent-root"],
                                               options: ScanOptions(), now: { Date(timeIntervalSince1970: 5) })

        #expect(result.homePath == home.path)
        #expect(result.extraRoots.map(\.rootPath) == [extra.path])
        #expect(Set(result.classification.items.map(\.path)) == [
            home.path + "/dev/web/node_modules", extra.path + "/target",
        ])
        #expect(result.finishedAt == Date(timeIntervalSince1970: 5))
    }

    @Test func skipsExtraRootsThatOverlapHome() async throws {
        // 홈의 조상·홈 자신·홈의 자손인 추가 루트는 홈을 두 번 세게 되므로 건너뛴다
        let base = try TempTree()
        try base.file("home/dev/web/package.json", bytes: 2)
        try base.file("home/dev/web/node_modules/lib/index.js", bytes: 40_000)
        let home = base.path + "/home"

        let result = try await ScanResult.scan(homePath: home, extraRootPaths: [base.path, home, home + "/dev"],
                                               options: ScanOptions())

        #expect(result.extraRoots.isEmpty)
        #expect(result.classification.items.map(\.path) == [home + "/dev/web/node_modules"])
    }

    @Test func extraRootConflictWithHome() {
        #expect(ExtraRootConflict.check("/Users/me", homePath: "/Users/me") == .sameAsHome)
        #expect(ExtraRootConflict.check("/Users/me/dev", homePath: "/Users/me") == .insideHome)
        #expect(ExtraRootConflict.check("/Users", homePath: "/Users/me") == .containsHome)
        #expect(ExtraRootConflict.check("/", homePath: "/Users/me") == .containsHome)
        #expect(ExtraRootConflict.check("/Users/meow", homePath: "/Users/me") == nil)
        #expect(ExtraRootConflict.check("/Volumes/Work", homePath: "/Users/me") == nil)
    }

    @Test func extraRootConflictWithOtherExtraRoots() {
        let home = "/Users/me"
        let others = ["/Volumes/Work", "/Volumes/Data/proj"]
        #expect(ExtraRootConflict.check("/Volumes/Work", homePath: home, otherRoots: others) == .duplicate)
        #expect(ExtraRootConflict.check("/Volumes/Work/", homePath: home, otherRoots: others) == .duplicate)
        #expect(ExtraRootConflict.check("/Volumes/Work/app", homePath: home, otherRoots: others) == .insideOtherRoot)
        #expect(ExtraRootConflict.check("/Volumes/Data", homePath: home, otherRoots: others) == .containsOtherRoot)
        #expect(ExtraRootConflict.check("/Volumes/Workshop", homePath: home, otherRoots: others) == nil)
        // 홈과의 겹침이 먼저 판정된다
        #expect(ExtraRootConflict.check("/Users/me/dev", homePath: home, otherRoots: ["/Users/me/dev"]) == .insideHome)
        // 목록을 주지 않으면 홈만 본다
        #expect(ExtraRootConflict.check("/Volumes/Work", homePath: home) == nil)
    }

    @Test func extraRootConflictResolvesRealPathsAndSymlinks() throws {
        let base = try TempTree()
        try base.dir("home/dev")
        try base.dir("other")
        let home = base.path + "/home"
        try FileManager.default.createSymbolicLink(atPath: base.path + "/other/home-link", withDestinationPath: home)
        try FileManager.default.createSymbolicLink(atPath: base.path + "/other/dev-link", withDestinationPath: home + "/dev")
        try FileManager.default.createSymbolicLink(atPath: base.path + "/other/base-link", withDestinationPath: base.path)

        // 심볼릭 링크는 실제 경로로 풀어 판정한다
        #expect(ExtraRootConflict.check(base.path + "/other/home-link", homePath: home) == .sameAsHome)
        #expect(ExtraRootConflict.check(base.path + "/other/dev-link", homePath: home) == .insideHome)
        #expect(ExtraRootConflict.check(base.path + "/other/base-link", homePath: home) == .containsHome)
        // 실제 존재하는 경로
        #expect(ExtraRootConflict.check(home + "/dev", homePath: home) == .insideHome)
        #expect(ExtraRootConflict.check(base.path, homePath: home) == .containsHome)
        #expect(ExtraRootConflict.check(base.path + "/other", homePath: home) == nil)
        // 다른 추가 루트도 링크를 풀어 비교한다
        #expect(ExtraRootConflict.check(base.path + "/other", homePath: home,
                                        otherRoots: [base.path + "/other/../other/"]) == .duplicate)
    }

    @Test func scanSkipsExtraRootsThatOverlapEachOther() async throws {
        let home = try TempTree()
        try home.file("a.bin", bytes: 10)
        let extra = try TempTree()
        try extra.file("proj/Cargo.toml", bytes: 2)
        try extra.file("proj/target/debug/app", bytes: 60_000)
        let target = extra.path + "/proj/target"
        let orderings: [[String]] = [
            [extra.path, extra.path + "/"],                                  // 같은 경로 두 번 (끝 / 포함)
            [extra.path, extra.path + "/proj"],                              // 한 추가 루트 안의 다른 추가 루트
            [extra.path + "/proj", extra.path],                              // 큰 루트가 뒤에 온다 (바깥 루트를 남긴다)
            [extra.path, extra.path + "/", extra.path + "/proj", extra.path + "/proj/"],
        ]
        for paths in orderings {
            var result = try await ScanResult.scan(homePath: home.path, extraRootPaths: paths, options: ScanOptions())
            #expect(result.extraRoots.map(\.rootPath) == [extra.path], "입력: \(paths)")
            #expect(result.classification.items.map(\.path) == [target], "입력: \(paths)")

            try FileManager.default.removeItem(atPath: target)
            #expect(result.apply(try result.rescan(path: target, options: ScanOptions())))
            #expect(result.classification.items.isEmpty, "입력: \(paths)")
            try extra.file("proj/target/debug/app", bytes: 60_000)
        }
    }

    @Test func applyingRescanOfDeletedPathUpdatesTreeAndClassification() async throws {
        let home = try TempTree()
        try home.file("dev/web/package.json", bytes: 2)
        try home.file("dev/web/node_modules/lib/index.js", bytes: 40_000)
        var result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [], options: ScanOptions())
        let before = result.home.allocatedSize
        let modules = home.path + "/dev/web/node_modules"
        let removed = try #require(result.home.descendant(at: ["dev", "web", "node_modules"])).allocatedSize

        try FileManager.default.removeItem(atPath: modules)
        let rescan = try result.rescan(path: modules, options: ScanOptions())
        result.apply(rescan)

        #expect(rescan.node == nil)
        #expect(result.home.allocatedSize == before - removed)
        #expect(result.classification.items.isEmpty)
    }

    @Test func rescanAndApplyReflectsDeletedPathsAndSkipsFailures() async throws {
        let home = try TempTree()
        try home.file("dev/web/package.json", bytes: 2)
        try home.file("dev/web/node_modules/lib/index.js", bytes: 40_000)
        try home.file("Library/Caches/com.foo/c", bytes: 30_000)
        var result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [], options: ScanOptions())
        let before = result.home.allocatedSize
        let modules = home.path + "/dev/web/node_modules"
        let cache = home.path + "/Library/Caches/com.foo"
        let removed = try #require(result.home.descendant(at: ["dev", "web", "node_modules"])).allocatedSize
            + (try #require(result.home.descendant(at: ["Library", "Caches", "com.foo"]))).allocatedSize
        #expect(result.classification.items.count == 2)

        try FileManager.default.removeItem(atPath: modules)
        try FileManager.default.removeItem(atPath: cache)
        let applied = result.rescanAndApply(paths: [modules, "/nonexistent-root/x", cache], options: ScanOptions())

        #expect(applied == 2)
        #expect(result.home.allocatedSize == before - removed)
        #expect(result.classification.items.isEmpty)
    }

    @Test func rescanKeepsHardLinkOwnedOutsideSubtreeCountedOnce() async throws {
        // pnpm store ↔ 프로젝트 node_modules: 귀속은 사전순 최소 경로(.pnpm-store/…)라 node_modules 를 다시 재도 홈 합계가 그대로다
        let home = try TempTree()
        try home.file(".pnpm-store/v3/files/ab/blob", bytes: 500_000)
        try home.file("dev/web/package.json", bytes: 2)
        try home.hardLink("dev/web/node_modules/lib/index.js", to: ".pnpm-store/v3/files/ab/blob")
        var result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [], options: ScanOptions())
        let before = result.home.allocatedSize
        let owners = result.homeScan.hardLinkOwners
        #expect(owners.values.sorted() == [home.path + "/.pnpm-store/v3/files/ab/blob"])

        result.apply(try result.rescan(path: home.path + "/dev/web/node_modules", options: ScanOptions()))

        #expect(result.home.allocatedSize == before)
        #expect(result.homeScan.hardLinkOwners == owners)
    }

    @Test func rescanOfExtraRootPathUsesThatRoot() async throws {
        let home = try TempTree()
        try home.file("a.bin", bytes: 10)
        let extra = try TempTree()
        try extra.file("Cargo.toml", bytes: 2)
        try extra.file("target/debug/app", bytes: 60_000)
        var result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [extra.path], options: ScanOptions())

        try FileManager.default.removeItem(atPath: extra.path + "/target")
        result.apply(try result.rescan(path: extra.path + "/target", options: ScanOptions()))

        #expect(result.extraRoots.first?.root.child(named: "target") == nil)
        #expect(result.classification.items.isEmpty)
        #expect(throws: RescanError.outsideRoot("/nonexistent-root/x")) {
            try result.rescan(path: "/nonexistent-root/x", options: ScanOptions())
        }
    }

    @Test func applyingRescanNotInTreeReturnsFalseAndKeepsState() async throws {
        let home = try TempTree()
        try home.file("dev/web/package.json", bytes: 2)
        try home.file("dev/web/node_modules/lib/index.js", bytes: 40_000)
        var result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [], options: ScanOptions())
        let treeBefore = result.homeScan
        let itemsBefore = result.classification.items
        let modules = home.path + "/dev/web/node_modules"

        // 대소문자가 틀린 사라진 경로: 트리에 그 경로가 없어 반영되지 않는다
        let missing = SubtreeRescan(rootPath: result.homePath, path: home.path + "/DEV/web/node_modules", node: nil)
        #expect(result.apply(missing) == false)
        // 이름이 다른 노드: 트리 반영이 거부되므로 분류 크기도 바뀌지 않아야 한다
        let mismatched = SubtreeRescan(rootPath: result.homePath, path: modules, node: DirectoryNode(name: "other"))
        #expect(result.apply(mismatched) == false)

        #expect(result.homeScan == treeBefore)
        #expect(result.classification.items == itemsBefore)
    }

    @Test func applyingRescanOfUnknownRootReturnsFalse() async throws {
        let home = try TempTree()
        try home.file("dev/web/package.json", bytes: 2)
        try home.file("dev/web/node_modules/lib/index.js", bytes: 40_000)
        var result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [], options: ScanOptions())
        let itemsBefore = result.classification.items

        let foreign = SubtreeRescan(rootPath: "/nonexistent-root", path: "/nonexistent-root/x", node: nil)
        #expect(result.apply(foreign) == false)
        #expect(result.classification.items == itemsBefore)
    }

    @Test func rescanAndApplyWorksWhenHomeItselfIsExcluded() async throws {
        let home = try TempTree()
        try home.file("proj/node_modules/big.bin", bytes: 200_000)
        let options = ScanOptions(leafThreshold: 1, excludedPaths: [home.path])
        var result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [], options: options)
        #expect(result.home.allocatedSize > 0)

        try FileManager.default.removeItem(atPath: home.path + "/proj/node_modules")
        let applied = result.rescanAndApply(paths: [home.path + "/proj/node_modules"], options: options)
        #expect(applied == 1)
        #expect(result.home.allocatedSize == 0)
    }
}
