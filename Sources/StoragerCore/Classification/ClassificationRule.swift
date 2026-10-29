import Darwin
import Foundation

/// 분류 규칙 하나: 매칭 조건 → 카테고리 → 안전 등급 → 정리 방법.
public struct ClassificationRule: Sendable, Hashable {
    public enum Matcher: Sendable, Hashable {
        /// 홈 기준 경로 글롭. 구성 요소마다 fnmatch(3) 로 비교한다 (예: "Library/Caches/*"). `**` 는 지원하지 않는다.
        case homePath(String)
        /// 디렉터리 이름 글롭 + (있으면) 부모 디렉터리에 `siblingMarkers` 중 하나의 표식 파일 + (있으면) 그 디렉터리 자신에
        /// `ownMarkers` 중 하나의 표식 파일이 있어야 함 (예: venv 안의 `pyvenv.cfg`).
        /// 홈의 `Library`·`Applications`·숨김 디렉터리(`.xxx`) 아래와 앱 번들(`*.app` 등) 안에서는 매칭하지 않는다
        /// (앱·확장이 동봉한 node_modules 보호. 번들 차단은 `Classifier` 가 한다).
        case directoryName(String, siblingMarkers: Set<String>, ownMarkers: Set<String> = [])
    }

    /// 항목을 만든 도구 이름을 정하는 방법.
    public enum ToolLabel: Sendable, Hashable {
        /// 항상 같은 이름
        case fixed(String)
        /// 부모 디렉터리의 표식 파일(잠금 파일 등)로 고른다. `candidates` 를 앞에서부터 보고 처음 맞는 도구,
        /// 하나도 없으면 `fallback`. 여러 잠금 파일이 함께 있으면 앞에 둔 것이 이긴다.
        /// 옆에 잠금 파일이 없으면 조상의 잠금 파일을 따르되(모노레포 워크스페이스), 그 조상에 `projectMarkers` 중
        /// 하나도 있어야 한다(진짜 프로젝트·워크스페이스 루트). 비어 있으면 조상에서 물려받지 않는다.
        case bySiblingMarker([MarkerTool], fallback: String, projectMarkers: Set<String> = [])

        public func resolve(parentMarkers: Set<String>) -> String {
            switch self {
            case .fixed(let name): name
            case .bySiblingMarker(_, let fallback, _): siblingTool(in: parentMarkers) ?? fallback
            }
        }

        /// `markers` 에 후보 표식이 있으면 처음 맞는 도구, 없거나 고정 이름이면 nil (대체값을 쓰지 않는다).
        public func siblingTool(in markers: Set<String>) -> String? {
            guard case .bySiblingMarker(let candidates, _, _) = self else { return nil }
            return candidates.first { !$0.markers.isDisjoint(with: markers) }?.tool
        }

        /// 이 표식을 가진 디렉터리가 자손에게 물려줄 도구. `projectMarkers` 중 하나가 함께 있는 프로젝트 루트일 때만.
        public func inheritableTool(in markers: Set<String>) -> String? {
            guard case .bySiblingMarker(_, _, let projectMarkers) = self,
                  !projectMarkers.isDisjoint(with: markers) else { return nil }
            return siblingTool(in: markers)
        }

        /// 이 라벨이 보는 표식 파일 이름 (스캐너가 기록해야 하는 이름)
        public var markerFileNames: Set<String> {
            switch self {
            case .fixed: []
            case .bySiblingMarker(let candidates, _, let projectMarkers):
                candidates.reduce(into: projectMarkers) { $0.formUnion($1.markers) }
            }
        }
    }

    /// 표식 파일 중 하나가 있으면 `tool`.
    public struct MarkerTool: Sendable, Hashable {
        public var markers: Set<String>
        public var tool: String

        public init(_ markers: Set<String>, _ tool: String) {
            self.markers = markers
            self.tool = tool
        }
    }

    public var id: String
    /// `compiled` 와 어긋나지 않도록 바꿀 수 없게 둔다
    public let matcher: Matcher
    public var category: Category
    public var level: SafetyLevel
    public var method: CleanupMethod
    /// 도구 이름. nil 이면 도구 구분이 없는 규칙이다
    public var tool: ToolLabel?
    /// `matcher` 를 init 에서 한 번만 풀어 둔 형태 (매 노드 문자열 쪼개기를 피한다)
    let compiled: Compiled

