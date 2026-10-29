import Foundation
import Testing
@testable import StoragerCore

struct CategorySummaryTests {
    func item(_ path: String, _ ruleID: String, _ size: Int64) -> ClassifiedItem {
        ClassifiedItem(path: path, tag: ruleTag(ruleID), allocatedSize: size, newestModification: .distantPast)
    }

    @Test func buildsCardsSortedBySizeWithCleanupAvailability() {
        let classification = Classification(items: [
            item("/h/Library/Developer/Xcode/DerivedData", "xcode.deriveddata", 300),
            item("/h/Library/Developer/Xcode/Archives", "xcode.archives", 50),
            item("/h/Library/Caches/Homebrew", "homebrew.cache", 500),
            item("/h/Library/Mail", "personal.mail", 100),
        ])

        let cards = CategorySummary.make(classification: classification, totals: [:], deltas: [.xcode: 40])

        #expect(cards.map(\.category) == [.homebrew, .xcode, .personalData])
        #expect(cards[0].cleanup == .nextVersion)
        #expect(cards[1].cleanup == .trash(reclaimable: 300, needsCommand: 0))
        #expect(cards[1].size == 350)
        #expect(cards[1].delta == 40)
        #expect(cards[2].cleanup == CleanupAvailability.none)
        #expect(cards[0].delta == nil)
    }

    @Test func trashCardAlsoReportsItemsThatNeedCommand() {
        let classification = Classification(items: [
            item("/h/dev/web/node_modules", "js.node_modules", 200),
            item("/h/.npm/_cacache", "js.npm", 70),
        ])

        let cards = CategorySummary.make(classification: classification, totals: [:], deltas: [:])

        #expect(cards.map(\.category) == [.javascript])
        #expect(cards[0].cleanup == .trash(reclaimable: 200, needsCommand: 70))
        #expect(cards[0].size == 270)
    }

    @Test func fallsBackToSnapshotTotalsWithoutCleanup() {
        let cards = CategorySummary.make(classification: nil,
                                         totals: [.logs: CategoryTotal(size: 7, itemCount: 1),
                                                  .gradle: CategoryTotal(size: 0, itemCount: 0)],
                                         deltas: [:])
        #expect(cards.map(\.category) == [.logs])
        #expect(cards[0].cleanup == CleanupAvailability.none)
        #expect(cards[0].tools.isEmpty)
    }

    func item(_ path: String, _ ruleID: String, tool: String, _ size: Int64) -> ClassifiedItem {
        var tag = ruleTag(ruleID)
        tag.tool = tool
        return ClassifiedItem(path: path, tag: tag, allocatedSize: size, newestModification: .distantPast)
    }

