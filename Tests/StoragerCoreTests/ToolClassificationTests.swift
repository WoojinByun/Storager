import Foundation
import Testing
@testable import StoragerCore

/// 언어별 카테고리와 도구 구분 규칙.
struct ToolClassificationTests {
    /// 홈(`/h`) 아래에 `relatives` 경로마다 디렉터리를 만든다 (마지막 구성 요소가 크기 1).
    func tree(_ relatives: [String]) -> DirectoryNode {
        var home = DirectoryNode(name: "h")
        for relative in relatives {
            insert(relative.split(separator: "/").map(String.init), into: &home)
        }
        return home
    }

    private func insert(_ parts: [String], into node: inout DirectoryNode) {
        guard let first = parts.first else { return }
        let rest = Array(parts.dropFirst())
        if let index = node.children.firstIndex(where: { $0.name == first }) {
            insert(rest, into: &node.children[index])
        } else {
            var child = DirectoryNode(name: first, directAllocatedSize: rest.isEmpty ? 1 : 0)
            insert(rest, into: &child)
            node.children.append(child)
        }
        node.recomputeTotals()
    }

    func classify(_ relatives: [String]) -> [String: CategoryTag] {
        let items = Classifier(homePath: "/h").classify(root: tree(relatives), rootPath: "/h")
        return Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.tag) })
    }

    @Test func homePathRulesMatchWithCategoryToolLevelAndMethod() {
        let conda = CleanupMethod.command("conda clean --all")
        // (경로, 규칙 id, 카테고리, 도구, 등급, 방법)
        let cases: [(String, String, StoragerCore.Category, String, SafetyLevel, CleanupMethod)] = [
            ("miniconda3/pkgs", "python.conda.pkgs.miniconda3", .python, "conda", .regenerable, conda),
            ("anaconda3/pkgs", "python.conda.pkgs.anaconda3", .python, "conda", .regenerable, conda),
            ("miniforge3/pkgs", "python.conda.pkgs.miniforge3", .python, "conda", .regenerable, conda),
            ("mambaforge/pkgs", "python.conda.pkgs.mambaforge", .python, "conda", .regenerable, conda),
            (".conda/pkgs", "python.conda.pkgs..conda", .python, "conda", .regenerable, conda),
            ("miniconda3/envs/ml", "python.conda.envs.miniconda3", .python, "conda", .caution, .trash),
            ("anaconda3/envs/ml", "python.conda.envs.anaconda3", .python, "conda", .caution, .trash),
            ("miniforge3/envs/ml", "python.conda.envs.miniforge3", .python, "conda", .caution, .trash),
            ("mambaforge/envs/ml", "python.conda.envs.mambaforge", .python, "conda", .caution, .trash),
            (".conda/envs/ml", "python.conda.envs..conda", .python, "conda", .caution, .trash),
            (".cache/uv", "python.uv.cache", .python, "uv", .regenerable, .command("uv cache clean")),
            (".local/share/uv/python", "python.uv.python", .python, "uv", .caution, .trash),
            (".local/share/uv/tools", "python.uv.tools", .python, "uv", .caution, .trash),
            ("Library/Caches/pypoetry/cache", "python.poetry.cache", .python, "poetry", .regenerable, .trash),
            ("Library/Caches/pypoetry/artifacts", "python.poetry.artifacts", .python, "poetry", .regenerable, .trash),
            ("Library/Caches/pypoetry/virtualenvs/app-py3.12", "python.poetry.virtualenvs", .python, "poetry",
             .caution, .trash),
            (".pyenv/versions/3.12.1", "python.pyenv.versions", .python, "pyenv", .caution, .trash),
            (".local/pipx/venvs/black", "python.pipx.venvs", .python, "pipx", .caution, .trash),
            (".cache/pip", "python.pip.dotcache", .python, "pip", .regenerable, .trash),
            ("Library/Caches/pip", "python.pip.cache", .python, "pip", .regenerable, .trash),
            ("Library/Caches/pnpm", "js.pnpm.cache", .javascript, "pnpm", .regenerable, .trash),
            ("Library/pnpm/store", "js.pnpm", .javascript, "pnpm", .regenerable, .trash),
            ("Library/Caches/Yarn", "js.yarn", .javascript, "yarn", .regenerable, .trash),
            (".yarn/berry/cache", "js.yarn.berry", .javascript, "yarn", .regenerable, .trash),
            (".bun/install/cache", "js.bun.cache", .javascript, "bun", .regenerable, .trash),
            (".npm/_cacache", "js.npm", .javascript, "npm", .regenerable, .command("npm cache clean --force")),
            (".nvm/versions/node/v20.11.0", "js.nvm.versions", .javascript, "nvm", .caution, .trash),
            (".nvm/.cache", "js.nvm.cache", .javascript, "nvm", .regenerable, .trash),
            (".volta/tools/image", "js.volta.image", .javascript, "volta", .caution, .trash),
            (".local/share/fnm/node-versions/v20.11.0", "js.fnm.versions", .javascript, "fnm", .caution, .trash),
            (".cargo/registry", "rust.cargo.registry", .rust, "cargo", .regenerable, .trash),
            (".cargo/git", "rust.cargo.git", .rust, "cargo", .regenerable, .trash),
            (".rustup/toolchains/stable-aarch64-apple-darwin", "rust.rustup.toolchains", .rust, "rustup", .caution,
             .trash),
            ("go/pkg/mod", "go.pkg.mod", .go, "Go 모듈", .regenerable, .trash),
            ("Library/Caches/go-build", "go.build.cache", .go, "Go 빌드 캐시", .regenerable, .trash),
        ]

        let tags = classify(cases.map(\.0))

        #expect(tags.count == cases.count)
        for (relative, ruleID, category, tool, level, method) in cases {
            let tag = tags["/h/" + relative]
            #expect(tag?.ruleID == ruleID, "\(relative)")
            #expect(tag?.category == category, "\(relative)")
            #expect(tag?.tool == tool, "\(relative)")
            #expect(tag?.level == level, "\(relative)")
            #expect(tag?.method == method, "\(relative)")
        }
    }

    @Test func versionGlobsTagEachVersionNotTheParent() {
        let tags = classify([".nvm/versions/node/v18", ".nvm/versions/node/v20", ".rustup/toolchains/stable",
                             ".pyenv/versions/3.11", ".pyenv/versions/3.12", "miniforge3/envs/a", "miniforge3/envs/b"])

        #expect(Set(tags.keys) == ["/h/.nvm/versions/node/v18", "/h/.nvm/versions/node/v20",
                                   "/h/.rustup/toolchains/stable", "/h/.pyenv/versions/3.11", "/h/.pyenv/versions/3.12",
                                   "/h/miniforge3/envs/a", "/h/miniforge3/envs/b"])
    }

    @Test func pypoetryIsSplitInsteadOfGeneralCache() {
        let tags = classify(["Library/Caches/pypoetry/cache", "Library/Caches/pypoetry/virtualenvs/a-py3.12",
                             "Library/Caches/pypoetry/virtualenvs/b-py3.11", "Library/Caches/pypoetry/unknown",
                             "Library/Caches/other"])

        #expect(tags["/h/Library/Caches/pypoetry"] == nil)
        #expect(tags["/h/Library/Caches/pypoetry/virtualenvs"] == nil)
        #expect(tags["/h/Library/Caches/pypoetry/cache"]?.ruleID == "python.poetry.cache")
        #expect(tags["/h/Library/Caches/pypoetry/virtualenvs/a-py3.12"]?.ruleID == "python.poetry.virtualenvs")
        #expect(tags["/h/Library/Caches/pypoetry/virtualenvs/b-py3.11"]?.ruleID == "python.poetry.virtualenvs")
        // 컨테이너 안에서 규칙에 맞지 않는 항목은 분류하지 않는다 (일반 캐시로도 잡지 않는다)
        #expect(tags["/h/Library/Caches/pypoetry/unknown"] == nil)
        #expect(tags["/h/Library/Caches/other"]?.ruleID == "caches.general")
    }

    @Test func containersOnlyApplyInsideHome() {
        // 홈 밖 추가 루트의 같은 모양 경로는 컨테이너가 아니다 (홈 경로 규칙도 적용되지 않는다)
        let repo = DirectoryNode(name: "repo", children: [
            DirectoryNode(name: "Library", children: [
                DirectoryNode(name: "Caches", children: [
                    DirectoryNode(name: "pypoetry", children: [DirectoryNode(name: "cache", directAllocatedSize: 1)]),
                ]),
            ]),
        ])

        #expect(Classifier(homePath: "/h").classify(root: repo, rootPath: "/Volumes/Work/repo").isEmpty)
    }

    func nodeModulesTool(siblings: Set<String>) -> String? {
        let app = DirectoryNode(name: "app", children: [DirectoryNode(name: "node_modules", directAllocatedSize: 1)],
                                markers: siblings.union(["package.json"]))
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [app])])
        let items = Classifier(homePath: "/h").classify(root: home, rootPath: "/h")
        #expect(items.map(\.path) == ["/h/dev/app/node_modules"])
        #expect(items.first?.tag.ruleID == "js.node_modules")
        return items.first?.tag.tool
    }

    @Test func nodeModulesToolComesFromSiblingLockfile() {
        #expect(nodeModulesTool(siblings: ["pnpm-lock.yaml"]) == "pnpm")
        #expect(nodeModulesTool(siblings: ["yarn.lock"]) == "yarn")
        #expect(nodeModulesTool(siblings: ["bun.lockb"]) == "bun")
        #expect(nodeModulesTool(siblings: ["bun.lock"]) == "bun")
        #expect(nodeModulesTool(siblings: ["package-lock.json"]) == "npm")
        #expect(nodeModulesTool(siblings: []) == "기타")
    }

    @Test func nodeModulesLockfilePriorityWhenSeveralExist() {
        #expect(nodeModulesTool(siblings: ["pnpm-lock.yaml", "yarn.lock", "bun.lockb", "package-lock.json"]) == "pnpm")
        #expect(nodeModulesTool(siblings: ["yarn.lock", "bun.lock", "package-lock.json"]) == "yarn")
        #expect(nodeModulesTool(siblings: ["bun.lockb", "package-lock.json"]) == "bun")
        #expect(nodeModulesTool(siblings: ["pnpm-lock.yaml", "package-lock.json"]) == "pnpm")
    }

    @Test func nodeModulesStillRequiresPackageJson() {
        let app = DirectoryNode(name: "app", children: [DirectoryNode(name: "node_modules", directAllocatedSize: 1)],
                                markers: ["pnpm-lock.yaml"])
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [app])])

        #expect(Classifier(homePath: "/h").classify(root: home, rootPath: "/h").isEmpty)
    }

    func venvTool(_ name: String, siblings: Set<String>) -> String? {
        let venv = DirectoryNode(name: name, directAllocatedSize: 1, markers: ["pyvenv.cfg"])
        let app = DirectoryNode(name: "app", children: [venv], markers: siblings)
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [app])])
        let items = Classifier(homePath: "/h").classify(root: home, rootPath: "/h")
        #expect(items.count == 1)
        #expect(items.first?.tag.category == .python)
        return items.first?.tag.tool
    }

    @Test func venvToolComesFromSiblingLockfile() {
        for name in [".venv", "venv"] {
            #expect(venvTool(name, siblings: ["uv.lock"]) == "uv", "\(name)")
            #expect(venvTool(name, siblings: ["poetry.lock"]) == "poetry", "\(name)")
            #expect(venvTool(name, siblings: []) == "venv", "\(name)")
            // 둘 다 있으면 uv 가 이긴다
            #expect(venvTool(name, siblings: ["poetry.lock", "uv.lock"]) == "uv", "\(name)")
        }
    }

    @Test func venvWithLockfileStillNeedsPyvenvCfg() {
        let app = DirectoryNode(name: "app", children: [DirectoryNode(name: ".venv", directAllocatedSize: 1)],
                                markers: ["uv.lock"])
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [app])])

        #expect(Classifier(homePath: "/h").classify(root: home, rootPath: "/h").isEmpty)
    }

    @Test func lockfileRulesStayBlockedInsideBundlesLibraryAndHiddenFolders() {
        func app(_ name: String) -> DirectoryNode {
            DirectoryNode(name: name, children: [
                DirectoryNode(name: "node_modules", directAllocatedSize: 1),
                DirectoryNode(name: ".venv", directAllocatedSize: 1, markers: ["pyvenv.cfg"]),
            ], markers: ["package.json", "pnpm-lock.yaml", "uv.lock"])
        }
        let home = DirectoryNode(name: "h", children: [
            DirectoryNode(name: "Library", children: [DirectoryNode(name: "Application Support", children: [app("a")])]),
            DirectoryNode(name: ".config", children: [app("b")]),
            DirectoryNode(name: "Applications", children: [app("c")]),
            DirectoryNode(name: "dev", children: [DirectoryNode(name: "Tool.app", children: [app("d")])]),
        ])

        #expect(Classifier(homePath: "/h").classify(root: home, rootPath: "/h").isEmpty)
    }

    @Test func projectRulesCarryTools() {
        let crate = DirectoryNode(name: "crate", children: [
            DirectoryNode(name: "target", directAllocatedSize: 1),
            DirectoryNode(name: "__pycache__", directAllocatedSize: 1),
        ], markers: ["Cargo.toml"])
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [crate])])
        let tags = Dictionary(uniqueKeysWithValues: Classifier(homePath: "/h").classify(root: home, rootPath: "/h")
            .map { ($0.path, $0.tag) })

        #expect(tags["/h/dev/crate/target"]?.category == .rust)
        #expect(tags["/h/dev/crate/target"]?.tool == "cargo")
        #expect(tags["/h/dev/crate/__pycache__"]?.category == .python)
        #expect(tags["/h/dev/crate/__pycache__"]?.tool == "__pycache__")
    }

    @Test func scannedLockfilesReachTheClassifier() async throws {
        // 실제 스캔: 작은 잠금 파일도 표식으로 남아 도구가 갈린다
        let tree = try TempTree()
        try tree.file("web/package.json", bytes: 2)
        try tree.file("web/pnpm-lock.yaml", bytes: 2)
        try tree.file("web/node_modules/x/a.js", bytes: 10)
        try tree.file("api/package.json", bytes: 2)
        try tree.file("api/package-lock.json", bytes: 2)
        try tree.file("api/node_modules/x/a.js", bytes: 10)
        try tree.file("py/poetry.lock", bytes: 2)
        try tree.file("py/.venv/pyvenv.cfg", bytes: 2)

        let root = try await TreeScanner(rootPath: tree.path).scan().root
        let items = Classifier(homePath: "/nonexistent-home").classify(root: root, rootPath: tree.path)
        let tools = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.tag.tool) })

        #expect(tools == [tree.path + "/web/node_modules": "pnpm", tree.path + "/api/node_modules": "npm",
                          tree.path + "/py/.venv": "poetry"])
    }

    /// 모노레포: 잠금 파일은 워크스페이스 루트에만 있고 패키지마다 package.json 과 node_modules 가 있다.
    func workspaceTools(rootLockfile: String) -> [String: String?] {
        func package(_ name: String) -> DirectoryNode {
            DirectoryNode(name: name, children: [DirectoryNode(name: "node_modules", directAllocatedSize: 1)],
                          markers: ["package.json"])
        }
        let repo = DirectoryNode(name: "repo", children: [
            DirectoryNode(name: "node_modules", directAllocatedSize: 1),
            DirectoryNode(name: "packages", children: [package("foo"), package("bar")]),
            DirectoryNode(name: "apps", children: [
                // 안쪽 잠금 파일이 있으면 그 패키지는 자기 잠금 파일을 따른다
                DirectoryNode(name: "web", children: [DirectoryNode(name: "node_modules", directAllocatedSize: 1)],
                              markers: ["package.json", "bun.lock"]),
                DirectoryNode(name: "deep", children: [package("pkg")]),
            ]),
        ], markers: ["package.json", rootLockfile])
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [repo])])
        let items = Classifier(homePath: "/h").classify(root: home, rootPath: "/h")
        return Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.tag.tool) })
    }

    @Test func workspacePackagesInheritRootLockfile() {
        for (lockfile, tool) in [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("package-lock.json", "npm")] {
            let tools = workspaceTools(rootLockfile: lockfile)
            #expect(tools == [
                "/h/dev/repo/node_modules": tool,
                "/h/dev/repo/packages/foo/node_modules": tool,
                "/h/dev/repo/packages/bar/node_modules": tool,
                "/h/dev/repo/apps/deep/pkg/node_modules": tool,
                "/h/dev/repo/apps/web/node_modules": "bun",
            ], "\(lockfile)")
        }
    }

    @Test func inheritedLockfileDoesNotLeakToSiblingsOrOtherLanguages() {
        let workspace = DirectoryNode(name: "ws", children: [
            DirectoryNode(name: "a", children: [DirectoryNode(name: "node_modules", directAllocatedSize: 1)],
                          markers: ["package.json"]),
        ], markers: ["package.json", "pnpm-lock.yaml"])
        let loose = DirectoryNode(name: "loose", children: [DirectoryNode(name: "node_modules", directAllocatedSize: 1)],
                                  markers: ["package.json"])
        // JS 잠금 파일은 venv 도구에 영향이 없다
        let mixed = DirectoryNode(name: "mixed", children: [
            DirectoryNode(name: ".venv", directAllocatedSize: 1, markers: ["pyvenv.cfg"]),
        ], markers: ["pnpm-lock.yaml"])
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [workspace, loose, mixed])])
        let tools = Dictionary(uniqueKeysWithValues: Classifier(homePath: "/h").classify(root: home, rootPath: "/h")
            .map { ($0.path, $0.tag.tool) })

        #expect(tools == ["/h/dev/ws/a/node_modules": "pnpm", "/h/dev/loose/node_modules": "기타",
                          "/h/dev/mixed/.venv": "venv"])
    }

    @Test func uvWorkspaceMembersInheritRootLockfile() {
        func member(_ name: String, markers: Set<String> = []) -> DirectoryNode {
            DirectoryNode(name: name, children: [DirectoryNode(name: ".venv", directAllocatedSize: 1,
                                                               markers: ["pyvenv.cfg"])],
                          markers: markers.union(["pyproject.toml"]))
        }
        let repo = DirectoryNode(name: "repo", children: [
            DirectoryNode(name: ".venv", directAllocatedSize: 1, markers: ["pyvenv.cfg"]),
            DirectoryNode(name: "packages", children: [member("core"), member("legacy", markers: ["poetry.lock"])]),
        ], markers: ["uv.lock", "pyproject.toml"])
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [repo])])
        let tools = Dictionary(uniqueKeysWithValues: Classifier(homePath: "/h").classify(root: home, rootPath: "/h")
            .map { ($0.path, $0.tag.tool) })

        #expect(tools == ["/h/dev/repo/.venv": "uv", "/h/dev/repo/packages/core/.venv": "uv",
                          "/h/dev/repo/packages/legacy/.venv": "poetry"])
    }

    func tools(_ home: DirectoryNode, rootPath: String = "/h") -> [String: String?] {
        Dictionary(uniqueKeysWithValues: Classifier(homePath: "/h").classify(root: home, rootPath: rootPath)
            .map { ($0.path, $0.tag.tool) })
    }

    func jsProject(_ name: String, markers: Set<String> = []) -> DirectoryNode {
        DirectoryNode(name: name, children: [DirectoryNode(name: "node_modules", directAllocatedSize: 1)],
                      markers: markers.union(["package.json"]))
    }

    @Test func strayLockfileInHomeIsNotInherited() {
        // 홈에서 실수로 `npm install` 하면 package.json 과 package-lock.json 이 함께 남는다
        let home = DirectoryNode(name: "h", children: [
            DirectoryNode(name: "node_modules", directAllocatedSize: 1),
            DirectoryNode(name: "dev", children: [jsProject("web")]),
            jsProject("app"),
        ], markers: ["package.json", "package-lock.json"])

        // 홈 바로 아래 node_modules 는 옆 잠금 파일이라 npm, 그 밖의 프로젝트는 물려받지 않는다
        #expect(tools(home) == ["/h/node_modules": "npm", "/h/dev/web/node_modules": "기타",
                                "/h/app/node_modules": "기타"])
    }

    @Test func homeIsNotInheritedEvenWhenClassifiedFromAnAncestorRoot() {
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [jsProject("web")])],
                                 markers: ["package.json", "pnpm-lock.yaml"])
        let slash = DirectoryNode(name: "", children: [home])

        #expect(tools(slash, rootPath: "/") == ["/h/dev/web/node_modules": "기타"])
    }

    @Test func lockfileWithoutPackageJsonIsNotInherited() {
        // ~/dev 에 잠금 파일만 남은 경우: 프로젝트 루트가 아니므로 아래 프로젝트에 물려주지 않는다
        let dev = DirectoryNode(name: "dev", children: [jsProject("a"), jsProject("b", markers: ["yarn.lock"])],
                                markers: ["package-lock.json"])
        let home = DirectoryNode(name: "h", children: [dev])

        #expect(tools(home) == ["/h/dev/a/node_modules": "기타", "/h/dev/b/node_modules": "yarn"])
    }

    @Test func pythonLockfileNeedsPyprojectToBeInherited() {
        func member(_ name: String) -> DirectoryNode {
            DirectoryNode(name: name, children: [DirectoryNode(name: ".venv", directAllocatedSize: 1,
                                                               markers: ["pyvenv.cfg"])],
                          markers: ["pyproject.toml"])
        }
        let stray = DirectoryNode(name: "stray", children: [member("m")], markers: ["uv.lock"])
        let poetryRoot = DirectoryNode(name: "mono", children: [member("m")], markers: ["poetry.lock", "pyproject.toml"])
        // JS 프로젝트 루트(package.json)는 Python 잠금 파일을 물려줄 수 없다
        let jsRoot = DirectoryNode(name: "js", children: [member("m")], markers: ["uv.lock", "package.json"])
        let home = DirectoryNode(name: "h", children: [
            DirectoryNode(name: "dev", children: [stray, poetryRoot, jsRoot]),
            member("top"),
        ], markers: ["uv.lock", "pyproject.toml"])

        #expect(tools(home) == ["/h/dev/stray/m/.venv": "venv", "/h/dev/mono/m/.venv": "poetry",
                                "/h/dev/js/m/.venv": "venv", "/h/top/.venv": "venv"])
    }

    @Test func siblingLockfileDoesNotLabelTheNextSibling() {
        // 앞 형제 폴더의 잠금 파일(프로젝트 루트)을 순회한 뒤 상속 도구가 되돌려져야 한다
        let first = DirectoryNode(name: "a-first", children: [jsProject("pkg")],
                                  markers: ["package.json", "pnpm-lock.yaml"])
        let second = DirectoryNode(name: "b-second", children: [DirectoryNode(name: "node_modules",
                                                                              directAllocatedSize: 1)],
                                   markers: ["package.json"])
        let third = DirectoryNode(name: "c-third", children: [jsProject("pkg")])
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [first, second, third])])
        // 크기가 같아 이름순으로 정렬되므로 잠금 파일이 있는 형제를 먼저 순회한다
        #expect(home.children[0].children.map(\.name) == ["a-first", "b-second", "c-third"])

        #expect(tools(home) == ["/h/dev/a-first/pkg/node_modules": "pnpm", "/h/dev/b-second/node_modules": "기타",
                                "/h/dev/c-third/pkg/node_modules": "기타"])
    }

    @Test func depthBucketsMatchTheLinearScan() {
        // 홈 경로 규칙 깊이 1~5, 이름 규칙, 컨테이너, 번들·Library·숨김 차단이 섞인 트리
        var home = tree([
            ".codex/sessions", ".cursor", ".claude/projects/x", ".gradle/caches", ".gradle/wrapper",
            "Library/Caches/Homebrew", "Library/Caches/com.apple.x", "Library/Caches/pnpm", "Library/Caches/other",
            "Library/Caches/pypoetry/cache", "Library/Caches/pypoetry/virtualenvs/v1", "Library/Logs/App",
            "Library/Developer/Xcode/DerivedData", "Library/Developer/CoreSimulator/Caches/dyld",
            "Library/Mail", "Library/pnpm/store", "go/pkg/mod", "miniconda3/envs/a", "miniconda3/pkgs",
            ".local/share/fnm/node-versions/v1", ".nvm/versions/node/v1", "Pictures/A.photoslibrary",
            "dev/a/b/c/d/e/f/__pycache__", "dev/Tool.app/Contents/__pycache__", "Applications/x/__pycache__",
        ])
        home.children.append(DirectoryNode(name: "proj", children: [
            DirectoryNode(name: "node_modules", directAllocatedSize: 1),
            DirectoryNode(name: "build", directAllocatedSize: 1),
            DirectoryNode(name: "target", directAllocatedSize: 1),
            DirectoryNode(name: "venv", directAllocatedSize: 1, markers: ["pyvenv.cfg"]),
            DirectoryNode(name: "deep", children: [DirectoryNode(name: "x", children: [
                DirectoryNode(name: "y", children: [DirectoryNode(name: ".build", directAllocatedSize: 1)],
                              markers: ["Package.swift"]),
            ])]),
        ], markers: ["package.json", "build.gradle", "Cargo.toml", "yarn.lock"]))
        home.recomputeTotals()
        let extra = DirectoryNode(name: "repo", children: [
            DirectoryNode(name: "Library", children: [DirectoryNode(name: "Caches", children: [
                DirectoryNode(name: "Homebrew", directAllocatedSize: 1)])]),
            DirectoryNode(name: "Pods", directAllocatedSize: 1),
        ], markers: ["Podfile"])

        let bucketed = Classifier(homePath: "/h")
        var linear = Classifier(homePath: "/h")
        linear.usesLinearMatching = true

        let fast = bucketed.classify(root: home, rootPath: "/h")
        #expect(fast.count > 20)
        #expect(Set(fast) == Set(linear.classify(root: home, rootPath: "/h")))
        #expect(Set(bucketed.classify(root: extra, rootPath: "/Volumes/W/repo"))
            == Set(linear.classify(root: extra, rootPath: "/Volumes/W/repo")))
        let wrapped = DirectoryNode(name: "", children: [home])
        #expect(Set(bucketed.classify(root: wrapped, rootPath: "/"))
            == Set(linear.classify(root: wrapped, rootPath: "/")))
    }

    @Test func toolLabelResolvesFirstMatchingCandidate() {
        let label = ClassificationRule.ToolLabel.bySiblingMarker([.init(["a"], "A"), .init(["b", "c"], "BC")],
                                                                 fallback: "other")
        #expect(label.resolve(parentMarkers: ["c", "a"]) == "A")
        #expect(label.resolve(parentMarkers: ["c"]) == "BC")
        #expect(label.resolve(parentMarkers: ["z"]) == "other")
        #expect(label.markerFileNames == ["a", "b", "c"])
        #expect(ClassificationRule.ToolLabel.fixed("x").resolve(parentMarkers: ["a"]) == "x")
    }

    @Test func everyLanguageRuleHasATool() {
        for rule in RuleCatalog.default where [.python, .rust, .go, .javascript].contains(rule.category) {
            #expect(rule.tool != nil, "\(rule.id)")
        }
    }

    @Test func toolLabelMarkersAreRecordedByTheScanner() {
        for rule in RuleCatalog.default {
            guard let tool = rule.tool else { continue }
            #expect(tool.markerFileNames.isSubset(of: ScanOptions.defaultMarkerFileNames), "\(rule.id)")
        }
    }

    @Test func newLibraryCachesRulesComeBeforeGeneralCaches() throws {
        let ids = RuleCatalog.default.map(\.id)
        let general = try #require(ids.firstIndex(of: "caches.general"))
        for id in ["js.pnpm.cache", "go.build.cache", "python.poetry.cache", "python.poetry.artifacts",
                   "python.poetry.virtualenvs"] {
            let index = try #require(ids.firstIndex(of: id), "\(id)")
            #expect(index < general, "\(id)")
        }
    }
}
