import StoragerCore
import SwiftUI

/// 정리 미리보기 → 실행 → 결과.
struct CleanupSheet: View {
    let request: CleanupRequest
    /// 표시 경로를 `~/…` 로 줄일 홈 (`ScanStore.homePath`, 스캔 결과와 같은 표기)
    let homePath: String
    /// 계획을 만든 뒤 결과가 바뀌었다 (실행 불가, "다시 계획" 필요)
    let isStale: Bool
    let run: () -> Void
    let replan: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.outcomes == nil ? "정리 미리보기" : "정리 결과").font(.title2.bold())
            if let outcomes = request.outcomes {
                results(outcomes)
            } else {
                preview
            }
            HStack {
                Spacer()
                if request.outcomes == nil {
                    // 실행 중에는 취소·Esc 로 닫지 않는다 (결과를 잃지 않도록)
                    Button("취소", role: .cancel, action: close)
                        .keyboardShortcut(.cancelAction)
                        .disabled(request.isRunning)
                    if isStale {
                        Button("다시 계획", action: replan)
                    }
                    Button("휴지통으로 이동", action: run)
                        .disabled(request.plan.isEmpty || request.isRunning || isStale)
                } else {
                    Button("닫기", action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
        .interactiveDismissDisabled(request.isRunning)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isStale {
                Label("스캔 결과나 권한 상태가 바뀌었습니다. 다시 계획하세요.", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
            ForEach(request.plan.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            List {
                if !request.plan.accepted.isEmpty {
                    Section("휴지통으로 이동") {
                        ForEach(request.plan.accepted) { item in
                            row(item.path, detail: ByteFormat.full(item.allocatedSize))
                        }
                    }
                }
                if !request.plan.rejected.isEmpty {
                    Section("제외") {
                        ForEach(request.plan.rejected, id: \.item.path) { rejected in
                            row(rejected.item.path, detail: rejected.reason.message).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("예상 회수 \(ByteFormat.full(request.plan.reclaimableBytes)). 휴지통을 비워야 디스크 공간이 실제로 회수됩니다.")
                .font(.callout)
            if request.isRunning {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func results(_ outcomes: [CleanupOutcome]) -> some View {
        List(outcomes, id: \.item.path) { outcome in
            HStack {
                Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(outcome.succeeded ? .green : .red)
                row(outcome.item.path, detail: outcome.message ?? ByteFormat.full(outcome.item.allocatedSize))
            }
        }
    }

    private func row(_ path: String, detail: String) -> some View {
        HStack {
            Text(FileActions.displayPath(path, home: homePath)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(detail).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
