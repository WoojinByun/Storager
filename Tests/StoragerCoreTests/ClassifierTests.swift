import Foundation
import Testing
@testable import StoragerCore

struct ClassificationRuleTests {
    func rule(_ matcher: ClassificationRule.Matcher) -> ClassificationRule {
        ClassificationRule(id: "t", matcher: matcher, category: .caches, level: .regenerable, method: .trash)
    }

    @Test func homePathGlobMatchesComponentWise() {
        let r = rule(.homePath("Library/Caches/*"))
        #expect(r.matches(name: "com.foo", homeRelative: ["Library", "Caches", "com.foo"], parentMarkers: []))
        #expect(r.matches(name: "Caches", homeRelative: ["Library", "Caches"], parentMarkers: []) == false)
        #expect(r.matches(name: "x", homeRelative: ["Library", "Caches", "com.foo", "x"], parentMarkers: []) == false)
        #expect(r.matches(name: "com.foo", homeRelative: nil, parentMarkers: []) == false)
    }

    @Test func homePathWithSpacesMatchesExactly() {
        let r = rule(.homePath("Library/Developer/Xcode/iOS DeviceSupport"))
        #expect(r.matches(name: "iOS DeviceSupport",
                          homeRelative: ["Library", "Developer", "Xcode", "iOS DeviceSupport"], parentMarkers: []))
    }

    @Test func directoryNameRequiresSiblingMarker() {
        let r = rule(.directoryName("node_modules", siblingMarkers: ["package.json"]))
        #expect(r.matches(name: "node_modules", homeRelative: ["dev", "app", "node_modules"], parentMarkers: ["package.json"]))
        #expect(r.matches(name: "node_modules", homeRelative: ["dev", "app", "node_modules"], parentMarkers: []) == false)
        // 홈 밖(추가 프로젝트 루트)에서도 이름 규칙은 동작한다
        #expect(r.matches(name: "node_modules", homeRelative: nil, parentMarkers: ["package.json"]))
    }

    @Test func directoryNameIsIgnoredUnderLibraryAndHiddenHomeDirectories() {
        let r = rule(.directoryName("node_modules", siblingMarkers: ["package.json"]))
        #expect(r.matches(name: "node_modules", homeRelative: ["Library", "App", "node_modules"],
                          parentMarkers: ["package.json"]) == false)
        #expect(r.matches(name: "node_modules", homeRelative: [".vscode", "extensions", "x", "node_modules"],
                          parentMarkers: ["package.json"]) == false)
    }

    @Test func directoryNameIsIgnoredUnderHomeApplications() {
        let r = rule(.directoryName("node_modules", siblingMarkers: ["package.json"]))
        #expect(r.matches(name: "node_modules", homeRelative: ["Applications", "tool", "node_modules"],
                          parentMarkers: ["package.json"]) == false)
    }

    @Test func directoryNameCanRequireOwnMarker() {
        let r = rule(.directoryName("venv", siblingMarkers: [], ownMarkers: ["pyvenv.cfg"]))
        #expect(r.matches(name: "venv", homeRelative: ["dev", "app", "venv"], parentMarkers: [],
                          ownMarkers: ["pyvenv.cfg"]))
        #expect(r.matches(name: "venv", homeRelative: ["dev", "app", "venv"], parentMarkers: ["pyvenv.cfg"]) == false)
        #expect(r.matches(name: "venv", homeRelative: nil, parentMarkers: [], ownMarkers: []) == false)
    }

    @Test func homePathLiteralAndGlobComponentsMixed() {
        let r = rule(.homePath("Library/Caches/com.apple.*"))
        #expect(r.matches(name: "com.apple.Safari", homeRelative: ["Library", "Caches", "com.apple.Safari"],
                          parentMarkers: []))
        #expect(r.matches(name: "com.google.x", homeRelative: ["Library", "Caches", "com.google.x"],
                          parentMarkers: []) == false)
        #expect(r.matches(name: "com.apple.x", homeRelative: ["Library", "caches", "com.apple.x"],
                          parentMarkers: []) == false)
    }

    @Test func directoryNameSupportsGlob() {
        let r = rule(.directoryName("*.photoslibrary", siblingMarkers: []))
        #expect(r.matches(name: "Photos Library.photoslibrary", homeRelative: ["Pictures", "Photos Library.photoslibrary"],
                          parentMarkers: []))
    }
}

