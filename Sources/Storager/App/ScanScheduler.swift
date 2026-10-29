import Foundation
import IOKit.ps
import StoragerCore

/// 60초마다 여유 용량을 갱신하고, 주기가 되면 스캔을 시작한다. 첫 스캔은 시작 30초 뒤.
@MainActor
final class ScanScheduler {
    private let store: ScanStore
    private let settings: StoragerSettings
    private var schedule: ScanSchedule
    private var timer: Timer?

    init(store: ScanStore, settings: StoragerSettings, launchedAt: Date = Date()) {
        self.store = store
        self.settings = settings
        schedule = ScanSchedule(launchedAt: launchedAt, interval: settings.scanInterval)
    }

    /// 두 번 불러도 타이머는 하나만 돈다.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // 60초 타이머를 기다리지 않고 30초 뒤 첫 스캔을 확인한다
        DispatchQueue.main.asyncAfter(deadline: .now() + ScanSchedule.initialDelay) { [weak self] in
            self?.tick()
        }
    }

    isolated deinit {
        timer?.invalidate()
    }

    private func tick() {
        store.refreshVolume()
        schedule.interval = settings.scanInterval
        let now = Date()
        switch schedule.decide(now: now, lastCompleted: store.result?.finishedAt,
                               onBattery: Self.isOnBattery, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled) {
        case .wait:
            break
        case .skipForPower:
            schedule.lastAttempt = now
            Log.scan.info("배터리·저전력 모드라 이번 주기 스캔을 건너뜀")
        case .run:
            schedule.lastAttempt = now
            store.startScan()
        }
    }

    /// 지금 배터리로 동작 중인지 (IOKit 전원 정보).
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPMBatteryPowerKey
    }
}
