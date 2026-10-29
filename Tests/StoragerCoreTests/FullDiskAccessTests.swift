import Darwin
import Foundation
import Testing
@testable import StoragerCore

struct FullDiskAccessTests {
    // MARK: 권한 확인

    @Test func readableProbeMeansGranted() throws {
        let tree = try TempTree()
        try tree.file("TCC.db", bytes: 10)
        #expect(FullDiskAccess.check(probePaths: [tree.path + "/TCC.db"]) == .granted)
    }

    @Test func directoryProbeOpensAsDirectory() throws {
        let tree = try TempTree()
        try tree.dir("Mail")
        #expect(FullDiskAccess.check(probePaths: [tree.path + "/Mail"]) == .granted)
    }

    @Test(.enabled(if: getuid() != 0, "root 는 chmod 000 파일도 열 수 있다"))
    func unreadableProbeMeansDenied() throws {
        let tree = try TempTree()
        let url = try tree.file("TCC.db", bytes: 10)
        #expect(chmod(url.path, 0o000) == 0)
        #expect(FullDiskAccess.check(probePaths: [url.path]) == .denied)
    }

    @Test func missingProbesMeanUnknown() throws {
        let tree = try TempTree()
        #expect(FullDiskAccess.check(probePaths: [tree.path + "/a", tree.path + "/b/c"]) == .unknown)
        #expect(FullDiskAccess.check(probePaths: []) == .unknown)
    }

    @Test(.enabled(if: getuid() != 0, "root 는 chmod 000 파일도 열 수 있다"))
    func probesAreCheckedInOrder() throws {
        let tree = try TempTree()
        let locked = try tree.file("locked", bytes: 1)
        #expect(chmod(locked.path, 0o000) == 0)
        try tree.file("readable", bytes: 1)
        let missing = tree.path + "/missing"
        // 없는 경로는 건너뛰고, 처음 판단되는 경로가 결과를 정한다
        #expect(FullDiskAccess.check(probePaths: [missing, locked.path, tree.path + "/readable"]) == .denied)
        #expect(FullDiskAccess.check(probePaths: [missing, tree.path + "/readable", locked.path]) == .granted)
    }