    public init(id: String, matcher: Matcher, category: Category, level: SafetyLevel, method: CleanupMethod,
                tool: ToolLabel? = nil) {
        self.id = id
        self.matcher = matcher
        self.category = category
        self.level = level
        self.method = method
        self.tool = tool
        compiled = Compiled(matcher)
    }

    /// 표식 없이 만든 태그 (도구 이름은 고정 이름이나 `fallback`). `Classifier` 가 잠금 파일로 도구를 바꾼다.
    public var tag: CategoryTag {
        CategoryTag(ruleID: id, category: category, level: level, method: method,
                    tool: tool?.resolve(parentMarkers: []))
    }

    /// 홈 경로 규칙이면 패턴 구성 요소 수, 이름 규칙이면 nil.
    var homePathDepth: Int? {
        if case .homePath(let parts) = compiled { parts.count } else { nil }
    }

    /// - Parameters:
    ///   - name: 디렉터리 이름
    ///   - homeRelative: 홈 기준 상대 경로 구성 요소. 홈 밖(추가 프로젝트 루트)이면 nil
    ///   - parentMarkers: 부모 디렉터리의 표식 파일
    ///   - ownMarkers: 그 디렉터리 자신의 표식 파일
    public func matches(name: String, homeRelative: [String]?, parentMarkers: Set<String>,
                        ownMarkers: Set<String> = []) -> Bool {
        matches(name: name, homeRelative: homeRelative, parentMarkers: parentMarkers, ownMarkers: ownMarkers,
                nameRulesAllowed: Self.nameRulesAllowed(homeRelative: homeRelative))
    }

    /// `Classifier` 용. 이름 규칙 허용 여부(홈 위치·번들 차단)를 호출자가 정한다.
    func matches(name: String, homeRelative: [String]?, parentMarkers: Set<String>, ownMarkers: Set<String>,
                 nameRulesAllowed: Bool) -> Bool {
        switch compiled {
        case .homePath(let parts):
            guard let homeRelative, parts.count == homeRelative.count else { return false }
            // 깊은 쪽(이름에 가까운 쪽)이 더 잘 갈리므로 뒤에서부터 비교한다
            var index = parts.count - 1
            while index >= 0 {
                guard parts[index].matches(homeRelative[index]) else { return false }
                index -= 1
            }
            return true
        case .directoryName(let pattern, let siblingMarkers, let ownRequired):
            guard nameRulesAllowed, pattern.matches(name) else { return false }
            if !siblingMarkers.isEmpty, siblingMarkers.isDisjoint(with: parentMarkers) { return false }
            if !ownRequired.isEmpty, ownRequired.isDisjoint(with: ownMarkers) { return false }
            return true
        }
    }

    /// 홈의 `Library`·`Applications`·숨김 디렉터리 아래에서는 이름 규칙을 끈다. 홈 밖이면 켠다.
    static func nameRulesAllowed(homeRelative: [String]?) -> Bool {
        guard let first = homeRelative?.first else { return true }
        return !(first == "Library" || first == "Applications" || first.hasPrefix("."))
    }

    static func glob(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }

    /// 패턴 구성 요소 하나. 와일드카드가 없으면 문자열 비교, 있으면 fnmatch.
    enum Component: Sendable, Hashable {
        case literal(String)
        case glob(String)

        init(_ pattern: String) {
            self = pattern.contains(where: { "*?[\\".contains($0) }) ? .glob(pattern) : .literal(pattern)
        }

        func matches(_ name: String) -> Bool {
            switch self {
            case .literal(let literal): literal == name
            case .glob(let pattern): ClassificationRule.glob(pattern, name)
            }
        }
    }

    enum Compiled: Sendable, Hashable {
        case homePath([Component])
        case directoryName(Component, siblingMarkers: Set<String>, ownMarkers: Set<String>)

        init(_ matcher: Matcher) {
            switch matcher {
            case .homePath(let pattern):
                self = .homePath(pattern.split(separator: "/").map { Component(String($0)) })
            case .directoryName(let pattern, let siblingMarkers, let ownMarkers):
                self = .directoryName(Component(pattern), siblingMarkers: siblingMarkers, ownMarkers: ownMarkers)
            }
        }
    }
}
