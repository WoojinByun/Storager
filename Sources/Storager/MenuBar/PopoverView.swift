import StoragerCore
import SwiftUI

/// 팝오버 버튼이 부르는 동작. AppDelegate 가 채운다.
struct PopoverActions {
    var openAnalysis: @MainActor (StoragerCore.Category?) -> Void
    var cleanup: @MainActor (StoragerCore.Category) -> Void
    var scanNow: @MainActor () -> Void
    var openSettings: @MainActor () -> Void
    /// 전체 디스크 접근 안내 창
    var openFullDiskAccess: @MainActor () -> Void
    var quit: @MainActor () -> Void

    /// 창을 여는 동작 전에 팝오버를 닫도록 감싼다.
    mutating func wrap(before close: @escaping @MainActor () -> Void) {
        let openAnalysis = openAnalysis, cleanup = cleanup, openSettings = openSettings
        let openFullDiskAccess = openFullDiskAccess
        self.openAnalysis = { close(); openAnalysis($0) }
        self.cleanup = { close(); cleanup($0) }
        self.openSettings = { close(); openSettings() }
        self.openFullDiskAccess = { close(); openFullDiskAccess() }
    }
}

struct PopoverView: View {
    let store: ScanStore
    let actions: PopoverActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            // 권한이 없거나, 허용됐어도 마지막 결과가 아직 보호 폴더를 건너뛴 결과면 보여 준다
            if !store.fullDiskAccess.isGranted || !store.skippedForPermission.isEmpty {
                permissionBanner
            }
            // 카드가 없으면(첫 스캔 전 등) 빈 목록과 구분선 하나를 감춘다
            if !store.summaries.isEmpty {
                categoryList
                Divider()
            }
            footer
        }
        .padding(14)
        .frame(width: 420)
    }

    // MARK: 상단: 볼륨 막대

    @ViewBuilder private var header: some View {
        if let volume = store.volume {
            VolumeBar(volume: volume)
            HStack {
                // Finder 의 "사용 가능" 과 같은 값(퍼지 가능 공간 포함)
                Text("사용 가능 \(ByteFormat.full(volume.availableForImportantUsage)) / \(ByteFormat.full(volume.total))")
                    .font(.headline)
                Spacer()
            }
        }
        Group {
            if store.isScanning {
                if store.progress.total == 0 {
                    // 1단계 디렉터리 수를 세기 전에는 fraction 이 1 이라 막대가 가득 차 보이므로 진행률 없이 돈다
                    ProgressView { Text("스캔 중…") }
                } else {
                    ProgressView(value: store.progress.fraction) {
                        Text("스캔 중… \(store.progress.completed)/\(store.progress.total)")
                    }
                }
            } else if let last = store.lastCompletedAt {
                // 팝오버가 떠 있는 동안에도 "n분 전" 이 낡지 않도록 1분마다 다시 그린다
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text("마지막 스캔 \(last.formatted(.relative(presentation: .named)))")
                }
            } else {
                Text("아직 스캔하지 않았습니다")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        if let error = store.lastError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        if !store.isPersistent {
            Text("추세 저장 불가: 데이터베이스를 열 수 없습니다(디스크 공간 부족일 수 있음)")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    // MARK: 중단: 권한 배너

    /// 전체 디스크 접근 권한이 없을 때 카드 위 한 줄. 허용된 뒤에는 다시 스캔해 건너뛴 곳이 없어질 때까지 남긴다.
    private var permissionBanner: some View {
        let skipped = store.skippedForPermission
        let granted = store.fullDiskAccess.isGranted
        return HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.shield" : "lock.shield")
                .foregroundStyle(granted ? .green : .orange)
            if granted {
                Text(store.isScanning ? "권한이 허용되었습니다 · 다시 스캔하는 중…" : "권한이 허용되었습니다 · 다시 스캔하면 반영됩니다")
            } else {
                Text(skipped.isEmpty ? "전체 디스크 접근 권한 없음" : "권한이 없어 \(skipped.count)곳을 건너뜀")
            }
            Spacer()
            if !granted {
                Button("권한 허용…") { actions.openFullDiskAccess() }
                    .buttonStyle(.borderless)
            } else if !store.isScanning {
                Button("지금 스캔") { actions.scanNow() }
                    .buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .help(skipped.isEmpty
            ? "전체 디스크 접근을 허용하지 않으면 데스크탑·문서·다운로드·iCloud Drive·사진 보관함 등은 건너뜁니다."
            : "건너뛴 폴더:\n" + skipped.map { FileActions.displayPath($0, home: store.homePath) }.joined(separator: "\n"))
    }

    // MARK: 중단: 카테고리 카드

    private var categoryList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                let baselineDays = store.baseline.map { CategoryCard.baselineDays(since: $0.at) }
                ForEach(store.summaries) { summary in
                    CategoryCard(summary: summary, baselineDays: baselineDays,
                                 open: { actions.openAnalysis(summary.category) },
                                 cleanup: { actions.cleanup(summary.category) })
                }
            }
        }
        .frame(maxHeight: 360)
    }

    // MARK: 하단

    private var footer: some View {
        HStack {
            Button("지금 스캔") { actions.scanNow() }
                .disabled(store.isScanning)
            Button("분석 윈도우 열기") { actions.openAnalysis(nil) }
            Spacer()
            Button {
                actions.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("설정")
            Button {
                actions.quit()
            } label: {
                Image(systemName: "power")
            }
            .help("종료")
        }
        .buttonStyle(.borderless)
    }
}

/// 사용 / 퍼지 가능 / 여유 3색 막대.
struct VolumeBar: View {
    let volume: VolumeStats

    var body: some View {
        GeometryReader { geometry in
            let total = max(Double(volume.total), 1)
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor)
                    .frame(width: geometry.size.width * Double(volume.used) / total)
                Rectangle().fill(Color.accentColor.opacity(0.35))
                    .frame(width: geometry.size.width * Double(volume.purgeable) / total)
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        // 헤더의 "사용 가능"(퍼지 가능 포함)과 구분해, 지금 바로 쓸 수 있는 공간은 "즉시 여유" 라고 쓴다
        .help("사용 \(ByteFormat.full(volume.used)) · 퍼지 가능 \(ByteFormat.full(volume.purgeable)) · 즉시 여유 \(ByteFormat.full(volume.available))")
    }
}

struct CategoryCard: View {
    let summary: CategorySummary
    /// 변화량 기준 스냅샷이 며칠 전인지. 기준이 없으면 nil (그때는 변화량도 없다)
    let baselineDays: Int?
    let open: () -> Void
    let cleanup: () -> Void

    /// 크기·변화량 열 폭. 모든 카드가 같아서 크기 숫자의 오른쪽 끝이 세로로 맞는다.
    static let sizeColumnWidth: CGFloat = 76
    /// 맨 오른쪽 동작 열 폭. 가장 넓은 "v0.2 에서 지원" 이 들어가며, 모든 카드가 비워 두더라도 잡는다.
    static let actionColumnWidth: CGFloat = 72

    /// 카드 높이를 모두 같게 하려고 두 번째 줄(도구 내역·변화량)은 비어 있어도 한 줄 높이를 잡는다.
    private static let blankText = " "

    var body: some View {
        let tools = Self.visibleTools(summary.tools)
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: summary.category.symbolName)
                        .foregroundStyle(summary.category.color)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.category.displayName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if tools.count >= CategorySummary.toolBreakdownMinimum {
                            // 들어가는 만큼만 도구를 보여 준다(3 → 2 → 1개). 항목 중간에서 잘리지 않게 한다.
                            ViewThatFits(in: .horizontal) {
                                Text(Self.toolLine(tools, limit: 3)).fixedSize()
                                Text(Self.toolLine(tools, limit: 2)).fixedSize()
                                // 한 개도 안 들어가면 마지막 후보라 그대로 잘린다
                                Text(Self.toolLine(tools, limit: 1)).lineLimit(1)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(Self.toolLine(tools, limit: tools.count))
                        } else {
                            blankLine
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ByteFormat.full(summary.size))
                            .monospacedDigit()
                            .lineLimit(1)
                        if let delta = summary.delta, delta != 0 {
                            Label(ByteFormat.delta(delta), systemImage: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption)
                                .monospacedDigit()
                                .lineLimit(1)
                                .foregroundStyle(delta > 0 ? .red : .green)
                                .help("\(baselineDays ?? 7)일 전 대비")
                        } else {
                            blankLine
                        }
                    }
                    .frame(width: Self.sizeColumnWidth, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Group {
                switch summary.cleanup {
                case .trash(let reclaimable, let needsCommand):
                    Button("정리", action: cleanup)
                        .controlSize(.small)
                        .help(Self.cleanupHelp(reclaimable: reclaimable, needsCommand: needsCommand))
                case .nextVersion:
                    Text("v0.2 에서 지원")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .none:
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .frame(width: Self.actionColumnWidth, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    /// 빈 두 번째 줄. 도구 줄·변화량과 같은 글꼴이라 높이가 같다.
    private var blankLine: some View {
        Text(Self.blankText)
            .font(.caption)
            .accessibilityHidden(true)
    }

    /// 0 바이트 도구는 줄에서 뺀다 (카테고리 합계에는 영향 없음).
    /// `CategorySummary.tools` 자체는 분석 윈도우 사이드바·트리도 쓰므로 그대로 두고 여기서만 거른다.
    static func visibleTools(_ tools: [ToolTotal]) -> [ToolTotal] {
        tools.filter { $0.size > 0 }
    }

    /// 기준 스냅샷이 몇 날 전인지(내림, 최소 1). 기준은 24시간보다 오래된 스냅샷이라 보통 1 이상이다.
    static func baselineDays(since date: Date, now: Date = Date()) -> Int {
        max(1, Int(now.timeIntervalSince(date) / 86_400))
    }

    /// 크기 아래 한 줄: 상위 도구 `limit` 개 ("pnpm 12 GB · npm 3.1 GB").
    static func toolLine(_ tools: [ToolTotal], limit: Int) -> String {
        tools.prefix(limit).map { "\($0.name) \(ByteFormat.full($0.size))" }.joined(separator: " · ")
    }

    /// "정리" 버튼 툴팁. 같은 카테고리에 도구 명령이 필요한 항목이 있으면 이 버튼으로는 정리하지 않는다고 알린다.
    static func cleanupHelp(reclaimable: Int64, needsCommand: Int64) -> String {
        var text = "정리 가능 \(ByteFormat.full(reclaimable))"
        if needsCommand > 0 {
            text += "\n일부 항목(\(ByteFormat.full(needsCommand)))은 명령으로 정리해야 해서 v0.2 에서 지원 예정"
        }
        return text
    }
}
