import AppKit
import StoragerCore
import SwiftUI

/// 홈 트리맵. squarified 레이아웃(TreemapLayout)을 Canvas 로 그린다.
/// 칸은 경로 해시 색(`PathColor`)으로 칠하고, 분류 칸은 위쪽 카테고리 색 띠와 모서리 기호 배지로 카테고리를 보인다.
/// 칸 글자는 바탕의 보색에 검은 외곽선이다.
/// 칸·사각형·색은 `AnalysisModel.treemapCells` 가 (결과 세대, 경로, 크기) 마다 한 번 계산하고,
/// 호버 상태는 `TreemapHoverLayer` 에만 있어 호버로 Canvas 를 다시 그리지 않는다.
struct TreemapView: View {
    @Bindable var model: AnalysisModel
    let result: ScanResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            breadcrumb
            GeometryReader { geometry in
                let cells = model.treemapCells(size: geometry.size)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for cell in cells where cell.rect.width >= 1 && cell.rect.height >= 1 {
                            Self.draw(cell, context: &context)
                        }
                    } symbols: {
                        // 카테고리 배지는 Canvas 심볼로 두어 SwiftUI 가 한 번 만들어 둔 것을 칸마다 다시 쓴다
                        ForEach(StoragerCore.Category.allCases) { category in
                            Self.badge(category).tag(category)
                        }
                    }
                    TreemapHoverLayer(model: model, cells: cells, homePath: result.homePath,
                                      layoutKey: TreemapLayoutKey(generation: model.store.resultGeneration,
                                                                  path: model.treemapPath, size: geometry.size))
                }
            }
        }
        .padding()
        // 새 스캔·부분 재스캔·섹션 전환 뒤 돌아왔을 때 경로가 사라졌으면 남은 가장 깊은 조상으로
        .onChange(of: model.store.resultGeneration, initial: true) { model.clampTreemapPath() }
    }

    // MARK: 그리기

    /// 칸 이름 글자. 이전 `.caption`(10pt) × 1.2 = 12pt, semibold.
    static let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// 칸 크기 글자. 이전 `.caption`(10pt) × 1.2 = 12pt.
    static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    /// 글자를 그리는 최소 칸 크기. 이전 60×30 을 글자와 같은 비율(× 1.2)로 키웠다.
    static let minLabelSize = CGSize(width: 72, height: 36)
    /// 분류 칸 위쪽의 카테고리 띠 두께
    static let stripThickness: CGFloat = 4
    /// 카테고리 기호 배지 한 변. 칸이 이보다 넉넉할 때만 그린다.
    static let badgeSide: CGFloat = 18
    /// 글자 검은 외곽선 두께(획 전체). 획은 글자 윤곽선 가운데에 그려지고 채우기가 안쪽 절반을 덮어 밖으로 절반이 남는다.
    /// 3pt 는 밝은 바탕(보색이 어두워 외곽선과 섞인다)에서 한글 획 사이가 막혀 1.25pt 로 줄였다.
    static let outlineWidth: CGFloat = 1.25
    /// 카테고리 띠 아래 구분선 두께. 바탕이 띠와 같은 색 계열이어도 띠가 보이게 한다.
    static let stripSeparator: CGFloat = 1

    private static let lineHeights = (name: lineHeight(nameFont), size: lineHeight(sizeFont))

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        (font.ascender - font.descender + font.leading).rounded(.up)
    }

    private static let truncatingParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private static func draw(_ cell: TreemapCell, context: inout GraphicsContext) {
        let inset = cell.rect.insetBy(dx: 1, dy: 1)
        let shape = Path(roundedRect: inset, cornerRadius: 3)
        context.fill(shape, with: .color(cell.color.color))

        var textTop = inset.minY
        var textTrailing = inset.maxX
        if let category = cell.tag?.category {
            var strip = context
            strip.clip(to: shape)
            let thickness = min(stripThickness, inset.height)
            strip.fill(Path(CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: thickness)),
                       with: .color(category.color))
            strip.fill(Path(CGRect(x: inset.minX, y: inset.minY + thickness, width: inset.width, height: stripSeparator)),
                       with: .color(.black.opacity(0.6)))
            textTop += thickness + stripSeparator
            if inset.width >= badgeSide + 8, inset.height >= badgeSide + thickness + stripSeparator + 6,
               let symbol = context.resolveSymbol(id: category) {
                let badge = CGRect(x: inset.maxX - 3 - badgeSide, y: textTop + 3, width: badgeSide, height: badgeSide)
                context.draw(symbol, in: badge)
                textTrailing = badge.minX - 2
            }
        }

        guard inset.width >= minLabelSize.width, inset.height >= minLabelSize.height else { return }
        let textRect = CGRect(x: inset.minX + 4, y: textTop + 3,
                              width: textTrailing - inset.minX - 8, height: inset.maxY - 3 - (textTop + 3))
        guard textRect.width > 8, textRect.height >= lineHeights.name else { return }
        let complement = cell.color.complement.nsColor
        context.withCGContext { cgContext in
            // Canvas 의 CG 좌표는 왼쪽 위가 원점(y 아래로)이라 flipped NSGraphicsContext 로 감싸 AppKit 글자 그리기를 쓴다
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: true)
            cgContext.setLineJoin(.round)
            var lineRect = CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: lineHeights.name)
            drawOutlined(cell.tile.name, font: nameFont, color: complement, in: lineRect)
            lineRect.origin.y = lineRect.maxY + 1
            lineRect.size.height = lineHeights.size
            if lineRect.maxY <= textRect.maxY + 1 {
                drawOutlined(ByteFormat.full(cell.tile.size), font: sizeFont, color: complement, in: lineRect)
            }
        }
    }

    /// 한 줄 글자를 검은 외곽선 + 보색 채우기로 그린다. 획만 그리는 패스(양수 strokeWidth) 위에 채우기 패스를 겹쳐,
    /// 외곽선이 글자 안쪽을 먹지 않고 밖으로만 보이게 한다. 칸 하나에 CoreText 줄 그리기 4번(이름·크기 × 2 패스).
    private static func drawOutlined(_ string: String, font: NSFont, color: NSColor, in rect: CGRect) {
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        let stroke = NSAttributedString(string: string, attributes: [
            .font: font,
            .paragraphStyle: truncatingParagraph,
            .strokeColor: NSColor.black,
            // strokeWidth 는 글자 크기 대비 퍼센트. 양수면 획만 그린다.
            .strokeWidth: outlineWidth / font.pointSize * 100,
        ])
        stroke.draw(with: rect, options: options, context: nil)
        let fill = NSAttributedString(string: string, attributes: [
            .font: font,
            .paragraphStyle: truncatingParagraph,
            .foregroundColor: color,
        ])
        fill.draw(with: rect, options: options, context: nil)
    }

    /// 분류 칸 모서리의 카테고리 기호 배지. 반투명 검은 바탕에 흰 기호라 어떤 칸 색·카테고리 색에서도 보인다
    /// (카테고리 색은 띠가 보여 준다).
    private static func badge(_ category: StoragerCore.Category) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.6))
            Image(systemName: category.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: badgeSide, height: badgeSide)
    }

    // MARK: 브레드크럼

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button("홈") { model.treemapPath = [] }
            ForEach(Array(model.treemapPath.enumerated()), id: \.offset) { index, name in
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                Button(name) { model.treemapPath = Array(model.treemapPath.prefix(index + 1)) }
            }
            Spacer()
            if let node = result.homeNode(at: model.treemapPath) {
                Text(ByteFormat.full(node.allocatedSize)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.link)
    }
}

