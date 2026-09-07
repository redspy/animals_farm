import { test } from 'node:test';
import assert from 'node:assert/strict';
import { envOf, envIsOff } from '../server/env.js';

// cmd의 `set VAR=값 && cmd`가 값에 뒤 공백을 담는 함정. 배포에서 두 번 물렸으므로
// (TLS가 "off "가 되어 https로 떴고, 그 상태로 http 헬스체크가 실패했다) 여기에
// 고정한다 — 다음에 누가 `process.env.X ||`로 되돌리면 이 테스트가 깨진다.

test('뒤 공백이 붙은 값도 같은 값으로 읽는다', () => {
  assert.equal(envOf({ TLS: 'off ' }, 'TLS'), 'off');
  assert.equal(envOf({ PORT: '3001 ' }, 'PORT'), '3001');
  assert.equal(envOf({ HOST: ' 0.0.0.0' }, 'HOST'), '0.0.0.0');
  assert.equal(envOf({ TLS_CERT: '/tmp/dev-cert.pem ' }, 'TLS_CERT'), '/tmp/dev-cert.pem');
});

test('비어 있거나 공백뿐이면 폴백을 쓴다', () => {
  // `PORT=" "`가 Number(" ")===0으로 랜덤 포트에 뜨던 동작도 이걸로 막힌다.
  assert.equal(envOf({}, 'PORT', '3001'), '3001');
  assert.equal(envOf({ PORT: '' }, 'PORT', '3001'), '3001');
  assert.equal(envOf({ PORT: '   ' }, 'PORT', '3001'), '3001');
  assert.equal(envOf({ HOST: undefined }, 'HOST', '0.0.0.0'), '0.0.0.0');
});

test('TLS=off 판정은 공백·대소문자를 무시한다', () => {
  for (const v of ['off', 'off ', ' off', 'OFF', 'Off ']) {
    assert.ok(envIsOff('TLS', { TLS: v }), `${JSON.stringify(v)}가 off로 안 읽힌다`);
  }
  // 값이 없으면 off가 아니다 — 인증서가 있으면 https로 뜨는 기존 동작을 지킨다.
  for (const v of ['', '   ', 'on', undefined]) {
    assert.ok(!envIsOff('TLS', { TLS: v }), `${JSON.stringify(v)}가 off로 읽힌다`);
  }
});
