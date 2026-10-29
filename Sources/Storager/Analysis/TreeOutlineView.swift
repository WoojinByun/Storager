import AppKit
import StoragerCore
import SwiftUI

/// 트리 뷰의 펼침·선택 상태(경로 기준). `AnalysisModel` 이 들고 있어 섹션을 바꿨다 돌아와도 남는다.
/// 새 결과(스캔·정리)로 바뀌면 아직 있는 경로만 되살린다.
@MainActor
final class TreeViewState {
    /// 펼친 디렉터리 경로 (최대 `TreeExpansionMemory.defaultLimit` 개, 넘치면 오래 쓰지 않은 것부터 잊는다). 접힌 부모 아래의 펼친 자식도 남겨 두었다가
    /// 부모를 다시 펼치면 함께 펼친다.
    var expansion = TreeExpansionMemory()
    /// 선택한 줄의 `TreeEntry.id`
    var selectedIDs: Set<String> = []
    /// 처음 보여 줄 때 홈을 펼쳐 두었는지
    var didExpandHomeOnce = false
}

/// 분석 윈도우의 "트리" 섹션. 펼친 행의 자식만 만드는 NSOutlineView 를 감싼다.
struct TreeView: View {
    let model: AnalysisModel
    let result: ScanResult

    var body: some View {
        // resultGeneration 을 읽어 스캔·정리로 결과가 바뀌면 다시 그려지고, 그때 펼침·선택을 되살려 다시 읽는다
        TreeOutlineView(model: model, generation: model.store.resultGeneration)
    }
}

/// NSOutlineView 기반 디스클로저 트리.
///
/// SwiftUI `List(children:)`·`OutlineGroup`·계층 `Table` 대신 NSOutlineView 를 쓴다:
/// - 데이터 소스가 펼친 행의 자식만 묻는다(lazy). SwiftUI 쪽은 행 전체를 값으로 diff 해 자식이 수만 개면 펼칠 때 멈춘다.
/// - 펼침 상태를 코드로 읽고 바꿀 수 있어(`expandItem`·`isItemExpanded`) 새 결과에서 경로 기준으로 되살릴 수 있다.
/// - 우클릭한 행(`clickedRow`)과 선택을 구분할 수 있어 카테고리 테이블과 같은 메뉴 대상 규칙을 그대로 쓴다.
struct TreeOutlineView: NSViewRepresentable {
    let model: AnalysisModel
    let generation: Int

    func makeCoordinator() -> TreeOutlineCoordinator {
        TreeOutlineCoordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.allowsMultipleSelection = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autosaveExpandedItems = false
        for column in TreeColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            if column != .name { tableColumn.resizingMask = .userResizingMask }
            tableColumn.headerCell.alignment = column.alignment
            outline.addTableColumn(tableColumn)
            if column == .name { outline.outlineTableColumn = tableColumn }
        }
        let coordinator = context.coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(TreeOutlineCoordinator.toggleClickedRow(_:))
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu
        coordinator.outlineView = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        coordinator.reload()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if context.coordinator.generation != generation {
            context.coordinator.reload()
        }
    }
}

enum TreeColumn: String, CaseIterable {
    case name, size, share, count, category, tool

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("tree." + rawValue) }

    var title: String {
        switch self {
        case .name: "이름"
        case .size: "크기"
        case .share: "비율"
        case .count: "파일 수"
        case .category: "카테고리"
        case .tool: "도구"
        }
    }

    var width: CGFloat {
        switch self {
        case .name: 360
        case .size: 90
        case .share: 110
        case .count: 80
        case .category: 150
        case .tool: 120
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: 160
        case .share: 50
        default: 60
        }
    }

    var alignment: NSTextAlignment {
        switch self {
        case .size, .count: .right
        default: .left
        }
    }
}

