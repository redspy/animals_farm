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
// 낚시터 세 곳에서 각각 다른 시나리오를 확인한다.
//
// **시나리오마다 다른 낚시터를 쓴다.** 한 곳을 공유하면 앞 시나리오가 그 자리를
// 소모(20초 쿨다운)하거나 그 판정이 다음 시나리오에 섞여, 실패가 "왜 그런지 알 수
// 없는" 간헐 실패가 된다(실측: 헛챔질 시나리오가 물기 순간과 겹쳐 물고기를 잡아
// 버리고, 다음 단계의 가방 비교가 어긋났다).
// ---------------------------------------------------------------------------
import { readFileSync } from 'node:fs';

const gcfg = JSON.parse(readFileSync('data/gatherables.json', 'utf-8'));
const fishCfg = JSON.parse(readFileSync('data/activities.json', 'utf-8')).fishing;
const maxWait = Number(fishCfg.wait_max_sec) * 1000 + 3000;

// 남쪽 해안선에서 **두 곳**만 쓴다. 좌표를 박지 않고 데이터에서 고른다 —
// 동쪽으로 가면 x≈7.5의 석벽에, 서쪽 끝(-34)으로 가면 wall_west 근처에서 걷기가
// 막힌다(실측: 목표까지 16유닛을 남기고 멈췄다).
//
// 소모되는 시나리오(성공)만 두 번째 낚시터에서 하고, 소모되지 않는 것(헛챔질·
// 놓침·우회 차단)은 첫 낚시터에서 한다 — 쿨다운이 다음 시나리오에 섞이지 않는다.
// 필터 조건이 타이트한 이유: 남쪽 해안(z < −10)에서 **걸어서 도달 가능한**
// 구간이 x ∈ [−20, 5]뿐이다. 동쪽은 x≈7.5의 석벽(z −20.5~−15.5), 서쪽 끝
// (x=−34)은 wall_west 근처에서 걷기가 막힌다(실측: 16유닛을 남기고 멈췄다).
// 서쪽부터 쓴다 — 석벽 옆(x=5)에서 시나리오 3개를 돌리면 접근 실패가 원인
// 불명으로 보인다.
const spots = gcfg.spawns
  .map((s, index) => ({ ...s, index }))
  .filter((s) => s.kind === 'fishing' && s.z < -10 && s.x <= 5 && s.x >= -20)
  .sort((a, b) => a.x - b.x)
  .slice(0, 2);
if (spots.length < 2) throw new Error(`쓸 수 있는 낚시터가 2곳 미만이다(${spots.length}) — 테스트 전제가 깨졌다`);

/** 낚시터 근처로 걸어간다. */
async function approach(spot) {
  await walkTo('z', spot.z + 1.2);
  await walkTo('x', spot.x);
  const near = await state();
  const dist = Math.hypot(near.x - spot.x, near.z - spot.z);
  check(dist < 3.0, `낚시터(${spot.x}, ${spot.z}) 근처까지 이동 (거리 ${dist.toFixed(2)})`);
  return dist;
}

/** 탭해서 낚시를 시작하고, 시작된 상태를 돌려준다.
 *  낚시 상태는 전이할 때 즉시 게시되므로(world.gd의 _publish_fish_state) 여기서
 *  보는 값은 지연 없는 값이다 — 주기 게시(0.4초)를 기다리면 "물기 전"이라는
 *  전제가 깨진 채로 다음 단계로 넘어간다(최소 대기가 1.5초다). */
async function cast(spot) {
  await clickWorld(spot.x, spot.z);
  const t0 = Date.now();
  let s = await state();
  let retried = false;
  while (Date.now() - t0 < 12000 && s.fishing !== 'wait') {
    if (!retried && Date.now() - t0 > 5000) { retried = true; await clickWorld(spot.x, spot.z); }
    await page.waitForTimeout(40);
    s = await state();
  }
  return s;
}

