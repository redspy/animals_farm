import { chromium } from 'playwright';
import { godotPoint, tapGodot } from './godot-tap.mjs';
import WebSocket from 'ws';
import { spawn } from 'child_process';
import { readFileSync } from 'fs';
import { mkdirSync, existsSync, rmSync } from 'fs';

// 2탭 멀티플레이 테스트 — 컨셉의 핵심("다른 기기에서 접속한 캐릭터도 월드맵에서
// 상호작용")을 검증한다. 브라우저 컨텍스트를 분리하므로 세이브(IndexedDB)와
// 토큰이 따로 생겨 "다른 기기"와 같은 조건이 된다.
//
// 판정 방식: **Node WS 옵저버가 서버 브로드캐스트를 직접 받아 확인한다.**
// 처음에는 스크린샷 해시 변화로 판정했는데, 실패한 동작도 토스트 때문에 화면이
// 변해서 거짓 통과했다(2026-09-04 실측 — B의 줍기가 "주변에 채집할 것이 없습니다"로
// 실패했는데 테스트는 통과로 봤다). 화면 변화는 사람이 볼 스크린샷으로 남기고,
// 자동 판정은 프로토콜 사실(누가 어디로 움직였고 무엇을 주웠는지)로 한다.
//
// 실행: npm run test:multiplayer   (사전에 ./scripts/build-web.sh 필요)

const PORT = Number(process.env.PORT || 3113);
const OUT = process.env.SHOT_DIR || 'build/screenshots';
const STATE = 'server/data/world.json';
const OBS_TOKEN = '99999999-9999-4999-8999-999999999999';

// data/gatherables.json에 실제로 있는 나무 좌표(스폰 0,0에서 오른쪽 약 5칸).
// 아무 데서나 Space를 눌러 채집이 되기를 기대했다가 실패한 적이 있어, 데이터에
// 있는 좌표를 근거로 이동 시간을 계산한다(player.gd SPEED=4.2).
const TREE = { x: 5.0, z: 1.0, item: 'wood' };
const WALK_MS = Math.round((TREE.x / 4.2) * 1000) + 150;

if (!existsSync('build/web/index.html')) {
  console.error('ERROR: build/web/index.html이 없습니다 — 먼저 ./scripts/build-web.sh를 실행하세요.');
  process.exit(1);
}
mkdirSync(OUT, { recursive: true });
if (existsSync(STATE)) rmSync(STATE);   // 이전 실행의 캐릭터가 섞이면 판정이 흐려진다

const failures = [];
const check = (cond, what) => {
  if (cond) console.log(`  ok  — ${what}`);
  else { failures.push(what); console.error(`  FAIL — ${what}`); }
};

const server = spawn('node', ['server/index.js'], {
  env: { ...process.env, PORT: String(PORT) },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let serverLog = '';
server.stdout.on('data', (d) => { serverLog += d.toString(); });
server.stderr.on('data', (d) => { serverLog += d.toString(); });
const stopServer = () => { try { server.kill(); } catch { /* 이미 종료 */ } };
process.on('exit', stopServer);

// 서버 기동 대기
let up = false;
for (let i = 0; i < 40; i++) {
  try { if ((await fetch(`http://localhost:${PORT}/healthz`)).ok) { up = true; break; } } catch { /* 아직 */ }
  await new Promise((r) => setTimeout(r, 250));
}
if (!up) { console.error('ERROR: 서버가 /healthz에 응답하지 않음'); process.exit(1); }

// ---------------------------------------------------------------------------
// 옵저버: 서버가 실제로 무엇을 브로드캐스트하는지 기록한다
// ---------------------------------------------------------------------------
const seen = [];
const obs = new WebSocket(`ws://localhost:${PORT}/ws`);
await new Promise((resolve, reject) => {
  obs.on('open', resolve);
  obs.on('error', reject);
});
obs.on('message', (raw) => {
  try { seen.push(JSON.parse(raw.toString('utf-8'))); } catch { /* 무시 */ }
});
obs.send(JSON.stringify({ t: 'join', token: OBS_TOKEN, name: 'Obs', preset: 'm1' }));

/** 옵저버가 본 마지막 좌표 — 클라이언트 내부를 들여다보지 않고 위치를 안다. */
const lastPos = (token) => {
  let pos = null;
  for (const m of seen) {
    if (m.t !== 'move') continue;
    for (const v of m.moves || []) if (v.token === token) pos = { x: v.x, z: v.z };
  }
  return pos;
};

const waitFor = async (pred, what, timeoutMs = 6000) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const hit = seen.find(pred);
    if (hit) return hit;
    await new Promise((r) => setTimeout(r, 100));
  }
  check(false, `${what} (${timeoutMs}ms 안에 서버 브로드캐스트를 못 받음)`);
  return null;
};

