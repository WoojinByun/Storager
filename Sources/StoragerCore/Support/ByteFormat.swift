import Foundation

/// 크기 표시. Finder·시스템 설정과 같은 10진(1 GB = 1,000,000,000 바이트) 단위를 쓴다.
public enum ByteFormat {
    /// 메뉴바용 짧은 표기: "812G", "9.5G", "1.2T", "640M".
    /// 표시 자릿수까지 내림한다 (9.97G -> "9.9G", 10G -> "10G"). 반올림하면 9.95G 부터 "10.0G" 로 보인다.
    /// 정수 연산이라 로케일·부동소수점 오차·오버플로와 무관하다 (모든 단위 크기가 10 의 배수라 size / 10 이 정확하다).
    public static func compact(_ bytes: Int64) -> String {
        let units: [(Int64, String)] = [(1_000_000_000_000, "T"), (1_000_000_000, "G"), (1_000_000, "M"), (1_000, "K")]
        let value = max(0, bytes)
        for (size, suffix) in units where value >= size {
            let tenths = value / (size / 10)
            return tenths < 100 ? "\(tenths / 10).\(tenths % 10)\(suffix)" : "\(tenths / 10)\(suffix)"
        }
        return "\(value)B"
    }

    /// 일반 표기: "1.23 GB". ByteCountFormatter(.file) 와 같고, 숫자 표기는 사용자 로케일을 따른다.
    /// 0 바이트는 "Zero KB" 가 아니라 숫자 표기("0 bytes")로 쓴다.
    public static func full(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    /// 변화량: "+40 GB", "-1.2 GB", 0 이면 "0".
    public static func delta(_ bytes: Int64) -> String {
        if bytes == 0 { return "0" }
        return (bytes > 0 ? "+" : "-") + full(Int64(clamping: bytes.magnitude))
    }
}
