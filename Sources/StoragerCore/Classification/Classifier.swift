import Foundation

/// 분류된 디렉터리 하나.
public struct ClassifiedItem: Sendable, Hashable, Identifiable {
    public var path: String
    public var tag: CategoryTag
    public var allocatedSize: Int64
    public var newestModification: Date
    public var id: String { path }

    public init(path: String, tag: CategoryTag, allocatedSize: Int64, newestModification: Date) {
        self.path = path
        self.tag = tag
        self.allocatedSize = allocatedSize
        self.newestModification = newestModification
    }
}

/// 카테고리 하나의 합계.
public struct CategoryTotal: Sendable, Hashable {
    public var size: Int64
    public var itemCount: Int

    public init(size: Int64, itemCount: Int) {
        self.size = size
        self.itemCount = itemCount
    }
}

/// 분류 결과. 태그는 트리 노드가 아니라 경로 → 태그 표로 따로 둔다 (트리 메모리 절약).
public struct Classification: Sendable {
    public private(set) var items: [ClassifiedItem]
    private var tagByPath: [String: CategoryTag]

    public init(items: [ClassifiedItem]) {
        self.items = items.sorted { $0.allocatedSize > $1.allocatedSize }
        tagByPath = Dictionary(items.map { ($0.path, $0.tag) }, uniquingKeysWith: { first, _ in first })
    }

    public static let empty = Classification(items: [])

    /// `path` 또는 가장 가까운 조상의 태그 (트리맵 색칠용).
    public func tag(forPath path: String) -> CategoryTag? {
        var current = path
        while true {
            if let tag = tagByPath[current] { return tag }
            guard let slash = current.lastIndex(of: "/"), slash != current.startIndex else { return nil }
            current = String(current[..<slash])
        }
    }

    public func items(in category: Category) -> [ClassifiedItem] {
        items.filter { $0.tag.category == category }
    }

    /// 카테고리 안에서 도구 이름(`ToolTotal.name(of:)`)이 `tool` 인 항목.
    public func items(in category: Category, tool: String) -> [ClassifiedItem] {
        items.filter { $0.tag.category == category && ToolTotal.name(of: $0) == tool }
    }

    public var totals: [Category: CategoryTotal] {
        var result: [Category: CategoryTotal] = [:]
        for item in items {
            result[item.tag.category, default: CategoryTotal(size: 0, itemCount: 0)].size += item.allocatedSize
            result[item.tag.category, default: CategoryTotal(size: 0, itemCount: 0)].itemCount += 1
        }
        return result
    }

    /// 정리·재스캔 뒤 바뀐 항목을 반영한다. `size` 가 nil 이면 항목을 뺀다. 크기가 바뀌면 크기 내림차순 위치로 옮긴다.
    ///
    /// v0.1 은 정리한 항목 경로만 재스캔하므로 `path` 는 분류 항목 경로 그 자체라고 본다. 항목의 조상·자손 경로를
    /// 재스캔한 결과는 반영하지 않는다(그 아래 새로 생긴 분류 대상도 다음 전체 스캔까지 나타나지 않는다).
    public mutating func update(path: String, size: Int64?, newestModification: Date? = nil) {
        guard let index = items.firstIndex(where: { $0.path == path }) else { return }
        var item = items.remove(at: index)
        guard let size else {
            tagByPath[path] = nil
            return
        }
        item.allocatedSize = size
        if let newestModification { item.newestModification = newestModification }
        let position = items.firstIndex { $0.allocatedSize < size } ?? items.endIndex
        items.insert(item, at: position)
    }
}

