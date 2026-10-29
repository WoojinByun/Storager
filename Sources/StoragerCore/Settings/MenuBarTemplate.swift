import Foundation

/// 메뉴바 표시 템플릿. `{icon}{remain_storage}` 처럼 토큰과 글자를 섞어 쓴다.
///
/// 남은 용량·사용 중 기준은 예전 메뉴바(여유 용량·사용률 % 모드)와 같다.
/// - `{remain_storage}`: `availableForImportantUsage`(퍼지 가능 공간을 더한 여유, Finder 의 "사용 가능")를 `ByteFormat.compact` 로.
/// - `{using_storage}`: `VolumeStats.used` = 전체 − max(즉시 여유, 퍼지 포함 여유). 보통 전체 − `{remain_storage}` 와 같다.
/// - `{using_storage_percent}`: `usedFraction × 100` 을 반올림한 정수 + "%" (예전 사용률 모드와 같은 값).
/// - `{remain_percent}`: 100 − 사용률 정수. 따로 반올림하지 않아 두 비율의 합이 항상 100% 다.
/// - `{total_storage}`: 전체 용량을 `ByteFormat.compact` 로.
public enum MenuBarTemplate {
    public static let defaultTemplate = "{icon}{remain_storage}"
    /// 설정에 저장하는 템플릿 최대 글자 수(Character 기준)
    public static let maxLength = 100
    /// 볼륨을 아직 읽지 못했을 때 토큰 값(설정 창 도움말 예시)에 보이는 글자. 메뉴바 렌더는 값 토큰을 빼고 그린다.
    public static let placeholder = "—"

    /// 값으로 바뀌는 토큰. `{icon}` 은 값이 아니라 그림이라 `Segment.icon` 으로 따로 둔다.
    public enum Token: String, CaseIterable, Sendable {
        case remainStorage = "remain_storage"
        case remainPercent = "remain_percent"
        case usingStorage = "using_storage"
        case usingStoragePercent = "using_storage_percent"
        case totalStorage = "total_storage"

        /// 설정 창 도움말에 보이는 뜻
        public var meaning: String {
            switch self {
            case .remainStorage: "남은 용량 (Finder 의 사용 가능)"
            case .remainPercent: "남은 비율"
            case .usingStorage: "사용 중 용량"
            case .usingStoragePercent: "사용률"
            case .totalStorage: "전체 용량"
            }
        }

        /// `stats` 로 만든 값. 볼륨을 아직 못 읽었으면 `placeholder`.
        public func value(for stats: VolumeStats?) -> String {
            guard let stats else { return MenuBarTemplate.placeholder }
            let usedPercent = Int((stats.usedFraction * 100).rounded())
            switch self {
            case .remainStorage: return ByteFormat.compact(stats.availableForImportantUsage)
            case .remainPercent: return "\(100 - usedPercent)%"
            case .usingStorage: return ByteFormat.compact(stats.used)
            case .usingStoragePercent: return "\(usedPercent)%"
            case .totalStorage: return ByteFormat.compact(stats.total)
            }
        }
    }

    /// `{icon}` 의 토큰 이름
    public static let iconName = "icon"

    /// 템플릿을 나눈 조각
    public enum Segment: Equatable, Sendable {
        case text(String)
        case icon
        case token(Token)
    }

    /// 그릴 조각. 이웃한 글자는 하나로 합쳐져 있다.
    public enum Piece: Equatable, Sendable {
        case text(String)
        case icon
    }

    public struct Parsed: Equatable, Sendable {
        public var segments: [Segment]
        /// 모르는 `{이름}` (중괄호 포함, 처음 나온 순서, 중복 없음). 글자 그대로 보인다.
        public var unknownTokens: [String]
    }

