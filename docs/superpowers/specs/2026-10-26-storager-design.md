# Storager 설계 문서

작성일: 2026-10-26
상태: 승인됨 (브레인스토밍 완료)

## 1. 배경과 목표

macOS 에서 "무엇이 디스크를 먹고 있는지"를 큰 덩어리 단위로 시각화하고, 개발자 빌드 캐시·AI 도구 캐시·Git worktree 처럼 자동으로 정리되지 않는 영역을 안전하게 정리하는 메뉴바 상주 앱.

출발점이 된 요구:

- 시스템 전체 용량이 아니라 "어떤 덩어리가 큰지"를 시각화
- 빌드 캐시 추적: Gradle(`~/.gradle`, 프로젝트별 `build/`), Xcode DerivedData·Archives·시뮬레이터, CocoaPods, npm/yarn/pnpm 캐시, `node_modules`
- AI 코딩 도구 캐시: Claude·Codex 세션/메모리 디렉터리, worktree 가 늘어나며 커진 모노레포
- macOS 가 "시스템 데이터"로 뭉뚱그리는 것(Adobe 캐시, 로그, 컨테이너 등)의 정체 밝히기
- 실시간 자원 모니터링은 부차적. RunCat 류와 겹치므로 "관리" 쪽이 차별점

추가 기능(제안 후 채택):

- 증가 추세: 스냅샷을 쌓아 "지난 7일간 DerivedData +40GB" 같은 변화량 표시, 임계치 알림
- Git worktree 인식: 메인 레포 대비 worktree 별 용량·마지막 커밋·머지 여부
- 안전한 정리: 등급별 허용, 휴지통 경유, 드라이런 미리보기
- Docker·시뮬레이터·Homebrew 는 도구 자체 명령으로 정리

## 2. 결정 사항 요약

| 항목 | 결정 |
|---|---|
| 형태 | 하이브리드. 메뉴바 아이콘 + 팝오버(요약) + 분석 윈도우(트리맵) |
| 스캔 범위 | 홈 디렉터리(`~`) 전체 파일 트리 스캔. 홈 밖은 숫자 요약만 |
| 분류 | "알려진 위치 목록"은 스캔 대상이 아니라 스캔 결과에 라벨을 붙이는 분류 레이어 |
| 정리 | 등급별 삭제(재생성 가능/주의/수동 확인) + 도구 네이티브 명령, 휴지통 경유 |
| 모니터링 | 주기 재스캔 + 스냅샷 추세 + 임계치 알림 |
| 스캐너 | 하이브리드 트리: 디렉터리는 전부 노드, 파일은 임계치 이상만 리프 |
| 기술 스택 | Swift 6, SwiftUI/AppKit, SwiftPM(Package.swift + Makefile), macOS 15+, Apple Silicon 전용, LSUIElement, GRDB, Sparkle, GitHub Releases zip 배포. 형제 프로젝트 Paster 의 빌드·서명·릴리스 스크립트 재사용 |

## 3. 전체 구조

Paster 와 같은 SwiftPM 레이아웃.

- **StoragerCore** (라이브러리, UI 의존 없음, 테스트 대상): 스캐너, 트리 모델, 분류 규칙, 정리 플래너, 스냅샷 저장소(GRDB), 시스템 요약 수집기, 포맷터
- **Storager** (실행 타깃): AppDelegate, 메뉴바 아이템·팝오버, 분석 윈도우(트리맵), 설정 창, 스케줄러, 알림, Sparkle
- **StoragerCoreTests**: 임시 디렉터리에 가짜 파일 트리를 만들어 스캐너·분류·플래너 검증

데이터 흐름은 단방향.

```
ScanScheduler → Scanner → FileTree → Classifier(태그 부여) → ScanResult → ScanStore(@Observable)
                                                                             ↓ 읽기 전용
                                                                 팝오버 / 분석 윈도우 / 메뉴바 아이콘
사용자 선택 → CleanupPlanner → CleanupPlan(미리보기) → CleanupExecutor → 해당 서브트리 부분 재스캔 → ScanStore 갱신
```

## 4. 스캐너와 데이터 모델

### 모델

```swift
struct DirectoryNode {
    let url: URL
    var allocatedSize: Int64      // 실제 점유 블록 합. Finder·시스템 설정 숫자와 맞춤
    var logicalSize: Int64
    var fileCount: Int
    var children: [DirectoryNode]
    var largeFiles: [FileLeaf]    // 임계치(기본 10MB, 설정 가능) 이상만
    var newestMTime: Date
    var tags: [CategoryTag]       // Classifier 가 부여
    var accessDenied: Bool
}

struct FileLeaf { let url: URL; let allocatedSize: Int64; let mtime: Date }
```

