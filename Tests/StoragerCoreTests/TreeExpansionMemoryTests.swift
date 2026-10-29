import Testing
@testable import StoragerCore

struct TreeExpansionMemoryTests {
    @Test func rememberForgetAndKeepDescendantsOfCollapsedParent() {
        var memory = TreeExpansionMemory()
        memory.remember("/h")
        memory.remember("/h/a")
        memory.remember("/h/a/b")

        memory.forget("/h/a")

        #expect(memory.paths == ["/h", "/h/a/b"])
        #expect(memory.contains("/h/a/b"))
    }

    @Test func pruneChildrenDropsVanishedChildAndItsDescendants() {
        var memory = TreeExpansionMemory()
        for path in ["/h", "/h/a", "/h/a/x", "/h/b", "/h/b/y"] { memory.remember(path) }

        let checked = memory.pruneChildren(of: "/h") { $0 == "/h/b" }

        #expect(checked == 2)
        #expect(memory.paths == ["/h", "/h/b", "/h/b/y"])
    }

    @Test func pruneReachesRememberedDescendantsOfCollapsedFolder() {
        // /h/a 는 접혀 있지만(기억 안 함) 그 아래 /h/a/b 는 기억 중. /h/a 가 사라지면 /h/a/b 도 빠진다
        var memory = TreeExpansionMemory()
        memory.remember("/h")
        memory.remember("/h/a/b")

        memory.pruneChildren(of: "/h") { _ in false }

        #expect(memory.paths == ["/h"])
        // 간선도 정리돼 다시 기억하면 처음처럼 동작한다
        memory.remember("/h/c")
        let result1 = memory.pruneChildren(of: "/h") { _ in true }
        #expect(result1 == 1)
    }

    @Test func forgetCleansEdgesSoPruneOnlyChecksLiveChildren() {
        var memory = TreeExpansionMemory()
        memory.remember("/h")
        memory.remember("/h/a/b/c")
        memory.forget("/h/a/b/c")

        let result2 = memory.pruneChildren(of: "/h") { _ in true }
        #expect(result2 == 0)
        #expect(memory.paths == ["/h"])
    }

    @Test func retainOnlyDropsPathsOutsideRoots() {
        var memory = TreeExpansionMemory()
        for path in ["/h", "/h/a", "/x", "/x/y", "/hh"] { memory.remember(path) }

        memory.retainOnly(underRoots: ["/h"])

        #expect(memory.paths == ["/h", "/h/a"])
    }

    @Test func limitEvictsLeastRecentlyUsed() {
        var memory = TreeExpansionMemory(limit: 2)

        memory.remember("/h")
        memory.remember("/x")
        memory.remember("/y")  // 가장 오래된 /h 를 잊는다
        #expect(memory.paths == ["/x", "/y"])

        memory.remember("/x")  // 다시 쓰면 최근으로
        memory.remember("/z")
        #expect(memory.paths == ["/x", "/z"])
    }

    @Test func rememberingDescendantKeepsAncestorsFresh() {
        var memory = TreeExpansionMemory(limit: 3)

        memory.remember("/h")
        memory.remember("/h/a")
        memory.remember("/h/a/1")
        memory.remember("/h/a/2")  // /h·/h/a 는 방금 함께 올라가 /h/a/1 이 밀려난다

        #expect(memory.paths == ["/h", "/h/a", "/h/a/2"])
    }

    @Test func collapsingAfterOptionClickDoesNotStickAtLimit() {
        // Option-클릭으로 /h/L 아래를 한도 넘게 펼친 뒤 /h/L 만 접어도, 이후 새 펼침을 계속 기억한다
        var memory = TreeExpansionMemory()
        memory.remember("/h")
        memory.remember("/h/L")
        for index in 0..<5_000 { memory.remember("/h/L/d\(index)") }
        #expect(memory.count == TreeExpansionMemory.defaultLimit)

        memory.forget("/h/L")
        memory.remember("/h/Projects")
        #expect(memory.contains("/h/Projects"))
        #expect(memory.contains("/h"))

        // 새 결과로 다시 그린 뒤에도 마찬가지
        memory.retainOnly(underRoots: ["/h"])
        memory.pruneChildren(of: "/h") { _ in true }
        memory.remember("/h/Other")
        #expect(memory.contains("/h/Other"))
        #expect(memory.contains("/h/Projects"))
        #expect(memory.count == TreeExpansionMemory.defaultLimit)
    }

