import Darwin
import Foundation

/// 테스트마다 임시 디렉터리에 고정 파일 트리를 만든다. deinit 에서 지운다.
final class TempTree {
    let root: URL
    var path: String { root.path }

    init() throws {
        // 스캐너가 루트를 realpath 로 정규화하므로 /var → /private/var 처럼 미리 풀어 둔다 (결과 경로와 바로 비교하려고)
        let temporary = NSTemporaryDirectory()
        let resolved = realpath(temporary, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        let base = URL(fileURLWithPath: resolved ?? temporary, isDirectory: true)
        root = base.appendingPathComponent("StoragerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // chmod 000 으로 만든 디렉터리도 지울 수 있게 권한을 되돌린다
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in enumerator {
                chmod(root.appendingPathComponent(relative).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// `relative` 디렉터리를 만든다 (중간 디렉터리 포함).
    @discardableResult
    func dir(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `relative` 에 `bytes` 바이트 파일을 만든다. 0 이 아닌 값으로 채워 실제 블록이 할당되게 한다.
    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    func hardLink(_ relative: String, to target: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: root.appendingPathComponent(target), to: url)
    }

    func symlink(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(relative).path,
                                                   withDestinationPath: destination)
    }

    /// lstat(2) 의 inode 번호 (하드링크 귀속 맵의 키)
    func fileID(_ relative: String) -> UInt64 {
        var info = stat()
        guard lstat(root.appendingPathComponent(relative).path, &info) == 0 else { return 0 }
        return UInt64(info.st_ino)
    }

    /// stat(2) 기준 실제 할당 바이트 (st_blocks × 512). 스캐너 결과의 기대값으로 쓴다.
    func allocated(_ relative: String) -> Int64 {
        var info = stat()
        guard lstat(root.appendingPathComponent(relative).path, &info) == 0 else { return -1 }
        return Int64(info.st_blocks) * 512
    }
}
