import Darwin
import Foundation
import GRDB
import Testing
@testable import StoragerCore

struct SnapshotStoreTests {
    let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let volume = VolumeStats(total: 1_000, available: 300, availableForImportantUsage: 450)

    func snapshot(daysAgo: Double, xcode: Int64 = 100) -> Snapshot {
        Snapshot(at: now.addingTimeInterval(-daysAgo * day), volume: volume,
                 categories: [.xcode: CategoryTotal(size: xcode, itemCount: 2), .logs: CategoryTotal(size: 5, itemCount: 1)],
                 topDirectories: [DirectorySize(path: "/h/a", size: 50), DirectorySize(path: "/h/b", size: 70)])
    }

    @Test func saveAndLoadLatestRoundTrips() throws {
        let store = try SnapshotStore.inMemory()
        try store.save(snapshot(daysAgo: 2))
        let id = try store.save(snapshot(daysAgo: 1, xcode: 999))

        let latest = try #require(try store.latest())

        #expect(latest.id == id)
        #expect(latest.at == now.addingTimeInterval(-day))
        #expect(latest.volume == volume)
        #expect(latest.categories[.xcode] == CategoryTotal(size: 999, itemCount: 2))
        #expect(latest.topDirectories.map(\.path) == ["/h/b", "/h/a"])
    }

    @Test func emptyStoreHasNoLatestOrBaseline() throws {
        let store = try SnapshotStore.inMemory()
        #expect(try store.latest() == nil)
        #expect(try store.baseline(now: now, limited: false) == nil)
    }

    @Test func baselineIsNearestToSevenDaysAgo() throws {
        let store = try SnapshotStore.inMemory()
        try store.save(snapshot(daysAgo: 10, xcode: 10))
        try store.save(snapshot(daysAgo: 6.5, xcode: 65))
        try store.save(snapshot(daysAgo: 0.1, xcode: 1))

        #expect(try store.baseline(now: now, limited: false)?.categories[.xcode]?.size == 65)
    }

    @Test func baselineIgnoresSnapshotsYoungerThanADay() throws {
        let store = try SnapshotStore.inMemory()
        try store.save(snapshot(daysAgo: 0.5))
        #expect(try store.baseline(now: now, limited: false) == nil)

        try store.save(snapshot(daysAgo: 2, xcode: 2))
        #expect(try store.baseline(now: now, limited: false)?.categories[.xcode]?.size == 2)
    }

    @Test func compactKeepsLatestPerDayAfterNinetyDaysAndDeletesAfterAYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let store = try SnapshotStore.inMemory()
        // now = 2027-01-15 08:00 UTC. 100일 전 같은 날 3개, 400일 전 1개, 최근 같은 날 2개
        try store.save(snapshot(daysAgo: 100.30, xcode: 1))
        try store.save(snapshot(daysAgo: 100.20, xcode: 2))
        try store.save(snapshot(daysAgo: 100.10, xcode: 3))
        try store.save(snapshot(daysAgo: 400))
        try store.save(snapshot(daysAgo: 3.2))
        try store.save(snapshot(daysAgo: 3.1))

        try store.compact(now: now, calendar: calendar)