// ---------------------------------------------------------------------------
// 브라우저 클라이언트
// ---------------------------------------------------------------------------
const browser = await chromium.launch({
  args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
});

async function newClient(label) {
  const ctx = await browser.newContext({ viewport: { width: 960, height: 540 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(`[${label}] pageerror: ${e.message}`));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(`[${label}] console.error: ${m.text()}`); });
  await page.goto(`http://localhost:${PORT}/`, { waitUntil: 'load', timeout: 30000 });
  await page.waitForSelector('canvas', { timeout: 30000 });
  for (let i = 0; i < 40; i++) {
    const len = await page.evaluate(() => {
      const c = document.querySelector('canvas');
      try { return c ? c.toDataURL('image/png').length : 0; } catch { return 0; }
    });
    if (len > 20000) break;
    await page.waitForTimeout(500);
    if (i === 39) check(false, `[${label}] 캔버스가 20초 안에 그려지지 않음`);
  }
  await page.waitForTimeout(1200);
  return { label, ctx, page, errors };
}

// Godot 캔버스는 DOM 위젯이 아니라 클릭 좌표로 UI를 조작해야 한다.
// 레이아웃은 character_select.gd가 정한다(중앙 정렬, 행 높이 44).
//
// ⚠️ 이름/채팅에 ASCII만 쓰는 이유: Playwright의 합성 키 이벤트로는 Godot 웹
// 빌드에 한글이 입력되지 않는다(IME 조합 이벤트 필요) — 첫 시도에서 이름이 빈
// 채로 제출됐다. 한글 입력은 사람이 확인할 항목으로 남기고, 자동 테스트는
// 파이프라인(입력→서버→상대 화면)이 도는지를 ASCII로 검증한다.
async function pickSlotAndName(client, name) {
  const { page } = client;
  await page.locator('canvas').click({ position: { x: 420, y: 182 } });   // 1번 슬롯
  await page.waitForTimeout(900);
  await page.locator('canvas').click({ position: { x: 480, y: 182 } });   // 첫 프리셋
  await page.waitForTimeout(900);
  await page.locator('canvas').click({ position: { x: 480, y: 218 } });   // 이름 입력창
  await page.waitForTimeout(200);
  await page.keyboard.type(name, { delay: 60 });
  await page.waitForTimeout(200);
  await page.keyboard.press('Enter');
  await page.waitForTimeout(3200);   // 월드 로딩 + WS 접속
}

/** 훅이 준 지점이 화면 안인지 — 화면 밖 좌표를 클릭하면 조용히 아무 일도 없다. */
async function pointOnScreen(page, key) {
  const pt = await godotPoint(page, key);
  const vp = page.viewportSize();
  const inside = pt.x > 6 && pt.y > 6 && pt.x < vp.width - 6 && pt.y < vp.height - 6;
  return inside ? pt : null;
}

const focusGame = async (page) => {
  // 캔버스에 포커스만 준다. 예전에는 캔버스를 **클릭**했는데, 탭-투-무브가
  // 생긴 뒤로는 그 클릭이 곧 "그 지점으로 이동" 명령이 되어 이어지는 키보드
  // 이동 검증이 어긋났다(2026-09-04 실측). 클릭 없이 focus()만 준다.
  await page.evaluate(() => {
    const c = document.querySelector('canvas');
    if (c) { c.setAttribute('tabindex', '0'); c.focus(); }
  });
  await page.waitForTimeout(150);
};

const a = await newClient('A');
const b = await newClient('B');

await a.page.screenshot({ path: `${OUT}/mp-01-슬롯화면.png` });
await pickSlotAndName(a, 'Ara');
await a.page.screenshot({ path: `${OUT}/mp-02-A입장.png` });
await pickSlotAndName(b, 'Bora');
await b.page.waitForTimeout(1200);
await b.page.screenshot({ path: `${OUT}/mp-03-B입장.png` });

console.log('\n[검증] 접속');
const joinA = await waitFor((m) => m.t === 'join' && m.player?.name === 'Ara', 'A 접속이 브로드캐스트됨');
const joinB = await waitFor((m) => m.t === 'join' && m.player?.name === 'Bora', 'B 접속이 브로드캐스트됨');
check(!!joinA, 'A(Ara) 접속');
check(!!joinB, 'B(Bora) 접속');
const tokenA = joinA?.player?.token;
const tokenB = joinB?.player?.token;
check(!!tokenA && !!tokenB && tokenA !== tokenB, '두 클라이언트가 서로 다른 토큰을 쓴다(다른 기기 조건)');

