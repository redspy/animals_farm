import { chromium } from 'playwright';
import WebSocket from 'ws';
import { spawn } from 'child_process';
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
  await page.locator('canvas').click({ position: { x: 480, y: 270 } });
  await page.locator('canvas').click({ position: { x: 420, y: 182 } });   // 1번 슬롯
  await page.waitForTimeout(600);
  await page.locator('canvas').click({ position: { x: 480, y: 182 } });   // 첫 프리셋
  await page.waitForTimeout(600);
  await page.locator('canvas').click({ position: { x: 480, y: 218 } });   // 이름 입력창
  await page.waitForTimeout(200);
  await page.keyboard.type(name, { delay: 60 });
  await page.waitForTimeout(200);
  await page.keyboard.press('Enter');
  await page.waitForTimeout(2500);   // 월드 로딩 + WS 접속
}

const focusGame = async (page) => {
  // 이름 입력창에서 포커스를 빼야 방향키가 게임으로 간다.
  await page.locator('canvas').click({ position: { x: 480, y: 420 } });
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

console.log('\n[검증] 위치 동기화');
await focusGame(a.page);
await a.page.keyboard.down('ArrowRight');
await a.page.waitForTimeout(WALK_MS);
await a.page.keyboard.up('ArrowRight');
await a.page.waitForTimeout(500);
const movedA = await waitFor(
  (m) => m.t === 'move' && (m.moves || []).some((v) => v.token === tokenA && v.x > 3),
  'A의 이동이 서버를 거쳐 브로드캐스트됨',
);
check(!!movedA, 'A 이동 동기화(x > 3)');
await b.page.waitForTimeout(600);
await b.page.screenshot({ path: `${OUT}/mp-04-B화면에A이동.png` });

console.log('\n[검증] 채집 → 드랍 → 상대가 줍기');
await a.page.keyboard.press('Space');           // 나무 채집
await a.page.waitForTimeout(700);
await a.page.screenshot({ path: `${OUT}/mp-05-A채집.png` });
await a.page.keyboard.press('KeyQ');            // 발밑에 놓기
const added = await waitFor((m) => m.t === 'item_add' && m.item?.item === TREE.item, '드랍이 브로드캐스트됨');
// 채집이 서버 가방에 반영되지 않으면 드랍은 "가방에 없는 아이템"으로 거부된다 —
// 이 단계가 통과하는 것 자체가 채집→서버 반영이 됐다는 증거다.
check(!!added, `채집한 ${TREE.item}을 드랍`);
await a.page.screenshot({ path: `${OUT}/mp-06-A드랍.png` });

await focusGame(b.page);
await b.page.keyboard.down('ArrowRight');
await b.page.waitForTimeout(WALK_MS);
await b.page.keyboard.up('ArrowRight');
await b.page.waitForTimeout(400);
await b.page.keyboard.press('Space');           // 줍기
const removed = await waitFor((m) => m.t === 'item_remove' && m.by === tokenB, '줍기가 브로드캐스트됨');
check(!!removed, 'B가 A의 물건을 주웠다(서버가 소유권을 옮김)');
check(!removed || removed.id === added?.item?.id, '주운 물건이 A가 놓은 그 물건이다');
await b.page.screenshot({ path: `${OUT}/mp-07-B줍기.png` });

console.log('\n[검증] 채팅');
await b.page.keyboard.press('KeyT');
await b.page.waitForTimeout(400);
await b.page.keyboard.type('hello there', { delay: 40 });
await b.page.keyboard.press('Enter');
const chat = await waitFor((m) => m.t === 'chat' && m.text === 'hello there', '채팅이 브로드캐스트됨');
check(!!chat, 'B의 채팅이 서버를 거쳐 전달됨');
check(!chat || chat.name === 'Bora', '채팅에 보낸 사람 이름이 붙는다');
await a.page.waitForTimeout(700);
await a.page.screenshot({ path: `${OUT}/mp-08-A화면에B채팅.png` });

console.log('\n[검증] 감정 표현 이모티콘');
await focusGame(a.page);
await a.page.keyboard.press('Digit1');
const emote = await waitFor((m) => m.t === 'emote' && m.token === tokenA, '이모티콘이 브로드캐스트됨');
check(!!emote, 'A의 이모티콘이 서버를 거쳐 전달됨');
await b.page.waitForTimeout(700);
await b.page.screenshot({ path: `${OUT}/mp-09-B화면에A이모티콘.png` });

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