/// 스캔 트리에 규칙 카탈로그를 적용한다. 노드가 규칙에 맞으면 태그를 붙이고 그 아래로는 내려가지 않는다
/// (node_modules 안의 node_modules 를 두 번 세지 않도록).
///
/// 이름 규칙(`directoryName`)은 홈의 `Library`·`Applications`·숨김 디렉터리 아래와 앱 번들(`bundleExtensions`) 안,
/// 그리고 `node_modules`·파이썬 환경(`pyvenv.cfg` 가 든 디렉터리, `site-packages`) 안(`isOpaqueContainer`)에서
/// 적용하지 않는다. 번들·node_modules·파이썬 환경 차단은 홈 밖 추가 프로젝트 루트에도 똑같이 적용한다.
public struct Classifier: Sendable {
    /// 이 확장자로 끝나는 디렉터리(앱·프레임워크·플러그인 번들) 아래로는 이름 규칙을 적용하지 않는다.
    /// 번들에 동봉된 node_modules 등을 지우면 앱이 망가지고 서명도 깨진다.
    public static let bundleExtensions = [
        ".app", ".framework", ".bundle", ".appex", ".xpc", ".plugin", ".kext", ".prefPane", ".qlgenerator", ".saver",
    ]

    /// 이 이름의 디렉터리 아래로는 태그가 붙지 않았어도 이름 규칙을 적용하지 않는다. 태그 없는 `node_modules`
    /// (예: 전역 Node 접두사의 `lib/node_modules`) 안의 `npm/node_modules` 는 옆에 `npm/package.json` 이 있어
    /// `js.node_modules` 에 맞지만, npm 이 동봉한 의존성이라 지우면 npm 이 망가진다. `site-packages` 안의 `build`·
    /// `target`·`.venv` 등도 패키지의 일부다.
    public static let opaqueContainerNames: Set<String> = ["node_modules", "site-packages"]

    public let rules: [ClassificationRule]
    /// `PathUtil.resolve` 로 심볼릭 링크를 푼 홈 경로 (스캐너 루트와 같은 표기)
    public let homePath: String
    /// 홈 경로 규칙 패턴의 최대 구성 요소 수. 이보다 깊은 노드는 홈 경로 규칙을 건너뛴다
    private let maxHomePathDepth: Int
    /// 이름 규칙만의 `rules` 색인 (카탈로그 순서). 홈 경로 규칙을 볼 수 없는 노드(홈 밖, 깊은 노드)에 쓴다
    private let nameRuleIndices: [Int]
    /// `[d]` = 구성 요소 수가 정확히 d 인 홈 경로 규칙 + 이름 규칙의 `rules` 색인 (카탈로그 순서 유지).
    /// 다른 깊이의 홈 경로 규칙은 어차피 맞지 않으므로 빼도 "처음 맞는 규칙" 결과는 같다
    private let ruleIndicesAtDepth: [[Int]]
    /// 옆 표식으로 도구를 고르는 라벨들 (`ToolLabel.bySiblingMarker`, 중복 없이)
    private let markerToolLabels: [ClassificationRule.ToolLabel]
    /// `rules[i]` 의 도구 라벨이 `markerToolLabels` 의 몇 번째인지 (해당 없으면 nil)
    private let markerToolLabelIndex: [Int?]
    /// 테스트용: 깊이별 묶음 대신 모든 규칙을 차례로 본다 (묶음과 결과가 같은지 비교)
    var usesLinearMatching = false

    /// 태그를 붙이지 않고 그 아래로 내려가 더 깊은 규칙을 적용할 홈 기준 경로 (글롭 구성 요소, `RuleCatalog.containers`)
    private let containers: [[ClassificationRule.Component]]

    public init(rules: [ClassificationRule] = RuleCatalog.default, containers: [String] = RuleCatalog.containers,
                homePath: String) {
        self.rules = rules
        self.homePath = PathUtil.resolve(homePath)
        self.containers = containers.map { $0.split(separator: "/").map { ClassificationRule.Component(String($0)) } }
        let maxDepth = rules.compactMap(\.homePathDepth).max() ?? 0
        maxHomePathDepth = maxDepth
        nameRuleIndices = rules.indices.filter { rules[$0].homePathDepth == nil }
        ruleIndicesAtDepth = (0...maxDepth).map { depth in
            rules.indices.filter { rules[$0].homePathDepth == nil || rules[$0].homePathDepth == depth }
        }
        var labels: [ClassificationRule.ToolLabel] = []
        markerToolLabelIndex = rules.map { rule in
            guard let label = rule.tool, case .bySiblingMarker = label else { return nil }
            if let index = labels.firstIndex(of: label) { return index }
            labels.append(label)
            return labels.count - 1
        }
        markerToolLabels = labels
    }

