#!/bin/zsh
# Godot 프로젝트 정적 검증 — 리소스 임포트와 GDScript 파싱이 통과하는지 확인.
# 씬을 .tscn 대신 코드로 조립하기 때문에(scripts/main.gd 주석 참고) 구성 오류를
# 잡을 유일한 자동 수단이 이 헤드리스 실행이다.
#
#   GODOT_BIN=/path/to/Godot_v4.7.1-stable_macos.universal ./scripts/verify-project.sh
#
# ⚠️ mono(.NET) 빌드로는 실행할 수 없다 — 헤드리스 기동이 .NET 초기화 단계에서
# 멈춘다(2026-09-03 이 머신의 4.6.3-mono에서 실측). 표준 빌드가 필요하다.
set -e
cd "$(dirname "$0")/.."

GODOT_BIN="${GODOT_BIN:-godot}"
EXPECTED_VERSION="${EXPECTED_GODOT_VERSION:-4.7.1}"

VERSION_LINE="$("$GODOT_BIN" --version 2>&1 | head -1)"
echo "[verify] Godot: $VERSION_LINE"
case "$VERSION_LINE" in
  *mono*)
    echo "ERROR: mono 빌드는 헤드리스 검증/웹 export가 불가합니다. 표준 빌드를 지정하세요."
    exit 1
    ;;
esac
case "$VERSION_LINE" in
  ${EXPECTED_VERSION}*) ;;
  *)
    echo "WARN: 고정 버전($EXPECTED_VERSION)과 다릅니다 — 배포 서버와 결과가 갈릴 수 있습니다."
    ;;
esac

echo "[verify] 리소스 임포트..."
"$GODOT_BIN" --headless --path . --import

echo "[verify] 메인 씬 헤드리스 실행(180프레임)..."
"$GODOT_BIN" --headless --path . --quit-after 180

echo "[verify] 통과 — 임포트/파싱/기동 정상"
