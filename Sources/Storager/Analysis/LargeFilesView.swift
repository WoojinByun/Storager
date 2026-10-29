import StoragerCore
import SwiftUI

/// 리프 상위 200개. 목록은 `AnalysisModel.largeFiles()` 가 결과 세대마다 한 번 계산해 보관한다.
struct LargeFilesView: View {
    let model: AnalysisModel
    let result: ScanResult
    @State private var selection = Set<LargeFileEntry.ID>()

    var body: some View {
        let files = model.largeFiles()
        Table(files, selection: $selection) {
            TableColumn("경로") { file in
                Text(FileActions.displayPath(file.path, home: result.homePath)).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("크기") { file in
                Text(ByteFormat.full(file.allocatedSize)).monospacedDigit()
            }
            .width(90)
            TableColumn("마지막 수정") { file in
                Text(file.modificationDate.formatted(date: .abbreviated, time: .omitted))
            }
            .width(110)
        }
        .contextMenu(forSelectionType: LargeFileEntry.ID.self) { ids in
            // 메뉴 대상: 우클릭한 행이 선택에 들어 있으면 선택 전체, 아니면 그 행 (목록 순서대로)
            let paths = files.map(\.path).filter(ids.contains)
            if !paths.isEmpty {
                Button("Finder 에서 보기") { FileActions.revealInFinder(paths, isDirectory: false) }
                Button(paths.count > 1 ? "경로 \(paths.count)개 복사" : "경로 복사") { FileActions.copyPaths(paths) }
            }
        }
    }
}
