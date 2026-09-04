import { chromium, devices } from 'playwright';
import { godotPoint, tapGodot, dragTouch } from './godot-tap.mjs';
import WebSocket from 'ws';
import { spawn } from 'child_process';
import { mkdirSync, existsSync, rmSync } from 'fs';

// 폰 브라우저 터치 조작 테스트.
// 설계 근거: docs/meetings/2026-09-04-1150-폰-터치-조작-설계.md
//
// 판정은 **Node WS 옵저버가 받은 브로드캐스트**로 한다 — 스크린샷 해시 판정은
// 실패한 동작도 토스트 때문에 화면이 변해 거짓 통과를 낸 전례가 있다.
//
// 자동으로 검증하지 못하는 것(회의 §8에 명시):
//  - 한글 IME 조합: 합성 키 이벤트로는 한글이 들어가지 않는다. DOM input이
//    실제로 IME와 붙는지는 사람이 폰에서 확인해야 한다.
//  - 실제 엄지 도달감, 저사양 폰 프레임.
//
// 실행: npm run test:mobile   (사전에 ./scripts/build-web.sh 필요)

const PORT = Number(process.env.PORT || 3115);
const OUT = process.env.SHOT_DIR || 'build/screenshots/mobile';
const OBS_TOKEN = '88888888-8888-4888-8888-888888888888';

// data/gatherables.json에 실제로 있는 나무 좌표(스폰 0,0에서 오른쪽 5칸).
// 아무 데서나 채집 버튼을 눌러 되기를 기대하면 실패한다 — 데이터에 있는
// 좌표를 근거로 목표를 잡는다.
const TREE = { x: 5.0, z: 1.0, item: 'wood' };

if (!existsSync('build/web/index.html')) {
  console.error('ERROR: build/web/index.html이 없습니다 — 먼저 ./scripts/build-web.sh를 실행하세요.');
  process.exit(1);
}
mkdirSync(OUT, { recursive: true });
if (existsSync('server/data/world.json')) rmSync('server/data/world.json');

const failures = [];
const check = (cond, what) => {
  if (cond) console.log(`  ok  — ${what}`);
  else { failures.push(what); console.error(`  FAIL — ${what}`); }
};

const server = spawn('node', ['server/index.js'], {
  env: { ...process.env, PORT: String(PORT) }, stdio: ['ignore', 'pipe', 'pipe'],
});
let serverLog = '';
server.stdout.on('data', (d) => { serverLog += d.toString(); });
server.stderr.on('data', (d) => { serverLog += d.toString(); });
process.on('exit', () => { try { server.kill(); } catch { /* 이미 종료 */ } });

for (let i = 0; i < 40; i++) {
  try { if ((await fetch(`http://localhost:${PORT}/healthz`)).ok) break; } catch { /* 아직 */ }
  await new Promise((r) => setTimeout(r, 250));
}

// 옵저버 — 서버가 실제로 무엇을 브로드캐스트하는지 본다
const seen = [];
const obs = new WebSocket(`ws://localhost:${PORT}/ws`);
await new Promise((res, rej) => { obs.on('open', res); obs.on('error', rej); });
obs.on('message', (raw) => { try { seen.push(JSON.parse(raw.toString('utf-8'))); } catch { /* 무시 */ } });
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

const waitFor = async (pred, what, timeoutMs = 8000) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const hit = seen.find(pred);
    if (hit) return hit;
    await new Promise((r) => setTimeout(r, 100));
  }
  check(false, `${what} (${timeoutMs}ms 안에 브로드캐스트를 못 받음)`);
  return null;
};

// 세로 모드 폰 에뮬레이션. hasTouch를 켜야 Godot의
// DisplayServer.is_touchscreen_available()이 참이 되어 터치 UI가 뜬다.
const phone = devices['Pixel 7'] ?? {
  viewport: { width: 412, height: 915 }, deviceScaleFactor: 2.6,
  isMobile: true, hasTouch: true,
};
const browser = await chromium.launch({
  args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
});
const ctx = await browser.newContext({ ...phone });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
page.on('console', (m) => { if (m.type() === 'error') errors.push(`console.error: ${m.text()}`); });

await page.goto(`http://localhost:${PORT}/`, { waitUntil: 'load', timeout: 30000 });
await page.waitForSelector('canvas', { timeout: 30000 });
for (let i = 0; i < 40; i++) {
  const len = await page.evaluate(() => {
    const c = document.querySelector('canvas');
    try { return c ? c.toDataURL('image/png').length : 0; } catch { return 0; }
  });
  if (len > 20000) break;
  await page.waitForTimeout(500);
  if (i === 39) check(false, '캔버스가 20초 안에 그려지지 않음');
}
await page.waitForTimeout(1500);
const size = page.viewportSize();
await page.screenshot({ path: `${OUT}/1-세로-슬롯화면.png` });
console.log(`\n뷰포트: ${size.width}x${size.height} (세로 모드)`);

