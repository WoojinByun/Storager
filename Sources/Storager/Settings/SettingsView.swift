import AppKit
import StoragerCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsModel
    /// 템플릿 토큰 도움말 팝오버
    @State private var showsTokenHelp = false
    /// 템플릿 이미지를 끈 미리보기의 글자 색을 정하는 설정 창 모양새
    @Environment(\.colorScheme) private var colorScheme

    /// 번들 없이(`swift run`) 실행하면 Info.plist 가 없어 버전을 알 수 없다
    private static let versionPrefix: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let version, !version.isEmpty else { return "Storager · " }
        return "Storager \(version) · "
    }()

    // 상수 리터럴이라 항상 유효하다
    private static let repositoryURL = URL(string: "https://github.com/WoojinByun/Storager")!

    var body: some View {
        VStack(spacing: 0) {
            form
            footer
        }
        .frame(width: 480)
        .frame(minHeight: 360)
    }

    /// 폼은 길면 스크롤하므로 푸터는 폼 밖에 둬서 스크롤 위치와 상관없이 창 맨 아래에 항상 보인다
    private var footer: some View {
        HStack(spacing: 0) {
            Text(Self.versionPrefix)
            Link("GitHub ↗", destination: Self.repositoryURL)
                .help("GitHub 에서 Storager 저장소 열기")
                .accessibilityLabel("Storager GitHub 저장소")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var form: some View {
        Form {
            Section("일반") {
                Toggle("로그인 시 실행", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .id(model.loginToggleRevision)
                .disabled(model.loginUnavailable)
                if model.loginUnavailable {
                    Text("설치된 앱에서만 설정할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.needsLoginApproval {
                    HStack {
                        Text("시스템 설정 → 일반 → 로그인 항목에서 Storager를 허용해 주세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("시스템 설정 열기") { model.openLoginItemsSettings() }
                    }
                }
                if let error = model.loginError {
                    errorText(error)
                }
                menuBarRows
                LabeledContent("전체 디스크 접근") {
                    HStack {
                        Text(model.fullDiskAccessGranted ? "허용됨" : "허용 안 됨")
                            .foregroundStyle(model.fullDiskAccessGranted ? Color.secondary : Color.orange)
                        Button("시스템 설정 열기") { model.openFullDiskAccessSettings() }
                    }
                }
                if !model.fullDiskAccessGranted {
                    Text("허용하지 않으면 데스크탑·문서·다운로드·iCloud Drive·사진 보관함 등은 스캔에서 건너뜁니다. 허용하면 바로 다시 스캔합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("스캔") {
                Picker("주기", selection: $model.scanIntervalHours) {
                    ForEach(StoragerSettings.scanIntervalChoices, id: \.self) { Text("\($0)시간").tag($0) }
                }
                Picker("큰 파일 기준", selection: $model.leafThresholdMB) {
                    ForEach(StoragerSettings.leafThresholdChoices, id: \.self) { Text("\($0) MB 이상").tag($0) }
                }
                Text("배터리 전원이거나 저전력 모드이면 그 회차는 건너뜁니다. 주기는 바로, 나머지는 다음 스캔부터 적용됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            pathSection("제외 경로", paths: model.excludedPaths, list: .excluded, canAdd: true,
                        note: "다음 스캔부터 적용됩니다. 홈 폴더나 추가 루트 자체는 제외할 수 없습니다.",
                        warnings: model.excludedWarnings)
            pathSection("무시 목록 (트리맵에서 추가)", paths: model.ignoredPaths, list: .ignored, canAdd: false,
                        note: "목록에서 지우면 다음 스캔부터 다시 셉니다.")
            pathSection("추가 프로젝트 루트 (홈 밖)", paths: model.extraProjectRoots, list: .extraRoots, canAdd: true,
                        note: "다음 스캔부터 반영됩니다. 홈이나 다른 추가 루트와 겹치는 폴더는 받지 않습니다.",
                        warnings: model.extraRootWarnings)
        }
        .formStyle(.grouped)
    }

    // MARK: 메뉴바 표시

    /// 프리셋 피커 · 템플릿 입력(오른쪽 위 "?" 도움말) · 모르는 토큰 경고 · 이모지 안내 · 크기 · 템플릿 이미지 · 미리보기
    @ViewBuilder private var menuBarRows: some View {
        Picker("메뉴바 표시", selection: $model.menuBarPreset) {
            ForEach(MenuBarPreset.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("템플릿")
                Spacer()
                tokenHelpButton
            }
            TextField("템플릿", text: $model.menuBarTemplate, prompt: Text("비우면 아이콘만 표시"))
                .labelsHidden()
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
            if !model.menuBarUnknownTokens.isEmpty {
                Text("알 수 없는 토큰: \(model.menuBarUnknownTokens.joined(separator: ", ")) (글자 그대로 표시됩니다)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.menuBarShowsEmojiHint {
                Text("이모지는 단색으로 보입니다. 원래 색으로 보려면 '템플릿 이미지로 표시'를 끄세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        LabeledContent("크기") {
            HStack {
                Slider(value: Binding(
                    get: { Double(model.menuBarScalePercent) },
                    set: { model.menuBarScalePercent = Int(($0 / 10).rounded()) * 10 }
                ), in: 100...200, step: 10)
                .labelsHidden()
                .accessibilityLabel("메뉴바 표시 크기")
                .accessibilityValue("\(model.menuBarScalePercent)%")
                Text("\(model.menuBarScalePercent)%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            Toggle("템플릿 이미지로 표시", isOn: $model.menuBarUsesTemplateImage)
            Text("메뉴바 색에 맞춰 단색으로 표시합니다. 끄면 이모지가 원래 색으로 보입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        LabeledContent("미리보기") {
            preview(model.menuBarPreview)
        }
    }

    private var tokenHelpButton: some View {
        Button {
            showsTokenHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("사용할 수 있는 토큰 보기")
        .accessibilityLabel("메뉴바 템플릿 토큰 도움말")
        // 오른쪽에 띄워 입력 칸을 가리지 않는다
        .popover(isPresented: $showsTokenHelp, arrowEdge: .trailing) {
            tokenHelp
        }
    }

    /// 토큰 · 뜻 · 지금 볼륨 값으로 만든 예시. 표는 자기 폭(가장 긴 토큰·뜻)대로 펼치고 잘리지 않게 고정하며,
    /// 아래 안내 두 줄은 `noteWidth` 안에서 줄바꿈한다(팝오버 폭은 둘 중 넓은 쪽).
    private var tokenHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("토큰")
                    Text("뜻")
                    Text("예시")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                GridRow {
                    tokenText(MenuBarTemplate.iconName)
                    Text("디스크 아이콘")
                    Image(systemName: MenuBarLabel.symbolName)
                }
                ForEach(MenuBarTemplate.Token.allCases, id: \.self) { token in
                    GridRow {
                        tokenText(token.rawValue)
                        Text(token.meaning)
                        Text(model.menuBarExample(token)).monospacedDigit()
                    }
                }
            }
            .lineLimit(1)
            .fixedSize()
            VStack(alignment: .leading, spacing: 4) {
                Text("다른 글자는 그대로 표시됩니다. 예: {icon}하하하{using_storage_percent}")
                Text("아이콘도 보이는 글자도 없으면 아이콘만 표시합니다.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Self.noteWidth, alignment: .leading)
        }
        .padding(14)
    }

    /// 토큰 도움말 아래 안내의 최대 폭
    private static let noteWidth: CGFloat = 360

    private func tokenText(_ name: String) -> some View {
        Text(verbatim: "{\(name)}")
            .font(.body.monospaced())
            .textSelection(.enabled)
    }

    /// 미리보기: 메뉴바와 같은 `MenuBarLabel` 이미지(메뉴바 두께, 크기 반영). 템플릿 이미지면 글자 색 단색(이모지도),
    /// 아니면 설정 창 모양새의 글자 색에 이모지는 원래 색이다.
    private func preview(_ pieces: [MenuBarTemplate.Piece]) -> some View {
        let usesTemplate = model.menuBarUsesTemplateImage
        let appearance = usesTemplate ? nil : NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let text = MenuBarTemplate.plainText(pieces)
        let image = MenuBarLabel.image(pieces, scale: CGFloat(model.menuBarScalePercent) / 100,
                                       height: NSStatusBar.system.thickness, accessibility: text, appearance: appearance)
        return Image(nsImage: image)
            .renderingMode(usesTemplate ? .template : .original)
            .foregroundStyle(.primary)
            .accessibilityLabel(text.isEmpty ? "아이콘" : text)
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// - Parameters:
    ///   - note: 적용 시점 안내 (섹션 맨 아래 작은 글씨)
    ///   - warnings: 경로 → 경고 문구. 있으면 그 행 옆에 작은 주황 글씨로 보여 준다.
    private func pathSection(_ title: String, paths: [String], list: SettingsModel.PathList, canAdd: Bool,
                             note: String, warnings: [String: String] = [:]) -> some View {
        Section(title) {
            ForEach(paths, id: \.self) { path in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FileActions.displayPath(path)).lineLimit(1).truncationMode(.middle)
                        if let warning = warnings[path] {
                            Text(warning)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Button {
                        model.remove(path, from: list)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(FileActions.displayPath(path)) 제거")
                    .help("목록에서 제거")
                }
            }
            if paths.isEmpty {
                Text("없음").foregroundStyle(.secondary)
            }
            if canAdd {
                Button("추가…") { model.addPaths(to: list) }
                // 거부 사유는 눌러 본 버튼 바로 아래에 보여 준다
                if let error = model.listErrors[list] {
                    errorText(error)
                }
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