### 동작

- 측정은 `getattrlistbulk` 로 디렉터리당 1회 호출. 속성: 이름, 타입, 할당 크기, 논리 크기, mtime, inode, 링크 수, 플래그
- 홈 바로 아래 1단계 디렉터리를 `TaskGroup` 으로 병렬 스캔(동시성 4), QoS `.utility`
- 하드링크(링크 수 > 1)와 APFS 클론은 inode 집합으로 중복 제거해 한 번만 셈
- 심볼릭 링크는 따라가지 않음. 마운트 경계(다른 볼륨)도 넘지 않음
- iCloud 미다운로드(dataless) 파일은 0 으로 셈
- 접근 거부(EPERM/EACCES) 디렉터리는 `accessDenied = true` 만 표시하고 계속 진행
- 스캔은 취소 가능. 진행률은 "1단계 디렉터리 완료 수 / 전체" 로 표시
- 부분 재스캔: 정리 후 해당 노드 서브트리만 다시 재고 조상 합계를 갱신
- 제외 경로(설정)와 무시 목록(트리맵 우클릭으로 추가)은 스캔에서 건너뜀

### 메모리·시간 목표

- 홈에 파일 300만 개 기준 트리 메모리 수십 MB 이내
- 첫 전체 스캔 수십 초 이내(Apple Silicon 내장 SSD 기준)

## 5. 분류 레이어

규칙 카탈로그는 StoragerCore 안의 선언적 목록. 각 규칙은 `매칭 조건 → 카테고리 → 안전 등급 → 정리 방법` 을 가진다. 매칭 조건은 (a) 홈 기준 경로 글롭, (b) "디렉터리명이 X 이고 부모에 Y 파일이 있음"(예: `node_modules` 옆에 `package.json`), (c) 외부 명령 결과(Git worktree) 세 종류.

### 초기 카탈로그

| 카테고리 | 예시 경로 | 등급 | 정리 방법 |
|---|---|---|---|
| Xcode | `~/Library/Developer/Xcode/DerivedData`, `Archives`, `iOS DeviceSupport` | 재생성 가능 (Archives 는 주의) | 휴지통 |
| 시뮬레이터 | `~/Library/Developer/CoreSimulator/Devices`, `Caches/dyld` | 재생성 가능 | `xcrun simctl delete unavailable` |
| Gradle | `~/.gradle/caches`, `~/.gradle/daemon`, `~/.gradle/wrapper`, 프로젝트 `build/`·`.gradle/` | 재생성 가능 | 휴지통 |
| JS | `node_modules`(옆에 package.json), `~/.npm/_cacache`, `~/Library/Caches/Yarn`, pnpm store(`~/Library/pnpm/store`) | 재생성 가능 | 휴지통 / `npm cache clean --force` |
| CocoaPods·SwiftPM | `~/Library/Caches/CocoaPods`, `~/Library/Caches/org.swift.swiftpm`, 프로젝트 `.build/`, `Pods/`(옆에 Podfile) | 재생성 가능 | 휴지통 |
| Docker | `~/Library/Containers/com.docker.docker/Data/vms` | 주의 | `docker system df` 표시 후 `docker system prune` |
| Homebrew | `~/Library/Caches/Homebrew` | 재생성 가능 | `brew cleanup` |
| AI 도구 | `~/.claude/projects`(세션 jsonl), `~/.codex`, `~/.cursor`, `~/Library/Application Support/Claude` | 주의 | 휴지통(세션 로그만). 메모리 디렉터리(`memory/`)는 정리 대상에서 제외 |
| Git worktree | `git worktree list --porcelain` 으로 수집, 메인 레포와 묶어 표시 | 주의 | `git worktree remove`(미커밋 변경이 있으면 차단) |
| Python | `.venv`·`venv`(안에 `pyvenv.cfg`), `__pycache__`, `~/.cache/pip`, `~/Library/Caches/pip`, `~/.cache/uv`, conda(`~/miniconda3` 등의 `pkgs`·`envs/*`), `~/Library/Caches/pypoetry`, `~/.pyenv/versions/*`, `~/.local/pipx/venvs/*` | 재생성 가능 (설치한 Python·가상 환경·conda envs 는 주의) | 휴지통 / `uv cache clean`·`conda clean --all` |
| Rust | `target/`(옆에 Cargo.toml), `~/.cargo/registry`, `~/.cargo/git`, `~/.rustup/toolchains/*` | 재생성 가능 (toolchain 은 주의) | 휴지통 |
| Go | `~/go/pkg/mod`, `~/Library/Caches/go-build` | 재생성 가능 | 휴지통 |
| Adobe·일반 캐시 | `~/Library/Caches/*`, `~/Library/Application Support/Adobe/Common/Media Cache Files` | 재생성 가능 | 휴지통 |
| 로그·크래시 | `~/Library/Logs`, `~/Library/Logs/DiagnosticReports` | 재생성 가능 | 휴지통 |
| 메일·메시지·사진 | `~/Library/Mail`, `~/Library/Messages`, `Photos Library.photoslibrary` | 수동 확인 | Finder 열기만 |

