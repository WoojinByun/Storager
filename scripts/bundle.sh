#!/bin/bash
# Storager.app 을 조립하고 서명한다.
# 사용법: scripts/bundle.sh [release|debug]
#   release -> build/Storager.app        (make app, make install)
#   debug   -> build/debug/Storager.app  (make run, 번들 ID com.wjbyun.Storager.dev)
# 환경 변수:
#   VERSION       CFBundleShortVersionString (기본 0.1.0)
#   SIGN_IDENTITY 서명 인증서 이름 (기본 "Storager Local Signing").
#                 "-" 를 명시하면 ad-hoc 서명 (인증서가 없는 곳 전용. 로그인 항목 등 권한이 빌드마다 초기화된다)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VERSION="${VERSION:-0.1.0}"
IDENTITY="${SIGN_IDENTITY:-Storager Local Signing}"
PLIST_BUDDY=/usr/libexec/PlistBuddy
CODESIGN_TIMEOUT=60

# release·debug 모두 같은 규칙: 버전은 x.y.z 형식이어야 한다 (기본값 0.1.0, make app / make run 도 Makefile 의 같은 기본값)
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: VERSION 은 x.y.z 형식이어야 합니다 (받은 값: '$VERSION')." >&2
    exit 1
fi

case "$CONFIG" in
    release) APP="build/Storager.app" ;;
    debug) APP="build/debug/Storager.app" ;;
    *)
        echo "error: 사용법: $0 [release|debug]" >&2
        exit 1
        ;;
esac

if [ "$IDENTITY" = "-" ]; then
    echo "warning: SIGN_IDENTITY=- : ad-hoc 서명합니다 (배포용이 아님)." >&2
elif IDENTITIES="$(security find-identity -v -p codesigning)"; ! grep -qF "\"$IDENTITY\"" <<<"$IDENTITIES"; then
    echo "error: 코드 서명 인증서 '$IDENTITY' 가 키체인에 없습니다." >&2
    echo "       먼저 'make cert' 를 실행해 인증서를 만드세요." >&2
    echo "       (인증서 없이 빌드만 확인하려면 SIGN_IDENTITY=- 로 ad-hoc 서명할 수 있습니다.)" >&2
    exit 1
fi

# 빌드 번호는 커밋 수. v0.3 Sparkle 도입 시 단조 증가가 필요하므로 main 에는 squash merge 하지 않는다.
BUILD_NUMBER="$(git rev-list --count HEAD)"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
EXECUTABLE="$APP/Contents/MacOS/Storager"
cp "$BIN_DIR/Storager" "$EXECUTABLE"
# SwiftPM 리소스 번들이 생기면 Bundle.module 이 Contents/Resources 에서 찾는다
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
# 앱 아이콘 (Resources/AppIcon.icns 는 scripts/make-icon.sh 로 만들어 커밋해 둔다)
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
"$PLIST_BUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
# 개발 빌드는 번들 ID 를 나눠 설치본과 동시에 띄운다. 설정(UserDefaults)·로그인 항목은 번들 ID 를 따르고,
# 잠금 파일·스냅샷 DB 는 AppEnvironment 가 번들 ID 로 폴더(Storager.dev)를 고른다.
if [ "$CONFIG" = "debug" ]; then
    "$PLIST_BUDDY" -c "Set :CFBundleIdentifier com.wjbyun.Storager.dev" "$PLIST"
    "$PLIST_BUDDY" -c "Set :CFBundleName Storager Dev" "$PLIST"
    "$PLIST_BUDDY" -c "Set :CFBundleDisplayName Storager Dev" "$PLIST"
fi

# rpath 정리: SwiftPM 이 넣는 빌드 머신의 절대 경로 rpath (예: /Users/<이름>/.../.build/...) 는
# 바이너리에 사용자 이름을 남기고 쓸모도 없으므로 지운다. 서명 전에 해야 한다.
rpaths() {
    otool -l "$EXECUTABLE" | awk '$1 == "cmd" { rpath = ($2 == "LC_RPATH") } rpath && $1 == "path" { print $2 }'
}
while IFS= read -r rpath; do
    case "$rpath" in
        /Users/* | "$PWD"*)
            install_name_tool -delete_rpath "$rpath" "$EXECUTABLE"
            ;;
    esac
done < <(rpaths)
# 파이프 대신 변수에 받아 둔다: grep -q 가 먼저 끝나면 앞 명령이 SIGPIPE 로 죽어 pipefail 이 거짓 실패를 낸다
REMAINING_RPATHS="$(rpaths)"
if grep -qE "^(/Users/|$PWD)" <<<"$REMAINING_RPATHS"; then
    echo "error: 실행 파일에 절대 경로 rpath 가 남아 있습니다:" >&2
    echo "$REMAINING_RPATHS" >&2
    exit 1
fi

# codesign 이 로그인 키체인의 개인 키에 처음 접근할 때 macOS 가 "codesign 이(가) 키에 접근하려고 합니다" 창을 띄운다.
# 응답이 없으면 무한정 기다리므로 시간 제한을 둔다.
# timeout 은 macOS 기본 명령이 아니다 (Homebrew coreutils). 없으면 시간 제한 없이 실행한다.
sign() {
    local status=0
    if command -v timeout >/dev/null 2>&1; then
        timeout "$CODESIGN_TIMEOUT" codesign --force --sign "$IDENTITY" "$@" || status=$?
    else
        codesign --force --sign "$IDENTITY" "$@" || status=$?
    fi
    if [ "$status" -eq 124 ]; then
        echo "error: codesign 이 ${CODESIGN_TIMEOUT}초 안에 끝나지 않았습니다." >&2
        echo "       키체인 접근 허용 창이 떠 있다면 로그인 암호를 입력하고 '항상 허용' 을 누른 뒤 다시 실행하세요." >&2
    fi
    if [ "$status" -ne 0 ]; then
        exit "$status"
    fi
}

# Hardened Runtime(-o runtime)은 쓰지 않는다: notarize 하지 않는 자체 서명 빌드다. --deep 은 쓰지 않는다.
sign "$APP"
codesign --verify --deep --strict "$APP"

echo "$APP ($VERSION, build $BUILD_NUMBER, $CONFIG)"
