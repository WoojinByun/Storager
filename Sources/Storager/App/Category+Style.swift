import AppKit
import StoragerCore
import SwiftUI

extension StoragerCore.Category {
    /// 카드 색, 트리맵 분류 칸의 카테고리 띠·기호 색.
    var color: Color {
        switch self {
        case .xcode: .blue
        case .simulator: .cyan
        case .gradle: .green
        case .javascript: .yellow
        case .cocoaPodsSwiftPM: .orange
        case .docker: .indigo
        case .homebrew: .brown
        case .aiTools: .purple
        case .python: .mint
        case .rust: Self.rustColor
        case .go: Self.goColor
        case .caches: .teal
        case .logs: .pink
        case .personalData: .red
        }
    }

    // 시스템 색이 모두 쓰여 Rust·Go 는 직접 정한다. 밝은·어두운 모양마다 배경 대비 3:1 이상(그래픽 기준)이 되도록
    // 두 값을 둔다: 흰 배경 대비 Rust 4.9:1, Go 6.1:1 / 어두운 배경(#282828) 대비 Rust 5.3:1, Go 6.0:1.
    // Go 는 시뮬레이터(cyan)·캐시(teal)와 헷갈리지 않도록 그보다 짙은(밝은 모양) 파랑으로 둔다.

    /// 녹 주황
    private static let rustColor = dynamic(light: (0.72, 0.33, 0.16), dark: (0.91, 0.50, 0.32))
    /// 짙은 세룰리안 파랑
    private static let goColor = dynamic(light: (0.04, 0.40, 0.64), dark: (0.42, 0.66, 0.96))

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (red, green, blue) = isDark ? dark : light
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        })
    }
}
