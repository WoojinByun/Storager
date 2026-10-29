import Foundation

public struct DirectorySize: Sendable, Equatable {
    public var path: String
    public var size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }
}

/// 완료된 스캔 하나의 요약. 추세 계산에 쓴다.
public struct Snapshot: Sendable, Equatable {
    public static let topDirectoryLimit = 100

    public var id: Int64?
    public var at: Date
    public var volume: VolumeStats
    public var categories: [Category: CategoryTotal]
    public var topDirectories: [DirectorySize]
    /// 전체 디스크 접근 권한 없이 잰 제한 스캔의 스냅샷인지 (`ScanResult.isLimited`).
    /// 변화량 기준(`SnapshotStore.baseline`)은 같은 값의 스냅샷만 고른다.
    public var isLimited: Bool

    public init(id: Int64? = nil, at: Date, volume: VolumeStats, categories: [Category: CategoryTotal],
                topDirectories: [DirectorySize], isLimited: Bool = false) {
        self.id = id
        self.at = at
        self.volume = volume
        self.categories = categories
        self.topDirectories = topDirectories
        self.isLimited = isLimited
    }

    public static func make(from result: ScanResult, volume: VolumeStats) -> Snapshot {
        let top = result.home.largestDirectories(path: result.homePath, limit: topDirectoryLimit)
            .map { DirectorySize(path: $0.path, size: $0.size) }
        return Snapshot(at: result.finishedAt, volume: volume, categories: result.classification.totals,
                        topDirectories: top, isLimited: result.isLimited)
    }

    /// 카테고리별 변화량 (현재 - 기준). 기준이 없으면 빈 사전. 정리 뒤처럼 스냅샷이 아닌 현재 합계로도 계산한다.
    public static func categoryDeltas(current: [Category: CategoryTotal], baseline: Snapshot?) -> [Category: Int64] {
        guard let baseline else { return [:] }
        var result: [Category: Int64] = [:]
        for category in Set(current.keys).union(baseline.categories.keys) {
            result[category] = (current[category]?.size ?? 0) - (baseline.categories[category]?.size ?? 0)
        }
        return result
    }
}

/// 정리 기록 한 줄 (cleanup_log).
public struct CleanupLogEntry: Sendable, Equatable {
    public var at: Date
    public var path: String
    public var category: Category
    public var method: String
    public var reclaimedBytes: Int64
    public var succeeded: Bool
    public var message: String?

    public init(at: Date, path: String, category: Category, method: String, reclaimedBytes: Int64, succeeded: Bool,
                message: String?) {
        self.at = at
        self.path = path
        self.category = category
        self.method = method
        self.reclaimedBytes = reclaimedBytes
        self.succeeded = succeeded
        self.message = message
    }
}
