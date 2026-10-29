import Foundation
import Testing
@testable import StoragerCore

struct ScanScheduleTests {
    let launch = Date(timeIntervalSince1970: 1_000_000)
    let hour: TimeInterval = 3600

    @Test func firstScanThirtySecondsAfterLaunch() {
        let schedule = ScanSchedule(launchedAt: launch, interval: 6 * hour)
        #expect(schedule.decide(now: launch.addingTimeInterval(29), lastCompleted: nil, onBattery: false, lowPowerMode: false) == .wait)
        #expect(schedule.decide(now: launch.addingTimeInterval(30), lastCompleted: nil, onBattery: false, lowPowerMode: false) == .run)
    }

    @Test func nextScanAfterIntervalFromLatestOfAttemptOrCompletion() {
        let schedule = ScanSchedule(launchedAt: launch, interval: 6 * hour, lastAttempt: launch)
        let manual = launch.addingTimeInterval(5 * hour)
        #expect(schedule.decide(now: launch.addingTimeInterval(6 * hour), lastCompleted: nil,
                                onBattery: false, lowPowerMode: false) == .run)
        #expect(schedule.decide(now: launch.addingTimeInterval(6 * hour), lastCompleted: manual,
                                onBattery: false, lowPowerMode: false) == .wait)
        #expect(schedule.decide(now: manual.addingTimeInterval(6 * hour), lastCompleted: manual,
                                onBattery: false, lowPowerMode: false) == .run)
    }

    @Test func skipsOnBatteryOrLowPowerOnlyWhenDue() {
        let schedule = ScanSchedule(launchedAt: launch, interval: hour)
        let due = launch.addingTimeInterval(60)
        #expect(schedule.decide(now: due, lastCompleted: nil, onBattery: true, lowPowerMode: false) == .skipForPower)
        #expect(schedule.decide(now: due, lastCompleted: nil, onBattery: false, lowPowerMode: true) == .skipForPower)
        #expect(schedule.decide(now: launch, lastCompleted: nil, onBattery: true, lowPowerMode: false) == .wait)
    }

    @Test func waitsWhenOneSecondShortOfInterval() {
        let schedule = ScanSchedule(launchedAt: launch, interval: 6 * hour, lastAttempt: launch)
        #expect(schedule.decide(now: launch.addingTimeInterval(6 * hour - 1), lastCompleted: nil,
                                onBattery: false, lowPowerMode: false) == .wait)
    }

    @Test func laterAttemptThanCompletionCountsFromAttempt() {
        // 시작한 스캔이 실패해 lastCompleted 가 더 오래된 경우: 시도 시각부터 한 주기를 기다린다
        let attempt = launch.addingTimeInterval(7 * hour)
        let completed = launch.addingTimeInterval(hour)
        let schedule = ScanSchedule(launchedAt: launch, interval: 6 * hour, lastAttempt: attempt)
        #expect(schedule.decide(now: attempt.addingTimeInterval(6 * hour - 1), lastCompleted: completed,
                                onBattery: false, lowPowerMode: false) == .wait)
        #expect(schedule.decide(now: attempt.addingTimeInterval(6 * hour), lastCompleted: completed,
                                onBattery: false, lowPowerMode: false) == .run)
    }

    @Test func skipsForPowerOnPeriodicPathOnlyWhenDue() {
        let schedule = ScanSchedule(launchedAt: launch, interval: 6 * hour, lastAttempt: launch)
        let due = launch.addingTimeInterval(6 * hour)
        #expect(schedule.decide(now: due, lastCompleted: nil, onBattery: true, lowPowerMode: false) == .skipForPower)
        #expect(schedule.decide(now: due, lastCompleted: nil, onBattery: false, lowPowerMode: true) == .skipForPower)
        #expect(schedule.decide(now: due.addingTimeInterval(-1), lastCompleted: nil,
                                onBattery: true, lowPowerMode: true) == .wait)
    }

    @Test func clockWentBackTreatsScanAsDue() {
        // 기준 시각이 now 보다 미래(시계가 뒤로 감)면 주기가 지난 것으로 본다
        let now = launch.addingTimeInterval(10 * hour)
        let future = now.addingTimeInterval(48 * hour)
        let attempted = ScanSchedule(launchedAt: launch, interval: 6 * hour, lastAttempt: future)
        #expect(attempted.decide(now: now, lastCompleted: nil, onBattery: false, lowPowerMode: false) == .run)
        let completed = ScanSchedule(launchedAt: launch, interval: 6 * hour)
        #expect(completed.decide(now: now, lastCompleted: future, onBattery: false, lowPowerMode: false) == .run)
        #expect(attempted.decide(now: now, lastCompleted: nil, onBattery: true, lowPowerMode: false) == .skipForPower)
    }

    @Test func futureTimestampIsIgnoredWhilePastOneIsWithinInterval() {
        // 성공 스캔 뒤 시계가 뒤로 가고 다음 자동 스캔이 실패해도, 미래의 완료 시각 때문에 매 tick 실행하지 않는다
        let now = launch.addingTimeInterval(10 * hour)
        let future = now.addingTimeInterval(48 * hour)
        let recent = ScanSchedule(launchedAt: launch, interval: 6 * hour, lastAttempt: now.addingTimeInterval(-60))
        #expect(recent.decide(now: now, lastCompleted: future, onBattery: false, lowPowerMode: false) == .wait)
        #expect(recent.decide(now: now, lastCompleted: future, onBattery: true, lowPowerMode: false) == .wait)
        let old = ScanSchedule(launchedAt: launch, interval: 6 * hour, lastAttempt: now.addingTimeInterval(-6 * hour))
        #expect(old.decide(now: now, lastCompleted: future, onBattery: false, lowPowerMode: false) == .run)
    }

    @Test func launchInTheFutureRunsFirstScan() {
        let schedule = ScanSchedule(launchedAt: launch.addingTimeInterval(48 * hour), interval: 6 * hour)
        #expect(schedule.decide(now: launch, lastCompleted: nil, onBattery: false, lowPowerMode: false) == .run)
        #expect(schedule.decide(now: launch, lastCompleted: nil, onBattery: true, lowPowerMode: false) == .skipForPower)
    }
}
