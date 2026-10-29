import Foundation

/// 설정이 쓰는 키-값 저장소. 앱은 UserDefaults, 테스트는 메모리 저장소를 쓴다.
public protocol SettingsStore: AnyObject, Sendable {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

/// 앱이 쓰는 UserDefaults 저장소. `UserDefaults` 가 SDK 에서 Sendable 로 표시되는지에 기대지 않고,
/// 문서상 스레드 안전한 UserDefaults 를 감싸 `@unchecked Sendable` 을 여기 한 곳에서만 선언한다.
public final class UserDefaultsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func object(forKey key: String) -> Any? {
        defaults.object(forKey: key)
    }

    public func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// 저장소(기본값은 UserDefaults)에 저장하는 설정.
public struct StoragerSettings: Sendable {
    public enum Key {
        public static let scanIntervalHours = "scanIntervalHours"
        public static let leafThresholdMB = "leafThresholdMB"
        public static let excludedPaths = "excludedPaths"
        public static let ignoredPaths = "ignoredPaths"
        public static let extraProjectRoots = "extraProjectRoots"
        public static let menuBarTemplate = "menuBarTemplate"
        public static let menuBarScalePercent = "menuBarScalePercent"
        public static let menuBarUsesTemplateImage = "menuBarUsesTemplateImage"
        /// 예전 3가지 메뉴바 표시 형식(`freeSpace`·`usedPercent`·`iconOnly`). 처음 만들 때 `menuBarTemplate` 으로 옮기고 지운다.
        public static let legacyMenuBarDisplay = "menuBarDisplay"
        public static let fullDiskAccessIntroShown = "fullDiskAccessIntroShown"
    }

    public static let scanIntervalChoices = [1, 3, 6, 12, 24]
    public static let leafThresholdChoices = [1, 10, 50, 100]
    public static let defaultScanIntervalHours = 6
    public static let defaultLeafThresholdMB = 10
    /// 메뉴바 표시 크기(%): 100…200, 10 단위
    public static let menuBarScaleChoices = Array(stride(from: 100, through: 200, by: 10))
    public static let defaultMenuBarScalePercent = 100

    private let store: any SettingsStore

    public init(store: any SettingsStore = UserDefaultsStore()) {
        self.store = store
        migrateLegacyMenuBarDisplay()
    }

    /// 예전 메뉴바 표시 형식 값을 템플릿으로 옮긴다. 템플릿이 이미 저장돼 있으면 그대로 두고, 옛 키는 어느 쪽이든 지운다
    /// (한 번만 옮긴다). 알 수 없는 옛 값은 옮기지 않아 기본 템플릿이 된다.
    private func migrateLegacyMenuBarDisplay() {
        guard let legacy = store.object(forKey: Key.legacyMenuBarDisplay) else { return }
        if store.object(forKey: Key.menuBarTemplate) == nil, let raw = legacy as? String,
           let template = Self.legacyMenuBarTemplates[raw] {
            store.set(template, forKey: Key.menuBarTemplate)
        }
        store.set(nil, forKey: Key.legacyMenuBarDisplay)
    }

    /// 예전 `MenuBarDisplay` raw 값 → 같은 모양의 템플릿
    static let legacyMenuBarTemplates = [
        "freeSpace": "{icon}{remain_storage}",
        "usedPercent": "{icon}{using_storage_percent}",
        "iconOnly": "{icon}",
    ]

    /// 주기 재스캔 간격(시간). 허용 값이 아니면 기본값 6. 허용 값(`scanIntervalChoices`)이 아닌 값은 저장하지 않는다.
    public var scanIntervalHours: Int {
        get {
            let value = store.object(forKey: Key.scanIntervalHours) as? Int
            return value.flatMap { Self.scanIntervalChoices.contains($0) ? $0 : nil } ?? Self.defaultScanIntervalHours
        }
        nonmutating set {
            guard Self.scanIntervalChoices.contains(newValue) else { return }
            store.set(newValue, forKey: Key.scanIntervalHours)
        }
    }

    /// 리프(큰 파일) 임계치 MB. 허용 값이 아니면 기본값 10. 허용 값(`leafThresholdChoices`)이 아닌 값은 저장하지 않는다.
    public var leafThresholdMB: Int {
        get {
            let value = store.object(forKey: Key.leafThresholdMB) as? Int
            return value.flatMap { Self.leafThresholdChoices.contains($0) ? $0 : nil } ?? Self.defaultLeafThresholdMB
        }
        nonmutating set {
            guard Self.leafThresholdChoices.contains(newValue) else { return }
            store.set(newValue, forKey: Key.leafThresholdMB)
        }
    }

    /// 스캔에서 뺄 디렉터리 (설정 창에서 추가). 정리·중복 제거해 정렬 저장한다 (`normalized` 참고).
    public var excludedPaths: [String] {
        get { storedPaths(Key.excludedPaths) }
        nonmutating set { store.set(Self.normalized(newValue), forKey: Key.excludedPaths) }
    }

    /// 트리맵 우클릭 "무시 목록에 추가" 로 넣은 디렉터리.
    public var ignoredPaths: [String] {
        get { storedPaths(Key.ignoredPaths) }
        nonmutating set { store.set(Self.normalized(newValue), forKey: Key.ignoredPaths) }
    }

