import AppKit
import StoragerCore
import SwiftUI

extension PathColor {
    /// sRGB NSColor (라이트·다크 모양과 무관하게 같은 값)
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}