console.log('\n[검증] 캐릭터끼리 겹치지 않는다');
// B를 A 쪽으로 계속 밀어 넣어도 두 캐릭터가 겹치지 않아야 한다.
// 판정은 옵저버가 받은 두 캐릭터 좌표의 최소 거리로 한다.
const SEPARATION = 0.8;
const posA0 = lastPos(tokenA);
await focusGame(b.page);
const overlapFrom = seen.length;

// B가 A에게 다가간다. 훅으로 얻은 A의 화면 좌표는 A가 화면 밖에 있으면
// (-1,-1)이라 클릭이 무의미하므로, **관측 좌표를 보며 방향키로 접근**한다
// (처음엔 훅 클릭만 써서 최소 거리가 13.9로 나왔다 — 애초에 못 만난 것이다).
async function walkTowardA(maxMs = 12000) {
  // 아직 한 번도 움직이지 않은 클라이언트는 move 브로드캐스트가 없어 좌표를
  // 알 수 없다 — 그 상태로 루프를 돌면 즉시 빠져나가 접근을 안 한다(실측:
  // 최소 거리 4.96으로 실패). 먼저 살짝 움직여 좌표를 알린다.
  for (const page of [b.page, a.page]) {
    await page.keyboard.down('ArrowUp');
    await page.waitForTimeout(250);
    await page.keyboard.up('ArrowUp');
  }
  await b.page.waitForTimeout(400);

  const t0 = Date.now();
  let held = null;
  while (Date.now() - t0 < maxMs) {
    const pa = lastPos(tokenA);
    const pb = lastPos(tokenB);
    if (!pa || !pb) {
      await b.page.waitForTimeout(150);
      continue;
    }
    const dx = pa.x - pb.x;
    const dz = pa.z - pb.z;
    if (Math.hypot(dx, dz) < 0.9) break;   // 겹침 한계(0.8)에 닿음
    const key = Math.abs(dx) > Math.abs(dz)
      ? (dx > 0 ? 'ArrowRight' : 'ArrowLeft')
      : (dz > 0 ? 'ArrowDown' : 'ArrowUp');
    if (process.env.MP_DEBUG) console.log(`    [walk] B(${pb.x},${pb.z}) → A(${pa.x},${pa.z}) key=${key}`);
    if (key !== held) {
      if (held) await b.page.keyboard.up(held);
      await b.page.keyboard.down(key);
      held = key;
    }
    await b.page.waitForTimeout(150);
  }
  if (held) await b.page.keyboard.up(held);
}
await walkTowardA();
// 닿은 뒤에도 계속 밀어붙여 본다 — 밀림이 없으면 여기서 겹친다.
const pushKey = ((lastPos(tokenA)?.x ?? 0) > (lastPos(tokenB)?.x ?? 0)) ? 'ArrowRight' : 'ArrowLeft';
await b.page.keyboard.down(pushKey);
await b.page.waitForTimeout(2500);
await b.page.keyboard.up(pushKey);
await b.page.waitForTimeout(600);
await b.page.screenshot({ path: `${OUT}/mp-09-겹침시도.png` });

// 두 캐릭터의 좌표를 시간순으로 짝지어 최소 거리를 구한다.
const trail = { [tokenA]: [], [tokenB]: [] };
for (const m of seen.slice(overlapFrom)) {
  if (m.t !== 'move') continue;
  for (const v of m.moves || []) {
    if (trail[v.token]) trail[v.token].push({ x: v.x, z: v.z });
  }
}
let minDist = Infinity;
const steps = Math.min(trail[tokenA].length, trail[tokenB].length);
for (let i = 0; i < steps; i++) {
  const a2 = trail[tokenA][i];
  const b2 = trail[tokenB][i];
  minDist = Math.min(minDist, Math.hypot(a2.x - b2.x, a2.z - b2.z));
}
// 마지막 좌표 기준 거리도 함께 본다(A가 가만히 있으면 짝지을 표본이 적다).
const finalDist = Math.hypot(
  (lastPos(tokenA)?.x ?? 0) - (lastPos(tokenB)?.x ?? 0),
  (lastPos(tokenA)?.z ?? 0) - (lastPos(tokenB)?.z ?? 0),
);
minDist = Math.min(minDist, finalDist);
console.log(`  (짝지은 표본 ${steps}개, 최종 거리 ${finalDist.toFixed(2)}, 최소 거리 ${minDist.toFixed(2)} / 기준 ${SEPARATION})`);
// 실제로 붙어 본 적이 없으면 이 테스트는 아무것도 검증하지 않는다.
// 판정은 **최소 거리**로 한다 — 밀어붙이면 상대를 지나쳐 다시 멀어지므로
// 최종 거리로는 "붙었는지"를 알 수 없다(실측: 최소 0.80인데 최종 3.82).
check(minDist < SEPARATION + 0.4, `B가 A에게 실제로 닿았다(최소 거리 ${minDist.toFixed(2)})`);
// 0.25는 10Hz 표본 사이의 보간·왕복 지연 여유.
check(minDist > SEPARATION - 0.25, `두 캐릭터가 겹치지 않는다(최소 거리 ${minDist.toFixed(2)})`);