    /// `root` 는 `rootPath` 디렉터리의 트리다. 홈 트리와 추가 프로젝트 루트 트리 모두에 쓴다.
    /// `rootPath` 도 `PathUtil.resolve` 로 풀며, 항목 경로는 그 표기다.
    /// 루트가 홈의 조상(`/Users`, `/` 등)이면 순회가 홈에 닿는 순간 홈 기준으로 바꿔, 홈 아래는 홈 루트로 분류할 때와 같게 한다.
    public func classify(root: DirectoryNode, rootPath: String) -> [ClassifiedItem] {
        let rootPath = PathUtil.resolve(rootPath)
        let homeRelative = PathUtil.components(of: rootPath, relativeTo: homePath)
        var walk = Walk(rootPath: rootPath, inHome: homeRelative != nil, components: homeRelative ?? [],
                        rootDepth: homeRelative?.count ?? 0,
                        homeBelowRoot: homeRelative == nil ? PathUtil.components(of: homePath, relativeTo: rootPath) : nil,
                        inheritedTools: Array(repeating: nil, count: markerToolLabels.count))
        visit(root, parentMarkers: [], nameRulesBlocked: false, walk: &walk)
        return walk.items
    }

    /// 순회 상태. `components` 는 현재 노드의 경로 구성 요소(홈 안이면 홈 기준, 밖이면 루트 기준)로,
    /// 자식으로 내려갈 때 이름을 붙이고 돌아올 때 뗀다 (노드마다 경로를 다시 쪼개지 않도록).
    private struct Walk {
        let rootPath: String
        let inHome: Bool
        var components: [String]
        /// `components` 중 `rootPath` 에 해당하는 앞부분 길이
        let rootDepth: Int
        /// 루트가 홈의 조상일 때 루트 기준 홈의 구성 요소. 순회가 여기 닿으면 홈 기준으로 바꾼다
        let homeBelowRoot: [String]?
        /// `markerToolLabels[i]` 기준으로, 프로젝트 루트인 가장 가까운 조상(홈 제외)의 잠금 파일이 가리키는 도구.
        /// 모노레포 워크스페이스처럼 잠금 파일이 루트에만 있는 경우의 대체값이다. 자리에서 바꾸고 되돌린다
        var inheritedTools: [String?]
        var items: [ClassifiedItem] = []

        var path: String {
            components[rootDepth...].reduce(rootPath) { DirectoryNode.join($0, $1) }
        }
    }