struct RuleCatalogTests {
    @Test func ruleIDsAreUnique() {
        let ids = RuleCatalog.default.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyMarkerIsRecordedByTheScanner() {
        for rule in RuleCatalog.default {
            if case .directoryName(_, let siblingMarkers, let ownMarkers) = rule.matcher {
                #expect(siblingMarkers.isSubset(of: ScanOptions.defaultMarkerFileNames), "\(rule.id)")
                #expect(ownMarkers.isSubset(of: ScanOptions.defaultMarkerFileNames), "\(rule.id)")
            }
        }
    }

    @Test func specificRulesComeBeforeGeneralOnes() throws {
        let ids = RuleCatalog.default.map(\.id)
        let general = try #require(ids.firstIndex(of: "caches.general"))
        for id in ["js.yarn", "cocoapods.cache", "swiftpm.cache", "homebrew.cache", "python.pip.cache",
                   "caches.cloudkit", "caches.apple", "caches.jetbrains", "caches.google"] {
            let index = try #require(ids.firstIndex(of: id), "\(id)")
            #expect(index < general, "\(id)")
        }
    }

    @Test func pythonVirtualEnvironmentsRequireTheirOwnMarker() throws {
        for id in ["python.venv", "python.venv.dot"] {
            let rule = try #require(RuleCatalog.default.first { $0.id == id })
            guard case .directoryName(_, _, let ownMarkers) = rule.matcher else {
                Issue.record("\(id) 는 이름 규칙이어야 한다")
                continue
            }
            #expect(ownMarkers == ["pyvenv.cfg"], "\(id)")
        }
    }

    @Test func specificCachesWinOverGeneralCaches() {
        let classifier = Classifier(homePath: "/h")
        let tree = DirectoryNode(name: "h", children: [
            DirectoryNode(name: "Library", children: [
                DirectoryNode(name: "Caches", children: [
                    DirectoryNode(name: "Homebrew", directAllocatedSize: 10),
                    DirectoryNode(name: "com.apple.x", directAllocatedSize: 20),
                    DirectoryNode(name: "CloudKit", directAllocatedSize: 30),
                    DirectoryNode(name: "JetBrains", directAllocatedSize: 40),
                    DirectoryNode(name: "Google", directAllocatedSize: 60),
                    DirectoryNode(name: "com.example.app", directAllocatedSize: 50),
                ]),
            ]),
        ])

        let items = classifier.classify(root: tree, rootPath: "/h")
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.tag) })

        #expect(byPath["/h/Library/Caches/Homebrew"]?.ruleID == "homebrew.cache")
        #expect(byPath["/h/Library/Caches/com.example.app"]?.ruleID == "caches.general")
        #expect(byPath["/h/Library/Caches/com.example.app"]?.isTrashCleanable == true)
        // 시스템·데몬 캐시는 주의 등급이라 v0.1 에서는 정리 버튼이 없다
        for (name, ruleID) in [("com.apple.x", "caches.apple"), ("CloudKit", "caches.cloudkit"),
                               ("JetBrains", "caches.jetbrains"), ("Google", "caches.google")] {
            let tag = byPath["/h/Library/Caches/\(name)"]
            #expect(tag?.ruleID == ruleID, "\(name)")
            #expect(tag?.category == .caches, "\(name)")
            #expect(tag?.level == .caution, "\(name)")
            #expect(tag?.isTrashCleanable == false, "\(name)")
        }
    }

    @Test func logsAreTaggedPerChildNotAsTheWholeFolder() {
        let tree = DirectoryNode(name: "h", children: [
            DirectoryNode(name: "Library", children: [
                DirectoryNode(name: "Logs", directAllocatedSize: 1, children: [
                    DirectoryNode(name: "DiagnosticReports", directAllocatedSize: 10),
                    DirectoryNode(name: "com.example.app", directAllocatedSize: 20),
                ]),
            ]),
        ])

        let items = Classifier(homePath: "/h").classify(root: tree, rootPath: "/h")

        #expect(Set(items.map(\.path)) == ["/h/Library/Logs/DiagnosticReports", "/h/Library/Logs/com.example.app"])
        #expect(items.allSatisfy { $0.tag.ruleID == "logs" && $0.tag.category == .logs })
    }
}

