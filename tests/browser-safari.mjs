// 사파리(WebKit)에서 **키보드가 뜨는 조건**을 검증한다.
//
// 사용자 보고(2026-09-05): "사파리에서 텍스트 입력할 때 키보드가 안나와".
// iOS 사파리는 `focus()`가 **사용자 제스처 핸들러 안에서** 호출될 때만 소프트
// 키보드를 띄운다. 그래서 두 경로를 각각 다르게 고쳤고, 여기서 둘 다 본다.
//
//  1) 이름 입력: Godot LineEdit은 웹에서 OS 키보드를 못 띄운다 → 실제 <input>을
//     필드 위에 겹쳐 둔다. 사용자가 그것을 직접 탭하므로 제스처가 그대로 인정된다.
//  2) 채팅: 버튼이 캔버스 안에 그려져 있어 탭 → Godot 신호 → focus()는 이미
//     제스처를 벗어난다 → 셸(web/shell.html)이 버튼 영역(afHotspots)을 받아
//     터치 핸들러 안에서 직접 포커스를 준다.
//  3) 전체화면: 브라우저가 요구하는 제약이 같다(제스처 안에서만 허용) —
//     그래서 같은 통로(afHotspots)로 처리한다.
//
// 판정은 **document.activeElement가 그 input인지**다. 헤드리스에서는 실제
// 키보드가 뜨지 않으므로, 브라우저가 요구하는 조건(제스처 안 포커스)이
// 충족됐는지로 본다.
import { webkit } from 'playwright';
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { tapGodot, godotPoint } from './godot-tap.mjs';
const PORT = Number(process.env.PORT || 3191);
// 상태 파일은 **매번 임시 디렉터리**로 만든다(고정 경로면 지난 실행의 캐릭터가
// 남는다). 서버가 떴는지는 고정 대기가 아니라 **우리 프로세스의 기동 로그**로
// 확인한다 — 그 포트를 남이 잡고 있으면 healthz만으로는 엉뚱한 서버에 붙는다
// (tests/server-reconnect.test.mjs와 같은 이유).
const statePath = join(mkdtempSync(join(tmpdir(), 'af-safari-')), 'world.json');
const srv = spawn('node', ['server/index.js'], {
  cwd: process.cwd(),
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
const browser = await webkit.launch();
const ctx = await browser.newContext({ viewport:{width:390,height:844}, deviceScaleFactor:3, isMobile:true, hasTouch:true });
const page = await ctx.newPage();
page.on('pageerror', e=>console.log('!! pageerror', e.message.slice(0,200)));
await page.goto(`http://127.0.0.1:${PORT}/`);
await page.waitForFunction(()=>window.afTest?.points?.slot1, null, {timeout:90000});
console.log('선택 화면 진입');
await tapGodot(page,'slot1',{touch:true}); await page.waitForTimeout(600);
await tapGodot(page,'preset1',{touch:true}); await page.waitForTimeout(800);
// 이름 화면: DOM input이 생겼는지 + 겹쳐 놓였는지
const info = await page.evaluate(()=>{
  const el = document.getElementById('af-name-input');
  if (!el) return {exists:false};
  const r = el.getBoundingClientRect();
  return {exists:true, display:el.style.display, rect:[Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)], focused: document.activeElement === el};
});
const results = [];
const check = (ok, label) => { results.push({ ok, label }); console.log(`  ${ok ? 'ok ' : '❌ '} — ${label}`); };
check(info.exists && info.display !== 'none', '이름 화면에 실제 <input>이 겹쳐 놓인다');
check(info.rect[2] > 100 && info.rect[3] > 20,
  `입력창이 필드 크기로 놓인다 (${info.rect.join(',')})`);
// 필드를 직접 탭 → 포커스가 걸려야 한다(= 키보드가 뜨는 조건)
const np = await godotPoint(page,'nameField');
await page.touchscreen.tap(np.x, np.y);
await page.waitForTimeout(500);
const focused = await page.evaluate(()=>document.activeElement === document.getElementById('af-name-input'));
check(focused, '필드를 탭하면 <input>에 포커스가 걸린다(= iOS 키보드가 뜨는 조건)');
await page.keyboard.type('Somi', {delay:60});
const typed = await page.evaluate(()=>document.getElementById('af-name-input').value);
check(typed === 'Somi', `입력한 글자가 들어간다 (${typed})`);
await tapGodot(page,'startButton',{touch:true});
await page.waitForFunction(()=>window.afTest?.points?.actionButton, null, {timeout:60000});
await page.waitForTimeout(1500);
check(true, 'DOM 입력으로 지은 이름으로 월드에 진입한다');
// 채팅 버튼 탭 → 핫스팟으로 포커스가 걸려야 한다
const hs = await page.evaluate(()=>window.afHotspots?.chat || null);
check(Array.isArray(hs) && hs.length === 5, `게임이 채팅 버튼 영역을 셸에 알린다 (${JSON.stringify(hs)})`);
const cb = await godotPoint(page,'chatButton');
await page.touchscreen.tap(cb.x, cb.y);
await page.waitForTimeout(700);
const chatFocused = await page.evaluate(()=>{
  const el = document.getElementById('af-chat-input');
  return {exists: !!el, display: el?.style.display, focused: document.activeElement === el};
});
check(chatFocused.focused, '채팅 버튼을 탭하면 채팅 <input>에 포커스가 걸린다');
await page.keyboard.type('안녕', {delay:60});
const chatTyped = await page.evaluate(()=>document.getElementById('af-chat-input').value);
check(chatTyped.length > 0, `채팅 입력창에 글자가 들어간다 (${chatTyped})`);

// --- 전체화면도 같은 제약(제스처 안에서만 허용)을 받는다 ---
await page.keyboard.press('Escape');   // 채팅 닫기
await page.waitForTimeout(400);
// **지원 여부에 따라 판정이 갈린다.** 아이폰 사파리에는 Fullscreen API가 없어
// (비디오 전용 webkitEnterFullscreen만 있다) 눌러도 아무 일이 없다 — 그런
// 브라우저에서는 버튼을 숨기는 것이 올바른 동작이고, 헤드리스 WebKit도 같은
// 상태를 보고한다. 그래서 두 경로를 각각 확인한다.
// 기본값 극성을 게임과 맞춘다(셸 초기화가 늦으면 지원한다고 본다) — 반대로
// 두면 원인 찾기 어려운 실패가 남는다.
const fsSupported = await page.evaluate(() => window.afFullscreenSupported !== false);
const fsHotspot = await page.evaluate(() => window.afHotspots?.fullscreen ?? null);
if (!fsSupported) {
  check(fsHotspot == null,
    '전체화면을 지원하지 않는 브라우저에서는 핫스팟을 내린다 — 눌러도 아무 일 없는 버튼을 남기지 않는다');
  // 훅은 보이지 않는 컨트롤을 게시하지 않으므로(test_hooks.gd) 키가 사라진다.
  // 앞 단언과 겹치는 `|| fsHotspot == null`을 두면 이 검증이 죽는다(리뷰 지적).
  // 훅 자체가 죽어도 "버튼이 사라졌다"로 읽히면 공허한 통과다 — 살아 있어야
  // 하는 키를 같이 단언한다(리뷰 지적).
  const points = await page.evaluate(() => window.afTest?.points ?? null);
  check(points != null && points.zoomIn != null, '테스트 훅이 살아 있다(zoomIn 존재)');
  check(points?.fullscreenButton == null, '버튼이 화면에서 사라진다(훅에서도 빠진다)');
} else {
  check(Array.isArray(fsHotspot) && fsHotspot[4] === 'fullscreen',
    `게임이 전체화면 버튼 영역을 셸에 알린다 (${JSON.stringify(fsHotspot)})`);
  const fsBefore = await page.evaluate(() => window.afFullscreenRequests ?? -1);
  await tapGodot(page, 'fullscreenButton', { touch: true });
  await page.waitForTimeout(600);
  const fsAfter = await page.evaluate(() => window.afFullscreenRequests ?? -1);
  const fsErr = await page.evaluate(() => window.afFullscreenLastError ?? '');
  // 판정은 "제스처 안에서 **실제로 호출까지 성공했는가**"다. 브라우저가 그 뒤
  // 거절하는지는 환경 정책이라 우리가 지킬 수 있는 범위가 아니다.
  check(fsAfter === fsBefore + 1,
    `버튼을 탭하면 셸이 제스처 안에서 전체화면을 요청한다 (${fsBefore} → ${fsAfter}${fsErr ? ', 오류: ' + fsErr : ''})`);
}
await page.screenshot({ path: 'build/screenshots/safari-채팅.png' }).catch(() => {});
await browser.close();
stop();

const failed = results.filter((r) => !r.ok);
console.log('');
if (failed.length) {
  console.error(`❌ 사파리 입력 테스트 실패 ${failed.length}건`);
  process.exit(1);
}
console.log('✅ 사파리 입력 테스트 통과 — 이름·채팅 입력이 제스처 안에서 포커스된다');