console.log('\n[검증] 위치 동기화 (클릭한 위치로 이동)');
await focusGame(a.page);
// 고정 시간만큼 방향키를 누르는 방식은 포커스 타이밍에 따라 이동량이 달라져
// x=2.8에서 임계값(3)을 못 넘긴 적이 있다 — 탭 이동으로 목표를 주고 도착을 본다.
const groundA = await godotPoint(a.page, 'groundRight');
await a.page.mouse.click(groundA.x, groundA.y);
await a.page.waitForTimeout(2000);
const movedA = await waitFor(
  (m) => m.t === 'move' && (m.moves || []).some((v) => v.token === tokenA && v.x > 1.5),
  'A의 이동이 서버를 거쳐 브로드캐스트됨',
);
check(!!movedA, 'A가 클릭한 지점으로 이동하고 그 위치가 동기화됨');
await b.page.waitForTimeout(600);
await b.page.screenshot({ path: `${OUT}/mp-04-B화면에A이동.png` });

console.log('\n[검증] 대상 클릭 → 자동 채집 → 드랍 → 상대가 클릭해 줍기');
// 나무를 클릭하면 사거리까지 걸어가 자동 채집한다 — "정확한 자리에 서기"를
// 테스트가 흉내낼 필요가 없어져 판정이 안정된다.
const treeA = await godotPoint(a.page, 'nearestGatherable');
await a.page.mouse.click(treeA.x, treeA.y);
await a.page.waitForTimeout(4500);
await a.page.screenshot({ path: `${OUT}/mp-05-A채집.png` });
await a.page.keyboard.press('KeyQ');            // 발밑에 놓기
const added = await waitFor((m) => m.t === 'item_add' && m.item?.item === TREE.item, '드랍이 브로드캐스트됨');
// 채집이 서버 가방에 반영되지 않으면 드랍은 "가방에 없는 아이템"으로 거부된다 —
// 이 단계가 통과하는 것 자체가 채집→서버 반영이 됐다는 증거다.
check(!!added, `나무 클릭으로 자동 채집한 ${TREE.item}을 드랍`);
await a.page.screenshot({ path: `${OUT}/mp-06-A드랍.png` });

// B는 놓인 물건을 클릭해 다가가서 줍는다.
await focusGame(b.page);
const dropB = await godotPoint(b.page, 'nearestDrop');
await b.page.mouse.click(dropB.x, dropB.y);
const removed = await waitFor((m) => m.t === 'item_remove' && m.by === tokenB, '줍기가 브로드캐스트됨');
check(!!removed, 'B가 물건을 클릭해 다가가서 주웠다(서버가 소유권을 옮김)');
check(!removed || removed.id === added?.item?.id, '주운 물건이 A가 놓은 그 물건이다');
await b.page.screenshot({ path: `${OUT}/mp-07-B줍기.png` });

console.log('\n[검증] 바위를 만나면 짧은 쪽으로 돌아서 간다');
// 바위 정의는 클라이언트와 같은 data/world.json에서 읽는다 — 테스트가 자기
// 사본을 갖고 있으면 데이터를 고칠 때 조용히 어긋난다.
const rocks = JSON.parse(readFileSync('data/world.json', 'utf-8')).obstacles ?? [];
check(rocks.length > 0, 'data/world.json에 바위가 정의돼 있다');

// 바위가 화면에 함께 보이도록 먼저 오른쪽으로 이동한다(카메라가 플레이어를
// 따라가므로 너무 멀면 목표 지점이 화면 밖으로 나가 클릭할 수 없다).
await focusGame(a.page);
for (let i = 0; i < 2; i++) {
  const g = await godotPoint(a.page, 'groundRight');
  await a.page.mouse.click(g.x, g.y);
  await a.page.waitForTimeout(1600);
}
const beforeRock = lastPos(tokenA);
console.log(`  (플레이어 x=${(beforeRock?.x ?? 0).toFixed(1)} z=${(beforeRock?.z ?? 0).toFixed(1)} / 바위 ${rocks.length}개)`);