### 등급 의미

- **재생성 가능**: 원클릭 정리 허용. 삭제해도 다음 빌드·실행 시 다시 만들어지는 것
- **주의**: 확인 다이얼로그와 상세 설명 후 허용. 다시 받는 데 시간이 걸리거나 사용자 데이터가 섞여 있을 수 있는 것
- **수동 확인**: 삭제 버튼 없음. Finder 에서 보기·경로 복사만

분류되지 않은 일반 디렉터리는 Finder 에서 보기·경로 복사·무시 목록 추가만 제공한다.

### 언어별 카테고리와 도구 구분

Python·Rust·Go 는 카드 하나가 아니라 **카테고리 셋**(`python`·`rust`·`go`)이다. 한 카드로 묶으면 어느 언어가 큰지 알 수 없다. 카테고리 rawValue 는 스냅샷 DB 에 저장되므로 값만 더하고, 예전 `pythonRustGo` 행은 마이그레이션하지 않고 읽을 때 건너뛴다.

같은 카테고리 안에서도 "누가 만든 것인가" 를 알아야 무엇을 지울지 정할 수 있으므로 분류 항목은 **도구 이름**(`tool`)을 가진다(예: JavaScript 의 pnpm·npm·yarn·bun·nvm, Python 의 pip·uv·conda·poetry·pyenv·pipx, Rust 의 cargo·rustup, Go 의 "Go 모듈"·"Go 빌드 캐시").

- 규칙이 도구 이름을 **고정**하거나(`~/.cargo/registry` → cargo), 부모 디렉터리의 **잠금 파일**로 고른다. `node_modules` 는 옆의 `pnpm-lock.yaml`(pnpm)·`yarn.lock`(yarn)·`bun.lockb`/`bun.lock`(bun)·`package-lock.json`(npm), `venv`·`.venv` 는 `uv.lock`(uv)·`poetry.lock`(poetry), 없으면 "기타"(`venv` 는 "venv"). 여러 잠금 파일이 함께 있으면 앞에 둔 도구가 이긴다.
- 옆에 잠금 파일이 없으면 가장 가까운 **프로젝트·워크스페이스 루트** 조상의 잠금 파일을 따른다(모노레포: 루트에만 잠금 파일이 있다). 조상은 잠금 파일과 함께 JS 는 `package.json`, Python 은 `pyproject.toml` 이 있어야 루트로 인정하고, **홈 자신은 도구를 물려주지 않는다**(홈에 실수로 남은 `package-lock.json` 이 홈 전체를 npm 으로 바꾸지 않도록). 우선순위는 옆 잠금 파일 > 상속 > 대체값이다.
- 도구 이름이 없는 항목은 카테고리 안에서 "기타" 로 묶는다. 도구가 붙은 항목이 하나도 없는 카테고리는 도구 구분이 없다(Xcode·Gradle 등).
- 일반 캐시 규칙(`~/Library/Caches/*`)에 통째로 걸리는 폴더를 더 구체적으로 나누기 위해 **컨테이너** 경로(예: `~/Library/Caches/pypoetry`)를 둔다: 컨테이너 자체는 태그하지 않고 아래 규칙으로 나눈다.
- 규칙이 많아져도 노드마다 전부 비교하지 않도록 홈 경로 규칙은 깊이별로 묶어 비교한다. 결과는 카탈로그 순서의 "처음 맞는 규칙" 과 같다.
- **이름 규칙 차단**: 디렉터리 이름 규칙(`node_modules`·`build`·`target` 등)은 앱 번들(`*.app`·`*.framework` 등) 안, 홈의 `Library`·`Applications`·숨김 디렉터리 아래, 그리고 `node_modules`·`site-packages` 디렉터리와 파이썬 가상 환경(자기 안에 `pyvenv.cfg` 가 있는 디렉터리) 아래에서는 매칭하지 않는다. 홈 안과 추가 프로젝트 루트 모두 같다. 태그되지 않은 전역 Node 접두사(`~/n`·`/opt/homebrew` 등)의 `lib/node_modules/npm/node_modules` 처럼 패키지 관리자가 동봉한 의존성을 "재생성 가능" 으로 지우면 그 도구가 망가지기 때문이다.

