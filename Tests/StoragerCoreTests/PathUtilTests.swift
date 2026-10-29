import Foundation
import Testing
@testable import StoragerCore

struct PathUtilTests {
    @Test func standardizeRemovesTrailingSlashAndDots() {
        #expect(PathUtil.standardize("/a/b/../c/") == "/a/c")
        #expect(PathUtil.standardize("~") == NSHomeDirectory())
        #expect(PathUtil.standardize("//a/./b//") == "/a/b")
        // realpath 결과(/private/var/…)를 /var/… 로 바꾸지 않는다
        #expect(PathUtil.standardize("/private/var/tmp") == "/private/var/tmp")
    }

    @Test func descendantCheckRespectsComponentBoundaries() {
        #expect(PathUtil.isSameOrDescendant("/a/b", of: "/a"))
        #expect(PathUtil.isSameOrDescendant("/a", of: "/a"))
        #expect(PathUtil.isSameOrDescendant("/ab", of: "/a") == false)
    }

    @Test func relativeComponents() {
        #expect(PathUtil.components(of: "/h/x/y", relativeTo: "/h") == ["x", "y"])
        #expect(PathUtil.components(of: "/h", relativeTo: "/h") == [])
        #expect(PathUtil.components(of: "/other", relativeTo: "/h") == nil)
    }

    @Test func resolveFollowsSymlinksAndKeepsMissingTail() throws {
        let tree = try TempTree()
        try tree.dir("real/sub")
        try tree.symlink("alias", to: tree.path + "/real")

        #expect(PathUtil.resolve(tree.path + "/alias/sub/") == tree.path + "/real/sub")
        // 없는 경로는 존재하는 조상까지만 풀고 나머지 이름은 그대로 붙인다
        #expect(PathUtil.resolve(tree.path + "/alias/gone/deeper") == tree.path + "/real/gone/deeper")
        // 풀 수 있는 조상이 없으면 standardize 와 같다
        #expect(PathUtil.resolve("/nonexistent-storager-root/x/../y") == "/nonexistent-storager-root/y")
    }
}