// 어느 바위를 기준으로 판정할지 테스트가 따로 추측하지 않는다 — 훅이 고른
// 바위와 테스트가 고른 바위가 갈려서(둘 다 "가장 가까운" 바위였지만 계산
// 시점이 달랐다) 우회는 성공했는데 실패로 보고된 적이 있다(2026-09-04 실측).
// 여기서는 **모든 바위에 대해** 통과 여부를 보고, "짧은 쪽으로 도는지"는
// tests/test_path.gd가 정확히 검증한다.
const trackFrom = seen.length;
const beyond = await godotPoint(a.page, 'beyondNearestRock');
await a.page.mouse.click(beyond.x, beyond.y);
// 고정 대기로는 우회 호를 도는 시간이 부족해 바위 앞에서 끝난 적이 있어
// 멈출 때까지 폴링한다.
let stableFor = 0;
let prev = lastPos(tokenA) ?? { x: 0, z: 0 };
for (let i = 0; i < 60 && stableFor < 5; i++) {
  await a.page.waitForTimeout(250);
  const now = lastPos(tokenA) ?? prev;
  stableFor = Math.hypot(now.x - prev.x, now.z - prev.z) < 0.05 ? stableFor + 1 : 0;
  prev = now;
}
await a.page.screenshot({ path: `${OUT}/mp-08-바위우회.png` });

const AGENT_RADIUS = 0.35;
const samples = seen.slice(trackFrom)
  .filter((m) => m.t === 'move')
  .flatMap((m) => m.moves || [])
  .filter((v) => v.token === tokenA);
let minGap = Infinity;
let worst = null;
for (const s of samples) {
  for (const r of rocks) {
    const gap = Math.hypot(s.x - r.x, s.z - r.z) - (r.radius + AGENT_RADIUS);
    if (gap < minGap) { minGap = gap; worst = r.id; }
  }
}
const afterRock = lastPos(tokenA) ?? beforeRock;
const traveled = Math.hypot((afterRock?.x ?? 0) - (beforeRock?.x ?? 0), (afterRock?.z ?? 0) - (beforeRock?.z ?? 0));
console.log(`  (이동 표본 ${samples.length}개, 최소 여유 ${minGap.toFixed(2)} (${worst}), 이동 거리 ${traveled.toFixed(1)})`);
if (process.env.ROCK_DEBUG) {
  console.log('  [debug] 궤적:', samples.map((s) => `(${s.x},${s.z})`).join(' '));
}
check(samples.length > 5, '바위 건너편을 클릭하면 실제로 이동한다');
// -0.25는 10Hz 표본 사이 보간 오차 여유. 이보다 파고들면 바위를 통과한 것이다.
check(minGap > -0.25, `이동 경로가 어떤 바위도 통과하지 않는다(최소 여유 ${minGap.toFixed(2)})`);
// 바위 앞에서 막혀 멈췄으면 이동 거리가 거의 0이 된다.
check(traveled > 3.0, `바위에 막히지 않고 돌아서 이동했다(거리 ${traveled.toFixed(1)})`);

console.log('\n[검증] 석벽(박스 장애물)도 돌아서 간다');
// 원(바위)과 달리 박스는 모서리로 돌아야 한다 — 데이터에 shape:"box"로 정의된
// 장애물이 실제 빌드에서도 통과되지 않는지 본다.
const walls = (JSON.parse(readFileSync('data/world.json', 'utf-8')).obstacles ?? [])
  .filter((o) => o.shape === 'box');
check(walls.length > 0, 'data/world.json에 석벽이 정의돼 있다');
await focusGame(a.page);

