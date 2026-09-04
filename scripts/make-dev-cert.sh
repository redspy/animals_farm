#!/bin/zsh
# 개발용 자체 서명 인증서 생성.
#
# 왜 필요한가: Godot 4 웹 빌드는 **보안 컨텍스트(secure context)가 아니면 아예
# 실행을 거부**한다("Secure Context - Check web server configuration (use HTTPS)").
# localhost는 브라우저가 보안 컨텍스트로 취급하지만, 같은 와이파이의 폰에서
# http://192.168.x.x:3001 로 붙으면 보안 컨텍스트가 아니라 실행되지 않는다
# (2026-09-04 실기에서 확인).
#
# 그래서 개발 중에도 HTTPS가 필요하다. 이 스크립트는 접속에 쓸 IP/호스트를
# SAN에 넣은 인증서를 만든다 — SAN이 없으면 최신 브라우저가 인증서를 아예
# 거부해서 "예외 허용"조차 안 된다.
#
#   ./scripts/make-dev-cert.sh                 # 자동 감지한 LAN IP 사용
#   ./scripts/make-dev-cert.sh 192.168.0.5 myhost.local
set -e
cd "$(dirname "$0")/.."
mkdir -p server/certs

HOSTS=("$@")
if [ ${#HOSTS[@]} -eq 0 ]; then
  LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
  if [ -z "$LAN_IP" ]; then
    LAN_IP="$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -1)"
  fi
  if [ -z "$LAN_IP" ]; then
    echo "ERROR: LAN IP를 찾지 못했습니다. 인자로 직접 지정하세요: ./scripts/make-dev-cert.sh 192.168.0.5"
    exit 1
  fi
  HOSTS=("$LAN_IP")
fi

SAN="DNS:localhost,IP:127.0.0.1"
for h in "${HOSTS[@]}"; do
  if echo "$h" | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
    SAN="$SAN,IP:$h"
  else
    SAN="$SAN,DNS:$h"
  fi
done
echo "[cert] SAN=$SAN"

openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
  -keyout server/certs/dev-key.pem \
  -out server/certs/dev-cert.pem \
  -subj "/CN=animals_farm-dev" \
  -addext "subjectAltName=$SAN" \
  -days 397 > /dev/null 2>&1

chmod 600 server/certs/dev-key.pem
echo "[cert] 생성 완료: server/certs/dev-cert.pem (유효 397일)"
echo "[cert] 서버를 다시 시작하면 https로 뜹니다. 폰에서는 최초 접속 시 인증서 경고를"
echo "       '고급 → 계속'으로 수락해야 합니다(자체 서명이라 정상적인 경고입니다)."
