import Foundation
import Testing
@testable import StoragerCore

struct StoragerSettingsTests {
    let store = InMemorySettingsStore()
    let settings: StoragerSettings

    init() {
        settings = StoragerSettings(store: store)
    }

    @Test func defaultsWhenEmpty() {
        #expect(settings.scanIntervalHours == 6)
        #expect(settings.leafThresholdMB == 10)
        #expect(settings.excludedPaths.isEmpty)
        #expect(settings.ignoredPaths.isEmpty)
        #expect(settings.extraProjectRoots.isEmpty)
        #expect(settings.menuBarTemplate == "{icon}{remain_storage}")
        #expect(settings.fullDiskAccessIntroShown == false)
        #expect(settings.menuBarScalePercent == 100)
        #expect(settings.menuBarUsesTemplateImage)
    }

    @Test func fullDiskAccessIntroShownPersists() {
        settings.fullDiskAccessIntroShown = true
        #expect(settings.fullDiskAccessIntroShown)
        #expect(store.object(forKey: StoragerSettings.Key.fullDiskAccessIntroShown) as? Bool == true)
        settings.fullDiskAccessIntroShown = false
        #expect(!settings.fullDiskAccessIntroShown)
    }

    @Test func valuesPersist() {
        settings.scanIntervalHours = 12
        settings.leafThresholdMB = 50
        settings.menuBarTemplate = "{icon}하하하{using_storage_percent}"
        #expect(settings.scanIntervalHours == 12)
        #expect(settings.leafThresholdMB == 50)
        #expect(settings.menuBarTemplate == "{icon}하하하{using_storage_percent}")
        #expect(settings.scanInterval == 12 * 3600)
    }

    @Test func invalidStoredValuesFallBackToDefaults() {
        store.set(7, forKey: StoragerSettings.Key.scanIntervalHours)
        store.set("x", forKey: StoragerSettings.Key.leafThresholdMB)
        store.set(42, forKey: StoragerSettings.Key.menuBarTemplate)
        #expect(settings.scanIntervalHours == 6)
        #expect(settings.leafThresholdMB == 10)
        #expect(settings.menuBarTemplate == MenuBarTemplate.defaultTemplate)
    }

    @Test func settersIgnoreValuesOutsideAllowedChoices() {
        settings.scanIntervalHours = 12
        settings.leafThresholdMB = 50
        settings.scanIntervalHours = 7
        settings.scanIntervalHours = 0
        settings.leafThresholdMB = -1
        settings.leafThresholdMB = 1000
        // 허용 값이 아니면 저장하지 않아 이전 값이 남는다
        #expect(store.object(forKey: StoragerSettings.Key.scanIntervalHours) as? Int == 12)
        #expect(store.object(forKey: StoragerSettings.Key.leafThresholdMB) as? Int == 50)
        #expect(settings.scanIntervalHours == 12)
        #expect(settings.leafThresholdMB == 50)
    }

    @Test func settersAcceptEveryAllowedChoice() {
        for hours in StoragerSettings.scanIntervalChoices {
            settings.scanIntervalHours = hours
            #expect(settings.scanIntervalHours == hours)
        }
        for mb in StoragerSettings.leafThresholdChoices {
            settings.leafThresholdMB = mb
            #expect(settings.leafThresholdMB == mb)
        }
        for preset in MenuBarPreset.allCases {
            guard let template = preset.template else { continue }
            settings.menuBarTemplate = template
            #expect(store.object(forKey: StoragerSettings.Key.menuBarTemplate) as? String == template)
        }
    }

    @Test func pathListsDropEmptyAndRelativePaths() {
        settings.excludedPaths = ["", "relative/dir", "./x", "/abs"]
        settings.ignoredPaths = [""]
        settings.extraProjectRoots = ["Volumes/Work", "/Volumes/Work"]
        #expect(settings.excludedPaths == ["/abs"])
        #expect(settings.ignoredPaths.isEmpty)
        #expect(settings.extraProjectRoots == ["/Volumes/Work"])
    }

    @Test func pathListsRejectTildeUserForm() {
        settings.excludedPaths = ["~root/x", "~", "~/dev"]
        let home = PathUtil.standardize("~")
        #expect(settings.excludedPaths == [home, home + "/dev"].sorted())
    }

    @Test func pathListGettersDropBadStoredValues() {
        // 직접 고친 값이나 예전 값처럼 setter 를 거치지 않고 저장된 경우
        store.set(["", "relative", "~other/x", "/ok", "~/fine"], forKey: StoragerSettings.Key.excludedPaths)
        store.set(["dev"], forKey: StoragerSettings.Key.ignoredPaths)
        store.set(["/Volumes/W", "Volumes/X"], forKey: StoragerSettings.Key.extraProjectRoots)
        #expect(settings.excludedPaths == ["/ok", "~/fine"])
        #expect(settings.ignoredPaths.isEmpty)
        #expect(settings.extraProjectRoots == ["/Volumes/W"])
    }

    @Test func pathListsAreStandardizedDedupedAndSorted() {
        settings.excludedPaths = ["/b/", "/a/x/..", "/b"]
        #expect(settings.excludedPaths == ["/a", "/b"])
    }

    @Test func scanOptionsCombineExcludedAndIgnored() {
        settings.excludedPaths = ["/x"]
        settings.ignoredPaths = ["/y"]
        settings.leafThresholdMB = 1
        let options = settings.makeScanOptions()
        #expect(options.excludedPaths == ["/x", "/y"])
        #expect(options.leafThreshold == 1_048_576)
    }

