// 놀이터 E2E — 실제 브라우저에서 놀이기구 네 개를 타 본다.
//
// 왜 브라우저인가: 탑승은 (a) 기구 탭 → 좌석까지 이동 → 도착 시 탑승,
// (b) 서버의 좌석 배정, (c) 스프라이트 교체, (d) 보이는 위치 오프셋이 맞물려
// 동작한다. 서버 단위 테스트는 규칙만 보고, 헤드리스 Godot은 파싱만 본다.
//
// 남의 화면에 어떻게 보이는지는 **WS 옵저버**로 판정한다(운동장 테스트와 같은
// 방식) — 화면 렌더 타이밍에 흔들리지 않는다.
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import WebSocket from 'ws';
import { tapGodot } from './godot-tap.mjs';

const PORT = Number(process.env.PORT || 3185);
const OUT = process.env.SHOT_DIR || 'build/screenshots/park';
const results = [];
const check = (ok, label) => {
  results.push({ ok, label });
  console.log(`  ${ok ? 'ok ' : '❌ '} — ${label}`);
};

const statePath = join(mkdtempSync(join(tmpdir(), 'af-park-')), 'world.json');
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
 *  훅이 주는 playerScreen과 groundRight/Down(각 +3유닛)으로 축척을 역산한다 —
 *  직교 카메라라 화면 x는 월드 x, 화면 y는 월드 z에 비례한다. */
async function clickWorld(x, z) {
  const pt = await page.evaluate(([wx, wz]) => {
    const t = window.afTest;
    const c = document.querySelector('canvas');
    const r = c.getBoundingClientRect();
    const ps = t.points.playerScreen;
    const gr = t.points.groundRight;
    const gd = t.points.groundDown;
    const px = Number(t.state.x);
    const pz = Number(t.state.z);
    const sxPerX = (gr[0] - ps[0]) / 3.0;
    const syPerZ = (gd[1] - ps[1]) / 3.0;
    const vx = ps[0] + (wx - px) * sxPerX;
    const vy = ps[1] + (wz - pz) * syPerZ;
    return { x: r.left + (vx / t.vw) * r.width, y: r.top + (vy / t.vh) * r.height };
  }, [x, z]);
  await page.mouse.click(pt.x, pt.y);
}

/** 기구 근처로 걸어가 그 기구를 클릭해 탄다. */
async function ride(x, z) {
  await walkTo('x', x);
  await walkTo('z', z);
  await page.waitForTimeout(400);
  await clickWorld(x, z);
  return await waitState((s) => s.act !== '', 9000);
}

// --- 놀이터 진입 ---
console.log('\n[검증] 놀이터 진입');
await walkTo('z', 14.0);
const atPark = await waitState((s) => s.zone === 'park');
check(atPark.zone === 'park', `놀이터 존에 들어왔다 (zone=${atPark.zone}, z=${atPark.z})`);
await page.screenshot({ path: `${OUT}/1-놀이터.png` }).catch(() => {});

// --- 미끄럼틀: 사다리를 탭하면 올라가 내려오고 저절로 끝난다 ---
console.log('\n[검증] 미끄럼틀');
const park = JSON.parse(
  (await import('node:fs')).readFileSync('data/world.json', 'utf-8')).park;
const slide = park.slide;
await walkTo('x', slide.ladder_x);
await walkTo('z', slide.ladder_z);
await page.waitForTimeout(400);
await clickWorld(slide.ladder_x, slide.ladder_z);
// 다 내려오면 활동이 저절로 끝나고 출구에 선다.
const afterSlide = await waitState(
  (s) => s.act === '' && Math.abs(s.z - slide.exit_z) < 1.2, 15000);
check(Math.abs(afterSlide.z - slide.exit_z) < 1.2,
  `미끄럼틀을 타고 출구까지 내려왔다 (z=${afterSlide.z}, 출구 ${slide.exit_z})`);