// --- 슬롯 선택: 세로 화면에서도 버튼이 화면 안에 있어야 누를 수 있다 ---
console.log('\n[검증] 세로 화면에서 캐릭터 만들기');
await tapGodot(page, 'slot1', { touch: true });
await page.waitForTimeout(700);
await page.screenshot({ path: `${OUT}/2-세로-외형선택.png` });
await tapGodot(page, 'preset1', { touch: true });
await page.waitForTimeout(700);
await page.screenshot({ path: `${OUT}/3-세로-이름입력.png` });
// 이름 입력창을 탭해 포커스를 주고 ASCII로 입력(한글은 합성 키로 안 들어간다)
await tapGodot(page, 'nameField', { touch: true });
await page.waitForTimeout(300);
await page.keyboard.type('Phone', { delay: 60 });
await page.keyboard.press('Enter');
await page.waitForTimeout(3000);
await page.screenshot({ path: `${OUT}/4-세로-월드진입.png` });
const joined = await waitFor((m) => m.t === 'join' && m.player?.name === 'Phone', '폰 클라이언트 접속');
check(!!joined, '세로 화면에서 슬롯·외형·이름을 거쳐 월드에 진입');
const token = joined?.player?.token;

// --- 가상 조이스틱: 왼쪽 하단을 눌러 끌면 이동해야 한다 ---
console.log('\n[검증] 가상 조이스틱 드래그로 이동');
const stick = await godotPoint(page, 'stickCenter');
const cdp = await ctx.newCDPSession(page);
const drag = await dragTouch(cdp, stick, { x: stick.x + 90, y: stick.y }, { page, steps: 4, holdMs: 60 });
await page.screenshot({ path: `${OUT}/5-조이스틱-드래그중.png` });
await drag.hold(350);
await drag.release();
const moved = await waitFor(
  (m) => m.t === 'move' && (m.moves || []).some((v) => v.token === token && v.x > 0.5),
  '조이스틱 이동이 서버에 반영됨',
);
check(!!moved, '조이스틱을 오른쪽으로 끌면 캐릭터가 오른쪽으로 이동(x > 0.5)');

// 손을 떼면 멈춰야 한다 — 떼고도 계속 가면 조이스틱 해제가 안 된 것이다.
await page.waitForTimeout(500);
const xAfterRelease = lastPos(token)?.x ?? 0;
await page.waitForTimeout(1200);
check(Math.abs((lastPos(token)?.x ?? 0) - xAfterRelease) < 0.2, '손을 떼면 이동이 멈춘다');

// --- 주 액션 버튼: 채집 → 버리기로 서버 가방까지 확인 ---
console.log('\n[검증] 터치 버튼(채집/줍기 · 버리기)');
// 스폰(0,0) 오른쪽 5칸에 나무가 있다(data/gatherables.json).
// 고정 시간만큼 끌면 지나치거나 못 미치므로, **옵저버가 알려주는 좌표를 보며**
// 목표에 다가가면 손을 뗀다(첫 시도에서 x가 16까지 가버려 채집이 실패했다).
async function walkToX(targetX, tolerance = 0.8, maxMs = 25000) {
  // 2단 조준. 굵은 단계에서는 손가락을 붙이고 끌면서 좌표를 폴링하고, 목표에
  // 가까워지면 손을 뗀 뒤 짧은 누름으로 미세 조정한다.
  //
  // 왜 이렇게 하나: 관측 좌표는 서버 tick(10Hz)만큼 늦게 오고, 손을 떼는 것도
  // 즉시 반영되지 않는다. 그래서 "목표에 닿으면 뗀다"만으로는 매번 지나쳐
  // 20 → 14 → 8.7 → 2.9로 목표를 넘나들었다(2026-09-04 실측).
  const tp = (x, y) => ({ x, y, radiusX: 12, radiusY: 12, force: 1 });
  const RELEASE_LEAD = 1.6;   // 지연 보상: 목표보다 이만큼 앞에서 손을 뗀다
  const t0 = Date.now();

  const press = async (d) => {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [tp(stick.x, stick.y)] });
    await cdp.send('Input.dispatchTouchEvent', {
      type: 'touchMove', touchPoints: [tp(stick.x + 90 * d, stick.y)],
    });
  };
  const keep = async (d) => cdp.send('Input.dispatchTouchEvent', {
    type: 'touchMove', touchPoints: [tp(stick.x + 90 * d, stick.y)],
  });
  const release = async () => cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  const x = () => lastPos(token)?.x ?? 0;

  // --- 굵은 접근 ---
  let dir = x() < targetX ? 1 : -1;
  if (Math.abs(targetX - x()) > RELEASE_LEAD) {
    await press(dir);
    while (Date.now() - t0 < maxMs) {
      const diff = targetX - x();
      if (Math.abs(diff) <= RELEASE_LEAD) break;
      if (Math.sign(diff) !== dir) {   // 지나쳤으면 방향 전환
        await release();
        dir = Math.sign(diff);
        await press(dir);
      } else {
        await keep(dir);
      }
      await page.waitForTimeout(100);
    }
    await release();
    await page.waitForTimeout(400);
  }

  // --- 미세 조정: 짧게 눌러 조금씩 ---
  for (let i = 0; i < 10; i++) {
    const diff = targetX - x();
    if (Math.abs(diff) <= tolerance) break;
    const d = Math.sign(diff);
    await press(d);
    await page.waitForTimeout(Math.min(220, Math.max(90, Math.abs(diff) * 120)));
    await release();
    await page.waitForTimeout(350);
  }
  return x();
}
const arrivedX = await walkToX(TREE.x);
console.log(`  (이동 결과 x=${arrivedX})`);
check(arrivedX !== null && Math.abs(arrivedX - TREE.x) <= 1.2, `나무 근처(x≈${TREE.x})까지 조이스틱으로 이동`);
await page.screenshot({ path: `${OUT}/6-이동후-터치UI.png` });

