// 재접속(같은 토큰으로 다시 들어오기) 전송 계층 테스트.
//
// 왜 별도 파일인가: server-world.test.mjs는 WorldState(순수 상태)를 직접
// 검증하는데, 이 버그는 **소켓 수명과 상태의 상호작용**에서 나온다 —
// 새 소켓이 토큰을 이어받은 뒤 옛 소켓의 close가 도착하는 순서. 실제 서버를
// 띄우고 WS로 붙어야 재현된다.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
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
  // **우리 프로세스가 스스로 "떴다"고 말할 때까지** 기다린다.
  // healthz 폴링만으로는 안 된다: 그 포트를 남이 이미 잡고 있으면 첫 요청이
  // 바로 200을 받고(우리 서버는 아직 부팅 중이라 EADDRINUSE로 죽기 전이다)
  // **엉뚱한 월드에 붙은 채로** 검증이 진행된다 — 임시 WORLD_STATE_PATH 격리도
  // 그때는 무의미해진다.
  await new Promise((resolve, reject) => {
    const check = () => { if (srvLog.includes('서버 기동')) resolve(); };
    srv.stdout.on('data', check);
    srv.on('exit', (code, sig) => reject(new Error(
      `테스트 서버가 뜨지 못했다(code=${code}, sig=${sig}, ${PORT} 포트 점유?)\n${srvLog}`)));
    setTimeout(() => reject(new Error(`테스트 서버 기동 시간 초과\n${srvLog}`)), 8000).unref();
    check();
  });

  const url = `ws://127.0.0.1:${PORT}/ws`;
  // 관찰자 — 남의 화면에서 어떻게 보이는지를 이 소켓으로 판정한다.
  const observer = await open(url);
  observer.send(JSON.stringify({ t: 'join', token: WATCHER, name: 'Watcher', preset: 'f1' }));
  await waitFor(observer, (m) => m.t === 'welcome');

  const first = await open(url);
  first.send(JSON.stringify({ t: 'join', token: DALLY, name: 'Dally', preset: 'f1' }));
  await waitFor(observer, (m) => m.t === 'join' && m.player?.token === DALLY);

  // 같은 토큰으로 다시 들어온다(폰이 절전에서 깨어나 재접속하는 상황).
  const second = await open(url);
  second.send(JSON.stringify({ t: 'join', token: DALLY, name: 'Dally', preset: 'f1' }));
  await waitFor(second, (m) => m.t === 'welcome');

  // 옛 소켓의 close가 서버에 도착할 시간을 준다(서버가 직접 끊는다).
  await new Promise((r) => setTimeout(r, 400));

  const left = observer.messages.some((m) => m.t === 'leave' && m.token === DALLY);
  assert.equal(left, false, '재접속했는데 남들에게 leave가 갔다 — 캐릭터가 화면에서 사라진다');

  // 서버 상태에도 남아 있어야 한다: 새 스냅샷에 보이는지로 확인한다.
  const third = await open(url);
  third.send(JSON.stringify({ t: 'join', token: LATE, name: 'Late', preset: 'f1' }));
  const snap = await waitFor(third, (m) => m.t === 'snapshot');
  const names = (snap.players ?? []).map((p) => p.token);
  assert.ok(names.includes(DALLY), `스냅샷에 재접속한 캐릭터가 없다: ${names.join(',')}`);

  // 재접속한 소켓의 조작이 서버에 먹어야 한다(플레이어가 지워졌으면 무시된다).
  second.send(JSON.stringify({ t: 'move', x: 3, z: 4, dir: 'down' }));
  const moved = await waitFor(observer, (m) => m.t === 'move' && m.moves?.some((v) => v.token === DALLY));
  assert.ok(moved, '재접속 후 이동이 남들에게 전달되지 않는다');

  for (const s of [observer, first, second, third]) { try { s.close(); } catch { /* 이미 닫힘 */ } }
});