/// NSOutlineView 의 한 줄. 디렉터리 줄은 자식 줄을 만들 때 쓰려고 노드를 들고 있다(결과 트리와 배열 저장소를 공유, CoW).
@MainActor
final class TreeItem: NSObject {
    let entry: TreeEntry
    /// 최상위 줄(홈·추가 루트)인지. 무시 목록 추가 대상에서 뺀다.
    let isRoot: Bool
    fileprivate let node: DirectoryNode?
    fileprivate var children: [TreeItem]?
    /// 이름 칸 견본의 경로 해시 색. 줄마다 처음 그릴 때 한 번 계산한다.
    private(set) lazy var color = PathColor(entry: entry)

    init(entry: TreeEntry, node: DirectoryNode?, isRoot: Bool = false) {
        self.entry = entry
        self.node = node
        self.isRoot = isRoot
    }

    var isExpandable: Bool {
        guard let node else { return false }
        return !node.children.isEmpty || !node.largeFiles.isEmpty || node.directFileCount > 0 || node.directAllocatedSize > 0
    }
}

@MainActor
final class TreeOutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let model: AnalysisModel
    weak var outlineView: NSOutlineView?
    /// 지금 보여 주는 결과 세대
    private(set) var generation = -1
    private var roots: [TreeItem] = []
    /// 자식을 만든 줄들 (id → 줄). 펼침·선택을 경로로 되살릴 때 쓴다.
    private var itemsByID: [String: TreeItem] = [:]
    /// 코드로 펼치고 선택하는 동안 상태 기록을 막는다
    private var isRestoring = false
    /// 도구 구분이 있는 카테고리 (카테고리 테이블과 같은 규칙). 결과 세대마다 `reload()` 에서 한 번 만든다.
    private var categoriesWithTools: Set<StoragerCore.Category> = []

    private var state: TreeViewState { model.treeState }
    private var homePath: String { model.store.homePath }

    init(model: AnalysisModel) {
        self.model = model
    }

    // MARK: 새 결과 반영

    /// 결과에서 최상위 줄을 다시 만들고, 남아 있는 경로의 펼침·선택을 되살린다. 사라진 경로는 상태에서 뺀다.
    func reload() {
        guard let outline = outlineView else { return }
        generation = model.store.resultGeneration
        categoriesWithTools = model.store.categoriesWithTools
        // 이전 줄들은 reloadData() 가 끝날 때까지 살려 둔다 (NSOutlineView 가 그 사이 옛 항목을 참조할 수 있다)
        let previous = roots
        itemsByID = [:]
        roots = []
        if let result = model.store.result {
            roots.append(makeRoot(result.home, path: result.homePath, name: "홈"))
            for extra in result.extraRoots {
                roots.append(makeRoot(extra.root, path: extra.rootPath, name: FileActions.displayPath(extra.rootPath, home: homePath)))
            }
            if !state.didExpandHomeOnce {
                state.didExpandHomeOnce = true
                state.expansion.remember(result.homePath)
            }
            state.expansion.retainOnly(underRoots: roots.map(\.entry.path))
        }

        isRestoring = true
        defer { isRestoring = false }
        withExtendedLifetime(previous) { outline.reloadData() }
        // 최상위부터 펼치면 outlineViewItemDidExpand 가 기억한 자식들을 이어서 펼치고, 사라진 자식은 그 자리에서 잊는다
        for root in roots where state.expansion.contains(root.entry.path) {
            outline.expandItem(root)
        }

        let rows = IndexSet(state.selectedIDs.compactMap { itemsByID[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        state.selectedIDs = Set(rows.compactMap { (outline.item(atRow: $0) as? TreeItem)?.entry.id })
    }

    private func makeRoot(_ node: DirectoryNode, path: String, name: String) -> TreeItem {
        let item = TreeItem(entry: TreeEntry.root(node, path: path, name: name), node: node, isRoot: true)
        itemsByID[item.entry.id] = item
        return item
    }

    private func children(of item: TreeItem) -> [TreeItem] {
        if let children = item.children { return children }
        guard let node = item.node else { return [] }
        let nodesByName = Dictionary(node.children.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let children = TreeEntry.children(of: node, path: item.entry.path).map { entry in
            TreeItem(entry: entry, node: entry.kind == .directory ? nodesByName[entry.name] : nil)
        }
        for child in children { itemsByID[child.entry.id] = child }
        item.children = children
        return children
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? TreeItem else { return roots.count }
        return children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? TreeItem else { return roots[index] }
        return children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TreeItem)?.isExpandable ?? false
    }

    // MARK: 펼침·선택 기록

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let outline = outlineView, let item = notification.userInfo?["NSObject"] as? TreeItem else { return }
        // Option-클릭이면 폴더마다 이 알림이 온다. 여기서 하는 일은 이 폴더의 자식 수에만 비례한다(전체 기억을 훑지 않는다).
        // 기억은 한도(TreeExpansionMemory.defaultLimit)를 넘으면 오래 쓰지 않은 것부터 잊어, 다음 결과에서 다시 펼치는 폴더 수도 그만큼으로 묶인다.
        state.expansion.remember(item.entry.path)
        let children = children(of: item)
        // 이 폴더 아래 기억했지만 새 결과에 없는 자식(과 그 아래)을 잊는다
        state.expansion.pruneChildren(of: item.entry.path) { itemsByID[$0] != nil }
        // 전에 펼쳐 두었던 자식은 함께 펼친다 (새 결과로 줄을 다시 만든 뒤에도 같은 모양으로)
        for child in children where child.isExpandable && state.expansion.contains(child.entry.path) {
            if !outline.isItemExpanded(child) { outline.expandItem(child) }
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRestoring, let item = notification.userInfo?["NSObject"] as? TreeItem else { return }
        // 자식의 펼침은 남겨 둔다 (다시 펼치면 함께 펼친다). Option-클릭으로 접으면 자식마다 이 알림이 와서 함께 지워진다.
        state.expansion.forget(item.entry.path)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoring, let outline = outlineView else { return }
        state.selectedIDs = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? TreeItem)?.entry.id })
    }

    @objc func toggleClickedRow(_ sender: Any?) {
        guard let outline = outlineView, outline.clickedRow >= 0,
              let item = outline.item(atRow: outline.clickedRow) as? TreeItem, item.isExpandable else { return }
        if outline.isItemExpanded(item) {
            outline.collapseItem(item)
        } else {
            outline.expandItem(item)
        }
    }

    // MARK: 셀

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let tableColumn, let column = TreeColumn(rawValue: String(tableColumn.identifier.rawValue.dropFirst(5))),
              let item = item as? TreeItem else { return nil }
        let entry = item.entry
        switch column {
        case .name:
            let cell = reuse(outlineView, column, make: TreeNameCell.init)
            cell.configure(entry: entry, color: item.color, toolTip: entry.hasRealPath ? FileActions.displayPath(entry.path, home: homePath) : nil)
            return cell
        case .size:
            let cell = reuse(outlineView, column) { TreeTextCell(alignment: .right) }
            cell.set(ByteFormat.full(entry.size), secondary: entry.kind == .remainder)
            return cell
        case .share:
            let cell = reuse(outlineView, column, make: TreeShareCell.init)
            cell.configure(share: item.isRoot ? nil : entry.share)
            return cell
        case .count:
            let cell = reuse(outlineView, column) { TreeTextCell(alignment: .right) }
            cell.set(entry.fileCount.map { $0.formatted() } ?? "", secondary: true)
            return cell
        case .category:
            let cell = reuse(outlineView, column, make: TreeCategoryCell.init)
            cell.configure(tag: entry.hasRealPath ? model.classifiedItem(at: entry.path)?.tag : nil)
            return cell
        case .tool:
            // 정확히 그 경로가 분류 항목이고 그 카테고리에 도구 구분이 있을 때만 (카테고리 테이블과 같은 규칙: 없으면 "기타")
            let cell = reuse(outlineView, column) { TreeTextCell(alignment: .left) }
            let classified = entry.hasRealPath ? model.classifiedItem(at: entry.path) : nil
            let tool = classified.flatMap { categoriesWithTools.contains($0.tag.category) ? ToolTotal.name(of: $0) : nil }
            cell.set(tool ?? "", secondary: false)
            return cell
        }
    }

    private func reuse<Cell: NSView>(_ outline: NSOutlineView, _ column: TreeColumn, make: () -> Cell) -> Cell {
        if let cell = outline.makeView(withIdentifier: column.identifier, owner: nil) as? Cell { return cell }
        let cell = make()
        cell.identifier = column.identifier
        return cell
    }

    // MARK: 우클릭 메뉴

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let outline = outlineView else { return }
        // 우클릭한 행이 선택에 들어 있으면 선택 전체, 아니면 그 행 (카테고리 테이블과 같은 규칙)
        let rows = TreeEntry.menuTargetRows(clickedRow: outline.clickedRow, selectedRows: outline.selectedRowIndexes)
        // 나머지 파일 줄은 실제 경로가 아니라 파일 동작에서 빠진다
        let targets = rows.compactMap { outline.item(atRow: $0) as? TreeItem }.filter(\.entry.hasRealPath)
        // "트리맵에서 보기" 는 우클릭한 줄 하나 기준이다. 나머지 파일 줄이면 그 줄이 속한 폴더로 간다
        let clicked = outline.item(atRow: outline.clickedRow) as? TreeItem
        let treemapComponents = clicked?.entry.treemapComponents(homePath: homePath)
        guard !targets.isEmpty || treemapComponents != nil else { return }

        if !targets.isEmpty {
            let paths = targets.map(\.entry.path)
            let reveal = targets.map { (path: $0.entry.path, isDirectory: $0.entry.kind == .directory) }
            menu.addItem(menuItem("Finder 에서 보기") { FileActions.revealInFinder(reveal) })
            menu.addItem(menuItem(paths.count > 1 ? "경로 \(paths.count)개 복사" : "경로 복사") { FileActions.copyPaths(paths) })
        }
        // 정리는 트리맵과 같은 규칙: 정확히 그 경로가 분류 항목이고 휴지통 정리 가능한 것만, 기존 미리보기 시트로
        let cleanable = targets.compactMap { model.classifiedItem(at: $0.entry.path) }.filter(\.tag.isTrashCleanable)
        if !cleanable.isEmpty {
            let model = model
            menu.addItem(menuItem(cleanable.count > 1 ? "\(cleanable.count)개 항목 정리…" : "정리…") {
                model.requestCleanup(items: cleanable)
            })
        }

        let ignorable = targets.filter { $0.entry.kind == .directory && !$0.isRoot }.map(\.entry.path)
        if !menu.items.isEmpty, treemapComponents != nil || !ignorable.isEmpty { menu.addItem(.separator()) }
        if let treemapComponents {
            let model = model
            menu.addItem(menuItem("트리맵에서 보기") { model.showInTreemap(components: treemapComponents) })
        }
        if !ignorable.isEmpty {
            let model = model
            let title = ignorable.count > 1 ? "\(ignorable.count)개 폴더를 무시 목록에 추가 (다음 스캔부터)" : "무시 목록에 추가 (다음 스캔부터)"
            menu.addItem(menuItem(title) {
                for path in ignorable { model.ignore(path: path) }
            })
        }
    }

    /// 클로저를 실행하는 메뉴 항목. 클로저는 `representedObject` 에 담아 `performMenuAction` 이 꺼내 부른다.
    private func menuItem(_ title: String, handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuAction(handler)
        return item
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.handler()
    }
}

