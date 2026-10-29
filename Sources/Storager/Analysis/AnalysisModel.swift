import AppKit
import Observation
import StoragerCore

enum AnalysisSection: String, Hashable, CaseIterable, Identifiable {
    case treemap
    case categories
    case largeFiles
    case tree

    var id: String { rawValue }

    var title: String {
        switch self {
        case .treemap: "홈 트리맵"
        case .categories: "카테고리"
        case .largeFiles: "큰 파일"
        case .tree: "트리"
        }
    }

    var symbolName: String {
        switch self {
        case .treemap: "square.grid.3x3.square"
        case .categories: "tag"
        case .largeFiles: "doc.richtext"
        case .tree: "list.bullet.indent"
        }
    }
}

/// 정리 미리보기 시트의 상태.
struct CleanupRequest: Identifiable {
    /// 무엇을 정리하려 했는지. "다시 계획" 이 현재 결과에서 같은 대상을 다시 찾는 기준이다.
    enum Source {
        /// 카테고리 전체 (팝오버 "정리" 버튼). 다시 계획하면 그 카테고리의 현재 정리 가능 항목으로 계획한다
        case category(StoragerCore.Category)
        /// 고른 항목들 (우클릭·선택 항목 정리). 다시 계획하면 같은 경로를 현재 분류에서 찾는다
        case items
    }

    let id = UUID()
    var plan: CleanupPlan
    var source: Source
    /// 마지막으로 계획한 분류 항목. 다시 계획할 때 현재 분류에서 사라진 항목은 `.missing` 으로 보여 준다
    var requestedItems: [ClassifiedItem]
    /// 계획을 만든 결과 세대(`ScanStore.resultGeneration`). 실행 전에 결과가 바뀌면 계획이 낡은 것이다
    var generation: Int
    /// 계획할 때의 권한 건너뛰기 위치(`ScanStore.permissionSkip`). 실행 전에 권한이 바뀌면 계획이 낡은 것이다
    var permissionSkip: PermissionSkip
    /// 실행 직전 확인에서 받아들인 항목이 권한 건너뛰기 위치 안으로 드러났다. "다시 계획" 하면 풀린다
    var needsReplan = false
    var outcomes: [CleanupOutcome]?
    var isRunning = false
}

/// 트리맵 한 칸과 그 위치·태그. 결과 세대·경로·크기가 같으면 다시 계산하지 않는다.
struct TreemapCell {
    let tile: TreemapTile
    let rect: CGRect
    /// 가장 가까운 조상의 태그 (나머지 칸은 nil)
    let tag: CategoryTag?
    /// 칸을 칠하는 경로 해시 색. 레이아웃마다 한 번 계산한다(호버로 다시 그릴 때 해시하지 않는다).
    let color: PathColor
}

struct TreemapLayoutKey: Equatable {
    var generation: Int
    var path: [String]
    var size: CGSize
}

/// 카테고리 뷰 사이드바의 선택: 카테고리 전체 또는 그 안의 도구 하나.
struct CategoryFilter: Hashable {
    var category: StoragerCore.Category
    /// nil 이면 카테고리 전체. 도구 이름은 `ToolTotal.name(of:)` 기준이다
    var tool: String?
}

/// 분석 윈도우의 화면 상태 (선택한 뷰, 트리맵 위치, 정리 시트).
@MainActor
@Observable
final class AnalysisModel {
    var section: AnalysisSection = .treemap
    var selectedCategory: StoragerCore.Category?
    /// 카테고리 안에서 고른 도구 (nil 이면 카테고리 전체)
    var selectedTool: String?
    /// 홈 기준 드릴다운 경로
    var treemapPath: [String] = []
    var cleanupRequest: CleanupRequest?
    /// 트리 뷰의 펼침·선택 (섹션을 바꿨다 돌아와도 남는다)
    @ObservationIgnored let treeState = TreeViewState()

    @ObservationIgnored let store: ScanStore
    @ObservationIgnored let settings: StoragerSettings
    @ObservationIgnored private let snapshots: SnapshotStore
    /// 큰 파일 목록과 그것을 계산한 결과 세대(`ScanStore.resultGeneration`). 홈 트리 전체를 훑으므로 결과가 바뀔 때만 다시 계산한다.
    @ObservationIgnored private var largeFilesCache: (generation: Int, files: [LargeFileEntry])?
    /// 경로 → 분류 항목 색인 (우클릭 메뉴용). 결과 세대마다 한 번 만든다.
    @ObservationIgnored private var itemIndexCache: (generation: Int, items: [String: ClassifiedItem])?
    /// 트리맵 칸·사각형. 호버로는 다시 계산하지 않는다.
    @ObservationIgnored private var treemapCache: (key: TreemapLayoutKey, cells: [TreemapCell])?

    init(store: ScanStore, settings: StoragerSettings, snapshots: SnapshotStore) {
        self.store = store
        self.settings = settings
        self.snapshots = snapshots
    }

