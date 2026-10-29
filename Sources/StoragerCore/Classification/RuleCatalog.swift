import Foundation

/// 초기 규칙 카탈로그 (spec 5장). 위에서부터 처음 맞는 규칙 하나만 적용하므로 구체적인 규칙을 먼저 둔다.
public enum RuleCatalog {
    static let simctl = CleanupMethod.command("xcrun simctl delete unavailable")

    /// 도구를 가릴 수 없는 항목의 도구 이름 (예: 잠금 파일이 없는 node_modules)
    public static let otherTool = "기타"

    /// conda 계열 설치 루트 (홈 기준). `pkgs` 는 패키지 캐시, `envs/*` 는 가상 환경이다
    static let condaRoots = ["miniconda3", "anaconda3", "miniforge3", "mambaforge", ".conda"]

    /// node_modules 옆 잠금 파일 → 패키지 매니저. 여러 개가 함께 있으면 앞의 것이 이긴다.
    /// 옆에 없으면 package.json 도 있는 가장 가까운 조상(워크스페이스 루트, 홈 제외)의 잠금 파일을 따른다
    static let nodeModulesTool = ClassificationRule.ToolLabel.bySiblingMarker([
        .init(["pnpm-lock.yaml"], "pnpm"),
        .init(["yarn.lock"], "yarn"),
        .init(["bun.lockb", "bun.lock"], "bun"),
        .init(["package-lock.json"], "npm"),
    ], fallback: otherTool, projectMarkers: ["package.json"])

    /// venv 옆 잠금 파일 → 그 venv 를 만든 도구. 없으면 그냥 venv.
    /// 옆에 없으면 pyproject.toml 도 있는 가장 가까운 조상(uv 워크스페이스 루트, 홈 제외)의 잠금 파일을 따른다
    static let venvTool = ClassificationRule.ToolLabel.bySiblingMarker([
        .init(["uv.lock"], "uv"),
        .init(["poetry.lock"], "poetry"),
    ], fallback: "venv", projectMarkers: ["pyproject.toml"])

    /// 태그를 붙이지 않고 아래로 내려가는 홈 기준 경로. 첫 매칭 노드 아래로는 내려가지 않으므로, 일반 규칙
    /// (`caches.general` 의 `Library/Caches/*`)에 먼저 걸리는 폴더 안을 더 깊은 규칙으로 나눌 때 쓴다.
    /// 여기 둔 폴더의 규칙에 맞지 않는 나머지 하위 항목은 분류하지 않는다.
    public static let containers: [String] = [
        "Library/Caches/pypoetry",
    ]