@MainActor
private final class MenuAction {
    let handler: @MainActor () -> Void

    init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }
}

// MARK: 셀 뷰

@MainActor private func makeLabel(alignment: NSTextAlignment = .left) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.alignment = alignment
    label.lineBreakMode = .byTruncatingMiddle
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

private final class TreeNameCell: NSTableCellView {
    private static let folder = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "폴더")
    private static let file = NSImage(systemSymbolName: "doc", accessibilityDescription: "파일")
    private static let rest = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "나머지 파일 묶음")

    /// 경로 해시 색 견본 (트리맵 칸과 같은 색). VoiceOver 는 건너뛴다.
    private let swatch = SwatchView()

    init() {
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        swatch.translatesAutoresizingMaskIntoConstraints = false
        let label = makeLabel()
        addSubview(icon)
        addSubview(swatch)
        addSubview(label)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            swatch.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 10),
            swatch.heightAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(entry: TreeEntry, color: PathColor, toolTip: String?) {
        swatch.color = color
        switch entry.kind {
        case .directory:
            imageView?.image = Self.folder
            imageView?.contentTintColor = .systemBlue
        case .file:
            imageView?.image = Self.file
            imageView?.contentTintColor = .secondaryLabelColor
        case .remainder:
            imageView?.image = Self.rest
            imageView?.contentTintColor = .tertiaryLabelColor
        }
        textField?.stringValue = entry.name
        textField?.textColor = entry.kind == .remainder ? .secondaryLabelColor : .labelColor
        self.toolTip = toolTip
    }
}