struct ClassifierTests {
    func project(_ name: String, markers: Set<String>, children: [DirectoryNode]) -> DirectoryNode {
        DirectoryNode(name: name, children: children, markers: markers)
    }

    @Test func tagsMatchedNodesAndDoesNotDescendIntoThem() {
        let nested = DirectoryNode(name: "node_modules", directAllocatedSize: 5)
        let dep = DirectoryNode(name: "dep", children: [nested], markers: ["package.json"])
        let modules = DirectoryNode(name: "node_modules", directAllocatedSize: 100, children: [dep])
        let app = project("app", markers: ["package.json"], children: [modules])
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [app])])

        let items = Classifier(homePath: "/h").classify(root: home, rootPath: "/h")

        #expect(items.map(\.path) == ["/h/dev/app/node_modules"])
        #expect(items.first?.allocatedSize == 105)
        #expect(items.first?.tag.category == .javascript)
        #expect(items.first?.tag.isTrashCleanable == true)
    }

    @Test func classifiesExtraProjectRootsByNameOnly() {
        let build = DirectoryNode(name: "build", directAllocatedSize: 7)
        let repo = DirectoryNode(name: "repo", children: [build], markers: ["build.gradle.kts"])

        let items = Classifier(homePath: "/Users/me").classify(root: repo, rootPath: "/Volumes/Work/repo")

        #expect(items.map(\.path) == ["/Volumes/Work/repo/build"])
        #expect(items.first?.tag.ruleID == "gradle.project.build")
    }

    @Test func nameRulesDoNotApplyInsideBundles() {
        func bundled(_ bundle: String) -> DirectoryNode {
            DirectoryNode(name: bundle, children: [
                DirectoryNode(name: "Contents", children: [
                    DirectoryNode(name: "Resources", children: [
                        DirectoryNode(name: "app", children: [DirectoryNode(name: "node_modules", directAllocatedSize: 9)],
                                      markers: ["package.json"]),
                    ]),
                ]),
            ])
        }
        let bundles = ["Code.app", "Kit.framework", "Res.bundle", "Ext.appex", "Helper.xpc", "Thing.plugin",
                       "Driver.kext", "Pane.prefPane", "Look.qlgenerator", "Saver.saver"]
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: bundles.map(bundled))])
        let extra = DirectoryNode(name: "repo", children: bundles.map(bundled))

        let classifier = Classifier(homePath: "/h")

        #expect(classifier.classify(root: home, rootPath: "/h").isEmpty)
        // 추가 프로젝트 루트에도 번들 차단을 똑같이 적용한다
        #expect(classifier.classify(root: extra, rootPath: "/Volumes/Work/repo").isEmpty)
    }

    /// 전역 Node 접두사(n, nvm 없이 푼 node-v22…, emsdk, Homebrew)의 `lib/node_modules` 는 옆에 package.json 이 없어
    /// 태그되지 않는다. 그 안의 `npm/node_modules` 는 npm 이 동봉한 의존성이라 이름 규칙을 적용하면 안 된다.
    func globalNodePrefix(_ name: String) -> DirectoryNode {
        let bundledDeps = DirectoryNode(name: "node_modules", directAllocatedSize: 9, children: [
            DirectoryNode(name: "semver", children: [DirectoryNode(name: "node_modules", directAllocatedSize: 1)],
                          markers: ["package.json"]),
        ])
        let npm = DirectoryNode(name: "npm", children: [bundledDeps], markers: ["package.json"])
        let corepack = DirectoryNode(name: "corepack", children: [
            DirectoryNode(name: "build", directAllocatedSize: 3),
            DirectoryNode(name: ".venv", directAllocatedSize: 3, markers: ["pyvenv.cfg"]),
        ], markers: ["package.json", "build.gradle"])
        return DirectoryNode(name: name, children: [
            DirectoryNode(name: "lib", children: [DirectoryNode(name: "node_modules", children: [npm, corepack])]),
        ])
    }

    @Test func nameRulesDoNotApplyInsideUntaggedNodeModulesUnderHome() {
        let home = DirectoryNode(name: "h", children: [globalNodePrefix("n"), globalNodePrefix("node-v22.11.0-darwin-arm64")])

        #expect(Classifier(homePath: "/h").classify(root: home, rootPath: "/h").isEmpty)
    }

    @Test func nameRulesDoNotApplyInsideUntaggedNodeModulesUnderExtraRoots() {
        let classifier = Classifier(homePath: "/Users/me")

        #expect(classifier.classify(root: globalNodePrefix("homebrew"), rootPath: "/opt/homebrew").isEmpty)
        #expect(classifier.classify(root: globalNodePrefix("local"), rootPath: "/usr/local").isEmpty)
    }

    @Test func nestedNodeModulesInsideProjectNodeModulesIsCoveredByParent() {
        let nested = DirectoryNode(name: "node_modules", directAllocatedSize: 4)
        let dep = DirectoryNode(name: "dep", children: [nested, DirectoryNode(name: "build", directAllocatedSize: 2)],
                                markers: ["package.json", "build.gradle"])
        let modules = DirectoryNode(name: "node_modules", directAllocatedSize: 10, children: [dep])
        let app = project("app", markers: ["package.json"], children: [modules])
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [app])])
        let extra = DirectoryNode(name: "repo", children: [app])

        let classifier = Classifier(homePath: "/h")
        let homeItems = classifier.classify(root: home, rootPath: "/h")
        let extraItems = classifier.classify(root: extra, rootPath: "/Volumes/Work/repo")

        #expect(homeItems.map(\.path) == ["/h/dev/app/node_modules"])
        #expect(homeItems.first?.allocatedSize == 16)
        #expect(homeItems.first?.tag.ruleID == "js.node_modules")
        #expect(extraItems.map(\.path) == ["/Volumes/Work/repo/app/node_modules"])
    }

    @Test func nameRulesDoNotApplyInsidePythonEnvironments() {
        // 이름이 venv/.venv 가 아닌 가상 환경(pyvenv.cfg 있음)과 conda·Homebrew 의 site-packages
        func sitePackages() -> DirectoryNode {
            DirectoryNode(name: "site-packages", children: [
                DirectoryNode(name: "pkg", children: [
                    DirectoryNode(name: "target", directAllocatedSize: 2),
                    DirectoryNode(name: ".venv", directAllocatedSize: 2, markers: ["pyvenv.cfg"]),
                    DirectoryNode(name: "node_modules", directAllocatedSize: 2),
                ], markers: ["Cargo.toml", "package.json"]),
            ])
        }
        let env = DirectoryNode(name: "env", children: [
            DirectoryNode(name: "lib", children: [DirectoryNode(name: "python3.12", children: [sitePackages()])]),
            DirectoryNode(name: "share", children: [
                DirectoryNode(name: "tool", children: [DirectoryNode(name: "build", directAllocatedSize: 1)],
                              markers: ["build.gradle"]),
            ]),
        ], markers: ["pyvenv.cfg"])
        let conda = DirectoryNode(name: "miniconda3", children: [
            DirectoryNode(name: "lib", children: [DirectoryNode(name: "python3.12", children: [sitePackages()])]),
        ])
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [env]), conda])

        let classifier = Classifier(homePath: "/h")

        #expect(classifier.classify(root: home, rootPath: "/h").isEmpty)
        #expect(classifier.classify(root: sitePackages(), rootPath: "/opt/homebrew/lib/python3.12/site-packages")
            .isEmpty)
    }

    @Test func topLevelProjectNodeModulesAndVenvStillTagged() {
        let app = project("app", markers: ["package.json", "Cargo.toml"], children: [
            DirectoryNode(name: "node_modules", directAllocatedSize: 3),
            DirectoryNode(name: ".venv", directAllocatedSize: 3, markers: ["pyvenv.cfg"]),
            DirectoryNode(name: "target", directAllocatedSize: 3),
        ])
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "dev", children: [app])])

        let items = Classifier(homePath: "/h").classify(root: home, rootPath: "/h")

        #expect(Set(items.map(\.tag.ruleID)) == ["js.node_modules", "python.venv.dot", "rust.project.target"])
    }

    @Test func nameRulesDoNotApplyUnderHomeApplications() {
        let app = DirectoryNode(name: "Visual Studio Code.app", children: [
            DirectoryNode(name: "Contents", children: [
                DirectoryNode(name: "Resources", children: [
                    DirectoryNode(name: "app", children: [DirectoryNode(name: "node_modules", directAllocatedSize: 9)],
                                  markers: ["package.json"]),
                ]),
            ]),
        ])
        let tool = project("tool", markers: ["package.json"], children: [DirectoryNode(name: "node_modules")])
        let home = DirectoryNode(name: "h", children: [DirectoryNode(name: "Applications", children: [app, tool])])

        #expect(Classifier(homePath: "/h").classify(root: home, rootPath: "/h").isEmpty)
    }

    @Test func nameRulesDoNotApplyUnderLibraryOrHiddenHomeDirectories() {
        func app(_ name: String) -> DirectoryNode {
            project(name, markers: ["package.json"], children: [DirectoryNode(name: "node_modules")])
        }
        let home = DirectoryNode(name: "h", children: [
            DirectoryNode(name: "Library", children: [DirectoryNode(name: "Application Support", children: [app("x")])]),
            DirectoryNode(name: ".vscode", children: [DirectoryNode(name: "extensions", children: [app("y")])]),
            DirectoryNode(name: "dev", children: [app("z")]),
        ])

        let items = Classifier(homePath: "/h").classify(root: home, rootPath: "/h")

        #expect(items.map(\.path) == ["/h/dev/z/node_modules"])
    }

    @Test func virtualEnvironmentsNeedPyvenvCfg() {
        let withCfg = DirectoryNode(name: ".venv", directAllocatedSize: 5, markers: ["pyvenv.cfg"])
        let plainVenv = DirectoryNode(name: "venv", directAllocatedSize: 5)
        let realVenv = DirectoryNode(name: "venv", directAllocatedSize: 5, markers: ["pyvenv.cfg"])
        let home = DirectoryNode(name: "h", children: [
            DirectoryNode(name: "dev", children: [
                DirectoryNode(name: "a", children: [withCfg]),
                DirectoryNode(name: "notes", children: [plainVenv]),
                DirectoryNode(name: "b", children: [realVenv]),
                DirectoryNode(name: "c", children: [DirectoryNode(name: ".venv")]),
            ]),
        ])

        let items = Classifier(homePath: "/h").classify(root: home, rootPath: "/h")
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.tag.ruleID) })

        #expect(byPath == ["/h/dev/a/.venv": "python.venv.dot", "/h/dev/b/venv": "python.venv"])
    }

    @Test func homePathRulesUseResolvedHomePath() {
        // /var 는 /private/var 의 심볼릭 링크다. 스캐너 루트는 realpath 표기라 홈도 같게 풀어야 규칙이 켜진다
        let tree = DirectoryNode(name: "h", children: [
            DirectoryNode(name: "Library", children: [
                DirectoryNode(name: "App", children: [DirectoryNode(name: "node_modules")], markers: ["package.json"]),
                DirectoryNode(name: "Caches", children: [DirectoryNode(name: "Homebrew", directAllocatedSize: 3)]),
            ]),
        ])

        let items = Classifier(homePath: "/var/h").classify(root: tree, rootPath: "/private/var/h")

        #expect(items.map(\.path) == ["/private/var/h/Library/Caches/Homebrew"])
        #expect(items.first?.tag.ruleID == "homebrew.cache")
    }

    @Test func extraRootAboveHomeSwitchesToHomeRulesAtHome() {
        // 추가 루트가 /Users 나 / 처럼 홈의 조상이어도 홈 아래는 홈 루트로 분류할 때와 같아야 한다
        func homeTree() -> DirectoryNode {
            DirectoryNode(name: "me", children: [
                DirectoryNode(name: "Library", children: [
                    DirectoryNode(name: "Caches", children: [DirectoryNode(name: "Homebrew", directAllocatedSize: 3)]),
                    DirectoryNode(name: "App", children: [DirectoryNode(name: "node_modules")], markers: ["package.json"]),
                ]),
                DirectoryNode(name: ".vscode", children: [
                    DirectoryNode(name: "extensions", children: [
                        DirectoryNode(name: "x", children: [DirectoryNode(name: "node_modules")], markers: ["package.json"]),
                    ]),
                ]),
                project("web", markers: ["package.json"], children: [DirectoryNode(name: "node_modules")]),
            ])
        }
        let other = project("proj", markers: ["package.json"], children: [DirectoryNode(name: "node_modules")])
        let users = DirectoryNode(name: "Users", children: [homeTree(), DirectoryNode(name: "other", children: [other])])
        let slash = DirectoryNode(name: "", children: [users])
        let classifier = Classifier(homePath: "/Users/me")
        func table(_ items: [ClassifiedItem]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.tag.ruleID) })
        }

        let fromHome = table(classifier.classify(root: homeTree(), rootPath: "/Users/me"))
        #expect(fromHome == ["/Users/me/Library/Caches/Homebrew": "homebrew.cache",
                             "/Users/me/web/node_modules": "js.node_modules"])

        for (root, rootPath) in [(users, "/Users"), (slash, "/")] {
            let all = table(classifier.classify(root: root, rootPath: rootPath))
            #expect(all.filter { PathUtil.isSameOrDescendant($0.key, of: "/Users/me") } == fromHome, "\(rootPath)")
            // 홈 밖 형제는 이름 규칙대로 분류한다
            #expect(all["/Users/other/proj/node_modules"] == "js.node_modules", "\(rootPath)")
        }
    }

    @Test func rootBelowHomeUsesHomeRelativePaths() {
        let caches = DirectoryNode(name: "Caches", children: [DirectoryNode(name: "Homebrew", directAllocatedSize: 3)])

        let items = Classifier(homePath: "/h").classify(root: caches, rootPath: "/h/Library/Caches")

        #expect(items.map(\.path) == ["/h/Library/Caches/Homebrew"])
        #expect(items.first?.tag.ruleID == "homebrew.cache")
    }

    @Test func classificationTotalsAndAncestorLookup() {
        let tag = RuleCatalog.default.first { $0.id == "xcode.deriveddata" }!.tag
        let other = RuleCatalog.default.first { $0.id == "xcode.archives" }!.tag
        let classification = Classification(items: [
            ClassifiedItem(path: "/h/a", tag: tag, allocatedSize: 10, newestModification: .distantPast),
            ClassifiedItem(path: "/h/b", tag: other, allocatedSize: 30, newestModification: .distantPast),
        ])

        #expect(classification.totals[.xcode] == CategoryTotal(size: 40, itemCount: 2))
        #expect(classification.items.map(\.path) == ["/h/b", "/h/a"])
        #expect(classification.tag(forPath: "/h/a/x/y") == tag)
        #expect(classification.tag(forPath: "/h/c") == nil)
    }

    @Test func updateChangesOrRemovesItems() {
        let tag = RuleCatalog.default[0].tag
        var classification = Classification(items: [
            ClassifiedItem(path: "/h/a", tag: tag, allocatedSize: 10, newestModification: .distantPast),
        ])

        classification.update(path: "/h/a", size: 3)
        #expect(classification.items.first?.allocatedSize == 3)

        classification.update(path: "/h/a", size: nil)
        #expect(classification.items.isEmpty)
        #expect(classification.tag(forPath: "/h/a") == nil)
    }

    @Test func updateKeepsItemsSortedBySize() {
        let tag = RuleCatalog.default[0].tag
        var classification = Classification(items: [
            ClassifiedItem(path: "/h/a", tag: tag, allocatedSize: 30, newestModification: .distantPast),
            ClassifiedItem(path: "/h/b", tag: tag, allocatedSize: 20, newestModification: .distantPast),
            ClassifiedItem(path: "/h/c", tag: tag, allocatedSize: 10, newestModification: .distantPast),
        ])

        classification.update(path: "/h/a", size: 5)
        #expect(classification.items.map(\.path) == ["/h/b", "/h/c", "/h/a"])

        classification.update(path: "/h/c", size: 50)
        #expect(classification.items.map(\.path) == ["/h/c", "/h/b", "/h/a"])
    }
}