    public static let `default`: [ClassificationRule] = [
        // Xcode
        rule("xcode.deriveddata", .homePath("Library/Developer/Xcode/DerivedData"), .xcode, .regenerable, .trash),
        rule("xcode.archives", .homePath("Library/Developer/Xcode/Archives"), .xcode, .caution, .trash),
        rule("xcode.devicesupport", .homePath("Library/Developer/Xcode/iOS DeviceSupport"), .xcode, .regenerable, .trash),
        // 시뮬레이터
        rule("simulator.devices", .homePath("Library/Developer/CoreSimulator/Devices"), .simulator, .regenerable, simctl),
        rule("simulator.dyld", .homePath("Library/Developer/CoreSimulator/Caches/dyld"), .simulator, .regenerable, simctl),
        // Gradle
        rule("gradle.caches", .homePath(".gradle/caches"), .gradle, .regenerable, .trash),
        rule("gradle.daemon", .homePath(".gradle/daemon"), .gradle, .regenerable, .trash),
        rule("gradle.wrapper", .homePath(".gradle/wrapper"), .gradle, .regenerable, .trash),
        // JS
        rule("js.npm", .homePath(".npm/_cacache"), .javascript, .regenerable, .command("npm cache clean --force"),
             tool: "npm"),
        rule("js.yarn", .homePath("Library/Caches/Yarn"), .javascript, .regenerable, .trash, tool: "yarn"),
        // Yarn Berry 전역 캐시. PnP(Plug'n'Play) + 전역 캐시(enableGlobalCache) 구성에서는 패키지가 이 캐시에서
        // 바로 읽히므로, 지우면 PnP 프로젝트마다 `yarn install` 을 다시 해야 한다(다시 받으면 되므로 재생성 가능 등급)
        rule("js.yarn.berry", .homePath(".yarn/berry/cache"), .javascript, .regenerable, .trash, tool: "yarn"),
        rule("js.pnpm", .homePath("Library/pnpm/store"), .javascript, .regenerable, .trash, tool: "pnpm"),
        rule("js.pnpm.cache", .homePath("Library/Caches/pnpm"), .javascript, .regenerable, .trash, tool: "pnpm"),
        rule("js.bun.cache", .homePath(".bun/install/cache"), .javascript, .regenerable, .trash, tool: "bun"),
        // Node 버전 관리자: 설치한 Node 버전 하나가 한 항목이다. 지우면 그 버전을 다시 설치해야 하므로 주의 등급
        rule("js.nvm.versions", .homePath(".nvm/versions/node/*"), .javascript, .caution, .trash, tool: "nvm"),
        rule("js.nvm.cache", .homePath(".nvm/.cache"), .javascript, .regenerable, .trash, tool: "nvm"),
        rule("js.volta.image", .homePath(".volta/tools/image"), .javascript, .caution, .trash, tool: "volta"),
        rule("js.fnm.versions", .homePath(".local/share/fnm/node-versions/*"), .javascript, .caution, .trash,
             tool: "fnm"),
        // CocoaPods·SwiftPM
        rule("cocoapods.cache", .homePath("Library/Caches/CocoaPods"), .cocoaPodsSwiftPM, .regenerable, .trash,
             tool: "CocoaPods"),
        rule("swiftpm.cache", .homePath("Library/Caches/org.swift.swiftpm"), .cocoaPodsSwiftPM, .regenerable, .trash,
             tool: "SwiftPM"),
        // Docker
        rule("docker.vms", .homePath("Library/Containers/com.docker.docker/Data/vms"), .docker, .caution,
             .command("docker system prune")),
        // Homebrew
        rule("homebrew.cache", .homePath("Library/Caches/Homebrew"), .homebrew, .regenerable, .command("brew cleanup")),
        // AI 도구 (세션 로그만 정리 대상. memory/ 제외는 v0.2 주의 등급 정리에서 처리)
        rule("ai.claude.projects", .homePath(".claude/projects"), .aiTools, .caution, .trash, tool: "Claude Code"),
        rule("ai.codex", .homePath(".codex"), .aiTools, .caution, .trash, tool: "Codex"),
        rule("ai.cursor", .homePath(".cursor"), .aiTools, .caution, .trash, tool: "Cursor"),
        rule("ai.claude.app", .homePath("Library/Application Support/Claude"), .aiTools, .caution, .trash,
             tool: "Claude"),
        // Python (홈 경로)
        rule("python.pip.dotcache", .homePath(".cache/pip"), .python, .regenerable, .trash, tool: "pip"),
        rule("python.pip.cache", .homePath("Library/Caches/pip"), .python, .regenerable, .trash, tool: "pip"),
        rule("python.uv.cache", .homePath(".cache/uv"), .python, .regenerable, .command("uv cache clean"), tool: "uv"),
        // uv 가 설치한 Python·도구: 지우면 다시 설치해야 하므로 주의 등급
        rule("python.uv.python", .homePath(".local/share/uv/python"), .python, .caution, .trash, tool: "uv"),
        rule("python.uv.tools", .homePath(".local/share/uv/tools"), .python, .caution, .trash, tool: "uv"),
    ] + condaRoots.map { root in
        rule("python.conda.pkgs.\(root)", .homePath("\(root)/pkgs"), .python, .regenerable,
             .command("conda clean --all"), tool: "conda")
    } + condaRoots.map { root in
        rule("python.conda.envs.\(root)", .homePath("\(root)/envs/*"), .python, .caution, .trash, tool: "conda")
    } + [
        // `Library/Caches/pypoetry` 는 `containers` 라 일반 캐시 규칙에 걸리지 않고 아래 규칙으로 나뉜다
        rule("python.poetry.cache", .homePath("Library/Caches/pypoetry/cache"), .python, .regenerable, .trash,
             tool: "poetry"),
        rule("python.poetry.artifacts", .homePath("Library/Caches/pypoetry/artifacts"), .python, .regenerable, .trash,
             tool: "poetry"),
        rule("python.poetry.virtualenvs", .homePath("Library/Caches/pypoetry/virtualenvs/*"), .python, .caution, .trash,
             tool: "poetry"),
        rule("python.pyenv.versions", .homePath(".pyenv/versions/*"), .python, .caution, .trash, tool: "pyenv"),
        rule("python.pipx.venvs", .homePath(".local/pipx/venvs/*"), .python, .caution, .trash, tool: "pipx"),
        // Rust (홈 경로)
        rule("rust.cargo.registry", .homePath(".cargo/registry"), .rust, .regenerable, .trash, tool: "cargo"),
        rule("rust.cargo.git", .homePath(".cargo/git"), .rust, .regenerable, .trash, tool: "cargo"),
        rule("rust.rustup.toolchains", .homePath(".rustup/toolchains/*"), .rust, .caution, .trash, tool: "rustup"),
        // Go (홈 경로)
        rule("go.pkg.mod", .homePath("go/pkg/mod"), .go, .regenerable, .trash, tool: "Go 모듈"),
        rule("go.build.cache", .homePath("Library/Caches/go-build"), .go, .regenerable, .trash, tool: "Go 빌드 캐시"),
        // Adobe
        rule("adobe.mediacache", .homePath("Library/Application Support/Adobe/Common/Media Cache Files"), .caches,
             .regenerable, .trash),
        // 로그·크래시 (DiagnosticReports 도 Logs 아래 항목이다). `Library/Logs` 폴더 자체가 아니라 그 아래 항목 단위로
        // 태그한다: 폴더째 휴지통으로 옮기면 앱이 열어 둔 로그 핸들까지 끊긴다. 분류는 디렉터리 노드 단위라
        // `Library/Logs` 바로 아래 **파일**은 의도적으로 분류하지 않는다(로그 카테고리 합계에서 빠진다)
        rule("logs", .homePath("Library/Logs/*"), .logs, .regenerable, .trash),
        // 메일·메시지·사진
        rule("personal.mail", .homePath("Library/Mail"), .personalData, .manual, .revealOnly, tool: "메일"),
        rule("personal.messages", .homePath("Library/Messages"), .personalData, .manual, .revealOnly, tool: "메시지"),
        rule("personal.photos", .directoryName("*.photoslibrary", siblingMarkers: []), .personalData, .manual,
             .revealOnly, tool: "사진"),
        // 시스템·데몬 캐시: 일반 캐시 카테고리로 보여 주되 주의 등급(v0.1 은 정리 버튼 없음)으로 둔다.
        // 실행 중인 데몬(cloudd, Apple 서비스)·IDE 가 쓰고 있어 지우면 동기화·색인이 다시 돌거나 상태가 꼬일 수 있다
        rule("caches.cloudkit", .homePath("Library/Caches/CloudKit"), .caches, .caution, .trash),
        rule("caches.apple", .homePath("Library/Caches/com.apple.*"), .caches, .caution, .trash),
        rule("caches.jetbrains", .homePath("Library/Caches/JetBrains"), .caches, .caution, .trash),
        // Android Studio 가 `Google/AndroidStudio<버전>/LocalHistory` 에 로컬 편집 이력을 둔다. 첫 매칭 노드 아래로는
        // 내려가지 않으므로 더 깊은 규칙으로는 못 가른다: Google 폴더 전체를 주의 등급으로 둔다
        // (대신 Chrome 캐시의 원클릭 정리는 잃는다)
        rule("caches.google", .homePath("Library/Caches/Google"), .caches, .caution, .trash),
        // 일반 캐시: 위의 구체적인 캐시 규칙 다음에 둔다
        rule("caches.general", .homePath("Library/Caches/*"), .caches, .regenerable, .trash),
        // 프로젝트 안의 빌드 산출물 (이름 + 옆 표식 파일). 도구는 옆 잠금 파일로 가린다(`nodeModulesTool`).
        // 이름 규칙은 `node_modules`·파이썬 환경 안에서는 태그가 없어도 적용하지 않는다(`Classifier.isOpaqueContainer`):
        // 전역 Node 접두사의 `lib/node_modules/npm/node_modules` 는 npm 이 동봉한 의존성이다
        rule("js.node_modules", .directoryName("node_modules", siblingMarkers: ["package.json"]), .javascript,
             .regenerable, .trash, tool: nodeModulesTool),
        rule("gradle.project.build", .directoryName("build", siblingMarkers: ["build.gradle", "build.gradle.kts"]),
             .gradle, .regenerable, .trash),
        rule("gradle.project.dotgradle", .directoryName(".gradle", siblingMarkers: [
            "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
        ]), .gradle, .regenerable, .trash),
        rule("swiftpm.project.build", .directoryName(".build", siblingMarkers: ["Package.swift"]), .cocoaPodsSwiftPM,
             .regenerable, .trash, tool: "SwiftPM"),
        rule("cocoapods.project.pods", .directoryName("Pods", siblingMarkers: ["Podfile"]), .cocoaPodsSwiftPM,
             .regenerable, .trash, tool: "CocoaPods"),
        rule("rust.project.target", .directoryName("target", siblingMarkers: ["Cargo.toml"]), .rust,
             .regenerable, .trash, tool: "cargo"),
        // venv 는 이름만으로는 잡지 않는다: 자기 안에 pyvenv.cfg 가 있어야 가상 환경이다. 도구는 옆 잠금 파일로 가린다
        rule("python.venv.dot", .directoryName(".venv", siblingMarkers: [], ownMarkers: ["pyvenv.cfg"]), .python,
             .regenerable, .trash, tool: venvTool),
        rule("python.venv", .directoryName("venv", siblingMarkers: [], ownMarkers: ["pyvenv.cfg"]), .python,
             .regenerable, .trash, tool: venvTool),
        rule("python.pycache", .directoryName("__pycache__", siblingMarkers: []), .python, .regenerable, .trash,
             tool: "__pycache__"),
    ]

    private static func rule(
        _ id: String,
        _ matcher: ClassificationRule.Matcher,
        _ category: Category,
        _ level: SafetyLevel,
        _ method: CleanupMethod,
        tool: String
    ) -> ClassificationRule {
        rule(id, matcher, category, level, method, tool: .fixed(tool))
    }

    private static func rule(
        _ id: String,
        _ matcher: ClassificationRule.Matcher,
        _ category: Category,
        _ level: SafetyLevel,
        _ method: CleanupMethod,
        tool: ClassificationRule.ToolLabel? = nil
    ) -> ClassificationRule {
        ClassificationRule(id: id, matcher: matcher, category: category, level: level, method: method, tool: tool)
    }
}
