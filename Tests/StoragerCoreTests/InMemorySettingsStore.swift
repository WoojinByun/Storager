import Foundation
@testable import StoragerCore

/// 테스트용 메모리 저장소. 실제 환경설정 파일을 건드리지 않는다.
final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? {
        lock.withLock { values[key] }
    }

    func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
    }
}
