// 낚시 E2E — 실제 브라우저에서 낚시터에 가서 물고기를 낚는다(F4).
//
// 왜 브라우저인가: 낚시는 (a) 낚시터 탭 → 이동 → 도착 시 활동 켜짐,
// (b) 대기 → 물기 상태 전이, (c) 제한 시간 안의 액션 입력, (d) 서버가 굴린
// 확률 테이블 결과가 맞물려 동작한다. **무엇이 잡히는지(시간·월 조건, 가중치)는
// 서버 유닛 테스트가 보고**, 여기서는 흐름과 UI 상태만 본다.
//
// 판정은 훅(state.fishing / bagCount / lastGather)으로 한다 — 스크린샷 해시로
// 판정하면 토스트 때문에 실패도 통과가 된다(과거 사례).
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import WebSocket from 'ws';
import { tapGodot } from './godot-tap.mjs';

const PORT = Number(process.env.PORT || 3186);
const OUT = process.env.SHOT_DIR || 'build/screenshots/fishing';
const results = [];
const check = (ok, label) => {
  results.push({ ok, label });
  console.log(`  ${ok ? 'ok ' : '❌ '} — ${label}`);
};

const statePath = join(mkdtempSync(join(tmpdir(), 'af-fishing-')), 'world.json');
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
  fishing: String(window.afTest?.state?.fishing ?? ''),
  bag: Number(window.afTest?.state?.bagCount ?? 0),
  last: String(window.afTest?.state?.lastGather ?? ''),
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
// 낚시터까지 걸어가 낚시를 해 본다.
// ---------------------------------------------------------------------------
import { readFileSync } from 'node:fs';

const gcfg = JSON.parse(readFileSync('data/gatherables.json', 'utf-8'));
const fishCfg = JSON.parse(readFileSync('data/activities.json', 'utf-8')).fishing;
// 스폰(0,0)에서 가장 가까운 낚시터를 고른다 — 좌표를 박으면 데이터를 고칠 때
// 조용히 엉뚱한 자리를 탭한다.
const spot = gcfg.spawns
  .map((s, index) => ({ ...s, index }))
  .filter((s) => s.kind === 'fishing')
  .sort((a, b) => Math.hypot(a.x, a.z) - Math.hypot(b.x, b.z))[0];
console.log(`\n[검증] 낚시 — 목표 낚시터 (${spot.x}, ${spot.z}) index=${spot.index}`);

// z를 먼저 맞추고 x를 맞춘다(대각선으로 가면 바위·벽에 걸려 멈춘다).
await walkTo('z', spot.z + 1.2);
await walkTo('x', spot.x);
const near = await state();
const dist = Math.hypot(near.x - spot.x, near.z - spot.z);
check(dist < 3.0, `낚시터 근처까지 이동 (거리 ${dist.toFixed(2)})`);

// (1) 낚시터를 탭하면 다가가서 낚시가 켜진다.
await clickWorld(spot.x, spot.z);
const casting = await waitState((s) => s.fishing === 'wait', 12000);
check(casting.fishing === 'wait', `낚시터를 탭하면 낚시가 시작된다 (fishing=${casting.fishing})`);
check(casting.act === 'fishing', `활동이 낚시로 바뀐다 (act=${casting.act})`);
await page.screenshot({ path: `${OUT}/1-낚시-대기.png` }).catch(() => {});

// (2) 물기 전에 누르면 헛챔질 — 가방은 늘지 않는다.
const bagBefore = (await state()).bag;
await page.keyboard.press('Space');
const early = await waitState((s) => s.fishing === 'off', 3000);
check(early.fishing === 'off', '물기 전에 누르면 낚시가 끝난다(헛챔질)');
check(early.bag === bagBefore, `헛챔질로는 가방이 늘지 않는다 (${bagBefore} → ${early.bag})`);