## 6. 정리(Cleanup)

### 절차

1. 사용자가 항목(들)을 고른다
2. `CleanupPlanner` 가 `CleanupPlan` 을 만든다: 대상 목록, 예상 회수 용량, 실행 방법(휴지통/명령), 경고(등급, 실행 중인 관련 앱)
3. 미리보기 시트에 Plan 을 보여준다. 도구 명령은 가능하면 드라이런 결과를 먼저 표시한다(`brew cleanup -n`, `docker system df`, `xcrun simctl list devices unavailable`)
4. 사용자가 실행을 누르면 먼저 권한(전체 디스크 접근)을 다시 확인하고, 계획 때와 달라졌으면 실행하지 않고 "다시 계획" 을 요구한다. 그렇지 않으면 `CleanupExecutor` 가 실행한다
   - 파일/디렉터리: `FileManager.trashItem(at:resultingItemURL:)`
   - 명령: `Process` 로 실행. PATH 는 로그인 셸 PATH 에 `/opt/homebrew/bin`, `/usr/local/bin` 을 더해 해석. stdout/stderr 를 로그 뷰에 남김
5. 완료 후 해당 서브트리만 부분 재스캔
6. 정리 기록(시각, 대상 경로, 회수 용량, 방법, 성공 여부)을 DB 에 남긴다

### 안전 장치

- 홈과 설정의 추가 프로젝트 루트는 정리 허용 루트다. 그 밖의 경로, 심볼릭 링크 대상, `~` 자체, `~/Library` 자체 등 카탈로그가 가리키지 않는 상위 디렉터리는 Planner 가 거부한다
- Xcode·Docker·Android Studio 가 실행 중이면 관련 카테고리 정리 시 경고한다
- Git worktree 는 `git status --porcelain` 이 비어 있지 않으면 제거를 차단한다
- 명령 실행은 사용자가 미리보기에서 명령 문자열을 볼 수 있다

## 7. 시스템 요약 (홈 밖)

트리 스캔 없이 숫자만 수집하는 `SystemSummaryCollector`.

- 볼륨: `statfs` 와 `URLResourceKey.volumeAvailableCapacityForImportantUsageKey` 로 전체·사용·여유·퍼지 가능 용량
- Time Machine 로컬 스냅샷: `tmutil listlocalsnapshots /` 개수. 크기는 API 가 주지 않으므로 개수만 표시하고 `tmutil thinlocalsnapshots` 안내
- 스왑: `sysctl vm.swapusage` 와 `/private/var/vm` 크기
- `/private/var/folders`, `/Library/Caches`: 읽기 가능한 범위만 합산. 거부 시 "Full Disk Access 필요" 배지
- `/Applications`: 상위 20개 앱 번들 크기
- 시스템 설정 앱의 "시스템 데이터" 숫자가 어떤 항목들의 합인지 설명하는 짧은 안내문

Full Disk Access 는 설정 창에서 상태를 보여주고 시스템 설정 패널로 보내는 버튼만 둔다. 없어도 홈의 대부분은 스캔된다(`~/Library/Mail`, Safari, Messages 등 일부만 거부).

## 8. UI

### 메뉴바 아이콘

- 기본은 SF Symbol `internaldrive` 옆에 여유 용량 텍스트(예: `812G`)
- 표시는 템플릿 문자열이다(기본 `{icon}{remain_storage}`). 토큰: `{icon}`, `{remain_storage}`(Finder 의 "사용 가능"), `{remain_percent}`, `{using_storage}`, `{using_storage_percent}`, `{total_storage}`. 다른 글자는 그대로 보이고(예: `{icon}하하하{using_storage_percent}`), 모르는 토큰은 글자 그대로 두고 설정 창에서 경고한다. 보이는 것이 없으면 아이콘만 보인다
- 설정에서 프리셋(남은 용량 / 사용률 / 남은 비율 / 사용 중 용량 / 아이콘만) 또는 직접 입력으로 고르고, 크기를 100~200%(10 단위)로 키울 수 있다. 메뉴바보다 크면 줄이지 않고 세로 가운데에 두어 위아래가 잘린다
- 예전 3가지 형식(여유 용량·사용률 %·아이콘만) 설정은 같은 모양의 템플릿으로 한 번 옮긴다
- 스캔 중에는 아이콘이 은은하게 펄스

### 팝오버 (너비 420pt)