private final class TreeTextCell: NSTableCellView {
    init(alignment: NSTextAlignment) {
        super.init(frame: .zero)
        let label = makeLabel(alignment: alignment)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(_ text: String, secondary: Bool) {
        textField?.stringValue = text
        textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
    }
}

private final class TreeShareCell: NSTableCellView {
    private let bar = ShareBarView()

    init() {
        super.init(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 막대와 VoiceOver 값. nil(최상위 줄)이면 막대를 그리지 않고 접근성 요소에서도 뺀다.
    func configure(share: Double?) {
        bar.fraction = share
        let text = share?.formatted(.percent.precision(.fractionLength(1)))
        toolTip = text
        setAccessibilityElement(share != nil)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("상위 폴더 대비 비율")
        setAccessibilityValue(share.map { $0 * 100 })
        setAccessibilityValueDescription(text)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
    }
}

/// 부모 대비 비율 막대. nil 이면 그리지 않는다(최상위 줄).
private final class ShareBarView: NSView {
    var fraction: Double? {
        didSet { if fraction != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let fraction else { return }
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()
        guard fraction > 0 else { return }
        // 아주 작은 비율도 보이도록 최소 높이만큼은 그린다
        var filled = bounds
        filled.size.width = max(bounds.height, bounds.width * fraction)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

private final class TreeCategoryCell: NSTableCellView {
    private let dot = DotView()

    init() {
        super.init(frame: .zero)
        dot.translatesAutoresizingMaskIntoConstraints = false
        let label = makeLabel()
        label.lineBreakMode = .byTruncatingTail
        addSubview(dot)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(tag: CategoryTag?) {
        dot.isHidden = tag == nil
        dot.color = tag.map { NSColor($0.category.color) }
        textField?.stringValue = tag?.category.displayName ?? ""
        toolTip = tag.map { "\($0.category.displayName) · \($0.level.displayName)" }
    }
}

/// 경로 해시 색 견본(둥근 사각형). 장식이라 접근성 요소가 아니다.
private final class SwatchView: NSView {
    var color: PathColor? {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
        color.nsColor.setFill()
        path.fill()
        // 바탕과 비슷한 색에서도 견본 경계가 보이도록 테두리
        NSColor.tertiaryLabelColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// 카테고리 점. `draw(_:)` 에서 NSColor 로 칠해 라이트·다크 전환 때 현재 모양새의 색으로 다시 그린다
/// (CGColor 를 한 번 풀어 두면 모양새가 바뀌어도 그대로 남는다).
private final class DotView: NSView {
    var color: NSColor? {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