    /// 홈 밖에서 분류 대상에 넣을 프로젝트 루트.
    public var extraProjectRoots: [String] {
        get { storedPaths(Key.extraProjectRoots) }
        nonmutating set { store.set(Self.normalized(newValue), forKey: Key.extraProjectRoots) }
    }

    /// 메뉴바 표시 템플릿 (`MenuBarTemplate`). 저장된 값이 문자열이 아니거나 쓸 수 없으면(`MenuBarTemplate.isUsable`) 기본값.
    /// 저장할 때는 줄바꿈을 공백으로 바꾸고 `MenuBarTemplate.maxLength` 글자까지 자른다. 빈 문자열은 그대로 저장한다(아이콘만 보인다).
    public var menuBarTemplate: String {
        get {
            let value = store.object(forKey: Key.menuBarTemplate) as? String
            return value.flatMap { MenuBarTemplate.isUsable($0) ? $0 : nil } ?? MenuBarTemplate.defaultTemplate
        }
        nonmutating set { store.set(MenuBarTemplate.sanitized(newValue), forKey: Key.menuBarTemplate) }
    }

    /// 메뉴바 글자·아이콘 크기(%). 허용 값(`menuBarScaleChoices`)이 아니면 기본값 100. 허용 값이 아닌 값은 저장하지 않는다.
    public var menuBarScalePercent: Int {
        get {
            let value = store.object(forKey: Key.menuBarScalePercent) as? Int
            return value.flatMap { Self.menuBarScaleChoices.contains($0) ? $0 : nil } ?? Self.defaultMenuBarScalePercent
        }
        nonmutating set {
            guard Self.menuBarScaleChoices.contains(newValue) else { return }
            store.set(newValue, forKey: Key.menuBarScalePercent)
        }
    }

    /// 메뉴바 라벨을 템플릿 이미지(메뉴바 색에 맞춘 단색)로 그릴지. 기본 켜짐. 끄면 이모지가 원래 색으로 보이고 아이콘·글자는
    /// 메뉴바 글자 색으로 그린다. 저장된 값이 Bool 이 아니면 기본값.
    public var menuBarUsesTemplateImage: Bool {
        get { store.object(forKey: Key.menuBarUsesTemplateImage) as? Bool ?? true }
        nonmutating set { store.set(newValue, forKey: Key.menuBarUsesTemplateImage) }
    }

    /// 전체 디스크 접근 안내 창을 이미 한 번 보여 줬는지. 처음 실행 때 권한이 없으면 한 번만 띄운다.
    public var fullDiskAccessIntroShown: Bool {
        get { store.object(forKey: Key.fullDiskAccessIntroShown) as? Bool ?? false }
        nonmutating set { store.set(newValue, forKey: Key.fullDiskAccessIntroShown) }
    }

    /// 현재 설정으로 만든 스캔 옵션. `permissionSkip` 은 전체 디스크 접근 권한이 없을 때 건너뛸 위치다
    /// (그 안쪽의 제외 경로는 realpath 하지 않고 뺀다).
    public func makeScanOptions(permissionSkip: PermissionSkip = .none) -> ScanOptions {
        ScanOptions(leafThreshold: Int64(leafThresholdMB) * 1024 * 1024,
                    excludedPaths: Set(excludedPaths + ignoredPaths), permissionSkip: permissionSkip)
    }

    public var scanInterval: TimeInterval { TimeInterval(scanIntervalHours) * 3600 }

    /// 저장된 경로 목록. 직접 고친 값이나 예전 값에 쓸 수 없는 경로(`isUsablePath` 가 아닌 것)가 있으면 빼고 돌려준다.
    private func storedPaths(_ key: String) -> [String] {
        (store.object(forKey: key) as? [String] ?? []).filter(Self.isUsablePath)
    }

    /// 경로 목록에 쓸 수 있는 값: 절대 경로(`/…`), `~` 자신, `~/…`. 빈 문자열·상대 경로·`~user` 꼴은 쓰지 않는다.
    /// `PathUtil.standardize` 는 상대 경로를 현재 작업 디렉터리 기준으로 붙이고 `~user` 는 다른 사용자 홈으로 풀므로,
    /// 그대로 두면 실행 위치나 계정에 따라 뜻이 달라진다.
    static func isUsablePath(_ path: String) -> Bool {
        path.hasPrefix("/") || path == "~" || path.hasPrefix("~/")
    }

    /// 경로 목록을 저장할 형태로 만든다. 쓸 수 없는 값(`isUsablePath`)은 버린다.
    ///
    /// 글자 단위로 정리(`standardize`)한 뒤 중복을 없애는 이유: 같은 폴더를 `/a/b/`·`/a/x/../b` 처럼 다르게 적거나
    /// 폴더 선택 패널에서 두 번 고르면 설정 화면 목록에 같은 행이 여러 번 보이고, 삭제(`remove`)는 글자가 같은 항목을
    /// 지우므로 하나만 지워도 나머지가 남는다. 저장 시점에 한 형태로 맞춰 두면 목록·삭제·비교가 글자 비교만으로 맞는다.
    /// 심볼릭 링크는 여기서 풀지 않는다(realpath 는 보호 폴더 안에서 동의 창을 띄울 수 있다). 스캔 쪽이 `PathUtil.resolve` 로 다시 푼다.
    private static func normalized(_ paths: [String]) -> [String] {
        let valid = paths.filter(isUsablePath)
        return Array(Set(valid.map(PathUtil.standardize))).sorted()
    }
}
