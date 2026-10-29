import Foundation

/// 카드·카테고리 목록에서 정리 버튼을 어떻게 보여 줄지.
public enum CleanupAvailability: Sendable, Equatable {
    /// "정리" 버튼. `reclaimable` 은 재생성 가능 + 휴지통 항목의 합,
    /// `needsCommand` 는 같은 카테고리에서 도구 명령이 필요해 이 버튼으로 정리하지 않는 재생성 가능 항목의 합(v0.2)
    case trash(reclaimable: Int64, needsCommand: Int64)
    /// 재생성 가능하지만 도구 명령이 필요 → "v0.2 에서 지원" 안내
    case nextVersion
    /// 버튼 없음 (주의·수동 확인 등급, 또는 스캔 결과 없음)
    case none
}

/// 카테고리 안 도구 하나의 합계 (예: JavaScript 의 pnpm).
public struct ToolTotal: Sendable, Equatable, Identifiable {
    public var name: String
    public var size: Int64
    public var itemCount: Int
    public var id: String { name }

    public init(name: String, size: Int64, itemCount: Int) {
        self.name = name
        self.size = size
        self.itemCount = itemCount
    }

    /// 항목의 도구 이름. 도구 구분이 없는 항목은 `RuleCatalog.otherTool`("기타")로 묶는다.
    public static func name(of item: ClassifiedItem) -> String {
        item.tag.tool ?? RuleCatalog.otherTool
    }

    /// 항목들을 도구별로 묶어 크기 내림차순(같으면 이름순)으로. 도구가 붙은 항목이 하나도 없으면 빈 배열이다.
    public static func make(_ items: [ClassifiedItem]) -> [ToolTotal] {
        guard items.contains(where: { $0.tag.tool != nil }) else { return [] }
        var totals: [String: ToolTotal] = [:]
        for item in items {
            let name = name(of: item)
            totals[name, default: ToolTotal(name: name, size: 0, itemCount: 0)].size += item.allocatedSize
            totals[name, default: ToolTotal(name: name, size: 0, itemCount: 0)].itemCount += 1
        }
        return totals.values.sorted { ($0.size, $1.name) > ($1.size, $0.name) }
    }
}

/// 팝오버 카드 한 장.
public struct CategorySummary: Sendable, Equatable, Identifiable {
    public var category: Category
    public var size: Int64
    public var itemCount: Int
    /// 7일 변화량. 기준 스냅샷이 없으면 nil
    public var delta: Int64?
    public var cleanup: CleanupAvailability
    /// 도구별 합계 (크기 내림차순). 스캔 결과가 없거나 도구 구분이 없는 카테고리면 빈 배열
    public var tools: [ToolTotal]
    /// 도구별 내역(팝오버 카드 한 줄, 분석 윈도우 사이드바 펼치기)을 보여 줄 최소 도구 수.
    /// 도구가 하나뿐이면 카테고리 합계와 같아 보여 줄 것이 없다
    public static let toolBreakdownMinimum = 2

    /// 도구별 내역을 보여 줄지 (`toolBreakdownMinimum` 개 이상)
    public var showsToolBreakdown: Bool { tools.count >= Self.toolBreakdownMinimum }
    public var id: Category { category }

    public init(category: Category, size: Int64, itemCount: Int, delta: Int64?, cleanup: CleanupAvailability,
                tools: [ToolTotal] = []) {
        self.category = category
        self.size = size
        self.itemCount = itemCount
        self.delta = delta
        self.cleanup = cleanup
        self.tools = tools
    }

    /// 크기가 0 보다 큰 카테고리를 크기 내림차순으로.
    /// - Parameters:
    ///   - classification: 현재 스캔 결과. 앱 시작 직후처럼 없으면 `totals` (마지막 스냅샷) 로 크기만 보여 준다
    ///   - totals: classification 이 없을 때 쓸 합계
    public static func make(
        classification: Classification?,
        totals: [Category: CategoryTotal],
        deltas: [Category: Int64]
    ) -> [CategorySummary] {
        let totals = classification?.totals ?? totals
        return totals.compactMap { category, total -> CategorySummary? in
            guard total.size > 0 else { return nil }
            let items = classification?.items(in: category) ?? []
            return CategorySummary(category: category, size: total.size, itemCount: total.itemCount,
                                   delta: deltas[category], cleanup: availability(items),
                                   tools: ToolTotal.make(items))
        }
        .sorted { ($0.size, $1.category.rawValue) > ($1.size, $0.category.rawValue) }
    }

    /// 휴지통으로 정리할 항목이 있어도 합이 0 바이트(모두 비었거나 dataless)면 "정리" 버튼을 띄우지 않는다.
    /// 그때는 휴지통 항목이 없는 것과 같이 도구 명령 항목이 있으면 `.nextVersion`, 없으면 `.none` 이다.
    static func availability(_ items: [ClassifiedItem]) -> CleanupAvailability {
        let reclaimable = items.filter(\.tag.isTrashCleanable).reduce(Int64(0)) { $0 + $1.allocatedSize }
        let commandItems = items.filter { item in
            if case .command = item.tag.method { return item.tag.level == .regenerable }
            return false
        }
        if reclaimable > 0 {
            return .trash(reclaimable: reclaimable, needsCommand: commandItems.reduce(0) { $0 + $1.allocatedSize })
        }
        return commandItems.isEmpty ? .none : .nextVersion
    }
}
