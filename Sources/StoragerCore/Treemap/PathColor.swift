import Foundation

/// 경로마다 정해지는 색. 절대 경로 문자열의 FNV-1a 64비트 해시를 섞고 24비트로 접어 그대로 RGB 로 쓴다
/// (채도·밝기 보정 없음). 프로세스·실행마다 같은 값이어야 하므로 Swift `Hasher`(실행마다 시드가 바뀐다)를 쓰지 않는다.
///
/// - 해시: FNV-1a 64 (offset basis `0xcbf29ce484222325`, prime `0x100000001b3`), 입력은 경로의 UTF-8 바이트.
/// - 섞기: murmur3 `fmix64`. FNV-1a 는 마지막 바이트가 아래 비트에만 퍼져, 마지막 글자만 다른 형제
///   (`app0`…`app9`, `2000`…`2099`)가 비슷한 색이 된다. fmix64 로 모든 비트에 퍼뜨린다.
/// - 접기: `(h ^ (h >> 24) ^ (h >> 48)) & 0xFFFFFF` → `0xRRGGBB`.
/// - 경로는 끝의 `/` 를 뗀 표준 절대 경로로 받는다(`/` 자신은 그대로). `~/foo` 와 `~/foo/foo` 처럼
///   마지막 이름이 같아도 전체 경로가 달라 색이 다르다.
public struct PathColor: Sendable, Hashable {
    /// 24비트 `0xRRGGBB`
    public let rgb: UInt32

    public init(rgb: UInt32) {
        self.rgb = rgb & 0xFF_FFFF
    }

    /// 절대 경로의 색. 끝의 `/` 는 떼고 해시한다.
    public init(path: String) {
        self.init(rgb: Self.rgb(hashing: Self.trimmingTrailingSlashes(path)))
    }

    /// 나머지 칸("나머지 N개")의 색. 부모 경로 + `remainderSuffix` 를 해시한다.
    /// 접미사에 NUL 이 들어 있어 실제 파일 이름(NUL 을 쓸 수 없다)의 자식 경로와 겹치지 않는다.
    public static func remainder(parentPath: String) -> PathColor {
        PathColor(rgb: rgb(hashing: trimmingTrailingSlashes(parentPath) + remainderSuffix))
    }

    /// 나머지 칸 해시 입력의 접미사
    public static let remainderSuffix = "/\u{0}remainder"

    /// 트리맵 칸의 색. 나머지 칸은 `path` 가 부모 경로라 `remainder(parentPath:)` 를 쓴다.
    public init(tile: TreemapTile) {
        self = tile.kind == .remainder ? .remainder(parentPath: tile.path) : PathColor(path: tile.path)
    }

    /// 트리 뷰 줄의 색. 나머지 줄은 `path` 가 부모 경로라 `remainder(parentPath:)` 를 쓴다.
    public init(entry: TreeEntry) {
        self = entry.kind == .remainder ? .remainder(parentPath: entry.path) : PathColor(path: entry.path)
    }

    public var red: UInt8 { UInt8(truncatingIfNeeded: rgb >> 16) }
    public var green: UInt8 { UInt8(truncatingIfNeeded: rgb >> 8) }
    public var blue: UInt8 { UInt8(truncatingIfNeeded: rgb) }

    /// `"#RRGGBB"` (대문자)
    public var hex: String {
        let digits = String(rgb, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// 보색 (255 - r, 255 - g, 255 - b)
    public var complement: PathColor {
        PathColor(rgb: ~rgb & 0xFF_FFFF)
    }

    // MARK: 해시

    /// 해시 입력 문자열 → 24비트 색: fold24(fmix64(fnv1a64(s)))
    static func rgb(hashing string: String) -> UInt32 {
        fold24(fmix64(fnv1a64(string)))
    }

    /// murmur3 64비트 마무리 섞기
    static func fmix64(_ hash: UInt64) -> UInt64 {
        var hash = hash
        hash ^= hash >> 33
        hash &*= 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        hash &*= 0xc4ce_b9fe_1a85_ec53
        hash ^= hash >> 33
        return hash
    }

    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// 64비트를 24비트씩 xor 해 접는다.
    static func fold24(_ hash: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: (hash ^ (hash >> 24) ^ (hash >> 48)) & 0xFF_FFFF)
    }

    /// 끝의 `/` 를 뗀다(첫 글자는 남겨 `/` 는 그대로). UTF-8 뷰 인덱스로 뒤에서부터 훑어 O(끝 `/` 개수).
    static func trimmingTrailingSlashes(_ path: String) -> String {
        let utf8 = path.utf8
        guard let first = utf8.indices.first else { return path }
        var end = utf8.endIndex
        while case let last = utf8.index(before: end), last > first, utf8[last] == UInt8(ascii: "/") {
            end = last
        }
        return end == utf8.endIndex ? path : String(path[..<end])
    }
}
