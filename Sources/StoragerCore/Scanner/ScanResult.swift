import Foundation

/// 한 번의 전체 스캔 결과: 홈 + 추가 루트(각각 트리와 하드링크 귀속 맵) + 분류.
public struct ScanResult: Sendable {
    public var homeScan: TreeScan
    /// 홈 밖에서 추가로 스캔한 프로젝트 루트들 (스캔 순서)
    public var extraRoots: [TreeScan]
    public var classification: Classification
    public var finishedAt: Date
    /// 전체 디스크 접근 권한 없이 잰 제한 스캔인지 (옵션에 권한 건너뛰기가 있었는지). 실제로 건너뛴 폴더가 없어도
    /// 권한이 없으면 메일·Safari 같은 폴더를 셀 수 없어 합계가 다르므로 권한 여부 하나로 정한다.
    /// 스냅샷에 기록해 변화량은 같은 범위의 스냅샷끼리만 비교한다.
    public var isLimited: Bool

    public init(homeScan: TreeScan, extraRoots: [TreeScan], classification: Classification, finishedAt: Date,
                isLimited: Bool = false) {
        self.homeScan = homeScan
        self.extraRoots = extraRoots
        self.classification = classification
        self.finishedAt = finishedAt
        self.isLimited = isLimited
    }

    /// 홈의 실제 경로 (`PathUtil.resolve`)
    public var homePath: String { homeScan.rootPath }
    public var home: DirectoryNode { homeScan.root }

    /// 전체 디스크 접근 권한이 없어 건너뛴 보호 폴더 (홈·추가 루트 순, 실제 경로).
    public var skippedForPermission: [String] {
        homeScan.skippedForPermission + extraRoots.flatMap(\.skippedForPermission)
    }