// 카메라가 플레이어를 따라가므로 석벽이 화면에 없으면 건너편 지점을 클릭할 수
// 없다(실측: 이동 표본 0개로 실패). 먼저 키보드로 석벽 근처까지 걸어간다.
// 목표 방향으로 **탭 이동**을 반복해 접근한다. 키보드로 접근하면 장애물을
// 우회하지 않아(수동 이동은 표면 밀림) 바위 앞에서 멈춘다 — 실측에서 A가
// x=13.75(바위 x=12 옆)에 붙어 더 못 갔다.
async function walkToPoint(page, token, target, tol = 4.0, maxMs = 25000) {
  const t0 = Date.now();
  while (Date.now() - t0 < maxMs) {
    const pos = lastPos(token);
    if (!pos) { await page.waitForTimeout(200); continue; }
    const dx = target.x - pos.x;
    const dz = target.z - pos.z;
    if (Math.hypot(dx, dz) <= tol) break;
    const key = Math.abs(dx) > Math.abs(dz)
      ? (dx > 0 ? 'groundRight' : 'groundLeft')
      : (dz > 0 ? 'groundDown' : 'groundUp');
    if (process.env.MP_DEBUG) console.log(`    [walkTo] (${pos.x},${pos.z}) → (${target.x},${target.z}) via ${key}`);
    const pt = await godotPoint(page, key);
    await page.mouse.click(pt.x, pt.y);
    await page.waitForTimeout(1100);
  }
  // 카메라가 플레이어를 lerp로 따라가므로, 멈춘 직후의 화면 좌표는 아직
  // 어긋나 있다 — 안정될 시간을 준다(실측: 같은 검증이 실행마다 통과/실패했다).
  await page.waitForTimeout(900);
}

/** 훅 지점을 클릭한다. 화면 밖이면 잠깐 기다려 다시 조회한다(카메라 안정 대기). */
async function tapWorldPoint(page, key, tries = 4) {
  for (let i = 0; i < tries; i++) {
    const pt = await pointOnScreen(page, key);
    if (pt) {
      await page.mouse.click(pt.x, pt.y);
      return true;
    }
    await page.waitForTimeout(400);
  }
  return false;
}
// **가로로 긴 벽**을 고른다. 세로로 긴 벽은 건너편 지점이 화면 세로 시야
// (직교 size 9.5 → ±4.75)를 넘어가 클릭할 수 없다(실측).
const nearWall = walls
  .filter((wl) => wl.size_x >= wl.size_z)
  .map((wl) => ({ wl, d: Math.hypot(wl.x - (lastPos(tokenA)?.x ?? 0), wl.z - (lastPos(tokenA)?.z ?? 0)) }))
  .sort((x, y) => x.d - y.d)[0].wl;
// 벽에 충분히 붙어야 건너편 지점이 화면에 들어온다.
await walkToPoint(a.page, tokenA, { x: nearWall.x, z: nearWall.z + nearWall.size_z / 2 + 2.0 }, 2.2);
// 건너편 지점이 화면에 들어올 때까지 조금 더 붙는다 — 접근 위치가 실행마다
// 조금씩 달라 경계를 넘나들면서 테스트가 취약해졌다(실측: 같은 검증이 실행에
// 따라 통과/실패).
let wallClicked = await tapWorldPoint(a.page, 'beyondNearestWall');
for (let i = 0; i < 2 && !wallClicked; i++) {
  await walkToPoint(a.page, tokenA, { x: nearWall.x, z: nearWall.z + nearWall.size_z / 2 + 1.2 }, 1.2);
  wallClicked = await tapWorldPoint(a.page, 'beyondNearestWall');
}
check(wallClicked, '석벽 건너편 지점을 화면에서 찾아 클릭했다');
console.log(`  (석벽 ${nearWall.id} @ ${nearWall.x},${nearWall.z} 근처로 이동: x=${(lastPos(tokenA)?.x ?? 0).toFixed(1)} z=${(lastPos(tokenA)?.z ?? 0).toFixed(1)})`);
const wallTrackFrom = seen.length;
let wallStable = 0;
let wallPrev = lastPos(tokenA) ?? { x: 0, z: 0 };
for (let i = 0; i < 60 && wallStable < 5; i++) {
  await a.page.waitForTimeout(250);
  const now = lastPos(tokenA) ?? wallPrev;
  wallStable = Math.hypot(now.x - wallPrev.x, now.z - wallPrev.z) < 0.05 ? wallStable + 1 : 0;
  wallPrev = now;
}
await a.page.screenshot({ path: `${OUT}/mp-09-석벽우회.png` });
const AGENT2 = 0.35;
let insideWall = 0;
const wallSamples = seen.slice(wallTrackFrom).filter((m) => m.t === 'move')
  .flatMap((m) => m.moves || []).filter((v) => v.token === tokenA);
for (const s of wallSamples) {
  for (const wl of walls) {
    // 0.2는 10Hz 표본 사이 보간 여유.
    const inX = Math.abs(s.x - wl.x) < wl.size_x / 2 + AGENT2 - 0.2;
    const inZ = Math.abs(s.z - wl.z) < wl.size_z / 2 + AGENT2 - 0.2;
    if (inX && inZ) insideWall++;
  }
}
console.log(`  (이동 표본 ${wallSamples.length}개, 석벽 내부 표본 ${insideWall}개)`);
check(wallSamples.length > 3, '석벽 건너편을 클릭하면 이동한다');
check(insideWall === 0, `이동 경로가 석벽을 통과하지 않는다(내부 표본 ${insideWall}개)`);