    /// 템플릿을 조각으로 나눈다.
    /// `{` 다음에 영문·숫자·`_` 가 하나 이상 오고 `}` 로 닫히면 토큰 자리다. 아는 이름이면 토큰, 모르면 글자 그대로 두고
    /// `unknownTokens` 에 알린다. 그 밖의 `{`·`}` (짝이 없거나 `{}`·`{a b}` 처럼 이름이 아닌 것)는 글자다.
    public static func parse(_ template: String) -> Parsed {
        var segments: [Segment] = []
        var unknown: [String] = []
        var text = ""
        func flush() {
            if !text.isEmpty { segments.append(.text(text)) }
            text = ""
        }
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            if character == "{", let (name, end) = tokenName(in: template, after: index) {
                if name == iconName {
                    flush()
                    segments.append(.icon)
                } else if let token = Token(rawValue: name) {
                    flush()
                    segments.append(.token(token))
                } else {
                    let literal = "{\(name)}"
                    text += literal
                    if !unknown.contains(literal) { unknown.append(literal) }
                }
                index = end
            } else {
                text.append(character)
                index = template.index(after: index)
            }
        }
        flush()
        return Parsed(segments: segments, unknownTokens: unknown)
    }

    /// `open`(`{`) 뒤의 토큰 이름과 `}` 다음 위치. 이름 꼴이 아니면 nil.
    private static func tokenName(in template: String, after open: String.Index) -> (String, String.Index)? {
        var name = ""
        var index = template.index(after: open)
        while index < template.endIndex {
            let character = template[index]
            if character == "}" {
                return name.isEmpty ? nil : (name, template.index(after: index))
            }
            guard character.isASCII, character.isLetter || character.isNumber || character == "_" else { return nil }
            name.append(character)
            index = template.index(after: index)
        }
        return nil
    }

    /// 템플릿과 볼륨 값으로 그릴 조각을 만든다. 볼륨을 아직 읽지 못했으면(`stats` nil) 값 토큰은 빼고 아이콘·글자만 그린다
    /// (예전처럼 첫 읽기 전에는 기본 템플릿이 아이콘만 보인다). 아이콘도 보이는 글자도 없으면(빈 문자열·공백뿐) 아이콘 하나로
    /// 대신해 메뉴바 항목이 사라지지 않게 한다.
    public static func render(_ template: String, stats: VolumeStats?) -> [Piece] {
        var pieces: [Piece] = []
        func append(_ string: String) {
            guard !string.isEmpty else { return }
            if case .text(let previous) = pieces.last {
                pieces[pieces.count - 1] = .text(previous + string)
            } else {
                pieces.append(.text(string))
            }
        }
        for segment in parse(template).segments {
            switch segment {
            case .text(let string): append(string)
            case .icon: pieces.append(.icon)
            case .token(let token): if let stats { append(token.value(for: stats)) }
            }
        }
        let hasIcon = pieces.contains(.icon)
        let visibleText = pieces.contains {
            if case .text(let string) = $0 { !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } else { false }
        }
        return hasIcon || visibleText ? pieces : [.icon]
    }

    /// 아이콘을 뺀 글자만 (손쉬운 사용 레이블 등)
    public static func plainText(_ pieces: [Piece]) -> String {
        pieces.reduce(into: "") { result, piece in
            if case .text(let string) = piece { result += string }
        }
    }

    /// 설정에 저장할 꼴: 줄바꿈은 공백으로 바꾸고 `maxLength` 글자까지 자른다.
    public static func sanitized(_ template: String) -> String {
        let singleLine = String(template.map { $0.isNewline ? " " : $0 })
        return String(singleLine.prefix(maxLength))
    }

    /// 저장된 값으로 쓸 수 있는지: `maxLength` 이하이고 줄바꿈이 없다.
    public static func isUsable(_ template: String) -> Bool {
        template.count <= maxLength && !template.contains(where: \.isNewline)
    }
}

/// 설정 창의 메뉴바 표시 프리셋
public enum MenuBarPreset: String, CaseIterable, Sendable {
    case remainStorage
    case usingStoragePercent
    case remainPercent
    case usingStorage
    case iconOnly
    case custom

    public var label: String {
        switch self {
        case .remainStorage: "남은 용량"
        case .usingStoragePercent: "사용률"
        case .remainPercent: "남은 비율"
        case .usingStorage: "사용 중 용량"
        case .iconOnly: "아이콘만"
        case .custom: "직접 입력"
        }
    }

    /// 프리셋 템플릿. 직접 입력은 nil.
    public var template: String? {
        switch self {
        case .remainStorage: "{icon}{remain_storage}"
        case .usingStoragePercent: "{icon}{using_storage_percent}"
        case .remainPercent: "{icon}{remain_percent}"
        case .usingStorage: "{icon}{using_storage}"
        case .iconOnly: "{icon}"
        case .custom: nil
        }
    }

    /// 템플릿과 글자가 같은 프리셋. 없으면 `.custom`.
    public static func matching(_ template: String) -> MenuBarPreset {
        allCases.first { $0.template == template } ?? .custom
    }
}