    /// 홈과 추가 루트를 스캔하고 분류한다. 진행률은 홈 1단계 디렉터리 기준이다.
    public static func scan(
        homePath: String,
        extraRootPaths: [String],
        options: ScanOptions,
        rules: [ClassificationRule] = RuleCatalog.default,
        now: @Sendable () -> Date = Date.init,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> ScanResult {
        let homeScanner = TreeScanner(rootPath: homePath, options: options)
        let homePath = homeScanner.rootPath
        let home = try await homeScanner.scan(progress: progress)
        let accepted = ExtraRootConflict.acceptedRoots(extraRootPaths, homePath: homePath,
                                                       permissionSkip: options.permissionSkip, logsSkipped: true)
        var extras: [TreeScan] = []
        // 루트마다 이미 1단계 디렉터리를 동시 4개로 재므로 추가 루트는 순차로 스캔한다 (동시성이 곱해지지 않도록)
        for path in accepted {
            try Task.checkCancellation()
            do {
                extras.append(try await TreeScanner(rootPath: path, options: options).scan())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 추가 루트가 없거나(외장 볼륨 분리 등) 읽을 수 없으면 건너뛴다
                Log.scan.error("추가 루트 스캔 실패 \(path, privacy: .private): \(String(describing: error), privacy: .public)")
            }
        }
        try Task.checkCancellation()
        let classifier = Classifier(rules: rules, homePath: homePath)
        var items = classifier.classify(root: home.root, rootPath: homePath)
        for extra in extras {
            items += classifier.classify(root: extra.root, rootPath: extra.rootPath)
        }
        return ScanResult(homeScan: home, extraRoots: extras, classification: Classification(items: items),
                          finishedAt: now(), isLimited: !options.permissionSkip.isEmpty)
    }

    /// `path` 가 속한 루트(홈 또는 추가 루트 중 가장 깊은 것)를 그 루트의 귀속 맵·볼륨으로 부분 재스캔한다 (동기, 결과는 바꾸지 않는다).
    /// 어느 루트에도 속하지 않으면 `RescanError.outsideRoot` 를 던진다. 반영은 `apply(_:)` 로 한다.
    public func rescan(path: String, options: ScanOptions) throws -> SubtreeRescan {
        try rescan(path: path, options: options, batches: [:])
    }

    /// `batches`(루트 경로 → 아직 귀속 맵에 반영하지 않은 변경)가 있으면 그것까지 반영한 귀속 맵으로 잰다.
    private func rescan(path: String, options: ScanOptions,
                        batches: [String: HardLinkOwnerBatch]) throws -> SubtreeRescan {
        // 권한 없이 건너뛰는 위치 안이면 realpath 전에 거부한다 (`TreeScanner.rescan(path:previous:)` 참고)
        let standardized = PathUtil.standardize(path)
        guard !options.permissionSkip.covers(standardized) else { throw RescanError.permissionRequired(standardized) }
        let resolved = PathUtil.resolve(standardized)
        let base = ([homeScan] + extraRoots)
            .filter { PathUtil.isSameOrDescendant(resolved, of: $0.rootPath) }
            .max { $0.rootPath.count < $1.rootPath.count }
        guard let base else { throw RescanError.outsideRoot(resolved) }
        let scanner = TreeScanner(rootPath: base.rootPath, options: options)
        guard let batch = batches[base.rootPath], !batch.isEmpty else {
            return try scanner.rescan(path: resolved, previous: base)
        }
        return try scanner.rescan(path: resolved, previous: base,
                                  existingOwner: { batch.owner(of: $0, in: base.hardLinkOwners) })
    }

    /// 부분 재스캔 결과를 해당 루트의 트리·귀속 맵과 분류에 반영한다. `rescan.node` 가 nil 이면 그 경로가 사라진 것이다.
    /// 분류는 `rescan.path` 와 같은 항목만 갱신한다 (그 경로 아래의 더 깊은 항목이나 조상 항목은 건드리지 않는다).
    /// 반영했으면 true. 루트를 모르거나 트리에 그 경로가 없어 반영하지 못하면(대소문자가 다른 경로 등) 분류는 건드리지 않고 notice 로그만 남긴 뒤 false 를 돌려준다.
    /// 하드링크 귀속은 다음 전체 스캔까지 근사일 수 있다(`TreeScanner.rescan(path:previous:)` 참고).
    @discardableResult
    public mutating func apply(_ rescan: SubtreeRescan) -> Bool {
        apply(rescan, updatingTree: { $0.apply($1) })
    }

    /// `apply(_:)` 와 같되 하드링크 귀속 맵은 바꾸지 않는다 (`rescanAndApply` 가 묶어서 반영한다).
    private mutating func applyTree(_ rescan: SubtreeRescan) -> Bool {
        apply(rescan, updatingTree: { $0.applyTree($1) })
    }

    private mutating func apply(_ rescan: SubtreeRescan,
                                updatingTree update: (inout TreeScan, SubtreeRescan) -> Bool) -> Bool {
        let applied: Bool
        if rescan.rootPath == homeScan.rootPath {
            applied = update(&homeScan, rescan)
        } else if let index = extraRoots.firstIndex(where: { $0.rootPath == rescan.rootPath }) {
            applied = update(&extraRoots[index], rescan)
        } else {
            applied = false
        }
        guard applied else {
            Log.scan.notice("부분 재스캔 반영 건너뜀 \(rescan.path, privacy: .private): 트리에 없는 경로이거나 알 수 없는 루트")
            return false
        }
        classification.update(path: rescan.path, size: rescan.node?.allocatedSize,
                              newestModification: rescan.node?.newestModification)
        return true
    }

    /// 정리한 경로들을 차례로 부분 재스캔해 반영한다 (동기). 각 경로는 앞 경로까지 반영한 결과의 귀속 맵으로 잰다.
    /// 재스캔에 실패한 경로(루트 밖·제외 경로·읽기 오류 등)는 "사라짐" 으로 반영하지 않고 로그만 남긴다.
    /// 반영한 경로 수를 돌려준다.
    ///
    /// 결과는 경로마다 `apply(rescan(path:options:))` 를 부른 것과 같다. 다만 하드링크 귀속 맵은 경로마다 전체를 거르지 않고
    /// 루트별 `HardLinkOwnerBatch` 에 모았다가 끝에 한 번 반영한다(경로 P 개 × 맵 H 항목 대신 P + H).
    @discardableResult
    public mutating func rescanAndApply(paths: [String], options: ScanOptions) -> Int {
        var applied = 0
        var batches: [String: HardLinkOwnerBatch] = [:]
        for path in paths {
            do {
                let rescan = try rescan(path: path, options: options, batches: batches)
                if applyTree(rescan) {
                    batches[rescan.rootPath, default: HardLinkOwnerBatch()].record(rescan)
                    applied += 1
                }
            } catch {
                Log.scan.error("부분 재스캔 실패 \(path, privacy: .private): \(String(describing: error), privacy: .public)")
            }
        }
        for (rootPath, batch) in batches {
            if rootPath == homeScan.rootPath {
                batch.apply(to: &homeScan.hardLinkOwners)
            } else if let index = extraRoots.firstIndex(where: { $0.rootPath == rootPath }) {
                batch.apply(to: &extraRoots[index].hardLinkOwners)
            }
        }
        return applied
    }

    /// 홈 트리에서 경로의 노드 (트리맵 드릴다운용).
    public func homeNode(at components: [String]) -> DirectoryNode? {
        home.descendant(at: components)
    }
}

/// 추가 프로젝트 루트가 홈 또는 다른 추가 루트와 겹치는 방식. 겹치면 같은 디렉터리를 두 번 세므로 추가 루트로 쓰지 않는다.
public enum ExtraRootConflict: Sendable, Equatable {
    /// 홈 자신
    case sameAsHome
    /// 홈의 자손 (이미 홈 스캔에 들어 있다)
    case insideHome
    /// 홈의 조상 (`/Users`, `/` 등)
    case containsHome
    /// 이미 있는 추가 루트와 같다
    case duplicate
    /// 이미 있는 다른 추가 루트의 자손 (그 스캔에 들어 있다)
    case insideOtherRoot
    /// 이미 있는 다른 추가 루트를 포함한다 (설정 화면은 기존 루트를 바꾸지 않고 추가를 거부한다)
    case containsOtherRoot
    /// 전체 디스크 접근 권한이 없어 건너뛰는 위치(홈 밖의 사진 보관함 자신이나 그 안쪽, 그리로 가는 링크)다. 권한을 허용하면 다시 쓴다
    case permissionRequired