- 상단: 볼륨 바(사용/퍼지 가능/여유 3색), 숫자, 마지막 스캔 시각
- 중단: 카테고리 카드 리스트(아이콘, 이름, 크기, 7일 변화량 화살표). 카드를 누르면 분석 윈도우가 해당 카테고리로 열림. 재생성 가능 등급은 카드 우측에 "정리" 버튼
- 카드의 도구 줄: 도구가 2개 이상인 카테고리는 크기 아래에 상위 도구를 크기 순으로 한 줄 보인다("pnpm 12 GB · npm 3.1 GB"). 폭이 모자라면 항목 중간에서 자르지 않고 3개 → 2개 → 1개로 줄이며, 툴팁에 전체 도구 목록을 보인다. 0 바이트 도구는 뺀 뒤 도구가 0~1개면 줄을 비워 둔다(카테고리 합계와 같아 보여 줄 것이 없다). 줄을 비워도 두 번째 줄 높이는 잡아 모든 카드 높이가 같다. 크기(오른쪽 맞춤)와 변화량은 고정 폭 열, "정리"·"v0.2 에서 지원" 은 그 오른쪽 고정 폭 열(오른쪽 맞춤, 없으면 빈 열)이라 크기 숫자가 세로로 맞는다
- 전체 디스크 접근 배너: 권한이 없거나, 허용됐어도 마지막 결과가 아직 보호 폴더를 건너뛴 결과면 카드 위에 한 줄("권한이 없어 N곳을 건너뜀" + "권한 허용…", 허용된 뒤에는 "다시 스캔하면 반영됩니다" + "지금 스캔"). 툴팁에 건너뛴 폴더 목록 (10장)
- 하단: "지금 스캔", "분석 윈도우 열기", 설정, 종료
- 바깥 클릭이나 포커스 이동 시 닫힘

### 분석 윈도우 (일반 윈도우, 기본 1000×680)

좌측 사이드바로 7개 뷰를 전환한다.

1. **홈 트리맵**: squarified treemap 을 SwiftUI `Canvas` 로 직접 그린다. 클릭으로 드릴다운, 브레드크럼으로 복귀, 호버 툴팁(경로·크기·mtime·태그·색). 우클릭 메뉴: Finder 에서 보기, 경로 복사, 정리(등급 허용 시), 무시 목록 추가. 칸의 색·글자·카테고리 표시는 아래 "트리맵 칸 표시" 참고
2. **카테고리**: 카테고리 → 항목 테이블(경로, 크기, 마지막 수정, 등급, 도구). 다중 선택 후 "선택 항목 정리". 사이드바의 카테고리는 도구가 2개 이상이면 펼쳐 도구별 합계를 보이고, 도구를 고르면 테이블이 그 도구의 항목만 보인다("모든 카테고리"·카드 클릭은 도구 선택을 지운다). "도구" 열은 도구 구분이 있는 카테고리에서 도구 없는 항목을 사이드바처럼 "기타" 로 보이고, 도구 구분이 없는 카테고리는 비워 둔다
3. **Git worktree**: 레포별로 메인 + worktree 목록(브랜치, 크기, 마지막 커밋 날짜, 머지 여부, 미커밋 변경 여부)
4. **큰 파일**: 리프 상위 200개
5. **시스템 요약**: 7장 내용
6. **정리 기록**: 시각·대상·회수 용량·방법, 월별 합계
7. **트리** (v0.1): 홈과 추가 프로젝트 루트(홈과 나란한 최상위 행)를 Finder 목록 보기처럼 펼치는 계층. 아래 "트리 뷰" 참고

### 트리맵 칸 표시

칸 색은 카테고리가 아니라 **경로**가 정한다(카테고리 색은 칸 색으로 쓰지 않는다). 카테고리는 띠와 기호로 따로 보인다.

