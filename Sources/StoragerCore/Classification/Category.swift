import Foundation

/// 분류 카테고리. rawValue 는 스냅샷 DB 에 저장되므로 바꾸지 않는다.
/// (예전 `pythonRustGo` 는 `python`·`rust`·`go` 로 나눴다. 옛 스냅샷의 그 값은 읽을 때 건너뛴다)
public enum Category: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case xcode
    case simulator
    case gradle
    case javascript
    case cocoaPodsSwiftPM
    case docker
    case homebrew
    case aiTools
    case python
    case rust
    case go
    case caches
    case logs
    case personalData

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .xcode: "Xcode"
        case .simulator: "시뮬레이터"
        case .gradle: "Gradle"
        case .javascript: "JavaScript"
        case .cocoaPodsSwiftPM: "CocoaPods·SwiftPM"
        case .docker: "Docker"
        case .homebrew: "Homebrew"
        case .aiTools: "AI 도구"
        case .python: "Python"
        case .rust: "Rust"
        case .go: "Go"
        case .caches: "캐시"
        case .logs: "로그"
        case .personalData: "메일·메시지·사진"
        }
    }

    /// SF Symbol 이름
    public var symbolName: String {
        switch self {
        case .xcode: "hammer"
        case .simulator: "iphone"
        case .gradle: "shippingbox"
        case .javascript: "curlybraces"
        case .cocoaPodsSwiftPM: "swift"
        case .docker: "server.rack"
        case .homebrew: "mug"
        case .aiTools: "sparkles"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .rust: "gearshape.2"
        case .go: "hare"
        case .caches: "archivebox"
        case .logs: "doc.text"
        case .personalData: "person.crop.square"
        }
    }
}

/// 안전 등급.
public enum SafetyLevel: String, Sendable, Codable, Hashable {
    /// 삭제해도 다음 빌드·실행 때 다시 만들어진다. 원클릭 정리 허용
    case regenerable
    /// 확인 후 허용 (v0.2)
    case caution
    /// 삭제 버튼 없음. Finder 보기·경로 복사만
    case manual

    public var displayName: String {
        switch self {
        case .regenerable: "재생성 가능"
        case .caution: "주의"
        case .manual: "수동 확인"
        }
    }
}

/// 정리 방법.
public enum CleanupMethod: Sendable, Hashable {
    /// 휴지통으로 이동
    case trash
    /// 도구 자체 명령 (v0.2 에서 실행 지원)
    case command(String)
    /// 정리하지 않음. Finder 에서 보기만
    case revealOnly
}

/// 분류 결과로 노드에 붙는 태그.
public struct CategoryTag: Sendable, Hashable {
    public var ruleID: String
    public var category: Category
    public var level: SafetyLevel
    public var method: CleanupMethod
    /// 이 항목을 만든 도구 이름 (예: "pnpm", "cargo"). 도구 구분이 없는 규칙이면 nil
    public var tool: String?

    public init(ruleID: String, category: Category, level: SafetyLevel, method: CleanupMethod, tool: String? = nil) {
        self.ruleID = ruleID
        self.category = category
        self.level = level
        self.method = method
        self.tool = tool
    }

    /// v0.1 에서 정리 버튼을 보여 줄 수 있는지: 재생성 가능 등급 + 휴지통 방법만.
    public var isTrashCleanable: Bool {
        level == .regenerable && method == .trash
    }
}
