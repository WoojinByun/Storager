import Darwin
import Foundation
import StoragerCore

/// 데이터 디렉터리의 잠금 파일로 Storager 가 하나만 돌게 한다.
/// fd 는 프로세스가 끝날 때까지 열어 두고, 종료·크래시 시 커널이 잠금을 푼다.
/// 디스크가 가득 차(ENOSPC) 잠금 파일을 만들 수 없으면 잠금 없이 시작한다(`isHeld == false`, 경고 로그).
final class InstanceLock {
    enum Failure: Error {
        /// 다른 Storager 가 잠금을 잡고 있다
        case alreadyRunning
        /// 잠금 파일을 만들거나 잠글 수 없다 (디스크가 가득 찬 경우는 던지지 않고 잠금 없이 시작한다)
        case unavailable(any Error)
    }

    static let fileName = "storager.lock"

    /// false 면 디스크가 가득 차 잠금 없이 도는 중이다(두 번째 인스턴스를 막지 못한다)
    let isHeld: Bool
    private let fd: Int32

    init(directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch where Self.isOutOfSpace(error) {
            Log.app.warning("디스크가 가득 차 데이터 폴더를 만들 수 없어 단일 인스턴스 잠금 없이 시작")
            fd = -1
            isHeld = false
            return
        } catch {
            throw Failure.unavailable(error)
        }
        let path = directory.appendingPathComponent(Self.fileName).path
        var fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        let openError = errno
        // 쓰기 권한 없는 잠금 파일이 남아 있어도 flock 은 읽기 전용 fd 로 된다
        if fd < 0, openError == EACCES {
            fd = open(path, O_RDONLY | O_CLOEXEC)
        }
        if fd < 0, openError == ENOSPC {
            Log.app.warning("디스크가 가득 차 잠금 파일을 만들 수 없어 단일 인스턴스 잠금 없이 시작")
            self.fd = -1
            isHeld = false
            return
        }
        // 다시 열기도 실패하면 처음 오류(EACCES)를 알린다
        guard fd >= 0 else { throw Failure.unavailable(Self.posixError(openError)) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK ? Failure.alreadyRunning : Failure.unavailable(Self.posixError(code))
        }
        self.fd = fd
        isHeld = true
    }

    /// 디스크 공간 부족(ENOSPC)인지. Foundation 오류는 밑에 깔린 POSIX 오류까지 본다.
    private static func isOutOfSpace(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    deinit {
        if fd >= 0 { close(fd) }
    }
}