    /// `nameRulesBlocked`: 조상 중에 번들·node_modules·파이썬 환경이 있어 이름 규칙을 끈다.
    private func visit(_ node: DirectoryNode, parentMarkers: Set<String>, nameRulesBlocked: Bool, walk: inout Walk) {
        if let home = walk.homeBelowRoot, walk.components.count == home.count, walk.components == home {
            // 홈에 닿았다: 홈을 루트로 분류할 때와 같은 기준(홈 경로 규칙, Library·숨김 차단)으로 이어 간다
            var homeWalk = Walk(rootPath: homePath, inHome: true, components: [], rootDepth: 0, homeBelowRoot: nil,
                                inheritedTools: walk.inheritedTools)
            visit(node, parentMarkers: parentMarkers, nameRulesBlocked: nameRulesBlocked, walk: &homeWalk)
            walk.items += homeWalk.items
            return
        }
        if !isContainer(walk),
           let index = matchingRuleIndex(for: node, parentMarkers: parentMarkers,
                                         nameRulesBlocked: nameRulesBlocked, walk: walk) {
            let rule = rules[index]
            var tag = rule.tag
            if let labelIndex = markerToolLabelIndex[index], let label = rule.tool {
                // 옆 잠금 파일 → 프로젝트 루트 조상에서 물려받은 도구 → 대체값
                tag.tool = label.siblingTool(in: parentMarkers) ?? walk.inheritedTools[labelIndex]
                    ?? label.resolve(parentMarkers: [])
            }
            walk.items.append(ClassifiedItem(path: walk.path, tag: tag, allocatedSize: node.allocatedSize,
                                             newestModification: node.newestModification))
            return
        }
        // 프로젝트·워크스페이스 루트(잠금 파일 + package.json/pyproject.toml)면 그 도구를 자손에게 물려준다.
        // 홈 자체는 제외한다: 실수로 홈에서 `npm install` 해 남은 잠금 파일이 홈 전체의 도구를 바꾸지 않도록.
        // 표식이 없는 대부분의 노드는 건너뛴다
        var saved: [(Int, String?)] = []
        if !node.markers.isEmpty, !(walk.inHome && walk.components.isEmpty) {
            for (labelIndex, label) in markerToolLabels.enumerated() {
                if let tool = label.inheritableTool(in: node.markers) {
                    saved.append((labelIndex, walk.inheritedTools[labelIndex]))
                    walk.inheritedTools[labelIndex] = tool
                }
            }
        }
        let childrenBlocked = nameRulesBlocked || Self.isBundle(node.name) || Self.isOpaqueContainer(node)
        for child in node.children {
            walk.components.append(child.name)
            visit(child, parentMarkers: node.markers, nameRulesBlocked: childrenBlocked, walk: &walk)
            walk.components.removeLast()
        }
        for (labelIndex, previous) in saved {
            walk.inheritedTools[labelIndex] = previous
        }
    }

    /// 홈 안의 컨테이너 경로(예: `Library/Caches/pypoetry`)인지. 컨테이너는 일반 규칙(`caches.general` 등)에
    /// 걸리지 않고 그 아래 항목을 더 구체적인 규칙으로 분류한다.
    private func isContainer(_ walk: Walk) -> Bool {
        guard walk.inHome, !containers.isEmpty else { return false }
        let components = walk.components
        return containers.contains { parts in
            parts.count == components.count && zip(parts, components).allSatisfy { $0.matches($1) }
        }
    }

    private func matchingRuleIndex(for node: DirectoryNode, parentMarkers: Set<String>, nameRulesBlocked: Bool,
                                   walk: Walk) -> Int? {
        // 홈 자체는 분류하지 않는다
        if walk.inHome && walk.components.isEmpty { return nil }
        let homeRelative = walk.inHome && walk.components.count <= maxHomePathDepth ? walk.components : nil
        let nameRulesAllowed = !nameRulesBlocked
            && (!walk.inHome || ClassificationRule.nameRulesAllowed(homeRelative: walk.components))
        if homeRelative == nil && !nameRulesAllowed { return nil }
        let candidates: [Int]
        if usesLinearMatching {
            candidates = Array(rules.indices)
        } else if let homeRelative {
            candidates = ruleIndicesAtDepth[homeRelative.count]
        } else {
            candidates = nameRuleIndices
        }
        return candidates.first {
            rules[$0].matches(name: node.name, homeRelative: homeRelative, parentMarkers: parentMarkers,
                              ownMarkers: node.markers, nameRulesAllowed: nameRulesAllowed)
        }
    }

    static func isBundle(_ name: String) -> Bool {
        bundleExtensions.contains { name.hasSuffix($0) }
    }

    /// 그 안에 든 것이 패키지 관리자·인터프리터의 일부라 이름 규칙을 적용하면 안 되는 디렉터리인지.
    /// `node_modules`·`site-packages` 이름이거나, 자기 안에 `pyvenv.cfg` 가 있는 파이썬 가상 환경(이름이 `venv`·`.venv`
    /// 가 아니라 태그되지 않은 것)이다. 태그된 node_modules·venv 는 어차피 그 아래로 내려가지 않는다.
    static func isOpaqueContainer(_ node: DirectoryNode) -> Bool {
        opaqueContainerNames.contains(node.name) || node.markers.contains("pyvenv.cfg")
    }
}
