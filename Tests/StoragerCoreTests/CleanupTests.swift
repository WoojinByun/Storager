import Foundation
import Synchronization
import Testing
@testable import StoragerCore

struct CleanupPlannerTests {
    let tree: TempTree
    let planner: CleanupPlanner

    init() throws {
        tree = try TempTree()
        planner = CleanupPlanner(homePath: tree.path)
    }

    func item(_ relative: String, _ ruleID: String, size: Int64 = 100) -> ClassifiedItem {
        ClassifiedItem(path: DirectoryNode.join(tree.path, relative), tag: ruleTag(ruleID), allocatedSize: size,
                       newestModification: .distantPast)
    }

    @Test func acceptsRegenerableTrashItemsAndSumsSize() throws {
        try tree.dir("Library/Developer/Xcode/DerivedData")
        try tree.dir("dev/app/node_modules")

        let plan = planner.plan([
            item("Library/Developer/Xcode/DerivedData", "xcode.deriveddata", size: 300),
            item("dev/app/node_modules", "js.node_modules", size: 200),
        ])

        #expect(plan.accepted.count == 2)
        #expect(plan.rejected.isEmpty)
        #expect(plan.reclaimableBytes == 500)
    }

    @Test func rejectsByLevelAndMethod() throws {
        try tree.dir("Library/Developer/Xcode/Archives")
        try tree.dir("Library/Caches/Homebrew")
        try tree.dir("Library/Mail")

        let plan = planner.plan([
            item("Library/Developer/Xcode/Archives", "xcode.archives"),
            item("Library/Caches/Homebrew", "homebrew.cache"),
            item("Library/Mail", "personal.mail"),
        ])

        #expect(plan.accepted.isEmpty)
        #expect(plan.rejected.map(\.reason) == [.notYetSupported, .notYetSupported, .manualOnly])
        #expect(plan.rejected[0].reason.message == "v0.2 에서 지원")
    }

