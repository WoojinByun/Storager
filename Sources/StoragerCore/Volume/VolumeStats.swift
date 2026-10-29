import Darwin
import Foundation

/// 볼륨 용량. 메뉴바 여유 용량·팝오버 3색 막대·스냅샷에 쓴다.
public struct VolumeStats: Sendable, Equatable {
    public var total: Int64
    /// 지금 바로 쓸 수 있는 여유 (statfs f_bavail)
    public var available: Int64
    /// 퍼지 가능 공간까지 더한 여유 (Finder 가 보여 주는 값)
    public var availableForImportantUsage: Int64

    public init(total: Int64, available: Int64, availableForImportantUsage: Int64) {
        self.total = total
        self.available = available
        self.availableForImportantUsage = availableForImportantUsage
    }

    /// 시스템이 필요할 때 비울 수 있는 공간 (캐시·로컬 스냅샷 등)
    public var purgeable: Int64 { max(0, availableForImportantUsage - available) }
    /// 사용 중 (퍼지 가능 제외)
    public var used: Int64 { max(0, total - max(available, availableForImportantUsage)) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// `path` 가 있는 볼륨을 읽는다. 기본은 홈 (Data 볼륨).
    public static func read(path: String = NSHomeDirectory()) throws -> VolumeStats {
        var info = statfs()
        guard statfs(path, &info) == 0 else { throw DirectoryReadError.posix(errno) }
        let blockSize = Int64(info.f_bsize)
        let total = Int64(info.f_blocks) * blockSize
        let available = Int64(info.f_bavail) * blockSize
        let important = importantUsage(fallback: available) {
            try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }
        return VolumeStats(total: total, available: available, availableForImportantUsage: important)
    }

    /// 퍼지 가능 공간을 더한 여유를 읽는다. 읽기에 실패하거나 값이 없으면 `fallback`(즉시 여유)으로 대신한다.
    static func importantUsage(fallback: Int64, read: () throws -> Int64?) -> Int64 {
        (try? read()) ?? fallback
    }
}