- **경로 해시 색**: 모든 칸(분류·미분류·큰 파일·나머지 칸)을 절대 경로에서 뽑은 24비트 색(`0xRRGGBB`)으로 그대로 칠한다. 채도·밝기 보정은 없다. 색은 `fold24(fmix64(fnv1a64(경로의 UTF-8)))` 이다. Swift `Hasher` 는 실행마다 시드가 바뀌므로 쓰지 않는다(재스캔·재시작해도 같은 칸은 같은 색). 경로 끝의 `/` 는 떼고 해시하므로 `~/foo` 와 `~/foo/foo` 는 이름이 같아도 색이 다르다. "나머지 N개" 칸은 부모 경로 + `/\0remainder` 를 해시해 실제 자식 경로와 겹치지 않는다. FNV-1a 만으로는 마지막 글자만 다른 형제(`app0`…`app9`, 연도 폴더)의 색이 비슷해져 `fmix64`(murmur3 마무리 섞기)를 더했다
- **글자**: 칸 바탕의 보색(255 − 각 채널)에 **항상 검은 외곽선**(1.25pt)을 두른다. 외곽선 패스(획만)를 먼저 그리고 채우기 패스를 겹쳐 글자 안쪽을 먹지 않게 한다. 이름 12pt semibold, 크기 12pt(이전 10pt 의 1.2배). 글자는 칸이 72×36pt 이상일 때만 그린다
- **카테고리 표시**: 분류된 칸은 위쪽에 4pt 카테고리 색 띠 + 1pt 검은 구분선(바탕이 띠와 비슷한 색이어도 띠가 보이게)을 두고, 칸이 넉넉하면 모서리에 반투명 검은 바탕의 흰 카테고리 기호 배지를 둔다(Canvas 심볼로 한 번 만들어 칸마다 다시 쓴다). 미분류 칸은 띠·배지가 없다
- **호버**: 검은·흰 이중 테두리를 칸 안쪽 2pt 에 그려 어떤 바탕색에서도 보인다. 툴팁 맨 아래에 "색 #XXXXXX" 와 작은 견본을 보인다
- 알려진 한계: 보색 글자는 중간 회색 바탕(전체 색의 약 1.6%)에서 대비가 약하다. 색은 라이트·다크 모양과 무관하게 같은 값이라 다크 모드에 맞춰 조정되지 않는다
- 트리 뷰 이름 칸에는 같은 경로 해시 색의 견본(10pt 둥근 사각형, `tertiaryLabelColor` 테두리)이 아이콘과 이름 사이에 있어 트리맵 칸과 짝을 지을 수 있다

### 트리 뷰

트리맵이 보여 주는 큰 덩어리를 폴더 단위로 따라 내려가 "이 폴더 아래에 정확히 무엇이 얼마나" 를 볼 때 쓴다.

- 구현은 AppKit `NSOutlineView` 다. 데이터 소스가 **펼친 행의 자식만** 만들어(lazy) 자식이 수만 개인 폴더도 멈추지 않고, 펼침 상태를 코드로 읽고 바꿀 수 있어 스캔·정리로 새 결과가 오면 아직 있는 경로를 되살린다
- 열: 이름 · 크기 · 비율(부모 대비 막대) · **파일 수**(하위 전체 파일 수) · 카테고리 · 도구. 이름 칸에는 트리맵 칸과 같은 경로 해시 색 견본이 있다. 행은 크기 내림차순(같으면 이름순). 디렉터리 바로 아래의 임계치 미만 작은 파일은 "나머지 파일 N개" 한 줄로 묶는다. 파일 수를 쓰는 이유: 스캐너가 작은 파일을 트리에 남기지 않아 직속 "항목 수" 는 실제와 달라 오해를 부르고, 하위 전체 파일 수는 이미 정확히 알고 있다
- 우클릭 메뉴는 트리맵·카테고리 테이블과 같은 규칙이다: 우클릭한 행이 선택에 들어 있으면 선택 전체, 아니면 그 행. Finder 에서 보기, 경로 복사, 정리(정확히 그 경로가 분류 항목이고 휴지통 정리 가능한 것만, 기존 미리보기 시트), 무시 목록 추가(디렉터리, 최상위 행 제외), **트리맵에서 보기**(폴더는 그 폴더, 파일은 든 폴더, "나머지 파일" 줄은 그 줄이 속한 폴더). 나머지 줄은 실제 경로가 아니라 파일 동작에서 빠진다
- 펼침은 기억해 둔다(최근 2,000개까지 LRU, 오래 쓰지 않은 것부터 잊는다). 새 결과·다른 뷰를 갔다 와도 펼침·선택이 남고, 처음에는 홈 한 단계를 펼쳐 둔다
- 접근성: 비율 막대는 VoiceOver 가 백분율을 읽는다(레벨 표시기). 카테고리 점은 라이트·다크 전환을 따라 색이 바뀐다

### 설정 창

- 일반: 로그인 시 실행(`SMAppService.mainApp`, 기본 꺼짐), 메뉴바 표시(프리셋·템플릿 입력·토큰 도움말·크기·미리보기), 전체 디스크 접근 상태("허용됨"/"허용 안 됨")와 시스템 설정 열기 버튼(v0.1 은 일반에 둔다)
- 스캔: 주기, 리프 임계치, 제외 경로, 추가 프로젝트 루트(홈 밖 레포를 분류 대상에 포함하고 싶을 때)
- 알림: 여유 용량 임계치 GB, 카테고리별 임계치 GB
- 권한: Full Disk Access 상태와 시스템 설정 열기 버튼 (v0.1 은 위 일반 항목에 포함)
- 업데이트: Sparkle 자동 확인