    /// 설정 화면에서 추가를 거부할 때·로그에 보여 줄 이유
    public var message: String {
        switch self {
        case .sameAsHome: "홈 폴더는 이미 스캔합니다."
        case .insideHome: "홈 안의 폴더는 이미 스캔합니다."
        case .containsHome: "홈을 포함하는 폴더는 홈을 두 번 세게 되어 추가 루트로 쓸 수 없습니다."
        case .duplicate: "이미 추가한 루트입니다."
        case .insideOtherRoot: "이미 추가한 다른 루트 안의 폴더는 이미 스캔합니다."
        case .containsOtherRoot: "이미 추가한 다른 루트를 포함하는 폴더는 같은 폴더를 두 번 세게 되어 추가할 수 없습니다. 기존 루트를 먼저 지우세요."
        case .permissionRequired: "전체 디스크 접근 권한이 없어 사진 보관함이나 그 안의 폴더는 쓸 수 없습니다. 권한을 허용한 뒤 다시 추가하세요."
        }
    }

    /// 이미 저장된 루트의 행 옆에 보여 줄 이유. 권한 사유만 추가 안내 대신 "허용하면 다시 스캔" 으로 바꾼다.
    public var storedRootMessage: String {
        switch self {
        case .permissionRequired: "전체 디스크 접근 권한이 없어 사진 보관함이나 그 안의 폴더는 스캔하지 않습니다. 권한을 허용하면 다시 스캔합니다."
        default: message
        }
    }

