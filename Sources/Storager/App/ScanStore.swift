import AppKit
import Observation
import StoragerCore

/// 스캔 결과와 진행 상태. UI 는 읽기만 하고, 바꾸는 일은 모두 이 클래스를 거친다.
@MainActor
@Observable
final class ScanStore {
    private(set) var result: ScanResult? {
        didSet {
            resultGeneration += 1
            recomputeSummaries()
        }
    }
    /// `result` 를 바꿀 때마다 늘어난다. 메인 밖에서 재스캔하는 동안 결과가 바뀌었는지 확인하고,
    /// 분석 윈도우가 결과에서 계산한 값(트리맵 칸·큰 파일 목록)을 다시 계산하거나 정리 계획이 낡았는지 판단한다.
    /// 관찰 대상이라 이 값을 읽은 뷰는 결과가 바뀌면 다시 그려진다.
    private(set) var resultGeneration = 0
    private(set) var isScanning = false
    private(set) var progress = ScanProgress(completed: 0, total: 0)
    private(set) var volume: VolumeStats?
    /// 앱 시작 직후(아직 스캔 전) 카드를 채우는 마지막 스냅샷
    private(set) var latestSnapshot: Snapshot? {
        didSet { recomputeSummaries() }
    }
    /// 7일 변화량 기준 스냅샷
    private(set) var baseline: Snapshot? {
        didSet { recomputeSummaries() }
    }
    private(set) var lastError: String?
    /// 전체 디스크 접근 권한 상태. 스캔을 시작할 때·앱이 활성화될 때(시스템 설정에서 돌아온 뒤) 다시 확인한다.
    /// 권한이 없으면(`.unknown` 포함) 스캔이 보호 폴더를 건너뛴다.
    private(set) var fullDiskAccess: FullDiskAccess.Status = .unknown
    /// 마지막 결과에서 권한이 없어 건너뛴 보호 폴더 (실제 경로)
    var skippedForPermission: [String] { result?.skippedForPermission ?? [] }

    /// 카테고리 카드(합계·변화량·도구). `result`·`baseline`·`latestSnapshot` 이 바뀔 때만 다시 계산한다.
    private(set) var summaries: [CategorySummary] = []

    /// 도구 구분이 있는 카테고리. 카테고리 테이블·트리 뷰의 "도구" 열이 도구 없는 항목을 사이드바처럼 "기타" 로 보여 줄 곳이다
    var categoriesWithTools: Set<StoragerCore.Category> {
        Set(summaries.filter { !$0.tools.isEmpty }.map(\.category))
    }

    /// false 면 DB 를 열 수 없어 메모리 저장소를 쓰는 중이다(추세가 종료와 함께 사라짐)
    @ObservationIgnored let isPersistent: Bool
    @ObservationIgnored let homePath: String
    @ObservationIgnored private let settings: StoragerSettings
    @ObservationIgnored private let snapshots: SnapshotStore
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var volumeRefresh: Task<Void, Never>?
    /// 전체 스캔 중에 정리한 경로. 스캔이 끝나면 새 결과에 다시 반영한다(그 스캔이 정리 전 상태를 읽었을 수 있다).
    @ObservationIgnored private var cleanedPathsDuringScan: [String] = []
    /// 앱 활성화 알림 구독 (deinit 에서 해제)
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    /// 상태만 갱신하는 확인(`refreshFullDiskAccess(rescanOnGrant: false)`)에서 새로 허용된 것을 봐 미뤄 둔 재스캔
    @ObservationIgnored private var pendingGrantRescan = false

