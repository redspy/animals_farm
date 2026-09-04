// 재접속(같은 토큰으로 다시 들어오기) 전송 계층 테스트.
//
// 왜 별도 파일인가: server-world.test.mjs는 WorldState(순수 상태)를 직접
// 검증하는데, 이 버그는 **소켓 수명과 상태의 상호작용**에서 나온다 —
// 새 소켓이 토큰을 이어받은 뒤 옛 소켓의 close가 도착하는 순서. 실제 서버를
// 띄우고 WS로 붙어야 재현된다.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import WebSocket from 'ws';

const PORT = 3211;
// 토큰은 uuid 형식만 서버를 통과한다(server/world.js의 TOKEN_RE).
const WATCHER = '11111111-1111-4111-8111-111111111111';
const DALLY = '22222222-2222-4222-8222-222222222222';
const LATE = '33333333-3333-4333-8333-333333333333';

function open(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.messages = [];
    ws.on('message', (raw) => ws.messages.push(JSON.parse(raw.toString('utf-8'))));
    ws.on('open', () => resolve(ws));
    ws.on('error', reject);
  });
}

const waitFor = (ws, pred, ms = 4000) => new Promise((resolve, reject) => {
  const t0 = Date.now();
  const tick = () => {
    const hit = ws.messages.find(pred);
    if (hit) return resolve(hit);
    if (Date.now() - t0 > ms) return reject(new Error('메시지를 기다리다 시간이 초과됨'));
    setTimeout(tick, 30);
  };
  tick();
});

test('같은 토큰으로 다시 들어오면 캐릭터가 사라지지 않는다', async (t) => {
  // 세이브가 개발용 월드를 오염시키지 않도록 임시 디렉터리를 쓴다.
  const statePath = join(mkdtempSync(join(tmpdir(), 'af-reconnect-')), 'world.json');
  const srv = spawn('node', ['server/index.js'], {
    env: { ...process.env, PORT: String(PORT), TLS: 'off', HOST: '127.0.0.1', WORLD_STATE_PATH: statePath },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  // 출력을 버리면 포트 점유(EADDRINUSE)로 서버가 죽었을 때 "메시지를 기다리다
  // 시간이 초과됨"만 남아 원인을 못 찾는다.
  let srvLog = '';
  srv.stdout.on('data', (d) => { srvLog += d.toString(); });
  srv.stderr.on('data', (d) => { srvLog += d.toString(); });
  srv.on('exit', (code) => {
    if (code !== null && code !== 0) console.error(`[테스트 서버 종료 ${code}]\n${srvLog}`);
  });
  t.after(() => srv.kill());
  // 남이 쓰던 서버에 붙으면 엉뚱한 월드를 검증하게 된다 — 우리가 띄운
  // 프로세스가 살아 있는지 함께 확인한다.
  let up = false;
  for (let i = 0; i < 40; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/healthz`);
      if (r.ok) { up = true; break; }
    } catch { /* 아직 */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  assert.ok(up, `테스트 서버가 ${PORT} 포트에 뜨지 않았다(포트 점유?)\n${srvLog}`);
  assert.equal(srv.exitCode, null, `테스트 서버가 죽었다\n${srvLog}`);

  const url = `ws://127.0.0.1:${PORT}/ws`;
  // 관찰자 — 남의 화면에서 어떻게 보이는지를 이 소켓으로 판정한다.
  const observer = await open(url);
  observer.send(JSON.stringify({ t: 'join', token: WATCHER, name: 'Watcher', preset: 'p1' }));
  await waitFor(observer, (m) => m.t === 'welcome');

  const first = await open(url);
  first.send(JSON.stringify({ t: 'join', token: DALLY, name: 'Dally', preset: 'p1' }));
  await waitFor(observer, (m) => m.t === 'join' && m.player?.token === DALLY);

  // 같은 토큰으로 다시 들어온다(폰이 절전에서 깨어나 재접속하는 상황).
  const second = await open(url);
  second.send(JSON.stringify({ t: 'join', token: DALLY, name: 'Dally', preset: 'p1' }));
  await waitFor(second, (m) => m.t === 'welcome');

  // 옛 소켓의 close가 서버에 도착할 시간을 준다(서버가 직접 끊는다).
  await new Promise((r) => setTimeout(r, 400));

  const left = observer.messages.some((m) => m.t === 'leave' && m.token === DALLY);
  assert.equal(left, false, '재접속했는데 남들에게 leave가 갔다 — 캐릭터가 화면에서 사라진다');

  // 서버 상태에도 남아 있어야 한다: 새 스냅샷에 보이는지로 확인한다.
  const third = await open(url);
  third.send(JSON.stringify({ t: 'join', token: LATE, name: 'Late', preset: 'p1' }));
  const snap = await waitFor(third, (m) => m.t === 'snapshot');
  const names = (snap.players ?? []).map((p) => p.token);
  assert.ok(names.includes(DALLY), `스냅샷에 재접속한 캐릭터가 없다: ${names.join(',')}`);

  // 재접속한 소켓의 조작이 서버에 먹어야 한다(플레이어가 지워졌으면 무시된다).
  second.send(JSON.stringify({ t: 'move', x: 3, z: 4, dir: 'down' }));
  const moved = await waitFor(observer, (m) => m.t === 'move' && m.moves?.some((v) => v.token === DALLY));
  assert.ok(moved, '재접속 후 이동이 남들에게 전달되지 않는다');

  for (const s of [observer, first, second, third]) { try { s.close(); } catch { /* 이미 닫힘 */ } }
});
