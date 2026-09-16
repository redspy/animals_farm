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

# 이제 **내용이 매치 불가능해진 상태**를 본다. 존재·비어있음만 보면 BOM이 붙거나
# 한 줄이 오타 나도 초록불이다.
#
# ⚠️ **"패턴이 자기 자신을 매치하는가"는 무의미하다.** 카나리아 줄을 패턴으로부터
# 만들면 BOM 붙은 패턴은 BOM 붙은 카나리아에 매치되어 **항상 통과한다** — 실제로
# 그렇게 짰다가 넷째 줄에 BOM을 넣은 대조가 통과해 버렸다(2026-09-16 실측).
# 그래서 두 가지를 본다: **고정 문자열 카나리아**(파일과 무관한 진짜 Godot 오류 줄)와
# **바이트 위생 검사**(패턴은 ASCII 리터럴이어야 한다 — BOM·CR·빈 줄을 여기서 잡는다).

# 1) 바이트 위생: 출력 가능한 ASCII 밖의 문자가 있으면 멈춘다(BOM U+FEFF, CR 등).
if printf '%s\n' "$ERROR_PATTERNS" | LC_ALL=C grep -q '[^ -~]'; then
  echo "ERROR: $ERROR_PATTERNS_FILE 에 ASCII가 아닌 문자가 있습니다(BOM·CR 등) — 패턴이 매치되지 않습니다."
  printf '%s\n' "$ERROR_PATTERNS" | LC_ALL=C grep -n '[^ -~]' | sed 's/^/       /'
  exit 1
fi

# 2) 빈 줄·공백뿐인 줄: `grep -F -e ""`는 **모든 줄에 매치**해서 정상 빌드까지 실패시킨다.
while IFS= read -r _ep_pat; do
  case "$_ep_pat" in
    *[!\ ]*) ;;
    *)
      echo "ERROR: $ERROR_PATTERNS_FILE 에 빈 줄 또는 공백뿐인 줄이 있습니다 — 모든 줄에 매치됩니다."
      exit 1
      ;;
  esac
done <<EOF
$ERROR_PATTERNS
EOF

# 3) 고정 카나리아: 파일과 무관한 실제 Godot 오류 줄을 정말로 잡는지 본다.
#    **한계**: 이건 첫 패턴 계열이 살아 있는지까지만 말한다. 가운데 한 줄만 오타가
#    나면(예: `Compile Error` → `Complie Error`) 여기서는 안 걸린다 — 줄마다 진짜
#    로그 표본을 두면 그 표본 목록이 또 드리프트한다. 바이트 위생(1)이 흔한 손상은
#    잡으므로 여기까지로 둔다. 남은 구멍을 알고 두는 것이다.
printf 'SCRIPT ERROR: canary\n' | grep -qF -e "$ERROR_PATTERNS" || {
  echo "ERROR: 오류 패턴이 알려진 Godot 오류 줄조차 잡지 못합니다 — 게이트가 죽었습니다."
  echo "       확인: $ERROR_PATTERNS_FILE"
  exit 1
}