// --- (1) 물기 전에 누르면 헛챔질 (자리를 소모하지 않는다) ---
console.log(`\n[검증] 헛챔질 — 낚시터 (${spots[0].x}, ${spots[0].z})`);
await approach(spots[0]);
const early = await cast(spots[0]);
check(early.fishing === 'wait', `낚시터를 탭하면 낚시가 시작된다 (fishing=${early.fishing})`);
check(early.act === 'fishing', `활동이 낚시로 바뀐다 (act=${early.act})`);
const seenFishing = await waitFor((m) => m.t === 'activity' && m.activity === 'fishing');
check(!!seenFishing, '낚시 활동이 다른 기기로 전달된다(activity 브로드캐스트)');
await page.screenshot({ path: `${OUT}/1-낚시-대기.png` }).catch(() => {});
await page.keyboard.press('Space');
const afterEarly = await waitState((s) => s.fishing === 'off', 3000);
check(afterEarly.fishing === 'off', '물기 전에 누르면 낚시가 끝난다(헛챔질)');
check(afterEarly.bag === early.bag,
  `헛챔질로는 가방이 늘지 않는다 (${early.bag} → ${afterEarly.bag})`);

// --- (2) 액션 버튼으로 낚시를 우회할 수 없다 ---
// 회귀 방지: _try_gather는 종류를 보지 않고 사거리 안 가장 가까운 것을 캐므로,
// 낚시터 옆에서 버튼만 눌러도 대기·타이밍을 건너뛰고 물고기가 나왔다.
console.log('\n[검증] 우회 차단 — 같은 낚시터에서 액션 버튼만 누른다');
const beforeBypass = await state();
await page.keyboard.press('Space');
const bypass = await waitState((s) => s.fishing === 'wait', 3000);
check(bypass.fishing === 'wait',
  `낚시터 옆에서 액션을 누르면 채집이 아니라 낚시가 시작된다 (fishing=${bypass.fishing})`);
check(bypass.bag === beforeBypass.bag,
  `그 순간 가방이 늘지 않는다 (${beforeBypass.bag} → ${bypass.bag})`);

// --- (3) 물었는데 안 누르면 놓친다 (역시 자리를 소모하지 않는다) ---
console.log('\n[검증] 놓침 — 같은 낚시터, 물었지만 누르지 않는다');
const bitMiss = await waitState((s) => s.fishing === 'bite', maxWait);
check(bitMiss.fishing === 'bite', `기다리면 물고기가 문다 (fishing=${bitMiss.fishing})`);
const bagAtMiss = bitMiss.bag;
await page.waitForTimeout(Number(fishCfg.bite_sec) * 1000 + 900);
const missed = await state();
check(missed.fishing === 'off', `놓치면 낚시가 끝난다 (fishing=${missed.fishing})`);
check(missed.bag === bagAtMiss, `놓치면 가방이 늘지 않는다 (${bagAtMiss} → ${missed.bag})`);

// --- (4) 제한 시간 안에 채면 잡힌다 (이 자리는 소모된다) ---
console.log(`\n[검증] 성공 — 낚시터 (${spots[1].x}, ${spots[1].z})`);
await approach(spots[1]);
const cast2 = await cast(spots[1]);
check(cast2.fishing === 'wait', `두 번째 낚시터에서 낚시가 시작된다 (fishing=${cast2.fishing})`);
const bit = await waitState((s) => s.fishing === 'bite', maxWait);
check(bit.fishing === 'bite', `기다리면 물고기가 문다 (fishing=${bit.fishing})`);
await page.screenshot({ path: `${OUT}/2-낚시-물기.png` }).catch(() => {});
const bagAtBite = bit.bag;
await page.keyboard.press('Space');
const caught = await waitState((s) => s.bag > bagAtBite, 6000);
check(caught.bag > bagAtBite, `제한 시간 안에 채면 잡힌다 (가방 ${bagAtBite} → ${caught.bag})`);
// 가방 개수(inventory)와 획득 아이템(gathered)은 **다른 메시지**라 훅 게시가
// 그 사이에 끼면 lastGather가 아직 비어 있다 — 개수만 보고 단정하면 안 된다.
const named = await waitState((s) => s.last.length > 0, 4000);
const fishIds = new Set(gcfg.catch_tables.fishing.map((r) => r.item));
check(fishIds.has(named.last), `잡힌 것이 낚시 테이블의 항목이다 (${named.last})`);
check(caught.fishing === 'off', '잡으면 낚시가 끝난다');
const seenGathered = await waitFor((m) => m.t === 'gathered' && m.index === spots[1].index);
check(!!seenGathered, `캔 낚시터가 다른 기기에도 전달된다 (item=${seenGathered && seenGathered.item})`);
await page.screenshot({ path: `${OUT}/3-낚시-성공.png` }).catch(() => {});

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
console.log('✅ 낚시 테스트 통과 — 헛챔질·우회 차단·놓침·성공을 낚시터 두 곳에서 확인');
