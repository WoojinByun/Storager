import AppKit
import StoragerCore

/// 메뉴바 라벨(템플릿 조각)을 한 장의 이미지로 그린다. 기본은 템플릿 이미지이고, "템플릿 이미지로 표시" 설정을 끄면
/// 이모지를 원래 색으로 두는 일반 이미지로 그린다(`appearance`).
///
/// 버튼의 제목(attributedTitle)에 아이콘을 첨부로 넣는 대신 이미지로 그리는 이유: `NSStatusBarButton` 은 제목 줄을 위에서
/// 3pt 아래에 고정해 두어, 메뉴바보다 큰 내용을 가운데에 두지 않고 아래만 잘라 낸다(오프스크린 측정). 이미지 높이를 메뉴바
/// 높이로 고정하고 그 안에서 위치를 정하면 크기를 키웠을 때 위아래가 똑같이 잘린다. 템플릿 이미지라 밝은·어두운 메뉴바,
/// 눌림 강조, 비활성 화면의 색을 시스템이 아이콘과 똑같이 입힌다. 그리기 핸들러는 그릴 때 불리므로 actor 에 묶지 않는다.
///
/// 100% 에서는 버튼의 이미지+제목 배치(`imagePosition = .imageLeading`)와 같은 자리에 그린다(오프스크린 측정값):
/// 버튼은 이미지만 있을 때 양옆에 3pt, 이미지+제목일 때 7pt 를 두므로 이미지 안 양옆에 4pt 를 더 둔다. 아이콘은 18.5pt
/// 칸(심볼 18pt 를 가운데) 에 그리고 칸 다음 2pt 뒤에 글자가 온다. 아이콘은 정렬 사각형을 세로 가운데(점 단위 반올림)에,
/// 글자 줄(기본 줄 높이)은 위에서 3pt 에 두되(24pt 보다 높은 메뉴바는 가운데 24pt 띠 기준) 위아래 3pt 여백 안에 들지 않으면
/// 세로 가운데에 둔다. 글자 시작은 점 단위로 맞춘다.
enum MenuBarLabel {
    static let symbolName = "internaldrive"
    /// 이미지 양옆 여백(pt). 버튼이 이미지 둘레에 두는 3pt 와 합쳐 이미지+제목 배치의 7pt 가 된다. 크기와 상관없이 같다.
    static let sidePadding: CGFloat = 4
    /// 아이콘 칸이 심볼보다 넓은 만큼(pt). 버튼의 이미지 칸(18.5pt)과 같게 둔다.
    static let iconSlotExtra: CGFloat = 0.5
    /// 아이콘 칸과 이웃 조각 사이 간격(pt, 100% 기준, 크기에 비례)
    static let iconGap: CGFloat = 2
    /// 버튼이 제목 줄 위에 두는 여백(pt)
    static let titleTopInset: CGFloat = 3
    /// 제목 줄 배치를 맞춘 메뉴바 높이(pt). 이보다 높은 메뉴바에서는 이 높이의 띠를 가운데에 두고 그 안에 배치한다.
    static let referenceBarHeight: CGFloat = 24
    /// 버튼의 제목 기준선이 줄 위 + ascender 보다 위에 있는 만큼(pt, 측정값)
    static let titleBaselineLift: CGFloat = 0.5