/// 호버 툴팁·클릭 드릴다운·우클릭 메뉴. 호버 상태가 바뀌면 이 뷰만 다시 그린다.
private struct TreemapHoverLayer: View {
    let model: AnalysisModel
    let cells: [TreemapCell]
    let homePath: String
    let layoutKey: TreemapLayoutKey
    @State private var hovered: TreemapCell?
    @State private var hoverLocation: CGPoint = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                if let hovered {
                    // 임의의 바탕색에서도 보이도록 검은·흰 이중 테두리. 굵은 검은 획(4pt)의 바깥 가장자리가 칸 경계에 닿도록
                    // 2pt 안쪽에 그려 뷰 가장자리 칸에서도 잘리지 않는다.
                    let outline = Path(roundedRect: hovered.rect.insetBy(dx: 2, dy: 2), cornerRadius: 3)
                    ZStack {
                        outline.stroke(.black, lineWidth: 4)
                        outline.stroke(.white, lineWidth: 1.5)
                    }
                    .allowsHitTesting(false)
                    tooltip(for: hovered.tile)
                        .offset(x: min(hoverLocation.x + 12, max(0, geometry.size.width - 280)),
                                y: min(hoverLocation.y + 12, max(0, geometry.size.height - 90)))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    let cell = cell(at: location)
                    if cell?.tile.id != hovered?.tile.id { hovered = cell }
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture { location in
                if let cell = cell(at: location), cell.tile.kind == .directory {
                    hovered = nil
                    model.treemapPath.append(cell.tile.name)
                }
            }
            .contextMenu { contextMenu }
        }
        // 정리·스캔·드릴다운·크기 변경으로 칸이 바뀌면 남은 툴팁을 지운다
        .onChange(of: layoutKey) { hovered = nil }
    }

    private func cell(at point: CGPoint) -> TreemapCell? {
        cells.first { $0.rect.width >= 1 && $0.rect.height >= 1 && $0.rect.contains(point) }
    }

    // MARK: 툴팁

    /// 나머지 칸은 실제 경로가 아니라(`path` 는 부모 폴더) 경로·태그 대신 이름("나머지 N개")과 설명·크기만 보여 준다.
    @ViewBuilder private func tooltipLines(for tile: TreemapTile) -> some View {
        if tile.kind == .remainder {
            Text(tile.name).font(.caption.bold())
            Text("이 폴더의 작은 항목을 합친 칸").font(.caption2)
            Text(ByteFormat.full(tile.size)).font(.caption)
            colorLine
        } else {
            Text(FileActions.displayPath(tile.path, home: homePath)).font(.caption.bold()).lineLimit(2)
            Text(ByteFormat.full(tile.size)).font(.caption)
            if let date = tile.modificationDate, date > .distantPast {
                Text("수정 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2)
            }
            if let tag = hovered?.tag {
                Text("\(tag.category.displayName) · \(tag.level.displayName)").font(.caption2)
            }
            colorLine
        }
    }

    /// "색 #A30D7E" 와 작은 견본
    @ViewBuilder private var colorLine: some View {
        if let color = hovered?.color {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(color.color).frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text("색 \(color.hex)").font(.caption2).monospaced()
            }
        }
    }

    /// 배경은 내용 크기에 맞추고, 너비는 280 까지만 쓴다.
    private func tooltip(for tile: TreemapTile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            tooltipLines(for: tile)
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: 280, alignment: .topLeading)
    }

    // MARK: 우클릭 메뉴

    @ViewBuilder private var contextMenu: some View {
        if let tile = hovered?.tile, tile.kind != .remainder {
            Button("Finder 에서 보기") { FileActions.revealInFinder([tile.path], isDirectory: tile.kind == .directory) }
            Button("경로 복사") { FileActions.copyPaths([tile.path]) }
            // 분류 항목 조회는 결과 세대마다 한 번 만든 색인이라 O(1)
            if let item = model.classifiedItem(at: tile.path), item.tag.isTrashCleanable {
                Button("정리…") { model.requestCleanup(items: [item]) }
            }
            if tile.kind == .directory {
                Divider()
                Button("무시 목록에 추가 (다음 스캔부터)") { model.ignore(path: tile.path) }
            }
        }
    }
}
