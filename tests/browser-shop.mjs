// 가게 E2E — 벨의 첫 소비처.
//
// 왜 브라우저인가: 사는 흐름은 (a) 가게 주인 탭 → 다가감, (b) 가게 화면이 목록과
// 잔액을 보여줌, (c) 사면 서버가 차감하고 보유로 바뀜, (d) **산 색이 꾸미기 화면에
// 열림**이 맞물려 있다. 가격·중복·잔액 판정은 서버 유닛 테스트가 보고, 여기서는
// 흐름과 UI를 본다.
//
// 상품 가격을 **50벨로 낮춘 데이터 사본**으로 서버를 띄운다 — 실제 가격(200~1500)을
// 벌려면 채집을 여러 번 해야 해서 테스트가 길고 흔들린다. 가격 판정 자체는 서버
// 유닛이 본다.
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, readdirSync, copyFileSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import WebSocket from 'ws';
import { tapGodot, godotPoint } from './godot-tap.mjs';

const PORT = Number(process.env.PORT || 3195);
const OUT = process.env.SHOT_DIR || 'build/screenshots/shop';
const results = [];
const check = (ok, label) => {
  results.push({ ok, label });
  console.log(`  ${ok ? 'ok ' : '❌ '} — ${label}`);
};

const tmpRoot = mkdtempSync(join(tmpdir(), 'af-shop-'));
const statePath = join(tmpRoot, 'world.json');

