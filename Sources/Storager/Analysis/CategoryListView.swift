import StoragerCore
import SwiftUI

/// 카테고리 → 항목 테이블. 다중 선택 후 "선택 항목 정리".
struct CategoryListView: View {
    @Bindable var model: AnalysisModel
    let result: ScanResult
    @State private var selection = Set<ClassifiedItem.ID>()

    private var summaries: [CategorySummary] { model.store.summaries }

    private var items: [ClassifiedItem] {
        guard let category = model.selectedCategory else { return result.classification.items }
        if let tool = model.selectedTool { return result.classification.items(in: category, tool: tool) }
        return result.classification.items(in: category)
    }

    /// 도구 구분이 있는 카테고리 (테이블 "도구" 열에서 도구 없는 항목을 사이드바처럼 "기타" 로 보여 줄 곳)
    private var categoriesWithTools: Set<StoragerCore.Category> { model.store.categoriesWithTools }

    /// 사이드바 행: 카테고리, 그 아래 도구별 합계 (도구가 2개 이상인 카테고리만 펼칠 수 있다).
    private var sidebarRows: [SidebarRow] {
        summaries.map { summary in
            SidebarRow(filter: CategoryFilter(category: summary.category), title: summary.category.displayName,
                       size: summary.size,
                       children: !summary.showsToolBreakdown ? nil : summary.tools.map { tool in
                           SidebarRow(filter: CategoryFilter(category: summary.category, tool: tool.name),
                                      title: tool.name, size: tool.size, children: nil)
                       })
        }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    model.categoryFilter = nil
                } label: {
                    Label("모든 카테고리", systemImage: "square.stack")
                }
                .buttonStyle(.link)
                .disabled(model.selectedCategory == nil)
                .padding(8)
                List(sidebarRows, children: \.children, selection: $model.categoryFilter) { row in
                    HStack {
                        if row.filter.tool == nil {
                            Image(systemName: row.filter.category.symbolName)
                                .foregroundStyle(row.filter.category.color)
                            Text(row.title)
                        } else {
                            Text(row.title).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteFormat.full(row.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(row.filter)
                }
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)

            VStack(alignment: .leading) {
                let items = items
                let categoriesWithTools = categoriesWithTools
                Table(items, selection: $selection) {
                    TableColumn("경로") { item in
                        Text(FileActions.displayPath(item.path, home: result.homePath)).lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn("크기") { item in
                        Text(ByteFormat.full(item.allocatedSize)).monospacedDigit()
                    }
                    .width(90)
                    TableColumn("도구") { item in
                        Text(categoriesWithTools.contains(item.tag.category) ? ToolTotal.name(of: item) : "")
                            .lineLimit(1)
                    }
                    .width(min: 60, ideal: 100)
                    TableColumn("마지막 수정") { item in
                        Text(item.newestModification.formatted(date: .abbreviated, time: .omitted))
                    }
                    .width(110)
                    TableColumn("등급") { item in
                        Text(levelText(item.tag))
                    }
                    .width(120)
                }
                .contextMenu(forSelectionType: ClassifiedItem.ID.self) { ids in
                    // 메뉴 대상: 우클릭한 행이 선택에 들어 있으면 선택 전체, 아니면 그 행 (목록 순서대로)
                    let targets = items.filter { ids.contains($0.id) }
                    if !targets.isEmpty {
                        let paths = targets.map(\.path)
                        Button("Finder 에서 보기") { FileActions.revealInFinder(paths, isDirectory: true) }
                        Button(paths.count > 1 ? "경로 \(paths.count)개 복사" : "경로 복사") { FileActions.copyPaths(paths) }
                        // 정리는 재생성 가능 + 휴지통 항목이 하나라도 있을 때만 (나머지는 미리보기에서 거부 사유로 보인다)
                        if targets.contains(where: \.tag.isTrashCleanable) {
                            Divider()
                            Button(targets.count > 1 ? "\(targets.count)개 항목 정리…" : "정리…") {
                                model.requestCleanup(items: targets)
                            }
                        }
                    }
                }
                HStack {
                    Text("\(selection.count)개 선택").foregroundStyle(.secondary)
                    Spacer()
                    Button("선택 항목 정리…") {
                        model.requestCleanup(items: items.filter { selection.contains($0.id) })
                    }
                    .disabled(selection.isEmpty)
                }
                .padding([.horizontal, .bottom])
            }
        }
        .onChange(of: model.categoryFilter) { selection.removeAll() }
        // 정리·스캔으로 항목이 바뀌면 남아 있는 항목만 선택에 남긴다
        .onChange(of: model.store.resultGeneration) {
            // 고른 도구의 항목이 정리·스캔으로 모두 사라지면 카테고리 전체로 되돌린다
            if let category = model.selectedCategory, let tool = model.selectedTool,
               !(summaries.first { $0.category == category }?.tools.contains { $0.name == tool } ?? false) {
                model.selectedTool = nil
            }
            selection.formIntersection(items.map(\.id))
        }
    }

    /// 사이드바 한 줄 (카테고리 또는 도구).
    private struct SidebarRow: Identifiable {
        var filter: CategoryFilter
        var title: String
        var size: Int64
        var children: [SidebarRow]?
        var id: CategoryFilter { filter }
    }

    private func levelText(_ tag: CategoryTag) -> String {
        if tag.level == .regenerable, case .command = tag.method { return "재생성 가능 (v0.2)" }
        return tag.level.displayName
    }
}
