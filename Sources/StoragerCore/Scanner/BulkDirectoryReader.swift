import Darwin
import Foundation

/// getattrlistbulk 한 항목.
public struct RawEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case file, directory, symlink, other }
    public var name: String
    public var kind: Kind
    public var fileID: UInt64
    public var deviceID: Int32
    public var modificationDate: Date
    public var flags: UInt32
    public var linkCount: UInt32
    public var allocatedSize: Int64
    public var logicalSize: Int64
    /// ATTR_CMN_ERROR. 0 이 아니면 이 항목의 다른 속성은 믿지 않는다.
    public var errorCode: Int32
    /// 다른 볼륨의 마운트 지점인지(ATTR_DIR_MOUNTSTATUS). 마운트 지점 항목의 deviceID 는 덮인 부모 볼륨의
    /// 값이라 deviceID 비교로는 마운트 경계를 알 수 없다. 비트가 오지 않았으면 false.
    public var isMountPoint: Bool

    public var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }
}

public enum DirectoryReadError: Error, Equatable, Sendable {
    /// open(2) 또는 getattrlistbulk(2) 의 errno
    case posix(Int32)
    public var isAccessDenied: Bool {
        if case .posix(let code) = self { return code == EACCES || code == EPERM }
        return false
    }
    public var isMissing: Bool {
        if case .posix(let code) = self { return code == ENOENT || code == ENOTDIR }
        return false
    }
}

/// 디렉터리 하나를 getattrlistbulk(2) 로 읽는다.
public enum BulkDirectoryReader {
    static let bufferSize = 256 * 1024
    /// 레코드 길이(UInt32) + ATTR_CMN_RETURNED_ATTRS(attribute_set_t)
    static let minimumRecordSize = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size

    // Darwin 은 ATTR_CMN_RETURNED_ATTRS 를 UInt32, 나머지를 Int32 로 들여온다. 한 식으로 OR 하면
    // 타입 추론이 끝나지 않으므로(컴파일 오류) 하나씩 attrgroup_t 로 바꿔 더한다.
    static let commonAttributes: attrgroup_t = [
        attrgroup_t(ATTR_CMN_RETURNED_ATTRS),
        attrgroup_t(ATTR_CMN_ERROR),
        attrgroup_t(ATTR_CMN_NAME),
        attrgroup_t(ATTR_CMN_DEVID),
        attrgroup_t(ATTR_CMN_OBJTYPE),
        attrgroup_t(ATTR_CMN_MODTIME),
        attrgroup_t(ATTR_CMN_FLAGS),
        attrgroup_t(ATTR_CMN_FILEID),
    ].reduce(0, |)
    static let fileAttributes: attrgroup_t = [
        attrgroup_t(ATTR_FILE_LINKCOUNT),
        attrgroup_t(ATTR_FILE_ALLOCSIZE),
        attrgroup_t(ATTR_FILE_DATALENGTH),
    ].reduce(0, |)
    static let directoryAttributes: attrgroup_t = attrgroup_t(ATTR_DIR_MOUNTSTATUS)

    public static func read(directoryPath path: String) throws(DirectoryReadError) -> [RawEntry] {
        var fd: Int32
        repeat {
            fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        } while fd < 0 && errno == EINTR
        guard fd >= 0 else { throw .posix(errno) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = commonAttributes
        request.dirattr = directoryAttributes
        request.fileattr = fileAttributes

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var entries: [RawEntry] = []
        while true {
            var count: Int32
            repeat {
                count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            } while count < 0 && errno == EINTR
            if count < 0 { throw .posix(errno) }
            if count == 0 { break }
            let bufferStart = UnsafeRawPointer(buffer)
            var record = bufferStart
            for _ in 0..<count {
                // 레코드 길이 필드와 returned 비트 집합은 항상 있어야 한다. 깨진 길이로 버퍼 밖을 읽지 않는다.
                let length = Int(record.loadUnaligned(as: UInt32.self))
                let used = record - bufferStart
                guard length >= minimumRecordSize, length <= bufferSize - used else { throw .posix(EIO) }
                entries.append(parse(record: record))
                record += length
            }
        }
        return entries
    }

    /// 레코드 하나를 읽는다. 속성은 요청 비트 순서(ATTR_CMN_RETURNED_ATTRS 가 맨 앞)로,
    /// returned 비트가 켜진 것만 4바이트 정렬로 붙어 있다. 순서는 common → dir → file. 8바이트 값은 정렬되지 않을 수 있어 loadUnaligned 를 쓴다.
    static func parse(record: UnsafeRawPointer) -> RawEntry {
        var cursor = record + MemoryLayout<UInt32>.size  // 레코드 길이
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr
        let directory = returned.dirattr
        let file = returned.fileattr

        var entry = RawEntry(name: "", kind: .other, fileID: 0, deviceID: 0,
                             modificationDate: Date(timeIntervalSince1970: 0), flags: 0,
                             linkCount: 1,  // ATTR_FILE_* 가 없는 디렉터리 레코드의 기본값
                             allocatedSize: 0, logicalSize: 0, errorCode: 0, isMountPoint: false)

        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            entry.errorCode = Int32(bitPattern: cursor.loadUnaligned(as: UInt32.self))
            cursor += MemoryLayout<UInt32>.size
        }
        if common & attrgroup_t(ATTR_CMN_NAME) != 0 {
            // attrreference_t 의 offset 은 attrreference_t 자신의 시작 위치 기준이다
            let reference = cursor.loadUnaligned(as: attrreference_t.self)
            let namePointer = (cursor + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
            // attr_length 는 끝의 NUL 을 포함한다
            entry.name = String(decoding: UnsafeRawBufferPointer(start: namePointer, count: max(0, Int(reference.attr_length) - 1)),
                                as: UTF8.self)
            cursor += MemoryLayout<attrreference_t>.size
        }
        if common & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            entry.deviceID = cursor.loadUnaligned(as: dev_t.self)
            cursor += MemoryLayout<dev_t>.size
        }
        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            let type = cursor.loadUnaligned(as: fsobj_type_t.self)
            switch Int(type) {
            case Int(VREG.rawValue): entry.kind = .file
            case Int(VDIR.rawValue): entry.kind = .directory
            case Int(VLNK.rawValue): entry.kind = .symlink
            default: entry.kind = .other
            }
            cursor += MemoryLayout<fsobj_type_t>.size
        }
        if common & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            let time = cursor.loadUnaligned(as: timespec.self)
            entry.modificationDate = Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
            cursor += MemoryLayout<timespec>.size
        }
        if common & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            entry.flags = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
        }
        if common & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            entry.fileID = cursor.loadUnaligned(as: UInt64.self)
            cursor += MemoryLayout<UInt64>.size
        }
        if directory & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
            let status = cursor.loadUnaligned(as: UInt32.self)
            entry.isMountPoint = status & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
            cursor += MemoryLayout<UInt32>.size
        }
        if file & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            entry.linkCount = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
        }
        if file & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            entry.allocatedSize = cursor.loadUnaligned(as: off_t.self)
            cursor += MemoryLayout<off_t>.size
        }
        if file & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            entry.logicalSize = cursor.loadUnaligned(as: off_t.self)
            cursor += MemoryLayout<off_t>.size
        }
        return entry
    }
}
