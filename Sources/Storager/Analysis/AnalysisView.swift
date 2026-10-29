import StoragerCore
import SwiftUI

struct AnalysisView: View {
    @Bindable var model: AnalysisModel
    let store: ScanStore

    var body: some View {
        NavigationSplitView {
            List(AnalysisSection.allCases, selection: Binding(
                get: { model.section },
                set: { if let section = $0 { model.section = section } }
            )) { section in
                Label(section.title, systemImage: section.symbolName).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            detail
                .toolbar {
                    ToolbarItem {
                        if store.isScanning {
                            HStack {
                                ProgressView(value: store.progress.fraction).frame(width: 120)
                                Button("취소") { store.cancelScan() }
                            }
                        } else {
                            Button {
                                store.startScan()
                            } label: {
                                Label("지금 스캔", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                }
        }
        .frame(minWidth: 720, minHeight: 480)
        // 시트가 스스로 닫히려 해도(Esc 등) 실행 중이면 `closeCleanup` 이 무시한다
        .sheet(item: Binding(get: { model.cleanupRequest }, set: { if $0 == nil { model.closeCleanup() } })) { request in
            CleanupSheet(request: request, homePath: store.homePath, isStale: model.isStale(request),
                         run: { model.runCleanup() }, replan: { model.replanCleanup() },
                         close: { model.closeCleanup() })
        }
    }

    @ViewBuilder private var detail: some View {
        if let result = store.result {
            switch model.section {
            case .treemap: TreemapView(model: model, result: result)
            case .categories: CategoryListView(model: model, result: result)
            case .largeFiles: LargeFilesView(model: model, result: result)
            case .tree: TreeView(model: model, result: result)
            }
        } else {
            ContentUnavailableView {
                Label(store.isScanning ? "스캔 중…" : "스캔 결과가 없습니다", systemImage: "internaldrive")
            } description: {
                if store.isScanning {
                    Text("\(store.progress.completed)/\(store.progress.total) 디렉터리 완료")
                } else {
                    Text("홈 디렉터리를 스캔하면 무엇이 공간을 차지하는지 보여 줍니다.")
                }
            } actions: {
                if !store.isScanning {
                    Button("지금 스캔") { store.startScan() }
                }
            }
        }
    }
}
