VERSION ?= 0.1.0
DEV_APP := build/debug/Storager.app
DEV_BIN := $(CURDIR)/$(DEV_APP)/Contents/MacOS/Storager
INSTALLED_BIN := /Applications/Storager.app/Contents/MacOS/Storager

.PHONY: cert app install test run icon

# 최초 1회: 자체 서명 인증서 "Storager Local Signing" (로그인 암호 입력 필요)
cert:
	./scripts/make-cert.sh

# build/Storager.app (release) 빌드 + 서명
app:
	VERSION=$(VERSION) ./scripts/bundle.sh release

# /Applications 로 복사하고 실행. 설치된 Storager 만 종료한다 (make run 으로 띄운 개발 빌드는 건드리지 않음)
install: app
	@pkill -f "^$(INSTALLED_BIN)$$" && sleep 1 || true
	rm -rf /Applications/Storager.app
	ditto build/Storager.app /Applications/Storager.app
	open /Applications/Storager.app

test:
	swift test

# 개발용 실행: debug 빌드를 같은 인증서로 서명해 build/debug/Storager.app 으로 연다.
# 번들 ID 가 com.wjbyun.Storager.dev 라 설치본과 동시에 뜨고, 설정·로그인 항목·
# 데이터 폴더(~/Library/Application Support/Storager.dev)가 설치본과 섞이지 않는다.
# 이 체크아웃의 개발 빌드만 종료한다 (/Applications 에 설치한 Storager 는 건드리지 않음)
run:
	VERSION=$(VERSION) ./scripts/bundle.sh debug
	@pkill -f "^$(DEV_BIN)$$" && sleep 1 || true
	open "$(DEV_APP)"

# 아이콘을 바꿨을 때: Resources/AppIcon.svg -> Resources/AppIcon.icns
icon:
	./scripts/make-icon.sh
