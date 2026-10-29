import Testing
@testable import StoragerCore

struct ByteFormatTests {
    @Test(arguments: [
        (Int64(812_400_000_000), "812G"),
        (Int64(9_540_000_000), "9.5G"),
        (Int64(1_234_000_000_000), "1.2T"),
        (Int64(640_000_000), "640M"),
        (Int64(999), "999B"),
        (Int64(-5), "0B"),
        // 표시 자릿수까지 내림: 9.95G 이상에서 "10.0G" 가 되지 않는다
        (Int64(9_949_999_999), "9.9G"),
        (Int64(9_950_000_000), "9.9G"),
        (Int64(9_970_000_000), "9.9G"),
        (Int64(9_999_999_999), "9.9G"),
        (Int64(10_000_000_000), "10G"),
        (Int64(10_999_999_999), "10G"),
        (Int64(999_999_999), "999M"),
        (Int64(1_000_000_000), "1.0G"),
        (Int64(9_999_999_999_999), "9.9T"),
        (Int64(10_000_000_000_000), "10T"),
        (Int64(1_000), "1.0K"),
        (Int64(0), "0B"),
    ])
    func compact(bytes: Int64, expected: String) {
        #expect(ByteFormat.compact(bytes) == expected)
    }

    @Test func deltaHasSign() {
        #expect(ByteFormat.delta(40_000_000_000).hasPrefix("+"))
        #expect(ByteFormat.delta(-1_200_000_000).hasPrefix("-"))
        #expect(ByteFormat.delta(0) == "0")
        // 소수점 기호는 로케일에 따라 "." 또는 "," 이므로 구분자를 통일해 비교한다
        #expect(digitsNormalized(ByteFormat.delta(-1_200_000_000)).contains("1.2"))
    }

    @Test func fullZeroIsNumeric() {
        let text = ByteFormat.full(0)
        #expect(!text.contains("Zero"))
        #expect(text.hasPrefix("0"))
        #expect(text.contains("byte"))
        #expect(ByteFormat.delta(0) == "0")
    }

    private func digitsNormalized(_ text: String) -> String {
        text.replacingOccurrences(of: ",", with: ".")
    }
}
