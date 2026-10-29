import Darwin
import Foundation
import Testing
@testable import StoragerCore

struct BulkDirectoryReaderTests {
    @Test func readsNamesKindsAndSizes() throws {
        let tree = try TempTree()
        try tree.file("a.bin", bytes: 100_000)
        try tree.dir("sub")
        try tree.symlink("link", to: "a.bin")

        let entries = try BulkDirectoryReader.read(directoryPath: tree.path)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["a.bin", "sub", "link"])
        #expect(byName["a.bin"]?.kind == .file)
        #expect(byName["a.bin"]?.logicalSize == 100_000)
        #expect(byName["a.bin"]?.allocatedSize == tree.allocated("a.bin"))
        #expect(byName["a.bin"]?.linkCount == 1)
        #expect(byName["sub"]?.kind == .directory)
        #expect(byName["link"]?.kind == .symlink)
        #expect(entries.allSatisfy { $0.errorCode == 0 })
    }

    @Test func reportsFileIDDeviceAndModificationDate() throws {
        let tree = try TempTree()
        let url = try tree.file("x", bytes: 10)
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        var info = stat()
        try #require(lstat(url.path, &info) == 0)

        let entry = try #require(try BulkDirectoryReader.read(directoryPath: tree.path).first)

        #expect(entry.fileID == UInt64(info.st_ino))
        #expect(entry.deviceID == info.st_dev)
        #expect(abs(entry.modificationDate.timeIntervalSince(past)) < 1)
        #expect(entry.isDataless == false)
    }

    @Test func hardLinksShareFileIDAndReportLinkCount() throws {
        let tree = try TempTree()
        try tree.file("orig", bytes: 4096)
        try tree.hardLink("copy", to: "orig")

        let entries = try BulkDirectoryReader.read(directoryPath: tree.path)

        #expect(entries.count == 2)
        #expect(Set(entries.map(\.fileID)).count == 1)
        #expect(entries.allSatisfy { $0.linkCount == 2 })
    }

    /// 버퍼(256KB) 를 여러 번 채우는 큰 디렉터리도 빠짐없이 읽는다.
    @Test func readsDirectoriesLargerThanOneBuffer() throws {
        let tree = try TempTree()
        let longName = String(repeating: "n", count: 200)
        for index in 0..<3000 {
            try Data().write(to: tree.root.appendingPathComponent("\(longName)-\(index)"))
        }

        let entries = try BulkDirectoryReader.read(directoryPath: tree.path)

        #expect(entries.count == 3000)
        #expect(Set(entries.map(\.name)).count == 3000)
    }

    @Test func missingDirectoryThrowsENOENT() {
        #expect(throws: DirectoryReadError.posix(ENOENT)) {
            try BulkDirectoryReader.read(directoryPath: "/nonexistent-\(UUID().uuidString)")
        }
    }

    /// 마운트 지점 항목의 devid 는 부모 볼륨 값이라 ATTR_DIR_MOUNTSTATUS 로 판별한다.
    @Test func flagsMountPointsAndNotOrdinaryDirectories() throws {
        let volumes = try BulkDirectoryReader.read(directoryPath: "/System/Volumes")
        let data = try #require(volumes.first { $0.name == "Data" })
        #expect(data.kind == .directory)
        #expect(data.isMountPoint == true)

        let tree = try TempTree()
        try tree.dir("sub")
        let entries = try BulkDirectoryReader.read(directoryPath: tree.path)
        #expect(entries.count == 1)
        #expect(entries.allSatisfy { !$0.isMountPoint })
    }

    @Test(.disabled(if: geteuid() == 0, "root 는 chmod 000 디렉터리도 읽을 수 있다"))
    func unreadableDirectoryThrowsAccessDenied() throws {
        let tree = try TempTree()
        let locked = try tree.dir("locked")
        chmod(locked.path, 0o000)

        do {
            _ = try BulkDirectoryReader.read(directoryPath: locked.path)
            Issue.record("접근 거부 오류가 나야 한다")
        } catch {
            #expect(error.isAccessDenied)
        }
    }
}