    /// 정리를 실행하는 중인지 (종료 확인·팝오버 요청 무시에 쓴다).
    var isCleanupRunning: Bool { cleanupRequest?.isRunning == true }

    func show(category: StoragerCore.Category?) {
        if let category {
            section = .categories
            selectedCategory = category
            selectedTool = nil
        }
    }

    /// 사이드바 선택 (카테고리 + 도구).
    var categoryFilter: CategoryFilter? {
        get { selectedCategory.map { CategoryFilter(category: $0, tool: selectedTool) } }
        set {
            selectedCategory = newValue?.category
            selectedTool = newValue?.tool
        }
    }

    // MARK: 정리

    /// 카테고리의 정리 가능 항목 전체로 미리보기를 연다 (팝오버 "정리" 버튼).
    /// 정리 실행 중이면 카테고리·선택을 바꾸지 않는다(창만 앞으로 나온다).
    func requestCleanup(category: StoragerCore.Category) {
        guard !isCleanupRunning else { return }
        show(category: category)
        startCleanupRequest(items: cleanableItems(in: category), source: .category(category))
    }

    /// 실행 중인 정리가 있으면 무시한다(결과를 덮어쓰지 않도록). 결과가 표시된 뒤의 새 요청은 새 계획으로 바꾼다.
    func requestCleanup(items: [ClassifiedItem]) {
        startCleanupRequest(items: items, source: .items)
    }

    private func startCleanupRequest(items: [ClassifiedItem], source: CleanupRequest.Source) {
        guard cleanupRequest?.isRunning != true else { return }
        guard !items.isEmpty else { return }
        // makePlan 이 권한을 다시 확인하므로 그 뒤의 건너뛰기 위치를 함께 기록한다
        let plan = makePlan(items)
        cleanupRequest = CleanupRequest(plan: plan, source: source, requestedItems: items,
                                        generation: store.resultGeneration, permissionSkip: store.permissionSkip)
    }

    /// 카테고리에서 휴지통으로 정리할 수 있는 현재 항목 (팝오버 카드의 "정리" 와 같은 기준).
    private func cleanableItems(in category: StoragerCore.Category) -> [ClassifiedItem] {
        store.result?.classification.items(in: category).filter(\.tag.isTrashCleanable) ?? []
    }

    private func makePlan(_ items: [ClassifiedItem]) -> CleanupPlan {
        makePlanner().plan(items, runningBundleIDs: FileActions.runningBundleIDs)
    }

    private func makePlanner() -> CleanupPlanner {
        // 권한을 도중에 거뒀을 수 있으므로 계획 직전에 다시 확인하고, 건너뛰는 위치 안의 항목은 건드리지 않고 거부한다.
        // 미리보기를 보는 중에 스캔이 시작되지 않도록 상태만 갱신한다 (허용 재스캔은 앱 활성화·스캔 시작 경로에서만)
        store.refreshFullDiskAccess(rescanOnGrant: false)
        return CleanupPlanner(homePath: store.homePath, extraRoots: settings.extraProjectRoots,
                              permissionSkip: store.permissionSkip)
    }

    /// 계획을 만든 뒤 스캔·정리로 결과가 바뀌었거나 권한 상태가 바뀌었는지 (실행 전 미리보기에서만 의미가 있다).
    func isStale(_ request: CleanupRequest) -> Bool {
        request.outcomes == nil && !request.isRunning
            && (request.needsReplan || request.generation != store.resultGeneration
                || request.permissionSkip != store.permissionSkip)
    }

    /// 낡은 계획을 현재 결과로 다시 계획한다. 카테고리 요청은 그 카테고리의 현재 정리 가능 항목으로,
    /// 항목 요청은 같은 경로를 현재 분류에서 다시 찾는다. 어떤 항목을 넘기고 어떤 이전 항목을 어떤 사유로 거부할지는
    /// `CleanupReplan.select` 가 정한다(거부한 이전 항목은 실행 대상이 되지 않는다).
    func replanCleanup() {
        guard var request = cleanupRequest, !request.isRunning, request.outcomes == nil else { return }
        // 권한 상태를 먼저 갱신해 사라진 항목의 사유도 현재 권한으로 정한다
        let planner = makePlanner()
        let category: StoragerCore.Category? = switch request.source {
        case .category(let category): category
        case .items: nil
        }
        let selection = CleanupReplan.select(previous: request.requestedItems, category: category,
                                             classification: store.result?.classification ?? .empty,
                                             permissionSkip: store.permissionSkip)
        var plan = planner.plan(selection.items, runningBundleIDs: FileActions.runningBundleIDs)
        plan.rejected += selection.rejected
        request.plan = plan
        request.requestedItems = selection.requested
        request.generation = store.resultGeneration
        request.permissionSkip = store.permissionSkip
        request.needsReplan = false
        cleanupRequest = request
    }