console.log('\n[검증] 나무를 탭하지 않았으면 채집되지 않는다 (회귀)');
// 사용자 보고: "나무 근처에 가면 나무가 채집되고 있다".
// 원인 두 가지 — (1) 나무를 탭한 뒤 방향키로 목표를 취소하면 "도착하면 채집"
// 의도가 남아 다음 도착 때 실행됨, (2) 탭 판정 반경(1.3)이 넓어 나무 옆 땅을
// 탭해도 나무를 집음.
await focusGame(a.page);
const invBefore = seen.filter((m) => m.t === 'inventory').length;

// (1) 나무를 클릭했다가 방향키로 취소하고, 다른 빈 땅으로 이동해 도착시킨다.
const treeForCancel = await godotPoint(a.page, 'nearestGatherable');
await a.page.mouse.click(treeForCancel.x, treeForCancel.y);
await a.page.waitForTimeout(300);
await a.page.keyboard.down('ArrowUp');       // 목표 취소
await a.page.waitForTimeout(700);
await a.page.keyboard.up('ArrowUp');
const groundAgain = await godotPoint(a.page, 'groundRight');
await a.page.mouse.click(groundAgain.x, groundAgain.y);
await a.page.waitForTimeout(2500);           // 빈 땅에 도착
const invAfter = seen.filter((m) => m.t === 'inventory').length;
check(invAfter === invBefore,
  `취소된 채집 의도가 나중에 실행되지 않는다(inventory 갱신 ${invBefore} → ${invAfter})`);

console.log('\n[검증] 가방 화면에서 골라 판매 (서버 정산)');
// 판매 결과(`sold`)는 **본인에게만** 가므로 WS 옵저버로는 볼 수 없다(설계상 맞다).
// 게임이 훅으로 공개하는 상태(벨·가방)를 읽어 판정한다.
const gameState = async (page) => page.evaluate(() => (window.afTest && window.afTest.state) || {});

await focusGame(a.page);
// 채집물이 화면에 없으면 클릭할 수 없다 — 데이터에 있는 나무 좌표 근처로
// 먼저 이동한다(앞 단계에서 A가 어디에 있든 이 검증이 성립하도록).
// 판매를 검증하려면 팔 물건이 있어야 한다 — 준비 단계이므로 될 때까지 몇 번
// 시도한다(판정 자체는 아래 벨/가방 비교로 한다).
// 특정 좌표까지 걸어가려 했더니, 중간 이동용 클릭이 **대상 지향 로직**에 걸려
// 근처 잡초 앞으로 끌려가곤 했다(기능은 의도대로 동작한 것이고 테스트가 그걸
// 고려하지 않았다). 어느 채집물이든 상관없으니 가장 가까운 것을 바로 탭한다.
let stBefore = await gameState(a.page);
for (let i = 0; i < 4 && (stBefore.bagCount ?? 0) === 0; i++) {
  const tapped = await tapWorldPoint(a.page, 'nearestGatherable');
  if (!tapped) {
    // 화면에 채집물이 없으면 한 칸 이동해 시야를 바꾼다.
    await tapWorldPoint(a.page, i % 2 === 0 ? 'groundDown' : 'groundRight');
    await a.page.waitForTimeout(1600);
    continue;
  }
  await a.page.waitForTimeout(5000);         // 접근 + 자동 채집
  stBefore = await gameState(a.page);
  const pos = lastPos(tokenA);
  console.log(`  (채집 시도 ${i + 1}: 위치=(${pos?.x ?? '?'},${pos?.z ?? '?'}) 가방=${stBefore.bagCount ?? 0} 마지막오류=${stBefore.lastError ?? '없음'})`);
}
check((stBefore.bagCount ?? 0) > 0, `판매 전 가방에 물건이 있다(${stBefore.bagCount ?? 0}개)`);