    /// `path` 가 홈이나 `otherRoots`(이미 받아들인 추가 루트들)와 겹치면 그 방식, 아니면 nil.
    /// 모든 경로를 `PathUtil.resolve` 로 풀어 비교하며, 홈과의 겹침을 먼저 판정한다.
    /// - Parameter permissionSkip: 전체 디스크 접근 권한이 없을 때 건너뛰는 위치. 그 안쪽 경로는 realpath 가 안을 lstat 해
    ///   동의 창을 띄우므로 풀지 않는다: 글자로 홈 안이면 `.insideHome`, 아니면(외장 볼륨의 사진 보관함 안 등) `.permissionRequired`.
    ///   `otherRoots` 중 그런 경로도 풀지 않고 비교에서 뺀다(스캔에 쓰이지 않는 루트다).
    public static func check(_ path: String, homePath: String, otherRoots: [String] = [],
                             permissionSkip: PermissionSkip = .none) -> ExtraRootConflict? {
        let standardized = PathUtil.standardize(path)
        if permissionSkip.coversInside(standardized) {
            let insideHome = permissionSkip.isInsideHomeTextually(standardized)
                || PathUtil.isSameOrDescendant(standardized, of: PathUtil.standardize(homePath))
            return insideHome ? .insideHome : .permissionRequired
        }
        let path = PathUtil.resolve(standardized)
        let home = PathUtil.resolve(homePath)
        if path == home { return .sameAsHome }
        if PathUtil.isSameOrDescendant(path, of: home) { return .insideHome }
        if PathUtil.isSameOrDescendant(home, of: path) { return .containsHome }
        // 링크를 풀어 보니 사진 보관함(이나 그 안)이면 스캔이 그 안에 들어가 동의 창을 띄우므로 쓰지 않는다.
        // 사진 보관함 자신을 고른 경우도 같다(루트가 되면 이름 규칙이 풀려 그 안을 읽는다).
        if permissionSkip.covers(path) { return .permissionRequired }
        let others = otherRoots.map(PathUtil.standardize)
            .filter { !permissionSkip.coversInside($0) }
            .map(PathUtil.resolve)
        if others.contains(path) { return .duplicate }
        if others.contains(where: { PathUtil.isSameOrDescendant(path, of: $0) }) { return .insideOtherRoot }
        if others.contains(where: { PathUtil.isSameOrDescendant($0, of: path) }) { return .containsOtherRoot }
        return nil
    }

    /// 저장된 추가 루트 목록에서 실제로 쓸 루트(`PathUtil.resolve` 로 푼 경로)를 고른다. 스캔(`ScanResult.scan`)과 정리 허용 루트(`CleanupPlanner`)가 같이 쓴다.
    /// 입력 순서대로 판정해 받아들인다: 홈과 겹치거나, 이미 받은 루트와 같거나 그 안이면 건너뛰고,
    /// 이미 받은 루트를 품은 바깥 루트가 뒤에 오면 안쪽 루트를 빼고 바깥 루트를 남긴다 (같은 디렉터리를 두 번 세지 않도록).
    /// - Parameter permissionSkip: 권한이 없을 때 건너뛰는 위치. 그 안쪽 루트는 풀지 않고 건너뛴다(`check` 참고).
    /// - Parameter logsSkipped: 건너뛴 루트를 notice 로그로 남길지. 스캔만 true 다(정리 계획마다 같은 로그가 반복되지 않도록).
    public static func acceptedRoots(_ paths: [String], homePath: String, permissionSkip: PermissionSkip = .none,
                                     logsSkipped: Bool) -> [String] {
        var accepted: [String] = []
        for raw in paths {
            let standardized = PathUtil.standardize(raw)
            // 권한 없이 건너뛰는 위치 안쪽은 realpath 전에 판정한다 (check 가 풀지 않고 이유를 돌려준다)
            let path = permissionSkip.coversInside(standardized) ? standardized : PathUtil.resolve(standardized)
            switch check(path, homePath: homePath, otherRoots: accepted, permissionSkip: permissionSkip) {
            case nil:
                accepted.append(path)
            case .containsOtherRoot:
                if logsSkipped {
                    for root in accepted where PathUtil.isSameOrDescendant(root, of: path) {
                        Log.scan.notice("추가 루트 건너뜀 \(root, privacy: .private): 바깥 추가 루트 \(path, privacy: .private) 가 포함한다")
                    }
                }
                accepted.removeAll { PathUtil.isSameOrDescendant($0, of: path) }
                accepted.append(path)
            case let conflict?:
                // 홈의 조상·홈 자신·홈의 자손, 중복, 다른 추가 루트 안, 권한 없는 위치 안 (설정 화면도 같은 함수로 추가를 막는다)
                if logsSkipped {
                    Log.scan.notice("추가 루트 건너뜀 \(path, privacy: .private): \(conflict.message, privacy: .public)")
                }
            }
        }
        return accepted
    }
}