test('welcome의 you는 목록 밖 외형도 원값으로 보낸다(남에게는 걸러진다)', async (t) => {
  // 이 규약에 테스트가 없어서 "welcome도 걸러 보내자"는 회귀가 실제로 났다.
  // 걸러 보내면 클라이언트가 그 값을 로컬 슬롯에 반영하고, 유저가 꾸미기를 한 번만
  // 건드려도 서버의 appearance()가 통째 교체해 디스크에서 지킨 값이 사라진다.
  const dir = mkdtempSync(join(tmpdir(), 'af-welcome-'));
  const statePath = join(dir, 'state.json');
  writeFileSync(statePath, JSON.stringify({
    players: [{
      token: DALLY, name: 'Dally', preset: 'f1', x: 0, z: 0, dir: 'down', bells: 0,
      inventory: {}, custom: { hair: '__개명된키__' },
    }],
  }));
  const port = PORT + 1;
  const srv = spawn('node', ['server/index.js'], {
    env: { ...process.env, PORT: String(port), TLS: 'off', HOST: '127.0.0.1', WORLD_STATE_PATH: statePath },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let srvLog = '';
  srv.stdout.on('data', (d) => { srvLog += d.toString(); });
  srv.stderr.on('data', (d) => { srvLog += d.toString(); });
  t.after(() => srv.kill());
  await new Promise((resolve, reject) => {
    const check = () => { if (srvLog.includes('서버 기동')) resolve(); };
    srv.stdout.on('data', check);
    srv.on('exit', (code, sig) => reject(new Error(
      `테스트 서버가 뜨지 못했다(code=${code}, sig=${sig})\n${srvLog}`)));
    setTimeout(() => reject(new Error(`테스트 서버 기동 시간 초과\n${srvLog}`)), 8000).unref();
    check();
  });

  const url = `ws://127.0.0.1:${port}/ws`;
  const me = await open(url);
  me.send(JSON.stringify({ t: 'join', token: DALLY, name: 'Dally', preset: 'f1' }));
  const welcome = await waitFor(me, (m) => m.t === 'welcome');
  assert.equal(welcome.you.custom.hair, '__개명된키__',
    `welcome이 자기 외형을 걸러 보냈다: ${JSON.stringify(welcome.you.custom)}`);

  // 남에게는 걸러져야 한다 — 방송 지점은 스냅샷·join 둘이다.
  const other = await open(url);
  other.send(JSON.stringify({ t: 'join', token: LATE, name: 'Late', preset: 'f1' }));
  const snap = await waitFor(other, (m) => m.t === 'snapshot');
  const row = (snap.players ?? []).find((p) => p.token === DALLY);
  assert.ok(row, '스냅샷에 상대가 없다');
  assert.equal(row.custom.hair, undefined,
    `목록 밖 외형이 남의 스냅샷에 실렸다: ${JSON.stringify(row.custom)}`);

  // **방송 지점은 셋이다**(스냅샷·join·appearance). 옷만 바꿨을 때 목록 밖 hair가
  // appearance 방송으로 남에게 새지 않는지 — 19차에 그 구멍이 실제로 뚫렸다.
  me.messages.length = 0;
  other.messages.length = 0;
  me.send(JSON.stringify({ t: 'appearance', custom: { hair: '__개명된키__', outfit: 'outfit_yellow' } }));
  const mine = await waitFor(me, (m) => m.t === 'appearance');
  assert.equal(mine.custom.hair, '__개명된키__', '자기에게 걸러진 값이 왔다(로컬 슬롯이 덮인다)');
  const theirs = await waitFor(other, (m) => m.t === 'appearance');
  assert.equal(theirs.custom.hair, undefined,
    `목록 밖 외형이 남에게 방송됐다: ${JSON.stringify(theirs.custom)}`);
  assert.equal(theirs.custom.outfit, 'outfit_yellow', '정상 값이 남에게 안 갔다');

  for (const sock of [me, other]) { try { sock.close(); } catch { /* 이미 닫힘 */ } }
});
