import Foundation
import Testing
@testable import StoragerCore

struct PathColorTests {
    @Test func fnv1a64MatchesReferenceVectors() {
        #expect(PathColor.fnv1a64("") == 0xcbf2_9ce4_8422_2325)
        #expect(PathColor.fnv1a64("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(PathColor.fnv1a64("foobar") == 0x8594_4171_f739_67e8)
    }

    @Test func knownPathColors() {
        #expect(PathColor(path: "/Users/x/work/foo/bar").hex == "#92F62D")
        #expect(PathColor(path: "/Users/x/foo").hex == "#C25697")
        #expect(PathColor(path: "/Users/x/foo/foo").hex == "#34B1F3")
        #expect(PathColor(path: "/").hex == "#1EC489")
        #expect(PathColor.remainder(parentPath: "/Users/x/foo").hex == "#8EC0AA")
    }

    @Test func fmix64() {
        #expect(PathColor.fmix64(0) == 0)
        #expect(PathColor.rgb(hashing: "/Users/x/foo") == PathColor.fold24(PathColor.fmix64(PathColor.fnv1a64("/Users/x/foo"))))
    }

    /// 마지막 글자만 다른 형제 이름들이 서로 다른 색으로 흩어지는지 (fmix64 없이 FNV-1a 만 쓰면 평균 107, 40 미만 11%).
    @Test func siblingsDifferingInLastCharacterAreDispersed() {
        let letters = (UInt8(ascii: "a")...UInt8(ascii: "z")).map { String(UnicodeScalar($0)) }
        let groups: [[String]] = [
            (0...9).map { "app\($0)" },
            (1...9).map { "v\($0)" },
            (2000...2099).map { "\($0)" },
            letters.map { "file" + $0 },
            (0...9).map { "test\($0)" },
            letters.map { "build_" + $0 },
            (0...9).map { "log\($0)" },
            (0...9).map { "item\($0)" },
        ]
        #expect(groups.reduce(0) { $0 + $1.count } == 201)
        var distances: [Double] = []
        for group in groups {
            let colors = group.map { PathColor(path: "/Users/x/work/" + $0) }
            for (a, b) in zip(colors, colors.dropFirst()) {
                let dr = Double(a.red) - Double(b.red), dg = Double(a.green) - Double(b.green), db = Double(a.blue) - Double(b.blue)
                distances.append((dr * dr + dg * dg + db * db).squareRoot())
            }
        }
        let mean = distances.reduce(0, +) / Double(distances.count)
        let close = distances.filter { $0 < 40 }.count
        #expect(mean > 140)
        #expect(Double(close) < Double(distances.count) * 0.05)
    }

    @Test func foldXorsThreeChunks() {
        #expect(PathColor.fold24(0x1a48_f829_f1b3_aef2) == 0x4B9D4B)
        #expect(PathColor.fold24(0xFF_FFFF) == 0xFF_FFFF)
        #expect(PathColor.fold24(1 << 24) == 1)
        #expect(PathColor.fold24(1 << 48) == 1)
        #expect(PathColor.fold24((1 << 48) | (1 << 24)) == 0)
    }

    @Test func isDeterministicAndIgnoresTrailingSlash() {
        let path = "/Users/x/work/foo/bar"
        #expect(PathColor(path: path) == PathColor(path: path))
        #expect(PathColor(path: path + "/") == PathColor(path: path))
        #expect(PathColor(path: "/") == PathColor(path: "//"))
    }

    @Test func trimsOnlyTrailingSlashes() {
        #expect(PathColor.trimmingTrailingSlashes("/a/b//") == "/a/b")
        #expect(PathColor.trimmingTrailingSlashes("/a/b") == "/a/b")
        #expect(PathColor.trimmingTrailingSlashes("///") == "/")
        #expect(PathColor.trimmingTrailingSlashes("/") == "/")
        #expect(PathColor.trimmingTrailingSlashes("") == "")
        #expect(PathColor.trimmingTrailingSlashes("/사진/") == "/사진")
    }

    @Test func sameLastNameDifferentPathDiffers() {
        #expect(PathColor(path: "/Users/x/foo") != PathColor(path: "/Users/x/foo/foo"))
    }

    @Test func components() {
        let color = PathColor(rgb: 0xA30D7E)
        #expect(color.red == 0xA3)
        #expect(color.green == 0x0D)
        #expect(color.blue == 0x7E)
        #expect(color.hex == "#A30D7E")
        #expect(PathColor(rgb: 0x00000A).hex == "#00000A")
    }

    @Test func complementMath() {
        let color = PathColor(rgb: 0xA30D7E)
        let complement = color.complement
        #expect(complement.red == 255 - 0xA3)
        #expect(complement.green == 255 - 0x0D)
        #expect(complement.blue == 255 - 0x7E)
        #expect(complement.hex == "#5CF281")
        #expect(complement.complement == color)
        #expect(PathColor(rgb: 0).complement.rgb == 0xFFFFFF)
    }

    @Test func remainderDiffersFromAnyRealChild() {
        let parent = "/Users/x/foo"
        let remainder = PathColor.remainder(parentPath: parent)
        #expect(remainder != PathColor(path: parent))
        // 접미사에 NUL 이 있어 실제 자식 이름으로는 같은 해시 입력을 만들 수 없다
        #expect(PathColor.remainderSuffix.utf8.contains(0))
        for name in ["remainder", "rest", "나머지", ".remainder", "remainder/x"] {
            #expect(remainder != PathColor(path: parent + "/" + name))
        }
    }

    @Test func tileAndEntryUseRemainderColorForRemainder() {
        let node = DirectoryNode(name: "n", directAllocatedSize: 30, directFileCount: 3,
                                 children: [DirectoryNode(name: "big", directAllocatedSize: 500)])
        let tiles = TreemapTile.tiles(for: node, path: "/h/n")
        #expect(PathColor(tile: tiles[0]) == PathColor(path: "/h/n/big"))
        #expect(tiles[1].kind == .remainder)
        #expect(PathColor(tile: tiles[1]) == PathColor.remainder(parentPath: "/h/n"))

        let entries = TreeEntry.children(of: node, path: "/h/n")
        let rest = entries.first { $0.kind == .remainder }
        #expect(rest.map(PathColor.init(entry:)) == PathColor.remainder(parentPath: "/h/n"))
        let big = entries.first { $0.kind == .directory }
        #expect(big.map(PathColor.init(entry:)) == PathColor(path: "/h/n/big"))
    }
}
