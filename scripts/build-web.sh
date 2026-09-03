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
# 고정 버전의 단일 출처는 저장소 루트 .godot-version (deploy.bat도 같은 파일을 읽는다)
EXPECTED_VERSION="${EXPECTED_GODOT_VERSION:-$(cat .godot-version 2>/dev/null || echo 4.7.1)}"

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
    # 경고만 하고 통과시키면 4.8 등 다른 버전으로도 로컬 검증이 통과해
    # "고정 버전"이 실질적으로 강제되지 않는다(2026-09-03 Codex 감사 지적).
    if [ "${ALLOW_GODOT_VERSION_MISMATCH:-0}" != "1" ]; then
      echo "ERROR: 고정 버전($EXPECTED_VERSION)이 아닌 빌드입니다 — 배포 서버와 결과가 갈릴 수 있습니다."
      echo "       의도한 것이면 ALLOW_GODOT_VERSION_MISMATCH=1 로 다시 실행하거나 .godot-version을 갱신하세요."
      exit 1
    fi
    echo "WARN: 고정 버전과 다른 빌드로 계속합니다(ALLOW_GODOT_VERSION_MISMATCH=1)."
    ;;
esac

# 배포(deploy.bat Step 4)와 동일하게 이전 산출물을 지운다 — 지우지 않으면
# 삭제된 에셋이나 구버전 파일이 로컬 결과에 남아 "같은 빌드 재현"이 깨진다
# (2026-09-03 Codex 감사 지적).
rm -rf build/web
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