// 데이터 사본: **상품 가격을 50벨로 낮춘다.** 클라이언트는 원본 데이터로 빌드돼
// 있지만 가게 목록·가격의 단일 출처는 서버(welcome 응답)라 이 사본만 바꾸면 된다.
const dataDir = join(tmpRoot, 'data');
mkdirSync(dataDir, { recursive: true });
for (const name of readdirSync('data')) copyFileSync(join('data', name), join(dataDir, name));
const shopFixture = JSON.parse(readFileSync(join(dataDir, 'shop.json'), 'utf-8'));
for (const g of shopFixture.goods) g.price = 50;
writeFileSync(join(dataDir, 'shop.json'), JSON.stringify(shopFixture, null, 2));
const srv = spawn('node', ['server/index.js'], {
  env: {
    ...process.env, PORT: String(PORT), TLS: 'off', HOST: '127.0.0.1',
    WORLD_STATE_PATH: statePath, AF_DATA_DIR: dataDir,
  },
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
  bag: Number(window.afTest?.state?.bagCount ?? 0),
  bells: Number(window.afTest?.state?.bells ?? 0),
  last: String(window.afTest?.state?.lastGather ?? ''),
  requests: String(window.afTest?.state?.npcRequests ?? ''),
  branch: String(window.afTest?.state?.tapBranch ?? ''),
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
// 가게 — 벌어서 사고, 산 것이 꾸미기에 열린다
// ---------------------------------------------------------------------------

const npcCfg = JSON.parse(readFileSync(join(dataDir, 'npcs.json'), 'utf-8'));
const gcfg = JSON.parse(readFileSync('data/gatherables.json', 'utf-8'));
const shopCfg = JSON.parse(readFileSync(join(dataDir, 'shop.json'), 'utf-8'));
const shopNpc = npcCfg.npcs.find((n) => n.shop === true);
if (!shopNpc) throw new Error('data/npcs.json에 가게 주인(shop:true)이 없다');

// --- 1. 살 돈을 번다(나무 한 번 캐서 판다) ---
console.log('\n[검증] 벌기 — 채집 후 판매');
const tree = gcfg.spawns
  .map((s, index) => ({ ...s, index }))
  .filter((s) => s.item === 'wood')
  .sort((a, b) => Math.hypot(a.x, a.z) - Math.hypot(b.x, b.z))[0];
await walkTo('x', tree.x);
await walkTo('z', tree.z + 1.2);
await clickWorld(tree.x, tree.z);
await page.waitForTimeout(2500);
const picked = await state();
check(picked.bag >= 1, `나무를 캤다 (가방 ${picked.bag})`);

// 가방을 열어 전부 판다(I 키 — 폰에서는 가방 버튼이고 같은 화면이 열린다).
await page.keyboard.press('KeyI');
await page.waitForFunction(() => window.afTest?.points?.invSellAll != null,
  null, { timeout: 8000 });
await tapGodot(page, 'invSellAll');
await page.waitForTimeout(900);
await tapGodot(page, 'invClose');
await page.waitForTimeout(500);
const earned = await state();
check(earned.bells >= shopCfg.goods[0].price,
  `팔아서 살 돈이 생겼다 (${earned.bells}벨 / 가격 ${shopCfg.goods[0].price})`);

// --- 2. 가게 주인을 탭하면 가게가 열린다 ---
console.log(`\n[검증] 가게 — ${shopNpc.label} (${shopNpc.x}, ${shopNpc.z})`);
await walkTo('z', shopNpc.z + 2.0);
await walkTo('x', shopNpc.x);
let opened = false;
for (let i = 0; i < 6; i += 1) {
  const pt = await godotPoint(page, 'nearestNpc').catch(() => null);
  if (pt) await page.mouse.click(pt.x, pt.y);
  opened = await page.waitForFunction(
    () => window.afTest?.points?.shopBuy1 != null, null, { timeout: 2500 },
  ).then(() => true).catch(() => false);
  if (opened) break;
  await page.waitForTimeout(400);
}
check(opened, '가게 주인을 탭하면 다가가서 가게가 열린다');
await page.screenshot({ path: `${OUT}/1-가게.png` }).catch(() => {});

// --- 3. 사면 벨이 줄고 "보유"로 잠긴다 ---
const beforeBuy = (await state()).bells;
await tapGodot(page, 'shopBuy1');
await page.waitForTimeout(1200);
const afterBuy = await state();
check(afterBuy.bells === beforeBuy - shopCfg.goods[0].price,
  `사면 서버가 벨을 차감한다 (${beforeBuy} → ${afterBuy.bells})`);
const locked = await page.evaluate(() => window.afTest?.points?.shopBuy1 != null);
check(locked, '가게 화면이 그대로 열려 있다(그 자리에서 잠긴다)');
// **산 사람에게만 응답한다**는 이 기능의 규약이다(protocol.md) — 관찰자 소켓에
// bought가 오면 안 된다. 관찰자를 깔아 두고 안 보면 규약이 테스트되지 않는다.
// 관찰자가 먼저 죽었으면 "안 왔다"가 아니라 "못 받았다"이므로, 살아 있는지 함께 본다
// (안 그러면 소켓이 끊겨도 초록불인 위양성 통과가 된다).
const leaked = await waitFor((m) => m.t === 'bought', 1500);
check(leaked === null && observer.readyState === WebSocket.OPEN,
  `구매는 남에게 방송되지 않는다 (관찰자 상태 ${observer.readyState})`);
// 대신 **외형 변경은** 남에게 가야 한다 — 서버가 구매 시점에 입히기 때문이다.
// **값까지 본다.** `t === 'appearance'`만 보면 waitFor가 누적 기록 전체를 훑으므로
// 구매와 무관한 옛 appearance를 집어 통과할 수 있다(위양성 — 리뷰 지적).
// (토큰까지 보면 더 정확하지만 클라이언트에 토큰을 노출하는 훅이 없다 — 관찰자를
// 하나 더 붙이게 되면 그때 훅을 만들고 토큰도 함께 볼 것.)
const boughtValue = shopCfg.goods[0].value;
const looked = await waitFor(
  (m) => m.t === 'appearance' && m.custom?.outfit === boughtValue, 2500);
check(looked !== null, `산 옷(${boughtValue})이 남의 화면에도 전달된다`);
await page.screenshot({ path: `${OUT}/2-구매후.png` }).catch(() => {});

// --- 3-b. 다시 연 가게가 서버 잔액을 그린다 ---
// 이 커밋들의 요지인데 E2E가 없어서 같은 회귀가 반복해서 났다(가게 창이 옛 잔액을
// 그려 "살 수 있어 보이는데 서버가 거절").
//
// **가게를 연 채 파는 흐름은 없다** — 모달은 서로 배타적이라 가게가 열려 있으면
// 가방이 안 열린다(그 사실을 여기서 함께 고정한다). 벨이 열린 채 바뀌는 실제 경로는
// 경주 보상·재동기화처럼 비동기로 오는 것들이고, 그건 서버 유닛과 `_refresh_shop_ui`
// 호출부로 덮는다.
console.log('\n[검증] 가게가 서버 잔액을 그린다');
await tapGodot(page, 'shopClose');
await page.waitForTimeout(700);
// **닫으면 훅도 사라져야 한다.** 남으면 아래 재오픈 판정이 "첫 인스턴스가 남긴 훅"을
// 보고 클릭이 실패해도 통과한다 — 값 비교도 "언젠가 그 값을 그린 적 있다"가 된다
// (2026-09-16 리뷰 지적. TestHooks._exit_tree가 자기 것을 치운다).
const afterClose = await page.evaluate(() => ({
  gone: window.afTest?.points?.shopBells == null
    && window.afTest?.state?.shopBells == null,
  // **남의 상태까지 지우면 안 된다.** 상태 키를 이름으로 지우면 같은 이름을 쓰는
  // 살아 있는 인스턴스의 값이 날아간다 — 월드의 벨이 그대로인지 함께 본다.
  bells: Number(window.afTest?.state?.bells ?? -1),
}));
check(afterClose.gone, '가게를 닫으면 그 화면의 훅이 사라진다');
check(afterClose.bells >= 0, `닫아도 월드 상태는 남는다 (벨 ${afterClose.bells})`);
const tree2 = gcfg.spawns
  .map((s, index) => ({ ...s, index }))
  .filter((s) => s.item === 'wood')
  .sort((a, b) => Math.hypot(a.x - shopNpc.x, a.z - shopNpc.z)
    - Math.hypot(b.x - shopNpc.x, b.z - shopNpc.z))[0];
const bagBefore = (await state()).bag;
await walkTo('x', tree2.x);
await walkTo('z', tree2.z + 1.2);
await clickWorld(tree2.x, tree2.z);
// **대기도 증분으로 본다.** 절대값(`> 0`)으로 기다리면 가방이 이미 비어 있지 않을 때
// (앞 판매가 `unsold`를 남겼거나 판매 응답이 늦었을 때) 즉시 참이 되어 20초 대기가
// 통째로 무력화되고, 채집 중인데 곧바로 읽어 실패한다 — 위양성을 위음성으로 바꾸는
// 셈이다(리뷰 지적).
await page.waitForFunction(
  (before) => Number(window.afTest?.state?.bagCount ?? 0) > before,
  bagBefore, { timeout: 20000 },
).catch(() => {});
// **원인을 원인 자리에서 잡는다.** 위 대기가 타임아웃을 삼키므로, 못 캤으면 아래
// "팔아서 벨이 늘었다"가 실패해 라벨과 원인이 어긋난다(리뷰 지적).
const bagged = (await state()).bag;
// **증가를 본다.** 절대값만 보면 앞 판매가 `unsold`(가격 미상)를 남겼을 때
// 두 번째 채집이 실패해도 통과한다 — 라벨이 "다시"인 이상 증가를 봐야 한다.
check(bagged > bagBefore, `다시 나무를 캤다 (${bagBefore} → ${bagged})`);
const beforeSell = (await state()).bells;
await page.keyboard.press('KeyI');
await page.waitForFunction(() => window.afTest?.points?.invSellAll != null,
  null, { timeout: 8000 });
await tapGodot(page, 'invSellAll');
await page.waitForTimeout(900);
await tapGodot(page, 'invClose');
await page.waitForTimeout(700);
const afterSell = await state();
check(afterSell.bells > beforeSell, `팔아서 벨이 늘었다 (${beforeSell} → ${afterSell.bells})`);

// 다시 연 가게가 **그 잔액**을 그려야 한다.
await walkTo('x', shopNpc.x);
await walkTo('z', shopNpc.z + 2.0);
let reopened = false;
for (let i = 0; i < 6; i += 1) {
  const pt = await godotPoint(page, 'nearestNpc').catch(() => null);
  if (pt) await page.mouse.click(pt.x, pt.y);
  reopened = await page.waitForFunction(
    () => window.afTest?.points?.shopBells != null, null, { timeout: 2500 },
  ).then(() => true).catch(() => false);
  if (reopened) break;
  await page.waitForTimeout(400);
}
check(reopened, '가게를 다시 열었다');
// **그려진 잔액을 읽어 서버 값과 비교한다.** 훅 존재만 보면 "창이 열렸다"까지만
// 증명하고, 라벨에 옛 숫자가 찍혀 있어도 통과한다(리뷰 지적).
// `afTest.state`는 값이 남는 사전이고 게시가 주기적이라, 바로 읽으면 **첫 가게
// 인스턴스가 남긴 옛 값**을 볼 수 있다 — 조건 대기로 갈라야 "안 바뀐 것"과
// "아직 안 올라온 것"이 구분된다(고정 대기 금지 규칙과 같은 이유).
await page.waitForFunction(
  (want) => Number(window.afTest?.state?.shopBells ?? -1) === want,
  afterSell.bells, { timeout: 5000 },
).catch(() => {});
const shownBells = await page.evaluate(
  () => Number(window.afTest?.state?.shopBells ?? -1));
// 라벨을 정확히 적는다 — `state.bells`와 `state.shopBells` 둘 다 클라이언트
// `_slot["bells"]`에서 나오므로 이 검사는 **클라 두 뷰의 일치**를 본다(잡으려던
// 회귀가 정확히 그 클래스다). 서버-클라 괴리는 서버 유닛이 본다.
check(shownBells === afterSell.bells,
  `가게 창이 최신 잔액을 그린다 (화면 ${shownBells} / HUD ${afterSell.bells})`);
await page.screenshot({ path: `${OUT}/4-판매후가게.png` }).catch(() => {});

// --- 4. 산 색이 꾸미기 화면에 열린다 ---
console.log('\n[검증] 산 것이 꾸미기에 열린다');
// 가게를 못 열었으면 여기서 예외로 죽어 **결과 요약까지 통째로 사라진다**(리뷰 지적).
if (reopened) await tapGodot(page, 'shopClose');
await page.waitForTimeout(600);
await page.keyboard.press('KeyI');
await page.waitForFunction(() => window.afTest?.points?.invLook != null,
  null, { timeout: 8000 });
await tapGodot(page, 'invLook');
await page.waitForFunction(() => Object.keys(window.afTest?.points ?? {})
  .some((k) => k.startsWith('look_outfit_')), null, { timeout: 8000 });
// **견본 개수로 판정한다.** 프리셋에서 유도한 옷은 5가지이고, 산 것이 열리면
// 하나 늘어난다 — 산 색이 서버 화이트리스트를 거쳐 화면까지 도달했다는 뜻이다.
const swatches = await page.evaluate(() => Object.keys(window.afTest?.points ?? {})
  .filter((k) => k.startsWith('look_outfit_')).length);
const presetOutfits = new Set(JSON.parse(readFileSync('data/characters.json', 'utf-8'))
  .presets.map((p) => p.outfit));
check(swatches === presetOutfits.size + 1,
  `산 색이 꾸미기에 열린다 (견본 ${swatches}개 = 프리셋 ${presetOutfits.size} + 산 것 1)`);
await page.screenshot({ path: `${OUT}/3-꾸미기.png` }).catch(() => {});

// --- 정리 ---
const failed = results.filter((r) => !r.ok);
console.log(`\n스크린샷: ${OUT}/`);
if (errors.length > 0) {
  console.log('\n--- 브라우저 오류 ---');
  for (const e of errors.slice(0, 10)) console.log('  ', e);
}
check(errors.length === 0, `브라우저 오류 0건 (실제 ${errors.length}건)`);
await browser.close();
srv.kill();
if (failed.length > 0) {
  console.log(`\n❌ 가게 테스트 실패 ${failed.length}건`);
  for (const f of failed) console.log('  -', f.label);
  process.exit(1);
}
console.log('\n✅ 가게 테스트 통과 — 벌어서 사고, 산 색이 꾸미기에 열린다');
