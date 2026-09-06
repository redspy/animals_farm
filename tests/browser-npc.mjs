// 이웃 동물(NPC) + 도감 E2E (F3).
//
// 왜 브라우저인가: 부탁은 (a) 동물 탭 → 다가감, (b) 대화창이 부족한 수를
// 보여줌, (c) 물건을 모아 오면 버튼이 "가져왔어"로 바뀜, (d) 서버 정산 후
// 벨·가방·부탁 상태가 갱신되는 흐름이 맞물려 있다. **정산 계산·하루 1회
// 제한은 서버 유닛 테스트가 보고**, 여기서는 흐름과 UI를 본다.
//
// **부탁을 나무 2개로 고정한다**: 데이터 사본(AF_DATA_DIR)에서 요구를 바꿔
// 서버를 띄운다. 실제 데이터의 부탁은 전부 시간 제한이 없는 아이템이지만
// (조개·농어 등) 스폰 위치가 멀어 테스트가 오래 걸리고, 어떤 부탁이 뽑히는지에
// 따라 왕복 거리가 달라져 판정이 흔들린다.
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, readdirSync, copyFileSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import WebSocket from 'ws';
import { tapGodot, godotPoint } from './godot-tap.mjs';

const PORT = Number(process.env.PORT || 3187);
const OUT = process.env.SHOT_DIR || 'build/screenshots/npc';
const results = [];
const check = (ok, label) => {
  results.push({ ok, label });
  console.log(`  ${ok ? 'ok ' : '❌ '} — ${label}`);
};

const tmpRoot = mkdtempSync(join(tmpdir(), 'af-npc-'));
const statePath = join(tmpRoot, 'world.json');

// 데이터 사본: 모든 NPC의 부탁을 **나무 2개**로 고정한다. 클라이언트는 원본
// 데이터로 빌드돼 있지만 부탁의 단일 출처는 서버라, 이 사본만 바꾸면 된다.
const dataDir = join(tmpRoot, 'data');
mkdirSync(dataDir, { recursive: true });
for (const name of readdirSync('data')) copyFileSync(join('data', name), join(dataDir, name));
{
  const npcs = JSON.parse(readFileSync(join(dataDir, 'npcs.json'), 'utf-8'));
  for (const n of npcs.npcs) n.requests = [{ item: 'wood', count: 2 }];
  writeFileSync(join(dataDir, 'npcs.json'), JSON.stringify(npcs, null, 2));
}
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
// 이웃에게 가서 부탁을 듣고, 나무를 모아 건네고, 도감을 확인한다.
// ---------------------------------------------------------------------------

const npcCfg = JSON.parse(readFileSync(join(dataDir, 'npcs.json'), 'utf-8'));
const gcfg = JSON.parse(readFileSync('data/gatherables.json', 'utf-8'));

// 서버가 알려준 부탁을 확인한다(훅 문자열: "id:item:count" 쉼표 구분).
const reqState = await waitState((s) => s.requests.length > 0, 8000);
check(reqState.requests.includes(':wood:2'),
  `서버가 부탁을 알려준다 (${reqState.requests})`);

// 스폰(0,0)에서 가장 가까운 이웃을 고른다.
const npc = npcCfg.npcs
  .map((n) => ({ ...n }))
  .sort((a, b) => Math.hypot(a.x, a.z) - Math.hypot(b.x, b.z))[0];
console.log(`\n[검증] 이웃 — ${npc.label} (${npc.x}, ${npc.z})`);

/** 이웃 근처로 걸어가 탭해서 대화창을 연다. */
async function talkTo() {
  await walkTo('z', npc.z + 2.0);
  await walkTo('x', npc.x);
  // 동물은 배회하므로(시간 함수) **지금 보이는 위치**를 탭해야 한다 — 기준
  // 좌표를 탭하면 반경만큼 빗나가 빈 땅 탭이 된다(실측). 훅이 알려주는 화면
  // 좌표를 그대로 쓴다.
  for (let i = 0; i < 6; i++) {
    const pt = await godotPoint(page, 'nearestNpc').catch(() => null);
    if (pt) await page.mouse.click(pt.x, pt.y);
    const s = await waitState((v) => v.branch.startsWith('npc:'), 2500);
    if (s.branch.startsWith('npc:')) break;
    await page.waitForTimeout(400);
  }
  return page.waitForFunction(
    () => window.afTest?.points?.npcAction != null, null, { timeout: 8000 },
  ).then(() => true).catch(() => false);
}