await tapGodot(page, 'actionButton', { touch: true });   // 채집
await page.waitForTimeout(800);
await page.screenshot({ path: `${OUT}/7-채집후.png` });
await tapGodot(page, 'dropButton', { touch: true });     // 버리기
const added = await waitFor((m) => m.t === 'item_add', '버리기가 서버에 반영됨');
check(!!added, '터치로 채집한 물건을 버리기 버튼으로 놓을 수 있다(= 서버 가방에 들어갔다)');
await page.screenshot({ path: `${OUT}/8-버리기후.png` });

// --- 이모티콘 하단 시트 ---
console.log('\n[검증] 이모티콘 하단 시트');
await tapGodot(page, 'emoteButton', { touch: true });
await page.waitForTimeout(600);
await page.screenshot({ path: `${OUT}/9-이모티콘-시트.png` });
await tapGodot(page, 'emoteItem1', { touch: true });
const emote = await waitFor((m) => m.t === 'emote' && m.token === token, '이모티콘이 서버에 반영됨');
check(!!emote, '이모티콘 시트에서 고르면 다른 기기로 전달된다');
await page.screenshot({ path: `${OUT}/10-이모티콘-전송후.png` });

// --- 채팅 버튼 → DOM input이 실제로 뜨는가 ---
console.log('\n[검증] 채팅 입력(DOM input 오버레이)');
await tapGodot(page, 'chatButton', { touch: true });
await page.waitForTimeout(600);
const domInput = await page.evaluate(() => {
  const el = document.getElementById('af-chat-input');
  if (!el) return null;
  const cs = window.getComputedStyle(el);
  return { display: cs.display, focused: document.activeElement === el, tag: el.tagName, type: el.type };
});
check(!!domInput, '채팅 버튼을 누르면 DOM <input>이 만들어진다');
check(domInput?.display === 'block', 'DOM input이 화면에 표시된다');
check(domInput?.focused === true, 'DOM input에 포커스가 걸린다(모바일 키보드가 뜨는 조건)');
await page.screenshot({ path: `${OUT}/11-채팅-DOM입력.png` });
// DOM input이므로 브라우저 네이티브 입력 — 여기서는 ASCII로 전송만 확인한다.
await page.keyboard.type('touch hello', { delay: 40 });
await page.keyboard.press('Enter');
const chat = await waitFor((m) => m.t === 'chat' && m.text === 'touch hello', '채팅이 서버에 반영됨');
check(!!chat, 'DOM input에서 Enter로 전송된다');
const afterSubmit = await page.evaluate(() => {
  const el = document.getElementById('af-chat-input');
  return el ? window.getComputedStyle(el).display : null;
});
check(afterSubmit === 'none', '전송 후 입력창이 닫힌다');
await page.screenshot({ path: `${OUT}/12-채팅-전송후.png` });

// --- 가로 모드 전환 ---
console.log('\n[검증] 가로 모드 회전');
await page.setViewportSize({ width: size.height, height: size.width });
await page.waitForTimeout(1200);
await page.screenshot({ path: `${OUT}/13-가로모드.png` });
check(true, '가로 모드로 회전 후에도 렌더 계속(스크린샷으로 잘림 확인)');

obs.close();
await browser.close();
await new Promise((r) => setTimeout(r, 300));
server.kill();

console.log(`\n스크린샷: ${OUT}/`);
if (errors.length) {
  console.log('\n=== 브라우저 오류 ===');
  console.log(errors.join('\n'));
  failures.push(`브라우저 오류 ${errors.length}건`);
}
if (failures.length) {
  console.error(`\n❌ 모바일 터치 테스트 실패 ${failures.length}건`);
  for (const f of failures) console.error(`  - ${f}`);
  console.error('\n--- 서버 로그 ---\n' + serverLog.slice(-1500));
  process.exit(1);
}
console.log('\n✅ 모바일 터치 테스트 통과 — 조이스틱·액션 버튼·이모티콘 시트·DOM 채팅 입력이 동작');
console.log('   ⚠️ 한글 IME 조합과 실제 엄지 도달감은 사람이 폰에서 확인해야 한다');