// (3) 다시 던지고 **물 때까지** 기다렸다가 누르면 잡힌다.
await clickWorld(spot.x, spot.z);
await waitState((s) => s.fishing === 'wait', 12000);
const maxWait = Number(fishCfg.wait_max_sec) * 1000 + 3000;
const bit = await waitState((s) => s.fishing === 'bite', maxWait);
check(bit.fishing === 'bite', `기다리면 물고기가 문다 (fishing=${bit.fishing})`);
await page.screenshot({ path: `${OUT}/2-낚시-물기.png` }).catch(() => {});
const bagAtBite = bit.bag;
await page.keyboard.press('Space');
const caught = await waitState((s) => s.bag > bagAtBite, 6000);
check(caught.bag > bagAtBite, `제한 시간 안에 채면 잡힌다 (가방 ${bagAtBite} → ${caught.bag})`);
// 가방 개수(inventory 메시지)와 획득 아이템(gathered 브로드캐스트)은 **다른
// 메시지**라 훅 게시(0.25초)가 그 사이에 끼면 lastGather가 아직 비어 있다 —
// 개수만 보고 단정하면 간헐 실패가 된다.
const named = await waitState((s) => s.last.length > 0, 4000);
const fishIds = new Set(gcfg.catch_tables.fishing.map((r) => r.item));
check(fishIds.has(named.last), `잡힌 것이 낚시 테이블의 항목이다 (${named.last})`);
check(caught.fishing === 'off', '잡으면 낚시가 끝난다');
await page.screenshot({ path: `${OUT}/3-낚시-성공.png` }).catch(() => {});

// (4) 물었는데 놓치면 가방이 늘지 않고 상태만 풀린다.
//     낚시터는 방금 잡아서 쿨다운(respawn_sec)이라, 다른 낚시터를 쓴다.
// **서쪽 낚시터를 고른다.** 동쪽으로 가면 x≈7.5의 석벽(z −20.5~−15.5)에 막혀
// 걷다가 멈추고, 그러면 탭 지점이 화면 밖이라 낚시가 시작되지 않는다(실측).
const others = gcfg.spawns
  .map((s, index) => ({ ...s, index }))
  .filter((s) => s.kind === 'fishing' && s.index !== spot.index);
const westward = others.filter((s) => s.x < caught.x - 3.0);
const other = (westward.length ? westward : others)
  .sort((a, b) => Math.hypot(a.x - caught.x, a.z - caught.z) - Math.hypot(b.x - caught.x, b.z - caught.z))[0];
console.log(`   두 번째 낚시터 (${other.x}, ${other.z})`);
await walkTo('x', other.x);
await walkTo('z', other.z + 1.2);
const near2 = await state();
console.log(`   도착 위치 (${near2.x.toFixed(1)}, ${near2.z.toFixed(1)}) — 목표까지 ${Math.hypot(near2.x - other.x, near2.z - other.z).toFixed(2)}`);
await clickWorld(other.x, other.z);
let cast2 = await waitState((s) => s.fishing === 'wait', 12000);
if (cast2.fishing !== 'wait') {
  // 한 번 더 시도한다 — 도착 판정과 탭이 한 프레임 어긋나면 놓친다.
  await clickWorld(other.x, other.z);
  cast2 = await waitState((s) => s.fishing === 'wait', 8000);
}
if (cast2.fishing === 'wait') {
  const bit2 = await waitState((s) => s.fishing === 'bite', maxWait);
  const bagAtBite2 = bit2.bag;
  // 아무 것도 누르지 않고 제한 시간을 넘긴다.
  await page.waitForTimeout(Number(fishCfg.bite_sec) * 1000 + 900);
  const missed = await state();
  check(missed.fishing === 'off', `놓치면 낚시가 끝난다 (fishing=${missed.fishing})`);
  check(missed.bag === bagAtBite2, `놓치면 가방이 늘지 않는다 (${bagAtBite2} → ${missed.bag})`);
} else {
  check(false, `두 번째 낚시터에서 낚시가 시작되지 않았다 (fishing=${cast2.fishing})`);
}

check(errors.length === 0, `브라우저 오류·서버 거절 0건 (실제 ${errors.length}건)`);
if (errors.length) console.log(errors.slice(0, 6).join('\n'));

await browser.close();
observer.close();
stop();

const failed = results.filter((r) => !r.ok);
console.log('');
if (failed.length) {
  console.error(`❌ 낚시 테스트 실패 ${failed.length}건`);
  for (const f of failed) console.error(`  - ${f.label}`);
  process.exit(1);
}
console.log('✅ 낚시 테스트 통과 — 낚시터 탭 → 대기 → 물기 → 채기 흐름과 헛챔질·놓침 처리');
