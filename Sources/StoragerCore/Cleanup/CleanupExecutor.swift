import Darwin
import Foundation

/// 휴지통 이동. 테스트에서는 가짜로 바꾼다.
public protocol Trasher: Sendable {
    func trash(path: String) throws
}

public struct FileManagerTrasher: Trasher {
    public init() {}

    public func trash(path: String) throws {
        // 정리 대상은 늘 디렉터리다(`CleanupExecutor.refusal` 이 확인했다). 종류를 넘겨 URL 이 다시 stat 하지 않게 한다
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path, isDirectory: true), resultingItemURL: nil)
    }
}

public struct CleanupOutcome: Sendable, Equatable {
    public var item: ClassifiedItem
    public var succeeded: Bool
    public var message: String?
}

/// 계획을 실행한다. 항목 하나가 실패해도 나머지는 계속하고, 모든 결과를 cleanup_log 에 남긴다.
/// 기록의 회수량(`reclaimedBytes`)은 계획 시점의 할당 크기다. 휴지통으로 옮긴 것이라 휴지통을 비우기 전까지 디스크 공간은 실제로 늘지 않는다.
public struct CleanupExecutor: Sendable {
    let trasher: any Trasher
    let store: SnapshotStore?
    /// 실행 직전 권한 상태로 건너뛰는 위치. 그 안의 항목은 lstat 하지 않고(동의 창을 띄운다) 실패로 남긴다.
    /// 호출자(`AnalysisModel.runCleanup`)가 권한이 바뀐 계획은 이미 막지만 한 겹 더 막는다. nil 이면 확인하지 않는다
    let permissionSkip: PermissionSkip?

    public init(trasher: any Trasher = FileManagerTrasher(), store: SnapshotStore?,
                permissionSkip: PermissionSkip? = nil) {
        self.trasher = trasher
        self.store = store
        self.permissionSkip = permissionSkip
    }

    public func execute(_ plan: CleanupPlan, now: Date = Date()) -> [CleanupOutcome] {
        plan.accepted.map { item in
            let outcome: CleanupOutcome
            if let permissionSkip, permissionSkip.covers(item.path) {
                outcome = CleanupOutcome(item: item, succeeded: false,
                                         message: CleanupRejection.permissionRequired.message)
            } else if let refusal = Self.refusal(for: item.path) {
                outcome = CleanupOutcome(item: item, succeeded: false, message: refusal)
            } else {
                do {
                    try trasher.trash(path: item.path)
                    outcome = CleanupOutcome(item: item, succeeded: true, message: nil)
                } catch {
                    outcome = CleanupOutcome(item: item, succeeded: false, message: error.localizedDescription)
                }
            }
            do {
                try store?.recordCleanup(CleanupLogEntry(
                    at: now, path: item.path, category: item.tag.category, method: "trash",
                    reclaimedBytes: outcome.succeeded ? item.allocatedSize : 0,
                    succeeded: outcome.succeeded, message: outcome.message))
            } catch {
                Log.cleanup.error("정리 기록 저장 실패: \(String(describing: error), privacy: .public)")
            }
            return outcome
        }
    }

    /// 휴지통으로 옮기기 직전에 경로를 다시 확인한다. 계획 뒤에 경로나 중간 디렉터리가 심볼릭 링크로 바뀌었거나,
    /// 표기(대소문자 등)가 실제 경로와 다르면 옮기지 않고 그 이유를 돌려준다. 괜찮으면 nil.
    static func refusal(for path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return CleanupRejection.missing.message }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: break
        case S_IFLNK: return CleanupRejection.symbolicLink.message
        default: return CleanupRejection.missing.message
        }
        guard PathUtil.resolve(path) == path else {
            return "경로가 계획 때와 다릅니다(중간 폴더가 링크이거나 표기가 다름). 다시 스캔한 뒤 정리하세요"
        }
        return nil
    }
}