check(afterSlide.act === '', '다 내려오면 저절로 내린다');
await page.screenshot({ path: `${OUT}/2-미끄럼틀.png` }).catch(() => {});

// --- 그네: 앉고, 액션으로 진폭을 올린다 ---
console.log('\n[검증] 그네');
const swingSeat = { x: park.swing.x, z: park.swing.z - park.swing.seat_gap / 2 };
const onSwing = await ride(swingSeat.x, swingSeat.z);
check(onSwing.act === 'swing', `그네에 앉았다 (act=${onSwing.act}, trick=${onSwing.trick})`);
check(!!(await waitFor((m) => m.t === 'activity' && m.activity === 'swing')),
  '그네에 앉은 것이 다른 기기에도 전달된다');
await page.keyboard.press('Space');
const higher = await waitState((s) => s.trick.includes(':'), 5000);
check(higher.trick.includes(':'), `액션 버튼으로 더 높이 흔든다 (trick=${higher.trick})`);
await page.screenshot({ path: `${OUT}/3-그네.png` }).catch(() => {});

// --- 앉은 채로는 걸어 나갈 수 없다 ---
const seatPos = await state();
await hold('ArrowUp', 1200);
const stillSeated = await state();
const drift = Math.hypot(stillSeated.x - seatPos.x, stillSeated.z - seatPos.z);
check(drift < 0.8, `앉은 채로 방향키를 눌러도 자리를 벗어나지 않는다 (${drift.toFixed(2)})`);

// --- 내리기 버튼 ---
await tapGodot(page, 'exercise1');
const off = await waitState((s) => s.act === '');
check(off.act === '', '내리기 버튼으로 내려온다');

// --- 뺑뺑이: 슬롯에 타고 밀면 돈다 ---
console.log('\n[검증] 뺑뺑이');
const slotZ = park.carousel.z - (park.carousel.radius - 0.35);
const onCarousel = await ride(park.carousel.x, slotZ);
check(onCarousel.act === 'carousel', `뺑뺑이에 탔다 (act=${onCarousel.act}, 자리 ${onCarousel.trick})`);
seen.length = 0;
await page.keyboard.press('Space');
const spun = await waitFor((m) => m.t === 'park' && Math.abs(m.park.carouselSpeed) > 0.05);
check(!!spun, `밀면 돌기 시작하고 그 상태가 전달된다 (속도 ${spun?.park?.carouselSpeed})`);
await page.screenshot({ path: `${OUT}/4-뺑뺑이.png` }).catch(() => {});
await tapGodot(page, 'exercise1');
await waitState((s) => s.act === '');

// --- 시소: 앉고 밀면 기운다 ---
console.log('\n[검증] 시소');
const seesawSeat = { x: park.seesaw.x - park.seesaw.arm, z: park.seesaw.z };
const onSeesaw = await ride(seesawSeat.x, seesawSeat.z);
check(onSeesaw.act === 'seesaw', `시소에 앉았다 (act=${onSeesaw.act}, 자리 ${onSeesaw.trick})`);
seen.length = 0;
await page.keyboard.press('Space');
const tilted = await waitFor((m) => m.t === 'park' && Math.abs(m.park.seesaw) > 0.02);
check(!!tilted, `밀면 기울고 그 상태가 전달된다 (기울기 ${tilted?.park?.seesaw})`);
await page.screenshot({ path: `${OUT}/5-시소.png` }).catch(() => {});

check(errors.length === 0, `브라우저 오류·서버 거절 0건 (실제 ${errors.length}건)`);
if (errors.length) console.log(errors.slice(0, 6).join('\n'));

await browser.close();
observer.close();
stop();

const failed = results.filter((r) => !r.ok);
console.log('');
if (failed.length) {
  console.error(`❌ 놀이터 테스트 실패 ${failed.length}건`);
  process.exit(1);
}
console.log('✅ 놀이터 테스트 통과 — 미끄럼틀·그네·뺑뺑이·시소를 타고 밀고 내린다');
