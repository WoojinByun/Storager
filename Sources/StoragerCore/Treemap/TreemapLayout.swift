import CoreGraphics

/// Squarified treemap (Bruls, Huizing, van Wijk 2000). 순수 함수라 UI 없이 테스트한다.
public enum TreemapLayout {
    /// `weights` 를 `rect` 안에 면적 비율대로 배치한다. 결과는 입력과 같은 순서이며,
    /// 0 이하 가중치는 `.zero` 사각형이 된다.
    public static func squarify(_ weights: [Double], in rect: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: weights.count)
        let total = weights.filter { $0 > 0 }.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }

        let scale = Double(rect.width * rect.height) / total
        // 큰 것부터 배치해야 정사각형에 가까워진다
        let order = weights.indices.filter { weights[$0] > 0 }.sorted { weights[$0] > weights[$1] }
        let areas = Dictionary(uniqueKeysWithValues: order.map { ($0, weights[$0] * scale) })

        var remaining = rect
        var row: [Int] = []
        var next = 0
        while next < order.count {
            let side = Double(min(remaining.width, remaining.height))
            let candidate = row + [order[next]]
            if row.isEmpty || worstRatio(row.map { areas[$0]! }, side: side) >= worstRatio(candidate.map { areas[$0]! }, side: side) {
                row = candidate
                next += 1
            } else {
                remaining = place(row, areas: areas, in: remaining, into: &result)
                row = []
            }
        }
        if !row.isEmpty {
            _ = place(row, areas: areas, in: remaining, into: &result)
        }
        return result
    }

    /// 한 줄에 놓인 사각형들의 가장 나쁜 가로세로비.
    static func worstRatio(_ areas: [Double], side: Double) -> Double {
        let sum = areas.reduce(0, +)
        guard let largest = areas.max(), let smallest = areas.min(), sum > 0, side > 0 else { return .infinity }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }

    /// 짧은 변을 따라 한 줄을 놓고 남은 사각형을 돌려준다.
    private static func place(_ row: [Int], areas: [Int: Double], in rect: CGRect, into result: inout [CGRect]) -> CGRect {
        let sum = row.reduce(0) { $0 + areas[$1]! }
        if rect.width >= rect.height {
            // 왼쪽에 세로 열
            let width = CGFloat(sum / Double(rect.height))
            var y = rect.minY
            for index in row {
                let height = CGFloat(areas[index]! / Double(width))
                result[index] = CGRect(x: rect.minX, y: y, width: width, height: height)
                y += height
            }
            return CGRect(x: rect.minX + width, y: rect.minY, width: max(0, rect.width - width), height: rect.height)
        } else {
            // 위쪽에 가로 행
            let height = CGFloat(sum / Double(rect.width))
            var x = rect.minX
            for index in row {
                let width = CGFloat(areas[index]! / Double(height))
                result[index] = CGRect(x: x, y: rect.minY, width: width, height: height)
                x += width
            }
            return CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: max(0, rect.height - height))
        }
    }
}