    init(settings: StoragerSettings, snapshots: SnapshotStore, isPersistent: Bool = true,
         homePath: String = NSHomeDirectory()) {
        self.settings = settings
        self.snapshots = snapshots
        self.isPersistent = isPersistent
        // 스캔 결과 경로(ScanResult.homePath)와 같은 표기가 되도록 심볼릭 링크를 푼다
        self.homePath = PathUtil.resolve(homePath)
        fullDiskAccess = FullDiskAccess.check()
        latestSnapshot = try? snapshots.latest()
        // 카드가 보여 주는 마지막 스냅샷과 같은 범위(제한 스캔 여부)의 기준을 고른다
        baseline = try? snapshots.baseline(now: Date(), limited: latestSnapshot?.isLimited ?? !fullDiskAccess.isGranted)
        // @Observable 의 init 접근자 동작에 기대지 않도록 끝에서 한 번 더 계산한다
        recomputeSummaries()
        refreshVolume()
        // 시스템 설정에서 전체 디스크 접근을 켜고 돌아오면 안내·배너가 바로 바뀌도록 다시 확인한다
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFullDiskAccess() }
        }
    }

    isolated deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// 전체 디스크 접근 권한을 다시 확인한다. 확인용 파일 몇 개를 열었다 닫을 뿐이라 메인에서 바로 한다.
    /// 권한이 없다가 허용되면 바로 다시 스캔한다("지금 스캔" 과 같은 경로라 배터리 전원이어도 돈다).
    /// 이미 스캔 중이면 그 스캔이 끝난 결과는 여전히 제한 스캔이라 배너가 다시 스캔하라고 안내한다.
    /// - Parameter rescanOnGrant: false 면 상태만 갱신한다. 정리 미리보기·설정 창·안내 창처럼 사용자가 다른 일을 하는
    ///   중에 스캔이 시작되지 않게 한다. 그때 새로 허용된 것을 보면 미뤄 두었다가, 다음 앱 활성화(true 로 부르는 경로)나
    ///   설정 창·안내 창 닫기, 팝오버 열기(`runPendingGrantRescan`)에서 다시 스캔한다. 그 사이 다른 스캔이 시작되면(`startScan`) 그 스캔이 권한을 반영하므로 미룬 요청을 버린다.
    func refreshFullDiskAccess(rescanOnGrant: Bool = true) {
        let status = FullDiskAccess.check()
        if status != fullDiskAccess {
            Log.app.info("전체 디스크 접근: \(String(describing: status), privacy: .public)")
            let newlyGranted = status.isGranted && !fullDiskAccess.isGranted
            fullDiskAccess = status
            pendingGrantRescan = newlyGranted && !isScanning
        }
        guard rescanOnGrant else { return }
        runPendingGrantRescan()
    }

    /// 상태만 갱신하는 확인에서 미뤄 둔 권한 허용 재스캔이 있으면 지금 한다 (권한을 다시 확인하지는 않는다).
    /// 앱이 활성 상태로 남아 활성화 알림이 오지 않는 경우를 위해 설정 창·안내 창을 닫을 때와 팝오버를 열 때도 부른다.
    /// 스캔 중이면 하지 않는다(그 스캔이 끝난 뒤 다음 기회에 한다). 정리 실행 중의 스캔은 원래 지원한다.
    func runPendingGrantRescan() {
        guard pendingGrantRescan, fullDiskAccess.isGranted, !isScanning else { return }
        pendingGrantRescan = false
        startScan()
    }

    /// 권한이 없을 때 스캔·재스캔·정리가 건너뛸 위치 (권한이 있으면 비어 있다)
    var permissionSkip: PermissionSkip { fullDiskAccess.permissionSkip(homePath: homePath) }

    /// 설정과 현재 권한 상태로 만든 스캔 옵션. 권한이 없으면 보호 위치를 건너뛴다(부분 재스캔도 들어가지 않는다).
    private func makeScanOptions() -> ScanOptions {
        settings.makeScanOptions(permissionSkip: permissionSkip)
    }

    var lastCompletedAt: Date? { result?.finishedAt ?? latestSnapshot?.at }

    private func recomputeSummaries() {
        let totals = result?.classification.totals ?? latestSnapshot?.categories ?? [:]
        let deltas = Snapshot.categoryDeltas(current: totals, baseline: baseline)
        summaries = CategorySummary.make(classification: result?.classification, totals: totals, deltas: deltas)
    }

    /// 여유 용량을 메인 스레드 밖에서 읽고 결과만 메인에서 반영한다
    /// (`volumeAvailableCapacityForImportantUsage` 는 수십 ms, 디스크가 꽉 차면 더 걸린다).
    /// 이미 읽는 중이면 새로 읽지 않고 그 작업을 돌려준다. 끝날 때까지 기다리려면 `.value` 를 await 한다.
    @discardableResult
    func refreshVolume() -> Task<Void, Never> {
        if let volumeRefresh { return volumeRefresh }
        let homePath = homePath
        let task = Task { [weak self] in
            let read = await Task.detached(priority: .utility) {
                Result { try VolumeStats.read(path: homePath) }
            }.value
            guard let self else { return }
            volumeRefresh = nil
            switch read {
            case .success(let volume):
                self.volume = volume
            case .failure(let error):
                Log.app.error("볼륨 정보 읽기 실패: \(String(describing: error), privacy: .public)")
            }
        }
        volumeRefresh = task
        return task
    }

    // MARK: 전체 스캔

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        progress = ScanProgress(completed: 0, total: 0)
        lastError = nil
        cleanedPathsDuringScan = []
        // 권한은 스캔마다 다시 확인한다 (나중에 허용하면 다음 스캔부터 보호 폴더도 센다).
        // 이 스캔이 현재 권한을 반영하므로 미뤄 둔 권한 허용 재스캔은 버린다.
        refreshFullDiskAccess()
        pendingGrantRescan = false
        let options = makeScanOptions()
        let extraRoots = settings.extraProjectRoots
        let homePath = homePath
        scanTask = Task { [weak self] in
            do {
                // ScanResult.scan 은 nonisolated async 라 메인 스레드 밖에서 돈다
                let result = try await ScanResult.scan(
                    homePath: homePath, extraRootPaths: extraRoots, options: options,
                    progress: { progress in Task { @MainActor in self?.progress = progress } })
                await self?.finish(with: result)
            } catch is CancellationError {
                Log.scan.info("스캔 취소")
                self?.endScanWithoutResult()
            } catch {
                Log.scan.error("스캔 실패: \(String(describing: error), privacy: .public)")
                self?.lastError = error.localizedDescription
                self?.endScanWithoutResult()
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    /// 취소·실패한 스캔. 스캔 중 정리한 경로는 `applyCleanup` 이 이미 이전 결과에 반영했으므로 목록만 비운다.
    private func endScanWithoutResult() {
        cleanedPathsDuringScan = []
        isScanning = false
    }

    /// 끝까지 완료된 스캔만 스냅샷으로 저장한다.
    private func finish(with scanned: ScanResult) async {
        // 스냅샷에 넣을 볼륨 값을 갱신하고 기다린다(읽기 실패 시 직전 값을 쓴다)
        await refreshVolume().value
        // 스캔 중에 정리한 경로를 새 결과 기준으로 다시 재고 나서 게시한다. 기다리는 동안 더 정리하면 그것도 반영한다.
        var result = scanned
        let options = makeScanOptions()
        while !cleanedPathsDuringScan.isEmpty {
            let paths = cleanedPathsDuringScan
            cleanedPathsDuringScan = []
            result = await Self.rescanned(result, paths: paths, options: options)
        }
        // 위 반복이 목록을 비운 직후 같은 메인 actor 구간에서 게시하므로 빠지는 경로가 없다
        self.result = result
        isScanning = false
        guard let volume else {
            Log.store.error("볼륨 정보가 없어 스냅샷 저장을 건너뜀")
            return
        }
        let snapshots = snapshots
        // 스냅샷 요약(상위 디렉터리 등)은 트리 전체를 훑으므로 저장과 함께 메인 밖에서 만든다 (결과는 Sendable 값이다)
        let saved = await Task.detached(priority: .utility) { [result] () -> Result<(Snapshot, Snapshot?), any Error> in
            Result {
                let snapshot = Snapshot.make(from: result, volume: volume)
                try snapshots.save(snapshot)
                try snapshots.compact(now: snapshot.at)
                return (snapshot, try snapshots.baseline(now: snapshot.at, limited: snapshot.isLimited))
            }
        }.value
        switch saved {
        case .success(let (snapshot, baseline)):
            latestSnapshot = snapshot
            self.baseline = baseline
        case .failure(let error):
            Log.store.error("스냅샷 저장 실패: \(String(describing: error), privacy: .public)")
        }
        Log.scan.info("스캔 완료: \(result.home.fileCount, privacy: .public)개 파일")
    }

    // MARK: 정리 후 부분 재스캔

    /// 정리에 성공한 경로들만 다시 재고 트리·분류를 갱신한다. 스냅샷은 저장하지 않는다.
    /// 전체 스캔 중이면 그 경로를 모아 두었다가 스캔이 끝난 뒤 새 결과에도 다시 반영한다.
    func applyCleanup(_ outcomes: [CleanupOutcome]) async {
        let paths = outcomes.filter(\.succeeded).map(\.item.path)
        guard !paths.isEmpty else { return }
        if isScanning {
            cleanedPathsDuringScan += paths
        }
        let options = makeScanOptions()
        // 재스캔은 현재 결과의 루트별 하드링크 귀속 맵을 기준으로 한다. 재는 동안 결과가 바뀌면(스캔 완료·다른 정리)
        // 이전 결과 기준 재스캔은 버리고 새 결과 기준으로 다시 잰다(정리 전 상태로 되돌아가지 않도록).
        while let current = result {
            let generation = resultGeneration
            let updated = await Self.rescanned(current, paths: paths, options: options)
            if resultGeneration == generation {
                result = updated
                break
            }
        }
        refreshVolume()
    }

    /// `result` 에 경로들의 부분 재스캔을 메인 스레드 밖에서 반영한 사본.
    private nonisolated static func rescanned(_ result: ScanResult, paths: [String],
                                              options: ScanOptions) async -> ScanResult {
        await Task.detached(priority: .userInitiated) {
            var updated = result
            updated.rescanAndApply(paths: paths, options: options)
            return updated
        }.value
    }
}
