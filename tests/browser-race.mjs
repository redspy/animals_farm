// 달리기 경주 E2E (F2).
//
// **규칙은 서버 유닛 테스트가 본다**(체크포인트 순서·순위·보상·실격). 트랙
// 두 바퀴를 브라우저에서 실제로 걷게 하면 90초를 먹고 카메라·타이밍에 취약한
// 테스트가 된다 — 여기서는 (a) 운동장 안에서만 버튼이 보이는지, (b) 참가하면
// 국면이 lobby → countdown → running으로 넘어가는지, (c) 그 상태가 UI에
// 반영되는지, (d) 포기하면 idle로 돌아가는지를 본다.
//
// 국면은 훅(state.racePhase)으로 판정한다 — 스크린샷 해시로 보면 토스트 때문에
// 실패도 통과가 된다(과거 사례).
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import WebSocket from 'ws';
import { tapGodot } from './godot-tap.mjs';

const PORT = Number(process.env.PORT || 3188);
const OUT = process.env.SHOT_DIR || 'build/screenshots/race';
const results = [];
const check = (ok, label) => {
  results.push({ ok, label });
  console.log(`  ${ok ? 'ok ' : '❌ '} — ${label}`);
};

const statePath = join(mkdtempSync(join(tmpdir(), 'af-race-')), 'world.json');
const srv = spawn('node', ['server/index.js'], {
  env: { ...process.env, PORT: String(PORT), TLS: 'off', HOST: '127.0.0.1', WORLD_STATE_PATH: statePath },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let srvLog = '';
srv.stdout.on('data', (d) => { srvLog += d.toString(); });
srv.stderr.on('data', (d) => { srvLog += d.toString(); });
const stop = () => { try { srv.kill(); } catch { /* 이미 종료 */ } };
process.on('exit', stop);
await new Promise((resolve, reject) => {
  const t0 = Date.now();
  const tick = () => {
    if (srvLog.includes('서버 기동')) return resolve();
    if (srv.exitCode !== null) return reject(new Error(`서버가 죽었다(${PORT} 점유?)\n${srvLog}`));
    if (Date.now() - t0 > 10000) return reject(new Error(`서버 기동 시간 초과\n${srvLog}`));
    setTimeout(tick, 60);
  };
  tick();
});

// 관찰자 — 남의 기기에 무엇이 전달되는지 본다.
const OBSERVER = '88888888-8888-4888-8888-888888888888';
const observer = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
const seen = [];
observer.on('message', (raw) => seen.push(JSON.parse(raw.toString('utf-8'))));
await new Promise((r) => observer.on('open', r));
observer.send(JSON.stringify({ t: 'join', token: OBSERVER, name: 'Watcher', preset: 'f1' }));
const waitFor = (pred, ms = 6000) => new Promise((resolve) => {
  const t0 = Date.now();
  const tick = () => {
    const hit = seen.find(pred);
    if (hit) return resolve(hit);
    if (Date.now() - t0 > ms) return resolve(null);
    setTimeout(tick, 40);
  };
  tick();
});

const browser = await chromium.launch({
  args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
});
const page = await browser.newPage({ viewport: { width: 1200, height: 700 } });
const errors = [];
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
page.on('console', (m) => {
  const text = m.text();
  if (m.type() === 'error' || text.includes('서버 오류')) errors.push(text.slice(0, 200));
});
await page.goto(`http://127.0.0.1:${PORT}/`);
await page.waitForFunction(() => window.afTest?.points?.slot1, null, { timeout: 60000 });

// 캐릭터 만들기 — 이름 입력은 캔버스 위에 겹친 DOM <input>이라 자리가 잡힐
// 때까지 기다려야 한다(사파리 키보드 대응, tests/browser-safari.mjs 참고).
await tapGodot(page, 'slot1');
await page.waitForTimeout(500);
await tapGodot(page, 'preset1');
await page.waitForFunction(() => {
  const el = document.getElementById('af-name-input');
  if (!el || el.style.display === 'none') return false;
  const r = el.getBoundingClientRect();
  if (!(r.width > 200 && r.height > 10 && r.top > 5)) return false;
  const key = `${Math.round(r.left)},${Math.round(r.top)},${Math.round(r.width)}`;
  const same = window.__afNameRect === key;
  window.__afNameRect = key;
  return same;
}, null, { timeout: 20000 });
await tapGodot(page, 'nameField');
await page.keyboard.type('Kid', { delay: 40 });
await page.waitForFunction(
  () => (document.getElementById('af-name-input')?.value ?? '').length >= 3, null, { timeout: 9000 });
await tapGodot(page, 'startButton');
await page.waitForFunction(() => window.afTest?.points?.playerScreen, null, { timeout: 40000 });
await page.waitForTimeout(1500);

const state = async () => await page.evaluate(() => ({
  x: Number(window.afTest?.state?.x ?? 0),
  z: Number(window.afTest?.state?.z ?? 0),
  act: String(window.afTest?.state?.activity ?? ''),
  trick: String(window.afTest?.state?.trick ?? ''),
  zone: String(window.afTest?.state?.zone ?? ''),
  phase: String(window.afTest?.state?.racePhase ?? 'idle'),
  runners: Number(window.afTest?.state?.raceRunners ?? 0),
  bells: Number(window.afTest?.state?.bells ?? 0),
}));
const waitState = async (pred, ms = 6000) => {
  const t0 = Date.now();
  let last = await state();
  while (Date.now() - t0 < ms) {
    if (pred(last)) return last;
    await page.waitForTimeout(150);
    last = await state();
  }
  return last;
};
const hold = async (key, ms) => {
  await page.keyboard.down(key);
  await page.waitForTimeout(ms);
  await page.keyboard.up(key);
  await page.waitForTimeout(250);
};
/** 좌표에 **도달할 때까지** 걷는다(시간으로 거리를 가정하면 안 된다 — 소프트웨어
 *  렌더에서는 실제 이동이 명목 속도의 60% 정도다). */
const walkTo = async (axis, target, timeoutMs = 90000) => {
  const t0 = Date.now();
  let stuck = 0;
  while (Date.now() - t0 < timeoutMs) {
    const s = await state();
    const cur = axis === 'x' ? s.x : s.z;
    if (Math.abs(cur - target) < 1.0) return s;
    const key = axis === 'x'
      ? (cur < target ? 'ArrowRight' : 'ArrowLeft')
      : (cur < target ? 'ArrowDown' : 'ArrowUp');
    await hold(key, 450);
    const after = await state();
    const moved = Math.abs((axis === 'x' ? after.x : after.z) - cur);
    stuck = moved < 0.05 ? stuck + 1 : 0;
    if (stuck >= 8) break;
  }
  return await state();
};

/** 월드 좌표를 화면 좌표로 바꿔 클릭한다.
 *
 *  훅의 groundLeft/Right/Up/Down(플레이어 기준 각 ±3유닛, **모두 지면**)으로
 *  축척과 원점을 역산한다. 직교 카메라 + yaw 0이라 화면 x는 월드 x에, 화면 y는
 *  월드 z에 정확히 비례한다.
 *
 *  playerScreen은 쓰지 않는다 — 그 훅은 캐릭터 **1유닛 위**를 투영하므로
 *  z 축척 계산에 섞으면 어긋난다(실측: 목표에서 1.6유닛 벗어나 시소 좌석을
 *  놓쳤다). */
async function clickWorld(x, z) {
  const pt = await page.evaluate(([wx, wz]) => {
    const t = window.afTest;
    const c = document.querySelector('canvas');
    const r = c.getBoundingClientRect();
    const gl = t.points.groundLeft;
    const gr = t.points.groundRight;
    const gu = t.points.groundUp;
    const gd = t.points.groundDown;
    const px = Number(t.state.x);
    const pz = Number(t.state.z);
    const originX = (gl[0] + gr[0]) / 2;
    const originY = (gu[1] + gd[1]) / 2;
    const sxPerX = (gr[0] - gl[0]) / 6.0;
    const syPerZ = (gd[1] - gu[1]) / 6.0;
    const vx = originX + (wx - px) * sxPerX;
    const vy = originY + (wz - pz) * syPerZ;
    return { x: r.left + (vx / t.vw) * r.width, y: r.top + (vy / t.vh) * r.height };
  }, [x, z]);
  await page.mouse.click(pt.x, pt.y);
}

// ---------------------------------------------------------------------------
// 운동장으로 걸어가 경주를 열고 국면 전이를 확인한다.
// ---------------------------------------------------------------------------
import { readFileSync } from 'node:fs';

const raceCfg = JSON.parse(readFileSync('data/world.json', 'utf-8')).playground.race;
const track = JSON.parse(readFileSync('data/world.json', 'utf-8')).playground.track;

// 경주 버튼은 운동장 밖에서는 없어야 한다(존 전용 UI).
const outside = await page.evaluate(() => window.afTest?.points?.raceButton != null);
check(!outside, '운동장 밖에서는 경주 버튼이 없다');

console.log(`\n[검증] 운동장(${track.x}, ${track.z})으로 이동`);
await walkTo('x', track.x + 3.0);
await walkTo('z', track.z);
const inZone = await waitState((s) => s.zone === 'playground', 20000);
check(inZone.zone === 'playground', `운동장 존에 들어갔다 (zone=${inZone.zone})`);
await page.waitForFunction(() => window.afTest?.points?.raceButton != null, null, { timeout: 8000 });
check(true, '운동장에서는 경주 버튼이 나타난다');
await page.screenshot({ path: `${OUT}/1-운동장.png` }).catch(() => {});

// 참가 → 대기실.
await tapGodot(page, 'raceButton');
const lobby = await waitState((s) => s.phase === 'lobby', 6000);
check(lobby.phase === 'lobby', `참가하면 대기실이 열린다 (phase=${lobby.phase})`);
check(lobby.runners === 1, `참가자 수가 반영된다 (${lobby.runners}명)`);
const seenRace = await waitFor((m) => m.t === 'race' && m.race?.phase === 'lobby');
check(!!seenRace, '경주 상태가 다른 기기로도 전달된다');

// 포기하면 즉시 idle(빈 대기실이 카운트다운을 시작하면 안 된다).
await tapGodot(page, 'raceButton');
const back = await waitState((s) => s.phase === 'idle', 6000);
check(back.phase === 'idle', `포기하면 대기실이 닫힌다 (phase=${back.phase})`);

// 다시 참가해 카운트다운 → 주행까지 본다.
await tapGodot(page, 'raceButton');
await waitState((s) => s.phase === 'lobby', 6000);
const countdownMs = (Number(raceCfg.lobby_sec) + 1) * 1000;
const counting = await waitState((s) => s.phase === 'countdown', countdownMs + 4000);
check(counting.phase === 'countdown', `대기 시간이 끝나면 카운트다운이 시작된다 (phase=${counting.phase})`);
await page.screenshot({ path: `${OUT}/2-카운트다운.png` }).catch(() => {});
const running = await waitState((s) => s.phase === 'running', (Number(raceCfg.countdown_sec) + 3) * 1000);
check(running.phase === 'running', `카운트다운이 끝나면 출발한다 (phase=${running.phase})`);
await page.screenshot({ path: `${OUT}/3-주행.png` }).catch(() => {});

// 출발선 근처에 서 있으므로 첫 체크포인트는 지났을 수 있다 — 진행 값만 확인한다.
const myRunner = await page.evaluate(() => Number(window.afTest?.state?.raceRunners ?? 0));
check(myRunner === 1, `주행 중 참가자가 유지된다 (${myRunner}명)`);

// 타임아웃까지 기다리지 않는다(90초) — 포기로 끝낸다.
await tapGodot(page, 'raceButton');
const ended = await waitState((s) => s.phase === 'idle', 8000);
check(ended.phase === 'idle', `주행 중 포기하면 경주가 끝난다 (phase=${ended.phase})`);

check(errors.length === 0, `브라우저 오류·서버 거절 0건 (실제 ${errors.length}건)`);
if (errors.length) console.log(errors.slice(0, 6).join('\n'));

await browser.close();
observer.close();
stop();

const failed = results.filter((r) => !r.ok);
console.log('');
if (failed.length) {
  console.error(`❌ 경주 테스트 실패 ${failed.length}건`);
  for (const f of failed) console.error(`  - ${f.label}`);
  process.exit(1);
}
console.log('✅ 경주 테스트 통과 — 존 전용 버튼·참가/포기·lobby→countdown→running 전이');