    /// 100% 메뉴바 글꼴
    static func font(scale: CGFloat) -> NSFont {
        .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize * scale, weight: .regular)
    }

    /// 크기에 맞춘 아이콘 심볼. 100% 는 설정 없이 만든 심볼(버튼 이미지와 같은 18×13pt)과 크기가 같다.
    static func symbol(scale: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize * scale, weight: .regular))
    }

    /// 조각마다의 가로 위치와 이미지 크기, 세로 위치(아래 기준). 테스트할 수 있게 그리기와 나눈다.
    struct Layout {
        struct Item {
            var piece: MenuBarTemplate.Piece
            /// 조각 칸의 왼쪽 x
            var x: CGFloat
            var width: CGFloat
        }
        var items: [Item]
        var size: NSSize
        /// 글자 기준선 y (아래 기준)
        var baseline: CGFloat
        /// 아이콘 이미지의 아래 y
        var iconY: CGFloat
        /// 아이콘 이미지가 칸 안에서 들어가는 정도
        var iconInset: CGFloat
    }

    static func layout(_ pieces: [MenuBarTemplate.Piece], scale: CGFloat, height: CGFloat) -> Layout {
        let font = font(scale: scale)
        let symbol = symbol(scale: scale)
        let iconSize = symbol?.size ?? .zero
        let alignment = symbol?.alignmentRect ?? NSRect(origin: .zero, size: iconSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        var items: [Layout.Item] = []
        var x = sidePadding
        for (index, piece) in pieces.enumerated() {
            if index > 0, piece == .icon || pieces[index - 1] == .icon { x += iconGap * scale }
            let width: CGFloat = switch piece {
            case .icon: iconSize.width + iconSlotExtra
            case .text(let string): NSAttributedString(string: string, attributes: attributes).size().width
            }
            items.append(.init(piece: piece, x: x, width: width))
            x += width
        }
        let width = ceil((x + sidePadding) * 2) / 2

        // 글자 줄: 메뉴바 세로 가운데의 24pt 띠 안에서 버튼처럼 위에서 3pt 에 둔다. 띠보다 낮은 메뉴바(22pt)는 메뉴바 자체가 띠다.
        // 그래서 22·24pt 는 버튼 배치와 같고, 더 높은 메뉴바(30·37pt)에서도 가운데인 아이콘과 함께 가운데에 남는다.
        // 줄이 띠의 위아래 3pt 여백 안에 안 들어가면 세로 가운데(넘치면 위아래가 같은 만큼 잘린다).
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let band = min(height, referenceBarHeight)
        let lineTop = (height - band) / 2 + min(titleTopInset, (band - lineHeight) / 2)
        // 버튼의 제목 기준선은 줄 위 + ascender 보다 0.5pt 위다(오프스크린 측정, 줄 높이 여유를 위아래로 나누지 않는다)
        let baselineFromTop = lineTop + font.ascender - titleBaselineLift
        // 아이콘: 정렬 사각형을 세로 가운데에 두고 버튼처럼 점 단위로 반올림한다.
        let alignmentTop = ((height - alignment.height) / 2).rounded()
        let iconY = height - alignmentTop - alignment.height - alignment.minY
        return Layout(items: items, size: NSSize(width: width, height: height), baseline: height - baselineFromTop,
                      iconY: iconY, iconInset: iconSlotExtra / 2)
    }

    /// - Parameters:
    ///   - scale: 1 = 메뉴바 기본 글자 크기(`NSFont.systemFontSize`)
    ///   - height: 이미지 높이(메뉴바 버튼 높이). 내용이 더 크면 위아래가 같은 만큼 잘린다.
    ///   - appearance: nil 이면 템플릿 이미지(시스템이 모든 픽셀을 한 색으로 입혀 이모지도 단색 실루엣이 된다).
    ///     주면 일반 이미지로 그린다: 이모지는 원래 색, 아이콘·글자는 그릴 때 이 모양새로 푼 `NSColor.labelColor`
    ///     (어두운 메뉴바는 흰색, 밝은 메뉴바는 검은색 계열, α 0.85). 배치는 템플릿 이미지와 같다.
    static func image(_ pieces: [MenuBarTemplate.Piece], scale: CGFloat, height: CGFloat,
                      accessibility: String, appearance: NSAppearance? = nil) -> NSImage {
        let font = font(scale: scale)
        let symbol = symbol(scale: scale)
        let layout = layout(pieces, scale: scale, height: height)
        let image = NSImage(size: layout.size, flipped: false) { rect in
            guard let appearance else {
                draw(layout, symbol: symbol, font: font, tint: nil, in: rect)
                return true
            }
            // 그릴 때의 모양새로 메뉴바 글자 색을 푼다(모양새가 바뀌면 StatusItemController 가 새 모양새로 다시 그린다)
            appearance.performAsCurrentDrawingAppearance {
                draw(layout, symbol: symbol, font: font, tint: NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor,
                     in: rect)
            }
            return true
        }
        image.isTemplate = appearance == nil
        image.accessibilityDescription = accessibility
        return image
    }

    /// - Parameter tint: nil 이면 템플릿 이미지용으로 모두 검은색. 주면 아이콘과 글자(색 글리프가 아닌 글리프)를 템플릿과
    ///   똑같이 검은색으로 투명 레이어에 그린 뒤 이 색으로 칠하고(`sourceIn`), 색 글리프(이모지)는 그 위에 원래 색으로 그린다.
    ///   밝은 글자를 투명한 비트맵에 바로 그리면 글꼴 다듬기가 획을 두껍게 해(다크 메뉴바에서 약 15%) 시스템이 템플릿에
    ///   입히는 색보다 진해지고, 아이콘을 따로 칠한 이미지로 그리면 소수점 위치에서 다시 샘플링돼 옅어지므로 이렇게 그린다.
    private static func draw(_ layout: Layout, symbol: NSImage?, font: NSFont, tint: NSColor?, in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        NSBezierPath(rect: rect).addClip()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if tint != nil { context.beginTransparencyLayer(auxiliaryInfo: nil) }
        var colorRuns: [(CTRun, CGPoint)] = []
        for item in layout.items {
            switch item.piece {
            case .icon:
                guard let symbol else { continue }
                symbol.draw(in: NSRect(x: item.x + layout.iconInset, y: layout.iconY,
                                       width: symbol.size.width, height: symbol.size.height))
            case .text(let string):
                // draw(at:) 은 줄 높이 여유만큼 기준선이 움직이므로 CoreText 로 기준선에 바로 그린다
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
                context.textMatrix = .identity
                // 버튼처럼 글자 시작을 점 단위로 내려 맞춘다
                let origin = CGPoint(x: item.x.rounded(.down), y: layout.baseline)
                guard tint != nil else {
                    context.textPosition = origin
                    CTLineDraw(line, context)
                    continue
                }
                for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                    if isColorGlyphRun(run) {
                        colorRuns.append((run, origin))
                    } else {
                        context.textPosition = origin
                        CTRunDraw(run, context, CFRange())
                    }
                }
            }
        }
        guard let tint else { return }
        context.setFillColor(tint.cgColor)
        context.setBlendMode(.sourceIn)
        context.fill(rect)
        context.endTransparencyLayer()
        context.setBlendMode(.normal)
        for (run, origin) in colorRuns {
            context.textMatrix = .identity
            context.textPosition = origin
            CTRunDraw(run, context, CFRange())
        }
    }

    /// 글리프 묶음이 색 글리프 글꼴(Apple Color Emoji 등)로 그려지는지
    private static func isColorGlyphRun(_ run: CTRun) -> Bool {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes[kCTFontAttributeName], CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID()
        else { return false }
        return CTFontGetSymbolicTraits(value as! CTFont).contains(.traitColorGlyphs)
    }

    /// 메뉴바 글꼴로 그렸을 때 색 글리프(이모지)가 생기는 글자가 있는지. 글꼴 대체 결과를 보므로 FE0F 가 없는 🗄,
    /// 글자 모양이 없어 FE0E 를 붙여도 색으로 그려지는 😁︎ 도 잡고, 시스템 글꼴에 글자 모양이 있는 ©·숫자는 잡지 않는다.
    static func containsColorGlyphs(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font(scale: 1)]))
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        return runs.contains(where: isColorGlyphRun)
    }
}
