import Foundation

/// 주기 스캔을 지금 시작할지 정한다. 앱의 60초 타이머가 매번 묻는다.
public struct ScanSchedule: Sendable, Equatable {
    /// 앱 시작 뒤 첫 스캔까지
    public static let initialDelay: TimeInterval = 30

    public enum Decision: Sendable, Equatable {
        case wait
        case run
        /// 배터리·저전력 모드라 이번 회차를 건너뛴다 (다음 주기에 다시)
        case skipForPower
    }

    public var launchedAt: Date
    public var interval: TimeInterval
    /// 마지막으로 스캔을 시작했거나 전원 때문에 건너뛴 시각
    public var lastAttempt: Date?

    public init(launchedAt: Date, interval: TimeInterval, lastAttempt: Date? = nil) {
        self.launchedAt = launchedAt
        self.interval = interval
        self.lastAttempt = lastAttempt
    }

    /// - Parameter lastCompleted: 마지막으로 끝난 스캔 (수동 "지금 스캔" 포함)
    public func decide(now: Date, lastCompleted: Date?, onBattery: Bool, lowPowerMode: Bool) -> Decision {
        // 미래 시각(시계가 뒤로 감)은 기준에서 뺀다. 남은 기준이 없으면 한 번 실행하고,
        // 앱이 그 시도 시각을 lastAttempt 로 기록하면 거기서부터 한 주기를 기다린다.
        let known = [lastAttempt, lastCompleted].compactMap { $0 }
        let due: Bool
        if !known.isEmpty {
            due = known.filter { $0 <= now }.max().map { now.timeIntervalSince($0) >= interval } ?? true
        } else {
            due = launchedAt > now || now.timeIntervalSince(launchedAt) >= Self.initialDelay
        }
        guard due else { return .wait }
        return onBattery || lowPowerMode ? .skipForPower : .run
    }
}