    @Test func defaultProbesUseGivenHomeInOrder() {
        #expect(FullDiskAccess.defaultProbePaths(home: "/Users/me") == [
            "/Users/me/Library/Application Support/com.apple.TCC/TCC.db",
            "/Users/me/Library/Safari/Bookmarks.plist",
            "/Users/me/Library/Mail",
        ])
    }

    @Test func realHomeIgnoresHomeEnvironment() {
        // getpwuid 결과라 HOME 을 바꿔도 같다. 최소한 절대 경로여야 한다
        #expect(FullDiskAccess.realHomeDirectory.hasPrefix("/"))
        #expect(FullDiskAccess.defaultProbePaths().first?.hasPrefix(FullDiskAccess.realHomeDirectory + "/") == true)
    }

    @Test func onlyGrantedSkipsNothing() throws {
        let home = try TempTree()
        #expect(FullDiskAccess.Status.granted.permissionSkip(homePath: home.path) == .none)
        #expect(PermissionSkip.none.isEmpty)
        let expected = Set(FullDiskAccess.protectedFolders.map { home.path + "/" + $0.relativePath })
        for status in [FullDiskAccess.Status.denied, .unknown] {
            let skip = status.permissionSkip(homePath: home.path)
            #expect(skip.paths == expected)
            #expect(skip.directoryNameSuffixes == [".photoslibrary"])
            #expect(skip.homePath == home.path)
        }
        #expect(expected.contains(home.path + "/Library/Application Support/AddressBook"))
        #expect(expected.contains(home.path + "/Library/Calendars"))
    }

    @Test func protectedPathsDoNotFollowSymlinkedFolders() throws {
        let home = try TempTree()
        let notes = try TempTree()
        // ~/Documents 가 보호되지 않는 다른 폴더로 가는 링크여도 그 대상은 건너뛰지 않는다
        try home.symlink("Documents", to: notes.path)
        let skip = FullDiskAccess.permissionSkip(homePath: home.path)
        #expect(skip.paths.contains(home.path + "/Documents"))
        #expect(!skip.covers(notes.path))
        #expect(!skip.covers(notes.path + "/x"))
    }

    @Test func coversMatchesPathsAndNamesTextually() {
        let skip = FullDiskAccess.permissionSkip(homePath: "/Users/me")
        #expect(skip.skips("/Users/me/Desktop"))
        #expect(!skip.skips("/Users/me/Desktop/a"))
        #expect(skip.skips("/Users/me/Pictures/Photos Library.photoslibrary"))
        #expect(skip.skips("/Users/me/x/Old.PhotosLibrary"))
        // 이름 규칙은 홈 밖(추가 루트)에도 걸린다 (외장 볼륨의 사진 보관함도 동의 창을 띄운다)
        #expect(skip.skips("/Volumes/Work/Photos Library.photoslibrary"))
        #expect(!skip.skips("/Users/me"))
        #expect(skip.covers("/Users/me/Desktop"))
        #expect(skip.covers("/Users/me/downloads/VMs"))
        #expect(skip.covers("/Users/me/Pictures/P.photoslibrary/database"))
        #expect(!skip.covers("/Users/me/Desktopper"))
        #expect(!skip.covers("/Users/me/Library"))
        #expect(skip.covers("/Volumes/Work/P.photoslibrary/x"))
        #expect(!skip.covers("/Volumes/Work/photoslibrary-notes"))
        // 안쪽만: 보호 위치 자신은 아니다
        #expect(!skip.coversInside("/Users/me/Downloads"))
        #expect(skip.coversInside("/Users/me/Downloads/VMs"))
        #expect(skip.coversInside("/Users/me/Pictures/P.photoslibrary/x"))
        #expect(!skip.coversInside("/Users/me/Pictures/P.photoslibrary"))
        #expect(!PermissionSkip.none.covers("/Users/me/Desktop"))
    }

    // MARK: 보호 폴더 건너뛰기

    /// 보호 위치 일부와 일반 폴더가 있는 가짜 홈
    func makeHome() throws -> TempTree {
        let home = try TempTree()
        try home.file("Desktop/a.bin", bytes: 20_000)
        try home.file("Library/Containers/com.foo/data.bin", bytes: 30_000)
        try home.file("Library/Caches/com.bar/c.bin", bytes: 40_000)
        try home.file("dev/web/package.json", bytes: 2)
        return home
    }

    func deniedOptions(_ home: TempTree, excluded: Set<String> = []) -> ScanOptions {
        ScanOptions(excludedPaths: excluded,
                    permissionSkip: FullDiskAccess.Status.denied.permissionSkip(homePath: home.path))
    }

    @Test func protectedFoldersAreSkippedAndReported() async throws {
        let home = try makeHome()

        let result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [], options: deniedOptions(home))

        #expect(result.home.child(named: "Desktop") == nil)
        #expect(result.home.descendant(at: ["Library", "Containers"]) == nil)
        #expect(result.home.descendant(at: ["Library", "Caches", "com.bar"]) != nil)
        #expect(result.home.child(named: "dev") != nil)
        #expect(result.home.allocatedSize == home.allocated("Library/Caches/com.bar/c.bin")
            + home.allocated("dev/web/package.json"))
        // 실제로 만난 보호 폴더만 보고한다 (Documents·Downloads 등은 없다)
        #expect(result.skippedForPermission == [home.path + "/Desktop", home.path + "/Library/Containers"])
        #expect(result.isLimited)
    }

    @Test func contactsCalendarsAndPhotoLibrariesAreSkipped() async throws {
        let home = try TempTree()
        try home.file("Library/Application Support/AddressBook/ab.db", bytes: 10_000)
        try home.file("Library/Application Support/Other/o.bin", bytes: 10_000)
        try home.file("Library/Calendars/c.db", bytes: 10_000)
        try home.file("Pictures/Photos Library.photoslibrary/database/p.db", bytes: 10_000)
        try home.file("Pictures/other/x.jpg", bytes: 10_000)
        try home.file("dev/Old.PhotosLibrary/y.db", bytes: 10_000)

        let result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [], options: deniedOptions(home))

        #expect(result.home.descendant(at: ["Library", "Application Support", "AddressBook"]) == nil)
        #expect(result.home.descendant(at: ["Library", "Application Support", "Other"]) != nil)
        #expect(result.home.descendant(at: ["Library", "Calendars"]) == nil)
        #expect(result.home.descendant(at: ["Pictures", "Photos Library.photoslibrary"]) == nil)
        #expect(result.home.descendant(at: ["Pictures", "other"]) != nil)
        #expect(result.home.descendant(at: ["dev", "Old.PhotosLibrary"]) == nil)
        #expect(result.skippedForPermission == [
            home.path + "/Library/Application Support/AddressBook",
            home.path + "/Library/Calendars",
            home.path + "/Pictures/Photos Library.photoslibrary",
            home.path + "/dev/Old.PhotosLibrary",
        ])
    }

    @Test func grantedScansProtectedFolders() async throws {
        let home = try makeHome()
        try home.file("Pictures/P.photoslibrary/p.db", bytes: 10_000)

        let result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [], options: ScanOptions())

        #expect(result.home.child(named: "Desktop") != nil)
        #expect(result.home.descendant(at: ["Library", "Containers", "com.foo"]) != nil)
        #expect(result.home.descendant(at: ["Pictures", "P.photoslibrary"]) != nil)
        #expect(result.skippedForPermission.isEmpty)
        #expect(!result.isLimited)
    }

    @Test func excludedProtectedFoldersAreNotReportedAsPermissionSkips() async throws {
        let home = try makeHome()

        let result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [],
                                               options: deniedOptions(home, excluded: [home.path + "/Library"]))

        #expect(result.home.child(named: "Library") == nil)
        #expect(result.skippedForPermission == [home.path + "/Desktop"])
    }

    @Test func extraRootsSkipOnlyPhotoLibraries() async throws {
        let home = try makeHome()
        // 추가 루트 안의 같은 이름 폴더는 보호 위치가 아니지만, 사진 보관함은 어디에 있든 건너뛴다
        let extra = try TempTree()
        try extra.file("Desktop/x.bin", bytes: 10_000)
        try extra.file("Documents/y.bin", bytes: 10_000)
        try extra.file("P.photoslibrary/z.bin", bytes: 10_000)

        let denied = try await ScanResult.scan(homePath: home.path, extraRootPaths: [extra.path],
                                               options: deniedOptions(home))

        let root = try #require(denied.extraRoots.first)
        #expect(root.root.child(named: "Desktop") != nil)
        #expect(root.root.child(named: "Documents") != nil)
        #expect(root.root.child(named: "P.photoslibrary") == nil)
        #expect(root.skippedForPermission == [extra.path + "/P.photoslibrary"])

        let granted = try await ScanResult.scan(homePath: home.path, extraRootPaths: [extra.path], options: ScanOptions())
        #expect(try #require(granted.extraRoots.first).root.child(named: "P.photoslibrary") != nil)
    }

    // MARK: 권한 없는 추가 루트

    @Test func extraRootInsideProtectedFolderIsNotResolved() throws {
        let home = try TempTree()
        let elsewhere = try TempTree()
        try elsewhere.dir("proj")
        // ~/Downloads 가 홈 밖으로 가는 링크라 realpath 하면 홈 밖 경로가 되어 받아들여진다.
        // 권한이 없으면 풀지 않고 글자로 홈 안이라 판정한다
        try home.symlink("Downloads", to: elsewhere.path)
        let skip = FullDiskAccess.permissionSkip(homePath: home.path)
        let root = home.path + "/Downloads/proj"

        #expect(ExtraRootConflict.check(root, homePath: home.path) == nil)
        #expect(ExtraRootConflict.check(root, homePath: home.path, permissionSkip: skip) == .insideHome)
        #expect(ExtraRootConflict.acceptedRoots([root], homePath: home.path, logsSkipped: false)
            == [elsewhere.path + "/proj"])
        #expect(ExtraRootConflict.acceptedRoots([root], homePath: home.path, permissionSkip: skip,
                                                logsSkipped: false).isEmpty)
        // 다른 루트 목록에 있는 그런 경로도 풀지 않고 비교에서 뺀다
        #expect(ExtraRootConflict.check(elsewhere.path + "/proj", homePath: home.path, otherRoots: [root],
                                        permissionSkip: skip) == nil)
        #expect(ExtraRootConflict.check(elsewhere.path + "/proj", homePath: home.path, otherRoots: [root])
            == .duplicate)
    }

    @Test func extraRootInsidePhotoLibraryNeedsPermission() async throws {
        let home = try makeHome()
        let volume = try TempTree()
        let photos = try TempTree()
        try photos.file("originals/a.jpg", bytes: 10_000)
        // 사진 보관함이 다른 곳으로 가는 링크라 풀면 이름 규칙에 걸리지 않는다. 거부되면 풀지 않은 것이다
        try volume.symlink("Lib.photoslibrary", to: photos.path)
        try volume.file("work/w.bin", bytes: 10_000)
        let inside = volume.path + "/Lib.photoslibrary/originals"
        let skip = FullDiskAccess.permissionSkip(homePath: home.path)

        #expect(ExtraRootConflict.check(inside, homePath: home.path, permissionSkip: skip) == .permissionRequired)
        #expect(ExtraRootConflict.check(inside, homePath: home.path) == nil)
        // 이름만 사진 보관함인 링크 자신은 풀어서 판정한다 (가리키는 곳이 일반 폴더라 받아들인다)
        #expect(ExtraRootConflict.check(volume.path + "/Lib.photoslibrary", homePath: home.path,
                                        permissionSkip: skip) == nil)

        let result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [inside, volume.path + "/work"],
                                               options: deniedOptions(home))
        #expect(result.extraRoots.map(\.rootPath) == [volume.path + "/work"])

        // 정리 허용 루트에서도 빠진다
        let planner = CleanupPlanner(homePath: home.path, extraRoots: [inside], permissionSkip: skip)
        #expect(planner.allowedRoots == [home.path])
        #expect(CleanupPlanner(homePath: home.path, extraRoots: [inside]).allowedRoots
            == [home.path, photos.path + "/originals"])
    }

    @Test func rescanDoesNotEnterProtectedFolders() async throws {
        let home = try makeHome()
        let options = deniedOptions(home)
        var result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [], options: options)

        // 보호 폴더 자신이나 그 아래는 읽기 전에 거부한다
        #expect(throws: RescanError.permissionRequired(home.path + "/Desktop")) {
            try result.rescan(path: home.path + "/Desktop", options: options)
        }
        #expect(throws: RescanError.permissionRequired(home.path + "/Library/Containers/com.foo")) {
            try result.rescan(path: home.path + "/Library/Containers/com.foo", options: options)
        }
        // 조상을 다시 재면 그 안의 보호 폴더는 건너뛰고, 새로 생긴 보호 위치는 건너뛴 목록에 반영한다
        try home.file("Library/Caches/com.bar/d.bin", bytes: 50_000)
        try home.dir("Library/Calendars")
        #expect(result.rescanAndApply(paths: [home.path + "/Library"], options: options) == 1)
        #expect(result.home.descendant(at: ["Library", "Containers"]) == nil)
        #expect(result.home.descendant(at: ["Library", "Calendars"]) == nil)
        #expect(result.home.descendant(at: ["Library", "Caches", "com.bar"])?.allocatedSize
            == home.allocated("Library/Caches/com.bar/c.bin") + home.allocated("Library/Caches/com.bar/d.bin"))
        #expect(result.skippedForPermission == [
            home.path + "/Desktop", home.path + "/Library/Calendars", home.path + "/Library/Containers",
        ])
    }

    @Test func rescanRefusesBeforeResolvingSymlinkedProtectedFolder() async throws {
        let home = try makeHome()
        // ~/Downloads 가 링크라 realpath 하면 다른 경로가 된다. 거부 사유가 푼 경로가 아니라 적힌 경로면 풀지 않은 것이다
        try home.dir("real/x")
        try home.symlink("Downloads", to: home.path + "/real")
        let options = deniedOptions(home)
        let result = try await ScanResult.scan(homePath: home.path, extraRootPaths: [], options: options)

        #expect(throws: RescanError.permissionRequired(home.path + "/Downloads/x")) {
            try result.rescan(path: home.path + "/Downloads/x", options: options)
        }
        #expect(throws: RescanError.permissionRequired(home.path + "/Downloads/x")) {
            try TreeScanner(rootPath: home.path, options: options).rescan(path: home.path + "/Downloads/x",
                                                                           previous: result.homeScan)
        }
    }

    @Test func excludedPathsInsideProtectedFoldersAreNotResolved() throws {
        let home = try TempTree()
        try home.dir("real/VMs")
        try home.symlink("Downloads", to: home.path + "/real")
        let excluded: Set<String> = [home.path + "/Downloads/VMs", home.path + "/Downloads", home.path + "/dev"]

        // 권한이 없으면 보호 폴더 안쪽 제외 경로는 realpath 하지 않고 뺀다 (풀었다면 real/VMs 가 남는다)
        let limited = ScanOptions(excludedPaths: excluded,
                                  permissionSkip: FullDiskAccess.permissionSkip(homePath: home.path))
        #expect(limited.excludedPaths == [home.path + "/real", home.path + "/dev"])

        // 권한이 있으면 지금처럼 푼다
        let full = ScanOptions(excludedPaths: excluded)
        #expect(full.excludedPaths == [home.path + "/real/VMs", home.path + "/real", home.path + "/dev"])

        // 설정에서 만들 때도 같다
        let store = InMemorySettingsStore()
        let settings = StoragerSettings(store: store)
        settings.excludedPaths = [home.path + "/Downloads/VMs"]
        settings.ignoredPaths = [home.path + "/Pictures/P.photoslibrary/resources"]
        let options = settings.makeScanOptions(permissionSkip: FullDiskAccess.permissionSkip(homePath: home.path))
        #expect(options.excludedPaths.isEmpty)
    }

    @Test func cleanupPlannerRejectsItemsInsideSkippedLocationsWithoutTouchingThem() throws {
        let home = try TempTree()
        let tag = try #require(RuleCatalog.default.first { $0.id == "js.node_modules" }?.tag)
        // 폴더를 만들지 않았다: lstat 했다면 .missing 이 된다
        let items = [
            ClassifiedItem(path: home.path + "/Desktop/app/node_modules", tag: tag, allocatedSize: 1,
                           newestModification: .distantPast),
            ClassifiedItem(path: home.path + "/Pictures/P.photoslibrary/node_modules", tag: tag, allocatedSize: 1,
                           newestModification: .distantPast),
        ]

        let limited = CleanupPlanner(homePath: home.path,
                                     permissionSkip: FullDiskAccess.permissionSkip(homePath: home.path)).plan(items)
        #expect(limited.rejected.map(\.reason) == [.permissionRequired, .permissionRequired])
        #expect(limited.rejected[0].reason.message == "전체 디스크 접근 권한이 없어 정리할 수 없습니다")

        let full = CleanupPlanner(homePath: home.path).plan(items)
        #expect(full.rejected.map(\.reason) == [.missing, .missing])
    }

    @Test func permissionSkipsAtOrAboveRootAreIgnored() throws {
        let home = try TempTree()
        try home.dir("Desktop/inner")
        // 보호 폴더 자신을 루트로 스캔하면 루트 전체를 빼지 않는다
        let skip = PermissionSkip(homePath: home.path, paths: [home.path + "/Desktop", "/"],
                                  directoryNameSuffixes: [".photoslibrary"])
        let scanner = TreeScanner(rootPath: home.path + "/Desktop", options: ScanOptions(permissionSkip: skip))
        #expect(scanner.options.permissionSkip.paths.isEmpty)
        // 사진 보관함을 루트로 고르면 이름 규칙도 뺀다
        try home.dir("P.photoslibrary/x")
        let library = TreeScanner(rootPath: home.path + "/P.photoslibrary", options: ScanOptions(permissionSkip: skip))
        #expect(library.options.permissionSkip.directoryNameSuffixes.isEmpty)
    }

    @Test func symlinkedExtraRootIntoPhotoLibraryNeedsPermission() async throws {
        let home = try makeHome()
        let volume = try TempTree()
        try volume.file("Real.photoslibrary/originals/a.jpg", bytes: 10_000)
        // 이름에 사진 보관함이 드러나지 않는 링크가 사진 보관함 안·자신을 가리킨다
        try volume.symlink("photos-link", to: volume.path + "/Real.photoslibrary/originals")
        try volume.symlink("library-link", to: volume.path + "/Real.photoslibrary")
        let skip = FullDiskAccess.permissionSkip(homePath: home.path)
        let roots = [volume.path + "/photos-link", volume.path + "/library-link", volume.path + "/Real.photoslibrary"]

        for root in roots {
            #expect(ExtraRootConflict.check(root, homePath: home.path, permissionSkip: skip) == .permissionRequired)
            #expect(ExtraRootConflict.check(root, homePath: home.path) == nil)
        }
        #expect(ExtraRootConflict.acceptedRoots(roots, homePath: home.path, permissionSkip: skip,
                                                logsSkipped: false).isEmpty)
        let result = try await ScanResult.scan(homePath: home.path, extraRootPaths: roots, options: deniedOptions(home))
        #expect(result.extraRoots.isEmpty)
        #expect(CleanupPlanner(homePath: home.path, extraRoots: roots, permissionSkip: skip).allowedRoots == [home.path])
        #expect(ExtraRootConflict.permissionRequired.message.contains("다시 추가하세요"))
        #expect(ExtraRootConflict.permissionRequired.storedRootMessage.contains("다시 스캔합니다"))
        #expect(ExtraRootConflict.duplicate.storedRootMessage == ExtraRootConflict.duplicate.message)
    }
}