        #expect(try store.snapshotCount() == 3)
        let old = try store.baseline(now: now, limited: false, lookback: 100 * day)
        #expect(old?.categories[.xcode]?.size == 3)
    }

    @Test func deletingSnapshotCascadesToChildTables() throws {
        let store = try SnapshotStore.inMemory()
        try store.save(snapshot(daysAgo: 400))
        try store.compact(now: now)
        let orphans = try store.dbQueue.read {
            try Int.fetchOne($0, sql: "SELECT (SELECT COUNT(*) FROM snapshot_categories) + (SELECT COUNT(*) FROM snapshot_top_dirs)")
        }
        #expect(orphans == 0)
    }

    @Test func categoryDeltasSubtractBaseline() {
        let current = snapshot(daysAgo: 0, xcode: 300)
        var base = snapshot(daysAgo: 7, xcode: 100)
        base.categories[.gradle] = CategoryTotal(size: 40, itemCount: 1)

        let deltas = Snapshot.categoryDeltas(current: current.categories, baseline: base)

        #expect(deltas[.xcode] == 200)
        #expect(deltas[.logs] == 0)
        #expect(deltas[.gradle] == -40)
        #expect(Snapshot.categoryDeltas(current: current.categories, baseline: nil).isEmpty)
    }

    @Test func cleanupLogRoundTrips() throws {
        let store = try SnapshotStore.inMemory()
        let entry = CleanupLogEntry(at: now, path: "/h/x", category: .javascript, method: "trash",
                                    reclaimedBytes: 123, succeeded: false, message: "권한 없음")
        try store.recordCleanup(entry)
        #expect(try store.cleanupLog() == [entry])
    }

    @Test func openCreatesFileAndReopens() throws {
        let tree = try TempTree()
        do {
            let store = try SnapshotStore.open(directory: tree.root)
            try store.save(snapshot(daysAgo: 1))
        }
        let reopened = try SnapshotStore.open(directory: tree.root)
        #expect(try reopened.snapshotCount() == 1)
        #expect(FileManager.default.fileExists(atPath: tree.path + "/storager.sqlite"))
    }

    @Test func openQuarantinesCorruptDatabase() throws {
        let tree = try TempTree()
        try Data(repeating: 0x42, count: 4096).write(to: tree.root.appendingPathComponent("storager.sqlite"))

        let store = try SnapshotStore.open(directory: tree.root, now: Date(timeIntervalSince1970: 77))

        #expect(try store.snapshotCount() == 0)
        #expect(FileManager.default.fileExists(atPath: tree.path + "/storager.sqlite.corrupt-77"))
    }

    @Test func snapshotFromScanResult() {
        let tag = RuleCatalog.default[0].tag
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "a", directAllocatedSize: 9)])
        let result = ScanResult(
            homeScan: TreeScan(rootPath: "/h", deviceID: 0, root: home), extraRoots: [],
            classification: Classification(items: [
                ClassifiedItem(path: "/h/a", tag: tag, allocatedSize: 9, newestModification: .distantPast),
            ]),
            finishedAt: now)

        let snapshot = Snapshot.make(from: result, volume: volume)

        #expect(snapshot.at == now)
        #expect(snapshot.categories[.xcode] == CategoryTotal(size: 9, itemCount: 1))
        #expect(snapshot.topDirectories == [DirectorySize(path: "/h/a", size: 9)])
    }

    @Test func volumeWithLessImportantUsageThanAvailableRoundTrips() throws {
        let store = try SnapshotStore.inMemory()
        // availableForImportantUsage 가 available 보다 작은 경우도 그대로 복원된다
        let odd = VolumeStats(total: 1_000, available: 300, availableForImportantUsage: 200)
        try store.save(Snapshot(at: now, volume: odd, categories: [:], topDirectories: []))

        #expect(try #require(try store.latest()).volume == odd)
    }

    @Test func baselineTieGoesToTheNewerSnapshot() throws {
        let store = try SnapshotStore.inMemory()
        // 7일 전에서 정확히 하루씩 떨어진 두 스냅샷
        try store.save(snapshot(daysAgo: 8, xcode: 8))
        try store.save(snapshot(daysAgo: 6, xcode: 6))

        #expect(try store.baseline(now: now, limited: false)?.categories[.xcode]?.size == 6)
    }

    @Test func fileDatabaseWaitsOnBusyLock() throws {
        let tree = try TempTree()
        let store = try SnapshotStore.open(directory: tree.root)
        guard case .timeout(let seconds) = store.dbQueue.configuration.busyMode else {
            Issue.record("busyMode 가 timeout 이 아님")
            return
        }
        #expect(seconds == 2)
    }

    @Test func writeWaitsWhileAnotherConnectionHoldsTheWriteLock() throws {
        let tree = try TempTree()
        let store = try SnapshotStore.open(directory: tree.root)
        // 다른 연결(이전 인스턴스·sqlite3 등)이 쓰기 잠금을 잠깐 쥐고 있다
        let other = try DatabaseQueue(path: tree.root.appendingPathComponent(SnapshotStore.databaseFileName).path)
        let locked = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? other.inTransaction(.immediate) { _ in
                locked.signal()
                Thread.sleep(forTimeInterval: 0.3)
                return .commit
            }
            done.signal()
        }
        locked.wait()
        // 바로 SQLITE_BUSY 로 실패하지 않고 잠금이 풀릴 때까지 기다렸다가 쓴다
        try store.dbQueue.write { try $0.execute(sql: "CREATE TABLE busy_probe (x INTEGER)") }
        done.wait()
        #expect(try store.dbQueue.read { try $0.tableExists("busy_probe") })
    }

    @Test func openOrFallbackIsPersistentInWritableDirectory() throws {
        let tree = try TempTree()

        let (store, isPersistent) = SnapshotStore.openOrFallback(directory: tree.root)

        #expect(isPersistent)
        try store.save(snapshot(daysAgo: 1))
        #expect(FileManager.default.fileExists(atPath: tree.path + "/storager.sqlite"))
    }

    @Test(.disabled(if: geteuid() == 0, "root 는 쓰기 권한 검사를 우회한다"))
    func openOrFallbackUsesMemoryStoreWhenDirectoryIsReadOnly() throws {
        let tree = try TempTree()
        let locked = tree.root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0o500)

        // DB 파일이 없는데 폴더에 쓸 수 없다 (디스크가 꽉 찬 첫 실행과 같은 열기 실패)
        let (store, isPersistent) = SnapshotStore.openOrFallback(directory: locked)

        #expect(!isPersistent)
        try store.save(snapshot(daysAgo: 2, xcode: 2))
        #expect(try store.baseline(now: now, limited: false)?.categories[.xcode]?.size == 2)
        #expect(!FileManager.default.fileExists(atPath: locked.path + "/storager.sqlite"))
    }

    @Test func openOrFallbackUsesMemoryStoreWhenDirectoryCannotBeCreated() throws {
        let tree = try TempTree()
        // 폴더 자리에 파일이 있다
        let blocker = tree.root.appendingPathComponent("blocker")
        try Data([1]).write(to: blocker)

        let (store, isPersistent) = SnapshotStore.openOrFallback(directory: blocker.appendingPathComponent("Storager"))

        #expect(!isPersistent)
        try store.save(snapshot(daysAgo: 1))
        #expect(try store.snapshotCount() == 1)
    }

    // MARK: 스캔 범위 (전체 디스크 접근)

    func limitedSnapshot(daysAgo: Double, xcode: Int64 = 100) -> Snapshot {
        var snapshot = snapshot(daysAgo: daysAgo, xcode: xcode)
        snapshot.isLimited = true
        return snapshot
    }

    @Test func limitedFlagRoundTrips() throws {
        let store = try SnapshotStore.inMemory()
        try store.save(limitedSnapshot(daysAgo: 1))
        #expect(try #require(try store.latest()).isLimited)
        try store.save(snapshot(daysAgo: 0.5))
        #expect(try #require(try store.latest()).isLimited == false)
    }

    @Test func baselineOnlyMatchesSameCoverage() throws {
        let store = try SnapshotStore.inMemory()
        // 7일 전에 가장 가까운 것은 제한 스캔, 그보다 먼 것은 전체 스캔
        try store.save(limitedSnapshot(daysAgo: 7, xcode: 7))
        try store.save(snapshot(daysAgo: 3, xcode: 3))

        #expect(try store.baseline(now: now, limited: true)?.categories[.xcode]?.size == 7)
        #expect(try store.baseline(now: now, limited: false)?.categories[.xcode]?.size == 3)
    }

    @Test func baselineIsNilWithoutSnapshotOfSameCoverage() throws {
        let store = try SnapshotStore.inMemory()
        // 권한을 막 허용한 상황: 지난 스냅샷은 모두 제한 스캔이다
        try store.save(limitedSnapshot(daysAgo: 7))
        try store.save(limitedSnapshot(daysAgo: 2))

        #expect(try store.baseline(now: now, limited: false) == nil)
        #expect(try store.baseline(now: now, limited: true) != nil)
    }

    @Test func snapshotFromScanResultCarriesCoverage() {
        let home = DirectoryNode(name: "h")
        let result = ScanResult(homeScan: TreeScan(rootPath: "/h", deviceID: 0, root: home), extraRoots: [],
                                classification: Classification(items: []), finishedAt: now, isLimited: true)
        #expect(Snapshot.make(from: result, volume: volume).isLimited)
    }

    @Test func compactKeepsOneSnapshotPerDayPerCoverage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let store = try SnapshotStore.inMemory()
        // 100일 전 같은 날: 제한 2개 + 전체 2개 → 범위마다 가장 늦은 1개씩
        try store.save(limitedSnapshot(daysAgo: 100.30, xcode: 1))
        try store.save(limitedSnapshot(daysAgo: 100.20, xcode: 2))
        try store.save(snapshot(daysAgo: 100.15, xcode: 3))
        try store.save(snapshot(daysAgo: 100.10, xcode: 4))

        try store.compact(now: now, calendar: calendar)

        #expect(try store.snapshotCount() == 2)
        #expect(try store.baseline(now: now, limited: true, lookback: 100 * day)?.categories[.xcode]?.size == 2)
        #expect(try store.baseline(now: now, limited: false, lookback: 100 * day)?.categories[.xcode]?.size == 4)
    }

    @Test func migratingVersionOneDatabaseMarksExistingSnapshotsFull() throws {
        let tree = try TempTree()
        let path = tree.path + "/storager.sqlite"
        // v1 까지만 적용한 DB 에 예전 형식으로 한 줄 넣는다
        do {
            let queue = try DatabaseQueue(path: path)
            try SnapshotStore.migrator.migrate(queue, upTo: "v1")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO snapshots (at, volume_total, volume_used, volume_available, volume_purgeable,
                                           volume_available_important) VALUES (?, 1000, 700, 300, 0, 450)
                    """, arguments: [now.addingTimeInterval(-7 * day).timeIntervalSince1970])
            }
        }

        let store = try SnapshotStore.open(directory: tree.root)

        let migrated = try #require(try store.latest())
        #expect(migrated.isLimited == false)
        #expect(try store.baseline(now: now, limited: false)?.id == migrated.id)
        #expect(try store.baseline(now: now, limited: true) == nil)
    }
}