## 9. 모니터링·스냅샷·알림

### 스케줄

- `ScanScheduler`: 앱 시작 30초 후 첫 스캔, 이후 설정 주기(기본 6시간)
- 배터리 전원이거나 저전력 모드이면 그 회차를 건너뛰고 다음 주기로. 시스템 유휴 판단은 하지 않는다(단순화)
- 여유 용량은 60초마다 `statfs` 로만 갱신

### 스냅샷 (GRDB)

```
snapshots(id, at, volume_total, volume_used, volume_available, volume_purgeable, limited)  -- limited: 전체 디스크 접근 없이 잰 제한 스캔 (10장)
snapshot_categories(snapshot_id, category, size, item_count)
snapshot_top_dirs(snapshot_id, path, size)          -- 상위 100개
cleanup_log(id, at, path, category, method, reclaimed_bytes, succeeded, message)
```

- 스캔이 끝까지 완료됐을 때만 스냅샷을 저장한다
- 보관: 90일 지난 스냅샷은 하루 1개로 압축, 1년 지나면 삭제
- 카테고리가 나뉘거나 없어진 뒤에는 저장된 이전 카테고리 값(예: 예전 `pythonRustGo`)을 알 수 없으므로 읽을 때 그 행을 건너뛴다. 그래서 나뉘기 전 스냅샷이 기준이 되는 동안(최대 약 7일)은 새 카테고리의 7일 변화량이 크게 보일 수 있다
- 팝오버·카테고리 뷰의 변화량은 "현재 vs 7일 전 가장 가까운 스냅샷" 으로 계산. 기준은 현재 스캔과 같은 범위(`limited` 값)의 스냅샷만 고르고, 없으면 변화량을 보여 주지 않는다. 보관 압축도 날짜·범위마다 1개를 남긴다

### 알림 (`UNUserNotificationCenter`)

- 여유 용량이 임계치(기본 50GB) 아래
- 한 카테고리가 임계치(기본 30GB) 초과
- 같은 조건은 24시간에 1회만
- 알림 클릭 시 분석 윈도우의 해당 뷰로 이동

## 10. 오류 처리·권한

