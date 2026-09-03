#!/bin/zsh
# 로컬(macOS/Linux) 웹 export — 배포 서버의 deploy.bat과 동일한 단계를 밟는다.
# Godot 표준(non-mono) 빌드가 필요하다: mono 빌드에는 웹 export 템플릿이 없고
# 헤드리스 실행도 .NET 초기화에서 멈춘다(2026-09-03 이 머신에서 실측).
#
#   GODOT_BIN=/path/to/Godot_v4.7.1-stable_macos.universal ./scripts/build-web.sh
set -e
cd "$(dirname "$0")/.."

GODOT_BIN="${GODOT_BIN:-godot}"

if ! command -v "$GODOT_BIN" > /dev/null 2>&1 && [ ! -x "$GODOT_BIN" ]; then
  echo "ERROR: Godot 실행 파일을 찾을 수 없음: $GODOT_BIN"
  echo "       GODOT_BIN 환경변수로 표준(non-mono) 빌드 경로를 지정하세요."
  exit 1
fi

# 배포 서버가 쓰는 버전(deploy.bat의 GODOT_VERSION)과 다르면 export 결과가
# 갈릴 수 있으므로 확인한다 — 로컬 검증이 통과했는데 서버에서 깨지는 상황을 막는다.
EXPECTED_VERSION="${EXPECTED_GODOT_VERSION:-4.7.1}"

VERSION_LINE="$("$GODOT_BIN" --version 2>&1 | head -1)"
echo "[build-web] Godot: $VERSION_LINE (고정 버전: $EXPECTED_VERSION)"
case "$VERSION_LINE" in
  *mono*)
    echo "ERROR: mono(.NET) 빌드는 웹 export를 지원하지 않습니다. 표준 빌드를 사용하세요."
    exit 1
    ;;
esac
case "$VERSION_LINE" in
  ${EXPECTED_VERSION}*) ;;
  *)
    echo "WARN: 배포 서버 고정 버전($EXPECTED_VERSION)과 다른 빌드입니다 — 서버 결과와 갈릴 수 있습니다."
    echo "      의도한 것이면 EXPECTED_GODOT_VERSION 환경변수로 기대 버전을 바꿔 주세요."
    ;;
esac

mkdir -p build/web
echo "[build-web] 리소스 임포트..."
"$GODOT_BIN" --headless --path . --import
echo "[build-web] Web export..."
"$GODOT_BIN" --headless --path . --export-release "Web" build/web/index.html

if [ ! -f build/web/index.html ] || ! ls build/web/*.wasm > /dev/null 2>&1; then
  echo "ERROR: export 산출물이 불완전합니다(build/web/index.html 또는 .wasm 없음)"
  exit 1
fi
echo "[build-web] 완료 — node server/index.js 로 확인하세요 (http://localhost:3001)"
