# 빌드 게이트의 오류 패턴을 읽어 `$ERROR_PATTERNS`에 담는다. **두 게이트 스크립트가
# 이 파일을 `source` 한다** — 읽는 로직까지 각자 복사하면 그 사본이 또 갈린다
# (패턴 목록을 한 곳으로 모은 이유와 같다).
#
# 부르는 쪽이 `cd` 하기 **전에** source 할 것: 경로를 여기서 절대경로로 고정한다.

_EP_DIR="$(cd "$(dirname "$0")" && pwd)"
ERROR_PATTERNS_FILE="$_EP_DIR/error-patterns.txt"

# **없거나 비면 멈춘다.** `grep -F -f <없는파일>`은 exit 2인데 `if ... grep -q`는
# 그걸 "패턴 없음 = 정상"으로 읽어, 단일 출처가 조용한 단일 실패점이 된다.
[ -s "$ERROR_PATTERNS_FILE" ] || {
  echo "ERROR: 오류 패턴 파일이 없거나 비어 있습니다: $ERROR_PATTERNS_FILE"
  exit 1
}

# **CR을 벗긴다.** `.gitattributes`가 이 파일을 CRLF로 체크아웃하므로(Windows
# 배포 서버의 findstr가 읽는다), 그대로 쓰면 패턴이 `SCRIPT ERROR\r`가 되고
# Godot 로그 줄(`SCRIPT ERROR: ...`)과 **영영 매치되지 않는다** — 게이트가 죽었는데
# 초록불이 되는 형태다(2026-09-16 리뷰 지적).
ERROR_PATTERNS="$(tr -d '\r' < "$ERROR_PATTERNS_FILE")"

# **카나리아.** 위 두 검사는 "파일이 있다"까지만 말한다 — 내용이 매치 불가능해진
# 상태는 아무도 못 본다. 알려진 오류 줄을 실제로 잡는지 확인하고, 못 잡으면 멈춘다.
printf 'SCRIPT ERROR: canary\n' | grep -qF -e "$ERROR_PATTERNS" || {
  echo "ERROR: 오류 패턴이 알려진 Godot 오류 줄조차 잡지 못합니다 — 게이트가 죽었습니다."
  echo "       확인: $ERROR_PATTERNS_FILE (줄바꿈·인코딩·빈 줄)"
  exit 1
}
