import Foundation
import Testing
@testable import StoragerCore

struct CleanupReplanTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    func item(_ relative: String, _ ruleID: String, size: Int64 = 100) -> ClassifiedItem {
        ClassifiedItem(path: DirectoryNode.join(tree.path, relative), tag: ruleTag(ruleID), allocatedSize: size,
                       newestModification: .distantPast)
    }

    @Test func categoryReplanUsesCurrentCleanableItems() {
        let old = item("a/node_modules", "js.node_modules")
        let added = item("b/node_modules", "js.node_modules")
        let classification = Classification(items: [old, added, item(".npm/_cacache", "js.npm"),
                                                    item("Library/Logs/x", "logs")])

        let selection = CleanupReplan.select(previous: [old], category: .javascript, classification: classification,
                                             permissionSkip: .none)

        // 명령 정리(npm)·다른 카테고리(logs)는 넣지 않는다
        #expect(Set(selection.items.map(\.path)) == [old.path, added.path])
        #expect(selection.rejected.isEmpty)
    }

    @Test func itemThatMovedToAnotherCategoryIsRejectedNotPlanned() {
        // 이전에는 JavaScript 였지만 최근 스캔에서 다른 카테고리(정리 가능 등급)로 분류된 경로
        let old = item("x/build", "js.node_modules")
        var moved = old
        moved.tag = ruleTag("logs")
        let classification = Classification(items: [moved])

        let selection = CleanupReplan.select(previous: [old], category: .javascript, classification: classification,
                                             permissionSkip: .none)

        #expect(selection.items.isEmpty)
        #expect(selection.rejected == [RejectedItem(item: old, reason: .categoryChanged)])
        #expect(selection.requested == [old])
        // 플래너에 넘기는 것이 없으니 실행 대상도 없다
        #expect(CleanupPlanner(homePath: tree.path).plan(selection.items).accepted.isEmpty)
    }

    @Test func sameCategoryItemThatIsNoLongerCleanableGoesToPlannerForItsReason() {
        let old = item(".nvm/versions/node/v1", "js.node_modules")
        var now = old
        now.tag = ruleTag("js.nvm.versions")  // 같은 JavaScript, 주의 등급
        let classification = Classification(items: [now])

        let selection = CleanupReplan.select(previous: [old], category: .javascript, classification: classification,
                                             permissionSkip: .none)

        #expect(selection.items == [now])
        #expect(selection.rejected.isEmpty)
        #expect(CleanupPlanner(homePath: tree.path).plan(selection.items).rejected.map(\.reason) == [.notYetSupported])
    }

    @Test func itemsReplanLooksUpSamePathsWithCurrentTags() throws {
        let kept = item("a/node_modules", "js.node_modules", size: 100)
        var current = kept
        current.allocatedSize = 300
        let gone = item("gone/node_modules", "js.node_modules")

        let selection = CleanupReplan.select(previous: [kept, gone], category: nil,
                                             classification: Classification(items: [current]), permissionSkip: .none)

        #expect(selection.items == [current])
        #expect(selection.rejected == [RejectedItem(item: gone, reason: .missing)])
    }

    @Test func vanishedReasonOrder() throws {
        try tree.dir("still/here")
        let skip = FullDiskAccess.permissionSkip(homePath: tree.path)

        // 디스크에 있지만 분류 항목이 아님
        #expect(CleanupReplan.vanishedReason(tree.path + "/still/here", permissionSkip: .none) == .notClassified)
        // 없음
        #expect(CleanupReplan.vanishedReason(tree.path + "/nope", permissionSkip: .none) == .missing)
        // 권한 없이 건너뛰는 위치면 디스크를 보기 전에 권한 사유 (있든 없든)
        try tree.dir("Desktop/app/node_modules")
        #expect(CleanupReplan.vanishedReason(tree.path + "/Desktop/app/node_modules", permissionSkip: skip)
            == .permissionRequired)
        #expect(CleanupReplan.vanishedReason(tree.path + "/Desktop/none", permissionSkip: skip) == .permissionRequired)
        #expect(CleanupReplan.vanishedReason(tree.path + "/still/here", permissionSkip: skip) == .notClassified)
    }

    @Test func vanishedItemsGetTheirReasonInBothModes() throws {
        try tree.dir("left/node_modules")
        let onDisk = item("left/node_modules", "js.node_modules")
        let missing = item("deleted/node_modules", "js.node_modules")
        let skip = FullDiskAccess.permissionSkip(homePath: tree.path)
        let protected = item("Documents/p/node_modules", "js.node_modules")

        for category in [StoragerCore.Category.javascript, nil] {
            let selection = CleanupReplan.select(previous: [onDisk, missing, protected], category: category,
                                                 classification: .empty, permissionSkip: skip)
            #expect(selection.items.isEmpty)
            #expect(selection.rejected.map(\.reason) == [.notClassified, .missing, .permissionRequired])
        }
    }
}