await a.page.keyboard.press('KeyI');          // 가방 열기
await a.page.waitForTimeout(700);
await a.page.screenshot({ path: `${OUT}/mp-10-가방화면.png` });
const stOpen = await gameState(a.page);
check((stOpen.invOpen ?? 0) === 1, '가방 화면이 열렸다');
// 가방이 비어 있으면 판매 항목이 없다 — 준비 실패를 예외가 아니라 실패로 남긴다.
if (process.env.MP_DEBUG) {
  const dbg = await a.page.evaluate(() => {
    const s = window.afTest;
    return { vw: s?.vw, vh: s?.vh, keys: Object.keys(s?.points || {}).filter((k) => k.startsWith('inv')),
      invSell1: s?.points?.invSell1, invSellAll: s?.points?.invSellAll };
  });
  console.log('  [debug] 가방 훅:', JSON.stringify(dbg));
}
const sellClicked = (stBefore.bagCount ?? 0) > 0 ? await tapWorldPoint(a.page, 'invSell1') : false;
check(sellClicked, '가방 목록에서 판매 버튼을 눌렀다');
await a.page.waitForTimeout(1500);
const stAfter = await gameState(a.page);
if ((stAfter.bells ?? 0) === (stBefore.bells ?? 0)) {
  console.log(`  [debug] 서버 마지막 오류=${stAfter.lastError ?? '(없음)'} invOpen=${stAfter.invOpen}`);
}
console.log(`  (벨 ${stBefore.bells ?? 0} → ${stAfter.bells ?? 0}, 가방 ${stBefore.bagCount ?? 0} → ${stAfter.bagCount ?? 0}개)`);
check((stAfter.bells ?? 0) > (stBefore.bells ?? 0), `판매로 벨이 늘었다(${stBefore.bells ?? 0} → ${stAfter.bells ?? 0})`);
check((stAfter.bagCount ?? 99) < (stBefore.bagCount ?? 0), '판 물건이 가방에서 빠졌다');
await a.page.screenshot({ path: `${OUT}/mp-11-판매후.png` });
await tapGodot(a.page, 'invClose');
await a.page.waitForTimeout(400);

console.log('\n[검증] 하단 접속자 바');
// 접속자 바는 캔버스에 그려져 DOM으로 읽을 수 없다 — 게임이 훅으로 알려주는
// 항목 좌표(rosterEntry1..N)로 "몇 명이 표시되는지"를 판정한다.
const rosterPoints = await a.page.evaluate(() => {
  const t2 = window.afTest;
  if (!t2 || !t2.points) return [];
  return Object.keys(t2.points).filter((k) => k.startsWith('rosterEntry'));
});
console.log(`  (접속자 바 항목 ${rosterPoints.length}개: ${rosterPoints.join(', ')})`);
// A 화면에는 자기 자신 + B + 옵저버(Obs) = 3명이 보여야 한다.
check(rosterPoints.length >= 3, `접속한 캐릭터가 하단 바에 모두 표시된다(${rosterPoints.length}명)`);
await a.page.screenshot({ path: `${OUT}/mp-12-접속자바.png` });

console.log('\n[검증] 채팅');
await b.page.keyboard.press('KeyT');
await b.page.waitForTimeout(400);
await b.page.keyboard.type('hello there', { delay: 40 });
await b.page.keyboard.press('Enter');
const chat = await waitFor((m) => m.t === 'chat' && m.text === 'hello there', '채팅이 브로드캐스트됨');
check(!!chat, 'B의 채팅이 서버를 거쳐 전달됨');
check(!chat || chat.name === 'Bora', '채팅에 보낸 사람 이름이 붙는다');
await a.page.waitForTimeout(700);
await a.page.screenshot({ path: `${OUT}/mp-13-A화면에B채팅.png` });

console.log('\n[검증] 감정 표현 이모티콘');
await focusGame(a.page);
await a.page.keyboard.press('Digit1');
const emote = await waitFor((m) => m.t === 'emote' && m.token === tokenA, '이모티콘이 브로드캐스트됨');
check(!!emote, 'A의 이모티콘이 서버를 거쳐 전달됨');
await b.page.waitForTimeout(700);
await b.page.screenshot({ path: `${OUT}/mp-14-B화면에A이모티콘.png` });

const errors = [...a.errors, ...b.errors];
obs.close();
await browser.close();
await new Promise((r) => setTimeout(r, 300));
stopServer();

console.log(`\n스크린샷: ${OUT}/mp-*.png`);
if (errors.length) {
  console.log('\n=== 브라우저 오류 ===');
  console.log(errors.join('\n'));
  failures.push(`브라우저 오류 ${errors.length}건`);
}
if (failures.length) {
  console.error(`\n❌ 멀티플레이 테스트 실패 ${failures.length}건`);
  for (const f of failures) console.error(`  - ${f}`);
  console.error('\n--- 서버 로그 ---\n' + serverLog.slice(-2000));
  process.exit(1);
}
console.log('\n✅ 멀티플레이 테스트 통과 — 접속·위치·채집/드랍/줍기·채팅·이모티콘이 서버를 거쳐 전달됨');
console.log('   (이름표·말풍선이 실제로 읽히는지는 스크린샷으로 눈으로 확인할 것)');