    /// 미리보기에서 "휴지통으로 이동" 을 눌렀을 때. 낡은 계획은 실행하지 않는다.
    /// 실행 직전에 권한을 다시 확인한다: 계획 뒤 권한을 거둬 건너뛰기 위치가 바뀌었거나 받아들인 항목이 그 안이면
    /// 보호 위치를 lstat 하지 않도록 실행하지 않고 낡은 계획("다시 계획")으로 둔다.
    func runCleanup() {
        guard let current = cleanupRequest, !current.isRunning, current.outcomes == nil else { return }
        // 미리보기를 보는 중에 스캔이 시작되지 않도록 상태만 갱신한다
        store.refreshFullDiskAccess(rescanOnGrant: false)
        let permissionSkip = store.permissionSkip
        guard var request = cleanupRequest, !isStale(request),
              !request.plan.accepted.contains(where: { permissionSkip.covers($0.path) }) else {
            // 권한이 바뀌었으면 isStale 이 이미 참이다. 위치는 같은데 받아들인 항목이 그 안이면(계획기가 거부했어야 한다)
            // 표시해서 다시 계획하게 한다
            cleanupRequest?.needsReplan = true
            return
        }
        request.isRunning = true
        cleanupRequest = request
        let plan = request.plan
        let executor = CleanupExecutor(store: snapshots, permissionSkip: permissionSkip)
        Task {
            let outcomes = await Task.detached(priority: .userInitiated) { executor.execute(plan) }.value
            await store.applyCleanup(outcomes)
            if cleanupRequest?.id == request.id {
                cleanupRequest?.outcomes = outcomes
                cleanupRequest?.isRunning = false
            }
        }
    }

    /// 시트 닫기(취소·Esc·닫기). 실행 중이면 무시한다(결과를 잃지 않도록).
    func closeCleanup() {
        guard cleanupRequest?.isRunning != true else { return }
        cleanupRequest = nil
    }

    // MARK: 트리 뷰

    /// 트리 뷰 "트리맵에서 보기": 트리맵으로 바꾸고 홈 기준 경로로 드릴다운한다.
    func showInTreemap(components: [String]) {
        treemapPath = components
        section = .treemap
    }

    // MARK: 무시 목록·분류 조회

    /// 무시 목록에 넣는다. 다음 스캔부터 빠진다.
    func ignore(path: String) {
        settings.ignoredPaths += [path]
    }

    /// 경로의 분류 항목 (정확히 그 경로가 분류된 경우만).
    func classifiedItem(at path: String) -> ClassifiedItem? {
        itemIndex()[path]
    }

    private func itemIndex() -> [String: ClassifiedItem] {
        let generation = store.resultGeneration
        if let cache = itemIndexCache, cache.generation == generation { return cache.items }
        let items = Dictionary((store.result?.classification.items ?? []).map { ($0.path, $0) },
                               uniquingKeysWith: { first, _ in first })
        itemIndexCache = (generation, items)
        return items
    }

    // MARK: 결과에서 계산한 값 (결과 세대마다 보관)

    /// 홈 트리의 큰 파일 상위 200개. 스캔·정리로 결과가 바뀐 뒤 처음 부를 때만 트리를 훑고, 그 밖에는 보관한 목록을 돌려준다.
    /// 뷰는 `store.result` 를 읽어 결과가 바뀌면 다시 그려지고, 그때 세대가 달라 새로 계산한다.
    func largeFiles() -> [LargeFileEntry] {
        guard let result = store.result else { return [] }
        let generation = store.resultGeneration
        if let cache = largeFilesCache, cache.generation == generation { return cache.files }
        let files = result.home.largestFiles(path: result.homePath, limit: 200)
        largeFilesCache = (generation, files)
        return files
    }

    /// 지금 드릴다운 경로의 트리맵 칸들. (결과 세대, 경로, 크기) 가 같으면 보관한 값을 돌려준다.
    func treemapCells(size: CGSize) -> [TreemapCell] {
        let key = TreemapLayoutKey(generation: store.resultGeneration, path: treemapPath, size: size)
        if let cache = treemapCache, cache.key == key { return cache.cells }
        var cells: [TreemapCell] = []
        if let result = store.result, let node = result.homeNode(at: treemapPath) {
            let path = treemapPath.reduce(result.homePath) { DirectoryNode.join($0, $1) }
            let tiles = TreemapTile.tiles(for: node, path: path)
            let rects = TreemapLayout.squarify(tiles.map { Double($0.size) }, in: CGRect(origin: .zero, size: size))
            cells = zip(tiles, rects).map { tile, rect in
                TreemapCell(tile: tile, rect: rect,
                            tag: tile.kind == .remainder ? nil : result.classification.tag(forPath: tile.path),
                            color: PathColor(tile: tile))
            }
        }
        treemapCache = (key, cells)
        return cells
    }

    /// 드릴다운 경로가 새 결과에 없으면 남아 있는 가장 깊은 조상으로 되돌린다.
    func clampTreemapPath() {
        guard let result = store.result else { return }
        var path = treemapPath
        while !path.isEmpty, result.homeNode(at: path) == nil { path.removeLast() }
        if path != treemapPath { treemapPath = path }
    }
}
