import Foundation
import GRDB

/// 스냅샷·정리 기록 저장소 (GRDB). 시각은 1970 기준 초(REAL)로 저장해 정렬·차이 계산을 SQL 로 한다.
public final class SnapshotStore: Sendable {
    public static let databaseFileName = "storager.sqlite"
    /// 이보다 오래된 스냅샷은 하루 1개로 줄인다
    public static let compactAfter: TimeInterval = 90 * 86_400
    /// 이보다 오래된 스냅샷은 지운다
    public static let deleteAfter: TimeInterval = 365 * 86_400

    let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    /// 테스트용 메모리 DB.
    public static func inMemory() throws -> SnapshotStore {
        try SnapshotStore(dbQueue: DatabaseQueue())
    }

    /// `directory/storager.sqlite` 를 연다. 손상됐으면 `storager.sqlite.corrupt-<초>` 로 옮기고 새로 만든다
    /// (스냅샷은 다시 쌓이는 데이터라 보존보다 계속 동작하는 쪽을 택한다).
    public static func open(directory: URL, now: Date = Date()) throws -> SnapshotStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(databaseFileName)
        do {
            return try openChecked(url)
        } catch let error as DatabaseError where error.resultCode.primaryResultCode == .SQLITE_CORRUPT
            || error.resultCode.primaryResultCode == .SQLITE_NOTADB {
            let suffix = ".corrupt-\(Int(now.timeIntervalSince1970))"
            for extra in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + extra) {
                try FileManager.default.moveItem(atPath: url.path + extra, toPath: url.path + suffix + extra)
            }
            Log.store.error("DB 손상, \(databaseFileName + suffix, privacy: .public) 로 옮기고 새로 만듦")
            return try openChecked(url)
        }
    }

    /// `open` 이 실패하면(디스크가 꽉 찬 첫 실행, 쓸 수 없는 폴더, 손상 복구 실패 등) 경고만 남기고 메모리 저장소를 돌려준다.
    /// 추세 저장은 못 해도 앱은 계속 동작하게 하려는 것이다. `isPersistent` 가 false 면 이 실행의 스냅샷은 종료와 함께 사라진다.
    public static func openOrFallback(directory: URL, now: Date = Date()) -> (store: SnapshotStore, isPersistent: Bool) {
        do {
            return (try open(directory: directory, now: now), true)
        } catch {
            Log.store.warning("DB 를 열 수 없어 메모리 저장소로 대체: \(String(describing: error), privacy: .private)")
        }
        do {
            return (try inMemory(), false)
        } catch {
            // 메모리 DB 의 마이그레이션이 실패하는 것은 프로그래밍 오류다
            fatalError("메모리 SnapshotStore 를 만들 수 없음: \(error)")
        }
    }

    /// 파일 DB 설정. 다른 연결(잠깐 겹친 이전 인스턴스, sqlite3 로 들여다보는 사용자 등)이 잠금을 쥐고 있으면
    /// 바로 `SQLITE_BUSY` 로 실패하지 않고 최대 2초 기다린다.
    /// 쓰기 트랜잭션은 IMMEDIATE 여야 처음부터 쓰기 잠금을 기다린다(DEFERRED 는 읽다가 쓰기로 올릴 때 경합하면
    /// busy 처리기를 거치지 않고 바로 `SQLITE_BUSY` 로 실패할 수 있다). GRDB 7 은 `Configuration.defaultTransactionKind`
    /// 를 없애고 읽기 전용이 아닌 연결의 `write` 트랜잭션을 늘 IMMEDIATE 로 시작하므로 따로 설정하지 않는다.
    static func fileConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.busyMode = .timeout(2)
        return configuration
    }

    private static func openChecked(_ url: URL) throws -> SnapshotStore {
        let dbQueue = try DatabaseQueue(path: url.path, configuration: fileConfiguration())
        let check = try dbQueue.read { try String.fetchOne($0, sql: "PRAGMA quick_check") }
        guard check == "ok" else {
            throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "quick_check: \(check ?? "nil")")
        }
        return try SnapshotStore(dbQueue: dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE snapshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    at REAL NOT NULL,
                    volume_total INTEGER NOT NULL,
                    volume_used INTEGER NOT NULL,
                    volume_available INTEGER NOT NULL,
                    volume_purgeable INTEGER NOT NULL,
                    volume_available_important INTEGER NOT NULL
                );
                CREATE INDEX snapshots_at ON snapshots(at);
                CREATE TABLE snapshot_categories (
                    snapshot_id INTEGER NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    category TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    item_count INTEGER NOT NULL,
                    PRIMARY KEY (snapshot_id, category)
                );
                CREATE TABLE snapshot_top_dirs (
                    snapshot_id INTEGER NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    size INTEGER NOT NULL
                );
                CREATE INDEX snapshot_top_dirs_snapshot ON snapshot_top_dirs(snapshot_id);
                CREATE TABLE cleanup_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    at REAL NOT NULL,
                    path TEXT NOT NULL,
                    category TEXT NOT NULL,
                    method TEXT NOT NULL,
                    reclaimed_bytes INTEGER NOT NULL,
                    succeeded INTEGER NOT NULL,
                    message TEXT
                );
                """)
        }
        // 배포 뒤 "v1" 은 고치지 않는다. 기존 스냅샷은 권한 확인 전에 찍힌 것이라 전체 스캔(0)으로 둔다.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE snapshots ADD COLUMN limited INTEGER NOT NULL DEFAULT 0")
        }
        return migrator
    }

    // MARK: 스냅샷

    @discardableResult
    public func save(_ snapshot: Snapshot) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO snapshots (at, volume_total, volume_used, volume_available, volume_purgeable,
                                           volume_available_important, limited)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [snapshot.at.timeIntervalSince1970, snapshot.volume.total, snapshot.volume.used,
                            snapshot.volume.available, snapshot.volume.purgeable,
                            snapshot.volume.availableForImportantUsage, snapshot.isLimited])
            let id = db.lastInsertedRowID
            for (category, total) in snapshot.categories {
                try db.execute(
                    sql: "INSERT INTO snapshot_categories (snapshot_id, category, size, item_count) VALUES (?, ?, ?, ?)",
                    arguments: [id, category.rawValue, total.size, total.itemCount])
            }
            for directory in snapshot.topDirectories {
                try db.execute(sql: "INSERT INTO snapshot_top_dirs (snapshot_id, path, size) VALUES (?, ?, ?)",
                               arguments: [id, directory.path, directory.size])
            }
            return id
        }
    }

    /// 가장 최근 스냅샷.
    public func latest() throws -> Snapshot? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM snapshots ORDER BY at DESC LIMIT 1")
            return try row.map { try Self.snapshot(from: $0, db: db) }
        }
    }

    /// 변화량 기준 스냅샷: `now - lookback` 에 가장 가까운 것. 단 `minimumAge` 보다 최근 것은 쓰지 않는다
    /// (방금 찍은 스냅샷과 비교해 0 에 가까운 변화량을 보여 주지 않도록).
    /// `limited` 는 비교할 현재 스캔이 제한 스캔인지다. 같은 범위의 스냅샷만 고른다(권한을 허용한 직후 보호 폴더 크기가
    /// 모두 증가로 보이지 않도록). 같은 범위의 스냅샷이 없으면 nil 이라 변화량을 보여 주지 않는다.
    public func baseline(now: Date, limited: Bool, lookback: TimeInterval = 7 * 86_400,
                         minimumAge: TimeInterval = 86_400) throws -> Snapshot? {
        let target = now.timeIntervalSince1970 - lookback
        let newest = now.timeIntervalSince1970 - minimumAge
        return try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM snapshots WHERE at <= ? AND limited = ? ORDER BY ABS(at - ?) ASC, at DESC LIMIT 1",
                arguments: [newest, limited, target])
            return try row.map { try Self.snapshot(from: $0, db: db) }
        }
    }

    public func snapshotCount() throws -> Int {
        try dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM snapshots") ?? 0 }
    }

    /// 보관 정책: 1년 지난 스냅샷은 지우고, 90일 지난 것은 (로컬) 날짜·범위(제한 스캔 여부)마다 가장 늦은 1개만 남긴다.
    /// 범위별로 남겨야 권한을 허용한 날의 스냅샷도 두 범위의 기준으로 계속 쓸 수 있다.
    public func compact(now: Date, calendar: Calendar = .autoupdatingCurrent) throws {
        let deleteBefore = now.timeIntervalSince1970 - Self.deleteAfter
        let compactBefore = now.timeIntervalSince1970 - Self.compactAfter
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM snapshots WHERE at < ?", arguments: [deleteBefore])
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, at, limited FROM snapshots WHERE at < ? ORDER BY at DESC", arguments: [compactBefore])
            struct DayKey: Hashable {
                var day: DateComponents
                var limited: Bool
            }
            var keptDays = Set<DayKey>()
            var doomed: [Int64] = []
            for row in rows {
                let date = Date(timeIntervalSince1970: row["at"])
                let key = DayKey(day: calendar.dateComponents([.year, .month, .day], from: date), limited: row["limited"])
                if !keptDays.insert(key).inserted {
                    doomed.append(row["id"])
                }
            }
            for id in doomed {
                try db.execute(sql: "DELETE FROM snapshots WHERE id = ?", arguments: [id])
            }
        }
    }

    private static func snapshot(from row: Row, db: Database) throws -> Snapshot {
        let id: Int64 = row["id"]
        var categories: [Category: CategoryTotal] = [:]
        for categoryRow in try Row.fetchAll(
            db, sql: "SELECT category, size, item_count FROM snapshot_categories WHERE snapshot_id = ?", arguments: [id]) {
            // 앞으로 없어진 카테고리 값은 무시한다
            guard let category = Category(rawValue: categoryRow["category"]) else { continue }
            categories[category] = CategoryTotal(size: categoryRow["size"], itemCount: categoryRow["item_count"])
        }
        let top = try Row.fetchAll(
            db, sql: "SELECT path, size FROM snapshot_top_dirs WHERE snapshot_id = ? ORDER BY size DESC", arguments: [id]
        ).map { DirectorySize(path: $0["path"], size: $0["size"]) }
        return Snapshot(
            id: id,
            at: Date(timeIntervalSince1970: row["at"]),
            volume: VolumeStats(total: row["volume_total"], available: row["volume_available"],
                                availableForImportantUsage: row["volume_available_important"]),
            categories: categories,
            topDirectories: top,
            isLimited: row["limited"])
    }

    // MARK: 정리 기록

    public func recordCleanup(_ entry: CleanupLogEntry) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cleanup_log (at, path, category, method, reclaimed_bytes, succeeded, message)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [entry.at.timeIntervalSince1970, entry.path, entry.category.rawValue, entry.method,
                            entry.reclaimedBytes, entry.succeeded, entry.message])
        }
    }

    /// 최신순 정리 기록 (v0.3 정리 기록 뷰에서 쓴다).
    public func cleanupLog(limit: Int = 500) throws -> [CleanupLogEntry] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM cleanup_log ORDER BY at DESC, id DESC LIMIT ?", arguments: [limit])
                .compactMap { row in
                    guard let category = Category(rawValue: row["category"]) else { return nil }
                    return CleanupLogEntry(at: Date(timeIntervalSince1970: row["at"]), path: row["path"],
                                           category: category, method: row["method"],
                                           reclaimedBytes: row["reclaimed_bytes"], succeeded: row["succeeded"],
                                           message: row["message"])
                }
        }
    }
}
