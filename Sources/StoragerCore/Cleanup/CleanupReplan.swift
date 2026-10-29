import Darwin
import Foundation

/// 낡은 정리 미리보기를 현재 분류로 다시 계획할 때 플래너에 넘길 항목과, 넘기지 않고 바로 거부할 이전 항목을 고른다.
public enum CleanupReplan {
    public struct Selection: Sendable, Equatable {
        /// 플래너(`CleanupPlanner.plan`)에 넘길 항목. 현재 분류의 태그를 가진다
        public var items: [ClassifiedItem]
        /// 플래너에 넘기지 않고 거부로만 보여 줄 이전 항목 (실행 대상이 될 수 없다)
        public var rejected: [RejectedItem]

        /// 다음 "다시 계획" 의 기준이 될 항목 (넘길 항목 + 거부한 이전 항목)
        public var requested: [ClassifiedItem] { items + rejected.map(\.item) }
    }

    /// - Parameters:
    ///   - previous: 마지막으로 계획한 항목
    ///   - category: 카테고리 정리 요청이면 그 카테고리, 고른 항목 요청이면 nil
    ///   - classification: 현재 분류
    ///   - permissionSkip: 권한이 없을 때 건너뛰는 위치. 그 안의 경로는 lstat 하지 않는다
    ///
    /// 카테고리 요청은 그 카테고리의 현재 휴지통 정리 가능 항목으로 계획한다. 이전 항목 중 그 목록에 없는 것은
    /// - 현재 분류에서 다른 카테고리면 실행하지 않고 `.categoryChanged` 로 거부한다(이 카테고리 정리로 지우지 않도록).
    /// - 같은 카테고리지만 정리 가능 등급이 아니게 되었으면 플래너에 넘겨 그 사유(`.notYetSupported` 등)로 거부되게 한다.
    /// 항목 요청은 같은 경로를 현재 분류에서 찾아 현재 태그로 넘긴다(미리보기에 그대로 보인다).
    /// 어느 쪽이든 현재 분류에 없는 이전 항목은 `vanishedReason` 으로 거부한다.
    public static func select(previous: [ClassifiedItem], category: Category?, classification: Classification,
                              permissionSkip: PermissionSkip) -> Selection {
        let index = Dictionary(classification.items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [ClassifiedItem] = []
        var rejected: [RejectedItem] = []
        if let category {
            items = classification.items(in: category).filter(\.tag.isTrashCleanable)
            var planned = Set(items.map(\.path))
            for old in previous where !planned.contains(old.path) {
                if let current = index[old.path] {
                    if current.tag.category != category {
                        rejected.append(RejectedItem(item: old, reason: .categoryChanged))
                    } else {
                        items.append(current)
                        planned.insert(old.path)
                    }
                } else {
                    rejected.append(RejectedItem(item: old, reason: vanishedReason(old.path,
                                                                                   permissionSkip: permissionSkip)))
                }
            }
        } else {
            for old in previous {
                if let current = index[old.path] {
                    items.append(current)
                } else {
                    rejected.append(RejectedItem(item: old, reason: vanishedReason(old.path,
                                                                                   permissionSkip: permissionSkip)))
                }
            }
        }
        return Selection(items: items, rejected: rejected)
    }

    /// 현재 분류에서 사라진 이전 항목의 거부 사유: 권한 없이 건너뛰는 위치면 `.permissionRequired`(lstat 하지 않는다),
    /// 디스크에는 아직 있으면 `.notClassified`, 없으면 `.missing`.
    public static func vanishedReason(_ path: String, permissionSkip: PermissionSkip) -> CleanupRejection {
        let path = PathUtil.standardize(path)
        if permissionSkip.covers(path) { return .permissionRequired }
        var info = stat()
        return lstat(path, &info) == 0 ? .notClassified : .missing
    }
}