    @Test func rejectsOutsideHomeProtectedSymlinkAndMissing() throws {
        let outside = try TempTree()
        try outside.dir("node_modules")
        try tree.dir("real/node_modules")
        try tree.symlink("linked", to: tree.path + "/real")

        let plan = planner.plan([
            ClassifiedItem(path: outside.path + "/node_modules", tag: ruleTag("js.node_modules"), allocatedSize: 1,
                           newestModification: .distantPast),
            item("Library", "caches.general"),
            item("Library/Caches", "caches.general"),
            item("linked", "js.node_modules"),
            item("gone/node_modules", "js.node_modules"),
        ])

        #expect(plan.accepted.isEmpty)
        #expect(plan.rejected.map(\.reason) == [
            .outsideAllowedRoots, .protectedDirectory, .protectedDirectory, .symbolicLink, .missing,
        ])
    }

    @Test func extraRootsAreAllowed() throws {
        let extra = try TempTree()
        try extra.dir("target")
        let planner = CleanupPlanner(homePath: tree.path, extraRoots: [extra.path])

        let plan = planner.plan([
            ClassifiedItem(path: extra.path + "/target", tag: ruleTag("rust.project.target"), allocatedSize: 1,
                           newestModification: .distantPast),
        ])

        #expect(plan.accepted.count == 1)
    }

    @Test func descendantOfSelectedAncestorIsDropped() throws {
        try tree.dir("a/node_modules/x/node_modules")

        let plan = planner.plan([
            item("a/node_modules", "js.node_modules", size: 10),
            item("a/node_modules/x/node_modules", "js.node_modules", size: 3),
        ])

        #expect(plan.accepted.map(\.path) == [tree.path + "/a/node_modules"])
        #expect(plan.reclaimableBytes == 10)
    }

    @Test func warnsWhenRelatedAppIsRunning() throws {
        try tree.dir("Library/Developer/Xcode/DerivedData")

        let plan = planner.plan([item("Library/Developer/Xcode/DerivedData", "xcode.deriveddata")],
                                runningBundleIDs: ["com.apple.dt.Xcode", "com.docker.docker"])

        #expect(plan.warnings.count == 1)
        #expect(plan.warnings.first?.contains("Xcode") == true)
    }

    @Test func extraRootsOverlappingHomeAreIgnored() throws {
        let outside = try TempTree()
        try outside.dir("node_modules")
        try tree.dir("dev/node_modules")
        // 홈의 조상(/)·홈 자신·홈의 자손은 추가 루트로 받지 않는다 (ScanResult.scan 과 같은 규칙)
        let planner = CleanupPlanner(homePath: tree.path, extraRoots: ["/", tree.path, tree.path + "/dev"])

        let plan = planner.plan([
            ClassifiedItem(path: outside.path + "/node_modules", tag: ruleTag("js.node_modules"), allocatedSize: 1,
                           newestModification: .distantPast),
            item("dev", "js.node_modules"),
            item("dev/node_modules", "js.node_modules"),
        ])

        #expect(planner.allowedRoots == [tree.path])
        #expect(plan.rejected.map(\.reason) == [.outsideAllowedRoots])
        // 홈 안은 홈 규칙으로만 판정한다 (홈 자손 추가 루트를 보호 경로로 삼지 않는다)
        #expect(plan.accepted.map(\.path) == [tree.path + "/dev"])
    }

    @Test func overlappingExtraRootsKeepOnlyOuterRoot() throws {
        let extra = try TempTree()
        try extra.dir("a/b/target")
        let planner = CleanupPlanner(homePath: tree.path,
                                     extraRoots: [extra.path + "/a/b", extra.path + "/a/b", extra.path + "/a/b/c",
                                                  extra.path + "/a"])

        let plan = planner.plan([
            ClassifiedItem(path: extra.path + "/a/b", tag: ruleTag("rust.project.target"), allocatedSize: 1,
                           newestModification: .distantPast),
        ])

        #expect(planner.allowedRoots == [tree.path, extra.path + "/a"])
        #expect(plan.accepted.map(\.path) == [extra.path + "/a/b"])
    }

    @Test func duplicatePathsAreAcceptedOnce() throws {
        try tree.dir("dev/app/node_modules")

        let plan = planner.plan([
            item("dev/app/node_modules", "js.node_modules", size: 100),
            item("dev/app/node_modules", "js.node_modules", size: 100),
            item("dev/app/node_modules/", "js.node_modules", size: 100),
        ])

        #expect(plan.accepted.map(\.path) == [tree.path + "/dev/app/node_modules"])
        #expect(plan.reclaimableBytes == 100)
    }

    @Test func rejectedAncestorDoesNotDropDescendant() throws {
        try tree.dir("dev/node_modules")

        let plan = planner.plan([
            item("dev", "xcode.archives"),
            item("dev/node_modules", "js.node_modules"),
        ])

        #expect(plan.rejected.map(\.reason) == [.notYetSupported])
        #expect(plan.accepted.map(\.path) == [tree.path + "/dev/node_modules"])
    }

    @Test func rejectsPathsThatDifferFromRealLocation() throws {
        try tree.dir("Library/Caches/app")
        try tree.dir("real/node_modules")
        try tree.symlink("link", to: tree.path + "/real")

        let plan = planner.plan([
            // 대소문자만 다른 표기로 ~/Library 보호 검사를 우회하지 못한다
            item("library", "caches.general"),
            item("LIBRARY/caches", "caches.general"),
            item("library/Caches/app", "caches.general"),
            // 중간 디렉터리가 링크
            item("link/node_modules", "js.node_modules"),
        ])

        #expect(plan.accepted.isEmpty)
        #expect(plan.rejected.map(\.reason) == [.pathMismatch, .pathMismatch, .pathMismatch, .pathMismatch])
    }

    @Test func plansManyItemsInLinearTime() throws {
        // 예전 이중 루프는 5천 개에서 debug 수 초였다 (2만 개 release 29초).
        // 절대 시간 제한은 CI·부하에 따라 흔들리므로, 항목 수를 4배로 늘렸을 때 걸리는 시간의 비율로 본다.
        // 선형이면 약 4배, 제곱이면 약 16배다. 판정식은 "큰 쪽 시간 < 작은 쪽 시간 x 10 + 절대 500ms 여유" 이다 (비율 10배 + 절대 0.5초).
        let small = 1_000
        let large = 4_000
        for index in 0..<large {
            guard mkdir(tree.path + "/p\(index)", 0o755) == 0 else { throw POSIXError(.EIO) }
        }
        func makeItems(_ count: Int) -> [ClassifiedItem] {
            var items = (0..<count).map { item("p\($0)", "js.node_modules", size: 1) }
            // 같은 경로를 다시 넣어도 한 번만 받는다
            items.append(item("p0", "js.node_modules", size: 1))
            return items
        }

        let clock = ContinuousClock()
        var smallPlan: CleanupPlan?
        var largePlan: CleanupPlan?
        let smallItems = makeItems(small)
        let largeItems = makeItems(large)
        let smallElapsed = clock.measure { smallPlan = planner.plan(smallItems) }
        let largeElapsed = clock.measure { largePlan = planner.plan(largeItems) }

        #expect(smallPlan?.accepted.count == small)
        #expect(largePlan?.accepted.count == large)
        #expect(largePlan?.reclaimableBytes == Int64(large))
        #expect(largeElapsed < smallElapsed * 10 + .milliseconds(500))
    }

    @Test func canonicallyEquivalentUnicodeIsNotPathMismatch() throws {
        // PathUtil.resolve 가 돌려주는 디스크상의 이름과 입력 경로를 Swift String == 로 비교한다.
        // Swift 의 == 는 정규 등가(NFC/NFD)를 같다고 보므로, 정규화 형태만 다른 경로는 .pathMismatch 가 아니다.
        // (APFS 는 정규화를 구분하지 않고 보존만 한다.) 이 테스트는 TMPDIR 가 APFS 위에 있다고 가정한다:
        // 정규화를 구분하는 파일시스템이면 NFC 경로가 존재하지 않아 결과가 달라진다. 대소문자 차이는 문자열이 달라 .pathMismatch 로 막힌다.
        let nfd = "cafe\u{301}"
        let nfc = "caf\u{e9}"
        try tree.dir("\(nfd)/node_modules")

        let plan = planner.plan([item("\(nfc)/node_modules", "js.node_modules")])

        #expect(plan.rejected.isEmpty)
        #expect(plan.accepted.count == 1)
    }
}