    @Test func toolBreakdownIsSortedBySizeDescending() {
        let classification = Classification(items: [
            item("/h/a/node_modules", "js.node_modules", tool: "npm", 30),
            item("/h/b/node_modules", "js.node_modules", tool: "pnpm", 100),
            item("/h/c/node_modules", "js.node_modules", tool: "pnpm", 20),
            item("/h/Library/pnpm/store", "js.pnpm", 50),
            item("/h/d/node_modules", "js.node_modules", 5),
            item("/h/.npm/_cacache", "js.npm", 40),
        ])

        let cards = CategorySummary.make(classification: classification, totals: [:], deltas: [:])

        #expect(cards.map(\.category) == [.javascript])
        #expect(cards[0].tools == [
            ToolTotal(name: "pnpm", size: 170, itemCount: 3),
            ToolTotal(name: "npm", size: 70, itemCount: 2),
            ToolTotal(name: "기타", size: 5, itemCount: 1),
        ])
        #expect(cards[0].tools.reduce(0) { $0 + $1.size } == cards[0].size)
    }

    @Test func toolBreakdownTiesAreOrderedByName() {
        let classification = Classification(items: [
            item("/h/.cargo/registry", "rust.cargo.registry", 10),
            item("/h/.rustup/toolchains/stable", "rust.rustup.toolchains", 10),
        ])

        let cards = CategorySummary.make(classification: classification, totals: [:], deltas: [:])

        #expect(cards[0].tools.map(\.name) == ["cargo", "rustup"])
    }

    @Test func categoriesWithoutToolsHaveNoBreakdown() {
        let classification = Classification(items: [
            item("/h/Library/Caches/com.example.a", "caches.general", 10),
            item("/h/Library/Caches/com.example.b", "caches.general", 20),
        ])

        let cards = CategorySummary.make(classification: classification, totals: [:], deltas: [:])

        #expect(cards[0].tools.isEmpty)
    }

    @Test func itemsInCategoryAndTool() {
        let classification = Classification(items: [
            item("/h/a/node_modules", "js.node_modules", tool: "npm", 30),
            item("/h/b/node_modules", "js.node_modules", tool: "pnpm", 100),
            item("/h/d/node_modules", "js.node_modules", 5),
            item("/h/.cargo/registry", "rust.cargo.registry", 10),
        ])

        #expect(classification.items(in: .javascript, tool: "pnpm").map(\.path) == ["/h/b/node_modules"])
        #expect(classification.items(in: .javascript, tool: "기타").map(\.path) == ["/h/d/node_modules"])
        #expect(classification.items(in: .javascript, tool: "cargo").isEmpty)
        #expect(classification.items(in: .rust, tool: "cargo").map(\.path) == ["/h/.cargo/registry"])
    }

    // MARK: 0 바이트 정리 대상

    @Test func zeroByteTrashableWithoutCommandItemsHasNoButton() {
        let classification = Classification(items: [
            item("/h/Library/Developer/Xcode/DerivedData", "xcode.deriveddata", 0),
            item("/h/Library/Developer/Xcode/Archives", "xcode.archives", 50),
        ])

        let cards = CategorySummary.make(classification: classification, totals: [:], deltas: [:])

        #expect(cards.map(\.category) == [.xcode])
        #expect(cards[0].cleanup == CleanupAvailability.none)
    }

    @Test func zeroByteTrashableWithCommandItemsShowsNextVersion() {
        let classification = Classification(items: [
            item("/h/dev/web/node_modules", "js.node_modules", 0),
            item("/h/.npm/_cacache", "js.npm", 70),
        ])

        let cards = CategorySummary.make(classification: classification, totals: [:], deltas: [:])

        #expect(cards[0].cleanup == .nextVersion)
    }

    @Test func anyPositiveTrashableKeepsTrashButton() {
        let classification = Classification(items: [
            item("/h/a/node_modules", "js.node_modules", 0),
            item("/h/b/node_modules", "js.node_modules", 1),
        ])

        #expect(CategorySummary.availability(classification.items(in: .javascript))
            == .trash(reclaimable: 1, needsCommand: 0))
        #expect(CategorySummary.availability([]) == CleanupAvailability.none)
    }

    // MARK: 섞인 카테고리 (리뷰 RV13 에서 옮김)

    /// 명령이 필요한 큰 항목과 휴지통 항목이 섞이면 휴지통 버튼이 이기고 명령 항목 크기는 따로 알린다.
    @Test func jsMixTrashWins() {
        let classification = Classification(items: [
            item("/h/.npm/_cacache", "js.npm", 900),
            item("/h/Library/Caches/Yarn", "js.yarn", 5),
        ])

        let cards = CategorySummary.make(classification: classification, totals: [:], deltas: [:])

        #expect(cards[0].cleanup == .trash(reclaimable: 5, needsCommand: 900))
        #expect(cards[0].tools.map(\.name) == ["npm", "yarn"])
    }

    @Test func pythonMixTrashWins() {
        let classification = Classification(items: [
            item("/h/.cache/uv", "python.uv.cache", 400),
            item("/h/.local/share/uv/python", "python.uv.python", 300),
            item("/h/.cache/pip", "python.pip.dotcache", 20),
        ])

        let cards = CategorySummary.make(classification: classification, totals: [:], deltas: [:])

        // 주의 등급(uv python)은 휴지통 합에도 명령 합에도 들지 않는다
        #expect(cards[0].cleanup == .trash(reclaimable: 20, needsCommand: 400))
        #expect(cards[0].tools.map(\.name) == ["uv", "pip"])
    }

    /// 크기가 같으면 카테고리 rawValue 순
    @Test func tieBreak() {
        let total = CategoryTotal(size: 5, itemCount: 1)
        let cards = CategorySummary.make(classification: nil,
                                         totals: [.xcode: total, .caches: total, .logs: total,
                                                  .python: total, .rust: total, .go: total],
                                         deltas: [:])
        #expect(cards.map(\.category) == [.caches, .go, .logs, .python, .rust, .xcode])
    }

    /// 스캔 결과가 있으면 스냅샷 합계 대신 그것만 쓴다 (사라진 카테고리는 변화량이 있어도 카드가 없다).
    @Test func classificationWins() {
        let classification = Classification(items: [
            item("/h/Library/Logs/x", "logs", 3),
            item("/h/go/pkg/mod", "go.pkg.mod", 8),
        ])

        let cards = CategorySummary.make(classification: classification,
                                         totals: [.gradle: CategoryTotal(size: 99, itemCount: 1),
                                                  .rust: CategoryTotal(size: 50, itemCount: 2)],
                                         deltas: [.gradle: -99, .logs: 3])

        #expect(cards.map(\.category) == [.go, .logs])
        #expect(cards[0].cleanup == .trash(reclaimable: 8, needsCommand: 0))
        #expect(cards[1].delta == 3)
    }
}
