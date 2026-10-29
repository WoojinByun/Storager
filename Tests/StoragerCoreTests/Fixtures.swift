@testable import StoragerCore

/// 카탈로그 규칙 id 로 태그를 꺼낸다. 없는 id 면 테스트가 바로 죽어 오타를 알려 준다.
func ruleTag(_ id: String) -> CategoryTag {
    RuleCatalog.default.first { $0.id == id }!.tag
}