final class FakeTrasher: Trasher {
    let failing: Set<String>
    let trashed = Mutex<[String]>([])

    init(failing: Set<String> = []) {
        self.failing = failing
    }

    func trash(path: String) throws {
        if failing.contains(path) { throw CocoaError(.fileWriteNoPermission) }
        trashed.withLock { $0.append(path) }
    }
}

struct CleanupExecutorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    func item(_ relative: String, size: Int64) -> ClassifiedItem {
        ClassifiedItem(path: DirectoryNode.join(tree.path, relative), tag: ruleTag("js.node_modules"),
                       allocatedSize: size, newestModification: .distantPast)
    }

    func plan(_ items: [ClassifiedItem]) -> CleanupPlan {
        CleanupPlan(accepted: items, rejected: [], warnings: [])
    }

    @Test func trashesEachItemContinuesOnFailureAndRecordsLog() throws {
        for name in ["a", "b", "c"] { try tree.dir(name) }
        let store = try SnapshotStore.inMemory()
        let trasher = FakeTrasher(failing: [tree.path + "/b"])

        let outcomes = CleanupExecutor(trasher: trasher, store: store)
            .execute(plan([item("a", size: 10), item("b", size: 20), item("c", size: 30)]), now: now)

        #expect(outcomes.map(\.succeeded) == [true, false, true])
        #expect(outcomes[1].message != nil)
        #expect(trasher.trashed.withLock { $0 } == [tree.path + "/a", tree.path + "/c"])
        let log = try store.cleanupLog()
        #expect(log.count == 3)
        #expect(log.map(\.reclaimedBytes).sorted() == [0, 10, 30])
        #expect(log.allSatisfy { $0.method == "trash" && $0.category == .javascript })
    }

    @Test func refusesPathsChangedSincePlanning() throws {
        try tree.dir("real/node_modules")
        try tree.dir("a/node_modules")
        try tree.dir("b/node_modules")
        try tree.dir("c/node_modules")
        try tree.file("d", bytes: 10)
        let planned = plan([item("a/node_modules", size: 1), item("b/node_modules", size: 2),
                            item("C/node_modules", size: 3), item("d", size: 4), item("gone", size: 5),
                            item("c/node_modules", size: 6)])
        // 계획 뒤에 경로 자체를 링크로, 중간 디렉터리를 링크로 바꾼다
        try FileManager.default.removeItem(atPath: tree.path + "/a/node_modules")
        try tree.symlink("a/node_modules", to: tree.path + "/real/node_modules")
        try FileManager.default.removeItem(atPath: tree.path + "/b")
        try tree.symlink("b", to: tree.path + "/real")
        let store = try SnapshotStore.inMemory()
        let trasher = FakeTrasher()

        let outcomes = CleanupExecutor(trasher: trasher, store: store).execute(planned, now: now)

        #expect(outcomes.map(\.succeeded) == [false, false, false, false, false, true])
        #expect(outcomes.dropLast().allSatisfy { $0.message != nil })
        #expect(trasher.trashed.withLock { $0 } == [tree.path + "/c/node_modules"])
        let log = try store.cleanupLog()
        #expect(log.filter { !$0.succeeded }.count == 5)
        #expect(log.filter { !$0.succeeded }.allSatisfy { $0.reclaimedBytes == 0 && $0.message != nil })
    }

    @Test func refusesItemsInsidePermissionSkipWithoutTouchingThem() throws {
        // 실행 직전 권한을 거뒀다: 건너뛰는 위치(Documents) 안의 항목은 lstat 하지 않고 권한 사유로 실패한다.
        // 디스크에 실제로 있는 디렉터리라 lstat 했다면 "없음" 이 아니라 휴지통 이동이 됐을 것이다
        try tree.dir("Documents/app/node_modules")
        try tree.dir("dev/app/node_modules")
        let skip = FullDiskAccess.permissionSkip(homePath: tree.path)
        #expect(skip.covers(tree.path + "/Documents/app/node_modules"))
        let store = try SnapshotStore.inMemory()
        let trasher = FakeTrasher()
        let planned = plan([item("Documents/app/node_modules", size: 10), item("dev/app/node_modules", size: 20)])

        let outcomes = CleanupExecutor(trasher: trasher, store: store, permissionSkip: skip).execute(planned, now: now)

        #expect(outcomes.map(\.succeeded) == [false, true])
        #expect(outcomes[0].message == CleanupRejection.permissionRequired.message)
        #expect(trasher.trashed.withLock { $0 } == [tree.path + "/dev/app/node_modules"])
        #expect(try store.cleanupLog().filter { !$0.succeeded }.map(\.reclaimedBytes) == [0])

        // 확인을 넘기지 않으면(nil) 예전처럼 lstat 으로만 판단한다
        let unchecked = CleanupExecutor(trasher: FakeTrasher(), store: nil).execute(planned, now: now)
        #expect(unchecked.map(\.succeeded) == [true, true])
    }

    @Test func outcomesDoNotDependOnLogStore() throws {
        try tree.dir("a")
        let trasher = FakeTrasher()

        let outcomes = CleanupExecutor(trasher: trasher, store: nil).execute(plan([item("a", size: 10)]), now: now)

        #expect(outcomes.map(\.succeeded) == [true])
        #expect(trasher.trashed.withLock { $0 } == [tree.path + "/a"])
    }

    @Test func logWriteFailureDoesNotChangeOutcome() throws {
        try tree.dir("a")
        let databaseDirectory = try tree.dir("db")
        let store = try SnapshotStore.open(directory: databaseDirectory)
        // 저널 파일을 만들 수 없게 해 기록 쓰기를 실패시킨다 (TempTree 가 정리할 때 권한을 되돌린다)
        chmod(databaseDirectory.path, 0o500)
        defer { chmod(databaseDirectory.path, 0o755) }
        #expect(throws: (any Error).self) {
            try store.recordCleanup(CleanupLogEntry(at: now, path: "/x", category: .javascript, method: "trash",
                                                    reclaimedBytes: 0, succeeded: true, message: nil))
        }
        let trasher = FakeTrasher()

        let outcomes = CleanupExecutor(trasher: trasher, store: store).execute(plan([item("a", size: 10)]), now: now)

        #expect(outcomes.map(\.succeeded) == [true])
        #expect(trasher.trashed.withLock { $0 } == [tree.path + "/a"])
    }
}