    @Test func childFirstExpandOrderStillRemembersParent() {
        // AppKit 이 Option-클릭에서 자식의 펼침 알림을 부모보다 먼저 보내는 경우
        var memory = TreeExpansionMemory(limit: 3)
        for path in ["/h/L/a", "/h/L/b", "/h/L/c", "/h/L"] { memory.remember(path) }

        #expect(memory.contains("/h/L"))
        #expect(memory.count == 3)
        // 밀려난 자식이 있어도 /h/L 이 사라지면 남은 자손까지 함께 빠진다
        memory.pruneChildren(of: "/h") { _ in false }
        #expect(memory.count == 0)
    }

    @Test func manyExpansionsDoBoundedWorkPerExpansion() {
        // Option-클릭으로 폴더 100,000개를 펼친 경우: 펼침마다 기억 + 그 폴더의 자식만 확인한다.
        // 확인 수의 합이 기억한 경로 수와 같다 (펼침마다 전체를 훑으면 약 n²/2 = 50억 번이다).
        var memory = TreeExpansionMemory(limit: 200_000)
        let parents = (0..<1_000).map { "/h/p\($0)" }
        memory.remember("/h")
        var checked = 0
        for parent in parents {
            memory.remember(parent)
            for child in 0..<100 { memory.remember("\(parent)/c\(child)") }
        }
        for parent in parents {
            checked += memory.pruneChildren(of: parent) { _ in true }
        }
        checked += memory.pruneChildren(of: "/h") { _ in true }

        #expect(memory.count == 1 + 1_000 + 100_000)
        #expect(checked == 100_000 + 1_000)
    }

    @Test func defaultLimitCapsOptionClickExpansion() {
        var memory = TreeExpansionMemory()
        for index in 0..<10_000 { memory.remember("/h/d\(index)") }

        #expect(memory.count == TreeExpansionMemory.defaultLimit)
        #expect(memory.contains("/h/d9999"))
        #expect(!memory.contains("/h/d0"))
    }

    @Test func orderLogStaysBoundedWithoutRememberedAncestor() {
        // 형제 경로만 100만 번 기억(한도 초과로 계속 밀려남): 순서 기록이 한도에 비례해 묶인다
        var memory = TreeExpansionMemory()
        var peak = 0
        for index in 0..<1_000_000 {
            memory.remember("/h/d\(index)")
            peak = max(peak, memory.orderStorageCount)
        }

        #expect(memory.count == TreeExpansionMemory.defaultLimit)
        #expect(peak <= 2 * TreeExpansionMemory.defaultLimit + 1_024)
    }

    @Test func orderLogStaysBoundedWithRememberedAncestor() {
        // 기억 중인 조상(/h, /h/L)도 매번 함께 최근으로 올라가 기록이 3배로 쌓이는 경우
        var memory = TreeExpansionMemory()
        memory.remember("/h")
        memory.remember("/h/L")
        var peak = 0
        for index in 0..<1_000_000 {
            memory.remember("/h/L/d\(index)")
            peak = max(peak, memory.orderStorageCount)
        }

        #expect(memory.count == TreeExpansionMemory.defaultLimit)
        #expect(memory.contains("/h") && memory.contains("/h/L"))
        #expect(peak <= 2 * TreeExpansionMemory.defaultLimit + 1_024)
    }

    @Test func orderLogStaysBoundedWhenRepeatedlyTouchingSamePaths() {
        // 한도 아래에서 같은 경로를 반복해 기억(다시 그릴 때마다 되살리기)해도 기록이 쌓이지 않는다
        var memory = TreeExpansionMemory()
        var peak = 0
        for _ in 0..<100_000 {
            memory.remember("/h/a/b")
            peak = max(peak, memory.orderStorageCount)
            memory.remember("/h/c")
            peak = max(peak, memory.orderStorageCount)
        }

        #expect(memory.count == 2)
        #expect(peak <= 2 * 2 + 1_024)
    }
}
