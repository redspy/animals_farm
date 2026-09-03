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
# 고정 버전의 단일 출처는 저장소 루트 .godot-version (deploy.bat도 같은 파일을 읽는다)
EXPECTED_VERSION="${EXPECTED_GODOT_VERSION:-$(cat .godot-version 2>/dev/null || echo 4.7.1)}"

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
    if [ "${ALLOW_GODOT_VERSION_MISMATCH:-0}" != "1" ]; then
      echo "ERROR: 고정 버전($EXPECTED_VERSION)이 아닌 빌드입니다."
      echo "       의도한 것이면 ALLOW_GODOT_VERSION_MISMATCH=1 로 다시 실행하세요."
      exit 1
    fi
    echo "WARN: 고정 버전과 다른 빌드로 계속합니다(ALLOW_GODOT_VERSION_MISMATCH=1)."
    ;;
esac

# Godot은 GDScript 컴파일/런타임 오류가 있어도 종료 코드 0으로 끝난다 —
# 실제로 game_clock.gd의 컴파일 에러를 이 스크립트가 "통과"로 보고했다
# (2026-09-04 실측). 출력에서 오류 패턴을 직접 걸러야 게이트가 의미를 가진다.
ERROR_PATTERN='SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Invalid call'

run_godot() {
  local label="$1"; shift
  local out
  out="$("$GODOT_BIN" "$@" 2>&1)"
  echo "$out"
  if echo "$out" | grep -qE "$ERROR_PATTERN"; then
    echo "ERROR: $label 단계에서 GDScript 오류가 검출됨(위 로그 참조)."
    return 1
  fi
  return 0
}

echo "[verify] 리소스 임포트..."
run_godot "리소스 임포트" --headless --path . --import

echo "[verify] 세이브 마이그레이션 회귀 테스트..."
# docs/design.md §4가 요구하는 구버전 세이브 로드 테스트 — 세이브 스키마를
# 건드리는 커밋은 반드시 이걸 통과해야 한다.
run_godot "세이브 마이그레이션 테스트" --headless --path . --script tests/test_save_migration.gd

echo "[verify] 메인 씬 헤드리스 실행(180프레임)..."
run_godot "메인 씬 기동" --headless --path . --quit-after 180

echo "[verify] 통과 — 임포트/파싱/기동 정상"