const opened = await talkTo();
check(opened, '이웃을 탭하면 다가가서 대화창이 열린다');
await page.screenshot({ path: `${OUT}/1-대화.png` }).catch(() => {});

// 물건이 없으면 버튼이 "알겠어"이고, 눌러도 벨이 늘지 않는다.
const actionText = await page.evaluate(() => {
  const p = window.afTest?.points?.npcAction;
  return p ? 'exists' : 'none';
});
check(actionText === 'exists', '대화창에 행동 버튼이 있다');
const beforeBells = (await state()).bells;
await tapGodot(page, 'npcAction');
await page.waitForTimeout(800);
const afterTry = await state();
check(afterTry.bells === beforeBells,
  `물건이 없으면 정산되지 않는다 (벨 ${beforeBells} → ${afterTry.bells})`);

// 나무 2개를 모은다 — 가장 가까운 나무 스폰을 두 곳 캔다.
console.log('\n[검증] 나무 2개를 모아 온다');
const trees = gcfg.spawns
  .map((s, index) => ({ ...s, index }))
  .filter((s) => s.item === 'wood')
  .sort((a, b) => Math.hypot(a.x - npc.x, a.z - npc.z) - Math.hypot(b.x - npc.x, b.z - npc.z))
  .slice(0, 4);
for (const tree of trees) {
  if ((await state()).bag >= 2) break;
  await walkTo('x', tree.x);
  await walkTo('z', tree.z + 1.2);
  await clickWorld(tree.x, tree.z);
  await page.waitForTimeout(2500);
}
const gathered = await state();
check(gathered.bag >= 2, `나무 ${gathered.bag}개를 모았다`);

// 다시 이웃에게 가서 건넨다.
const reopened = await talkTo();
check(reopened, '다시 대화창을 연다');
const bellsBefore = (await state()).bells;
await tapGodot(page, 'npcAction');
const paid = await waitState((s) => s.bells > bellsBefore, 8000);
check(paid.bells > bellsBefore, `부탁을 완료하면 벨을 받는다 (${bellsBefore} → ${paid.bells})`);
check(paid.requests.includes(':done'), `부탁 상태가 완료로 바뀐다 (${paid.requests})`);
await page.screenshot({ path: `${OUT}/2-정산후.png` }).catch(() => {});

// 도감: 가방 → 도감. 방금 캔 나무는 이름이 보이고, 안 만난 것은 물음표다.
console.log('\n[검증] 도감');
await page.keyboard.press('KeyI');
await page.waitForFunction(() => window.afTest?.points?.invDex != null, null, { timeout: 8000 });
await tapGodot(page, 'invDex');
const dexOpen = await page.waitForFunction(
  () => window.afTest?.points?.dexItem1 != null, null, { timeout: 8000 },
).then(() => true).catch(() => false);
check(dexOpen, '가방 화면의 [도감]으로 도감이 열린다');
await page.screenshot({ path: `${OUT}/3-도감.png` }).catch(() => {});
const dexCells = await page.evaluate(() => Object.keys(window.afTest?.points ?? {})
  .filter((k) => k.startsWith('dexItem')).length);
check(dexCells >= 8, `도감에 아이템 칸이 채워진다 (${dexCells}칸)`);
const npcTab = await page.evaluate(() => window.afTest?.points?.dexTabNpcs != null);
check(npcTab, '도감에 이웃 탭이 있다');
await tapGodot(page, 'dexTabNpcs');
await page.waitForTimeout(600);
const npcRows = await page.evaluate(() => Object.keys(window.afTest?.points ?? {})
  .filter((k) => k.startsWith('dexNpc')).length);
check(npcRows === npcCfg.npcs.length, `이웃 탭에 ${npcCfg.npcs.length}명이 보인다 (${npcRows})`);
await page.screenshot({ path: `${OUT}/4-도감-이웃.png` }).catch(() => {});
await tapGodot(page, 'dexClose');
await page.waitForTimeout(400);

check(errors.length === 0, `브라우저 오류·서버 거절 0건 (실제 ${errors.length}건)`);
if (errors.length) console.log(errors.slice(0, 6).join('\n'));

await browser.close();
observer.close();
stop();

const failed = results.filter((r) => !r.ok);
console.log('');
if (failed.length) {
  console.error(`❌ 이웃·도감 테스트 실패 ${failed.length}건`);
  for (const f of failed) console.error(`  - ${f.label}`);
  process.exit(1);
}
console.log('✅ 이웃·도감 테스트 통과 — 부탁 확인 → 물건 모으기 → 정산 → 도감 표시');
