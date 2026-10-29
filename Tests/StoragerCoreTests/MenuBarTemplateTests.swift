import Testing
@testable import StoragerCore

struct MenuBarTemplateTests {
    /// 전체 1T, 즉시 여유 300G, 퍼지 포함 여유 812.4G → 사용 중 187.6G (18.76%)
    let stats = VolumeStats(total: 1_000_000_000_000, available: 300_000_000_000,
                            availableForImportantUsage: 812_400_000_000)

    private func render(_ template: String, _ stats: VolumeStats?) -> [MenuBarTemplate.Piece] {
        MenuBarTemplate.render(template, stats: stats)
    }

    @Test func everyToken() {
        #expect(render("{remain_storage}", stats) == [.text("812G")])
        #expect(render("{remain_percent}", stats) == [.text("81%")])
        #expect(render("{using_storage}", stats) == [.text("187G")])
        #expect(render("{using_storage_percent}", stats) == [.text("19%")])
        #expect(render("{total_storage}", stats) == [.text("1.0T")])
        #expect(render("{icon}", stats) == [.icon])
    }

    @Test func percentsAlwaysSumTo100() {
        // 사용률이 x.5 로 떨어져도 남은 비율은 100 − 사용률이라 합이 100 이다
        for usedTenths in stride(from: 0, through: 1000, by: 5) {
            let used = Int64(usedTenths) * 1_000_000_000
            let free = 1_000_000_000_000 - used
            let stats = VolumeStats(total: 1_000_000_000_000, available: free, availableForImportantUsage: free)
            let using = Int(MenuBarTemplate.Token.usingStoragePercent.value(for: stats).dropLast())!
            let remain = Int(MenuBarTemplate.Token.remainPercent.value(for: stats).dropLast())!
            #expect(using + remain == 100)
        }
    }

    @Test func defaultMatchesOldFreeSpaceMode() {
        // 예전 여유 용량 모드: 아이콘 + ByteFormat.compact(availableForImportantUsage)
        #expect(render(MenuBarTemplate.defaultTemplate, stats)
            == [.icon, .text(ByteFormat.compact(stats.availableForImportantUsage))])
        #expect(render(MenuBarTemplate.defaultTemplate, stats) == [.icon, .text("812G")])
        // 예전 사용률 모드와 같은 값
        #expect(render("{using_storage_percent}", stats)
            == [.text("\(Int((stats.usedFraction * 100).rounded()))%")])
    }

    @Test func mixedKoreanText() {
        #expect(render("{icon}하하하{using_storage_percent}", stats) == [.icon, .text("하하하19%")])
        #expect(render("남음 {remain_storage} / {total_storage}", stats) == [.text("남음 812G / 1.0T")])
    }

    @Test func multipleIcons() {
        #expect(render("{icon}{remain_storage}{icon}", stats) == [.icon, .text("812G"), .icon])
        #expect(render("{icon}{icon}", stats) == [.icon, .icon])
    }

    @Test func unknownTokensStayLiteralAndAreReported() {
        let parsed = MenuBarTemplate.parse("{icon}{foo}{remain_storage}{Icon}{foo}")
        #expect(parsed.segments == [.icon, .text("{foo}"), .token(.remainStorage), .text("{Icon}{foo}")])
        #expect(parsed.unknownTokens == ["{foo}", "{Icon}"])
        #expect(render("{foo}{remain_storage}", stats) == [.text("{foo}812G")])
    }

    @Test func braceEdgeCases() {
        let cases: [(String, [MenuBarTemplate.Segment])] = [
            ("{", [.text("{")]),
            ("}", [.text("}")]),
            ("{}", [.text("{}")]),
            ("{{icon}", [.text("{"), .icon]),
            ("{icon}}", [.icon, .text("}")]),
            ("{icon", [.text("{icon")]),
            ("{remain storage}", [.text("{remain storage}")]),
            ("{하하}", [.text("{하하}")]),
            ("a{icon}b", [.text("a"), .icon, .text("b")]),
        ]
        for (template, segments) in cases {
            let parsed = MenuBarTemplate.parse(template)
            #expect(parsed.segments == segments, "\(template)")
            #expect(parsed.unknownTokens.isEmpty, "\(template)")
        }
        #expect(MenuBarTemplate.parse("").segments.isEmpty)
    }

    @Test func nilStatsDropValueTokens() {
        // 첫 읽기 전에는 예전처럼 프리셋이 아이콘만 보인다
        for preset in MenuBarPreset.allCases {
            guard let template = preset.template else { continue }
            #expect(render(template, nil) == [.icon], "\(preset)")
        }
        // 아이콘·글자는 남고 값 토큰만 빠진다
        #expect(render("{icon}하하하{using_storage_percent}", nil) == [.icon, .text("하하하")])
        #expect(render("{remain_percent}/{using_storage}", nil) == [.text("/")])
        // 값 토큰만 있으면 빈 결과라 아이콘으로 대신한다
        #expect(render("{remain_storage} {total_storage}", nil) == [.icon])
        // 도움말 예시 값은 자리 표시 글자
        for token in MenuBarTemplate.Token.allCases {
            #expect(token.value(for: nil) == "—")
        }
    }

    @Test func emptyOrWhitespaceFallsBackToIcon() {
        #expect(render("", stats) == [.icon])
        #expect(render("   ", stats) == [.icon])
        #expect(render(" \t ", nil) == [.icon])
        // 아이콘이 있으면 공백도 그대로 둔다
        #expect(render("{icon} ", stats) == [.icon, .text(" ")])
        // 보이는 글자가 있으면 아이콘 없이 그린다
        #expect(render("{remain_storage}", stats) == [.text("812G")])
    }

    @Test func plainTextDropsIcons() {
        #expect(MenuBarTemplate.plainText([.icon, .text("a"), .icon, .text("b")]) == "ab")
    }

    @Test func sanitizedAndUsable() {
        #expect(MenuBarTemplate.sanitized("a\nb") == "a b")
        #expect(MenuBarTemplate.sanitized(String(repeating: "가", count: 120)).count == 100)
        #expect(MenuBarTemplate.isUsable(String(repeating: "x", count: 100)))
        #expect(!MenuBarTemplate.isUsable(String(repeating: "x", count: 101)))
        #expect(!MenuBarTemplate.isUsable("a\nb"))
    }

    @Test func presetsMatchTemplates() {
        #expect(MenuBarPreset.matching("{icon}{remain_storage}") == .remainStorage)
        #expect(MenuBarPreset.matching(MenuBarTemplate.defaultTemplate) == .remainStorage)
        #expect(MenuBarPreset.matching("{icon}{using_storage_percent}") == .usingStoragePercent)
        #expect(MenuBarPreset.matching("{icon}{remain_percent}") == .remainPercent)
        #expect(MenuBarPreset.matching("{icon}{using_storage}") == .usingStorage)
        #expect(MenuBarPreset.matching("{icon}") == .iconOnly)
        #expect(MenuBarPreset.matching("{icon}하하하") == .custom)
        #expect(MenuBarPreset.custom.template == nil)
        for preset in MenuBarPreset.allCases {
            if let template = preset.template {
                #expect(MenuBarTemplate.parse(template).unknownTokens.isEmpty)
            }
        }
    }
}