- 접근 거부는 오류가 아니라 노드 상태. 요약 화면에 "접근하지 못한 디렉터리 N개" 와 FDA 안내를 보여준다
- **전체 디스크 접근(FDA)**: 앱은 권한을 요청할 수 없고 상태를 확인해 시스템 설정을 열어 줄 수만 있다. 권한은 확인용 파일(`TCC.db`·Safari 북마크·`~/Library/Mail`)을 읽기 전용으로 열어 보아 판단하고(열림 = 허용, EPERM/EACCES = 거부, 모두 없으면 거부로 간주), 스캔 시작·앱 활성화·정리 계획 직전에 다시 확인한다
- 권한이 없으면 macOS 가 보호 폴더마다 동의 창을 띄우므로, 스캔은 보호 위치(데스크탑·문서·다운로드·iCloud Drive·다른 앱의 컨테이너·클라우드 저장소·연락처·캘린더, `*.photoslibrary`)를 읽지 않고 건너뛰는 **제한 스캔**으로 돈다. 사진 보관함은 홈 안에서만이 아니라 추가 프로젝트 루트(외장 볼륨 등) 안에서도 이름으로 건너뛴다. 건너뛴 위치는 스캔 결과에 남겨 팝오버 배너·툴팁으로 알린다. 판정은 글자 비교만 하고(lstat·realpath 도 동의 창을 띄운다), 보호 위치 안의 제외 경로·부분 재스캔·정리 대상은 읽기 전에 거른다(정리는 "전체 디스크 접근 권한이 없어 정리할 수 없습니다"). 추가 프로젝트 루트는 보호 위치 규칙을 적용하지 않지만, 권한이 없을 때 건너뛰는 위치 안쪽을 가리키는 루트는 realpath 없이 글자로 판정한다(글자로 홈 안이면 기존 "홈과 겹침" 사유, 홈 밖의 사진 보관함 안이면 새 사유 "권한 필요"). 설정 창은 그런 루트를 추가하지 않고 "권한을 허용한 뒤 다시 추가하세요" 라고 안내하며, 저장된 값은 행 옆에 경고를 보이고 스캔은 건너뛴다. 심볼릭 링크로 사진 보관함에 들어가는 루트는 resolve 뒤 같은 규칙으로 거부한다
- 처음 실행 때 권한이 없으면 안내 창을 한 번 띄운다(스캔을 막거나 미루지 않는다). 팝오버 배너의 "권한 허용…" 으로 다시 열 수 있고, 권한이 허용된 것을 감지하면 바로 다시 스캔한다. 설정 창·안내 창·정리 계획처럼 사용자가 다른 일을 하는 중의 권한 확인은 상태만 갱신하고, 새로 허용된 것을 보면 재스캔을 미뤄 둔다. 미룬 재스캔은 다음 앱 활성화, 설정 창·안내 창 닫기, 팝오버 열기 중 먼저 오는 때에 한다(앱이 활성 상태로 남아 활성화 알림이 오지 않아도 묻히지 않게 한다. 스캔 중이면 하지 않고, 그 사이 시작된 스캔은 권한을 반영하므로 미룬 요청을 버린다). 정리 미리보기를 연 채 스캔이 시작될 수 있고, 계획이 낡으면 "다시 계획" 이 현재 결과로 맞춘다 창의 "다시 시작" 은 .app 번들·실제 홈에서만 보인다
- 스냅샷은 제한 스캔 여부(`limited`)를 함께 저장하고 변화량은 같은 범위끼리만 비교한다(9장). 권한을 허용한 직후 보호 폴더 크기가 전부 증가로 보이지 않게 하기 위해서다
- 스캔 중 디렉터리가 사라지면 그 노드만 건너뛴다
- 도구 명령 실패(비 0 종료, 바이너리 없음)는 로그 뷰에 stderr 를 그대로 표시하고, 부분 성공도 기록한다
- 휴지통 이동 실패(외장 볼륨·권한)는 항목별로 실패 표시하고 나머지는 계속한다
- 실행 직전과 "Finder 에서 보기" 직전에 권한을 다시 확인한다. 미리보기를 연 채 전체 디스크 접근을 거두면 계획이 낡은 것으로 보고("스캔 결과나 권한 상태가 바뀌었습니다. 다시 계획하세요.") 보호 위치 안의 항목을 읽거나 옮기지 않아 macOS 동의 창이 뜨지 않는다. Finder 보기는 스캔 결과가 아는 파일 종류를 써서 경로를 stat 하지 않는다
- 두 번째 인스턴스 실행 방지(Paster 의 InstanceLock 패턴 재사용)
- 스캔 중 앱 종료 시 그냥 취소한다. 미완료 스캔은 스냅샷을 저장하지 않는다

## 11. 테스트

- StoragerCore 단위 테스트(임시 디렉터리에 고정 트리 생성):
  - 크기 합산, 하드링크 중복 제거, 심볼릭 링크 무시
  - 리프 임계치 동작
  - 분류 규칙 매칭(글롭, "옆에 package.json" 조건)
  - CleanupPlanner 의 등급별 허용·거부, 예상 회수 용량, 상위 디렉터리 거부
  - 스냅샷 저장·조회·압축·삭제
  - worktree 파서(`git worktree list --porcelain` 고정 출력)
- 트리맵 레이아웃은 순수 함수로 두고 면적 비율 보존·경계 안 배치 테스트
- UI 는 수동 확인. `make run` 으로 개발 빌드 실행

## 12. 릴리스 단계

- **v0.1**: 홈 스캔 + 분류(Python·Rust·Go 분리, 도구 구분) + 메뉴바 아이콘·팝오버(도구 줄) + 분석 윈도우(트리맵·카테고리(도구 필터)·큰 파일·트리) + 휴지통 정리(재생성 가능 등급 중 정리 방법이 휴지통인 항목만. 시뮬레이터·Homebrew 처럼 도구 명령이 필요한 항목은 v0.1 에서 정리 버튼 대신 "v0.2 에서 지원" 안내만 표시) + 스냅샷·7일 변화량 표시 + 설정(일반·스캔). 앱 버전은 0.1.0(`CFBundleShortVersionString`, `make app` 의 기본값)
- **v0.2**: 도구 명령 정리(simctl·brew·docker·npm), 주의 등급 정리, Git worktree 뷰, 알림, 설정(알림)
- **v0.3**: 시스템 요약 뷰, FDA 안내·설정(권한), 정리 기록 뷰·월별 통계, Sparkle 자동 업데이트, GitHub Releases 배포

구현 계획은 v0.1 부터 작성한다.

## 13. 범위 밖 (YAGNI)

- FSEvents 기반 실시간 증분 갱신
- 디스크 전체(`/`) 트리 스캔
- CPU·메모리·네트워크 모니터링(Barrun 영역)
- 외장 볼륨·네트워크 볼륨 스캔
- 중복 파일 탐지
- Intel Mac 지원
