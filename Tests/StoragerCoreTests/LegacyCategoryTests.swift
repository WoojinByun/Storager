import Foundation
import GRDB
import Testing
@testable import StoragerCore

/// 예전 카테고리 값(`pythonRustGo`)이 남은 스냅샷 DB 를 읽어도 실패하지 않아야 한다.
struct LegacyCategoryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func removedCategoryRawValueIsGone() {
        #expect(StoragerCore.Category(rawValue: "pythonRustGo") == nil)
        #expect(StoragerCore.Category(rawValue: "python") == .python)
        #expect(StoragerCore.Category(rawValue: "rust") == .rust)
        #expect(StoragerCore.Category(rawValue: "go") == .go)
    }

    @Test func snapshotSkipsUnknownCategoryRows() throws {
        let store = try SnapshotStore.inMemory()
        let id = try store.save(Snapshot(
            at: now, volume: VolumeStats(total: 1_000, available: 300, availableForImportantUsage: 450),
            categories: [.xcode: CategoryTotal(size: 10, itemCount: 1)], topDirectories: []))
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO snapshot_categories (snapshot_id, category, size, item_count)
                VALUES (?, 'pythonRustGo', 77, 3)
                """, arguments: [id])
        }

        let latest = try #require(try store.latest())
        #expect(latest.categories == [.xcode: CategoryTotal(size: 10, itemCount: 1)])

        // 기준 스냅샷으로 읽혀도 옛 값은 빠지므로 변화량 비교에서 사라진다
        let baseline = try #require(try store.baseline(now: now.addingTimeInterval(3 * 86_400), limited: false))
        #expect(baseline.categories == [.xcode: CategoryTotal(size: 10, itemCount: 1)])
    }

    @Test func cleanupLogSkipsUnknownCategoryRows() throws {
        let store = try SnapshotStore.inMemory()
        let entry = CleanupLogEntry(at: now, path: "/h/x", category: .rust, method: "trash",
                                    reclaimedBytes: 1, succeeded: true, message: nil)
        try store.recordCleanup(entry)
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO cleanup_log (at, path, category, method, reclaimed_bytes, succeeded, message)
                VALUES (?, '/h/old', 'pythonRustGo', 'trash', 5, 1, NULL)
                """, arguments: [now.timeIntervalSince1970 + 1])
        }

        #expect(try store.cleanupLog() == [entry])
    }
}