    @Test func menuBarTemplateSetterCapsLengthAndRemovesNewlines() {
        settings.menuBarTemplate = String(repeating: "가", count: 150)
        #expect(settings.menuBarTemplate.count == MenuBarTemplate.maxLength)
        settings.menuBarTemplate = "{icon}\n{remain_storage}\r\n!"
        #expect(settings.menuBarTemplate == "{icon} {remain_storage} !")
        // 빈 문자열은 그대로 저장한다 (그릴 때 아이콘만 보인다)
        settings.menuBarTemplate = ""
        #expect(settings.menuBarTemplate == "")
    }

    @Test func menuBarTemplateGetterRejectsUnusableStoredValues() {
        store.set(String(repeating: "x", count: 101), forKey: StoragerSettings.Key.menuBarTemplate)
        #expect(settings.menuBarTemplate == MenuBarTemplate.defaultTemplate)
        store.set("{icon}\n", forKey: StoragerSettings.Key.menuBarTemplate)
        #expect(settings.menuBarTemplate == MenuBarTemplate.defaultTemplate)
        store.set(String(repeating: "x", count: 100), forKey: StoragerSettings.Key.menuBarTemplate)
        #expect(settings.menuBarTemplate.count == 100)
    }

    @Test(arguments: [
        ("freeSpace", "{icon}{remain_storage}"),
        ("usedPercent", "{icon}{using_storage_percent}"),
        ("iconOnly", "{icon}"),
    ])
    func legacyMenuBarDisplayMigrates(raw: String, template: String) {
        let store = InMemorySettingsStore()
        store.set(raw, forKey: StoragerSettings.Key.legacyMenuBarDisplay)
        let settings = StoragerSettings(store: store)
        #expect(settings.menuBarTemplate == template)
        #expect(store.object(forKey: StoragerSettings.Key.menuBarTemplate) as? String == template)
        #expect(store.object(forKey: StoragerSettings.Key.legacyMenuBarDisplay) == nil)
    }

    @Test func legacyMigrationRunsOnceAndKeepsExistingTemplate() {
        let store = InMemorySettingsStore()
        store.set("usedPercent", forKey: StoragerSettings.Key.legacyMenuBarDisplay)
        _ = StoragerSettings(store: store)
        // 옮긴 뒤 사용자가 바꾼 값은 다시 만들어도 덮어쓰지 않는다
        let settings = StoragerSettings(store: store)
        settings.menuBarTemplate = "{total_storage}"
        #expect(StoragerSettings(store: store).menuBarTemplate == "{total_storage}")

        // 템플릿이 이미 있으면 옛 값은 옮기지 않고 지우기만 한다
        store.set("iconOnly", forKey: StoragerSettings.Key.legacyMenuBarDisplay)
        #expect(StoragerSettings(store: store).menuBarTemplate == "{total_storage}")
        #expect(store.object(forKey: StoragerSettings.Key.legacyMenuBarDisplay) == nil)
    }

    @Test func unknownLegacyValueFallsBackToDefaultAndIsRemoved() {
        let store = InMemorySettingsStore()
        store.set("bogus", forKey: StoragerSettings.Key.legacyMenuBarDisplay)
        let settings = StoragerSettings(store: store)
        #expect(settings.menuBarTemplate == MenuBarTemplate.defaultTemplate)
        #expect(store.object(forKey: StoragerSettings.Key.menuBarTemplate) == nil)
        #expect(store.object(forKey: StoragerSettings.Key.legacyMenuBarDisplay) == nil)
    }

    @Test func menuBarScaleAcceptsStepsFrom100To200() {
        #expect(StoragerSettings.menuBarScaleChoices == [100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200])
        for percent in StoragerSettings.menuBarScaleChoices {
            settings.menuBarScalePercent = percent
            #expect(settings.menuBarScalePercent == percent)
        }
    }

    @Test func menuBarScaleSetterIgnoresInvalidValues() {
        settings.menuBarScalePercent = 150
        for invalid in [0, 90, 105, 155, 210, -100] {
            settings.menuBarScalePercent = invalid
        }
        #expect(store.object(forKey: StoragerSettings.Key.menuBarScalePercent) as? Int == 150)
        #expect(settings.menuBarScalePercent == 150)
    }

    @Test func menuBarScaleGetterRejectsBadStoredValues() {
        for bad: Any in [95, 125, 300, "150", 1.5] {
            store.set(bad, forKey: StoragerSettings.Key.menuBarScalePercent)
            #expect(settings.menuBarScalePercent == 100)
        }
    }

    @Test func menuBarUsesTemplateImagePersists() {
        settings.menuBarUsesTemplateImage = false
        #expect(!settings.menuBarUsesTemplateImage)
        #expect(store.object(forKey: StoragerSettings.Key.menuBarUsesTemplateImage) as? Bool == false)
        settings.menuBarUsesTemplateImage = true
        #expect(settings.menuBarUsesTemplateImage)
    }

    @Test func menuBarUsesTemplateImageGetterRejectsBadStoredValues() {
        for bad: Any in ["false", "NO", 0, 0.0, [false]] {
            store.set(bad, forKey: StoragerSettings.Key.menuBarUsesTemplateImage)
            #expect(settings.menuBarUsesTemplateImage)
        }
    }
}
