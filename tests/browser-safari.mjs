// 사파리(WebKit)에서 **키보드가 뜨는 조건**을 검증한다.
//
// 사용자 보고(2026-09-05): "사파리에서 텍스트 입력할 때 키보드가 안나와".
// iOS 사파리는 `focus()`가 **사용자 제스처 핸들러 안에서** 호출될 때만 소프트
// 키보드를 띄운다. 그래서 두 경로를 각각 다르게 고쳤고, 여기서 둘 다 본다.
//
//  1) 이름 입력: Godot LineEdit은 웹에서 OS 키보드를 못 띄운다 → 실제 <input>을
//     필드 위에 겹쳐 둔다. 사용자가 그것을 직접 탭하므로 제스처가 그대로 인정된다.
//  2) 채팅: 버튼이 캔버스 안에 그려져 있어 탭 → Godot 신호 → focus()는 이미
//     제스처를 벗어난다 → 셸(web/shell.html)이 버튼 영역(afTextHotspots)을 받아
//     터치 핸들러 안에서 직접 포커스를 준다.
//
// 판정은 **document.activeElement가 그 input인지**다. 헤드리스에서는 실제
// 키보드가 뜨지 않으므로, 브라우저가 요구하는 조건(제스처 안 포커스)이
// 충족됐는지로 본다.
import { webkit } from 'playwright';
import { spawn } from 'node:child_process';
import { tapGodot, godotPoint } from './godot-tap.mjs';
const PORT = Number(process.env.PORT || 3191);
const srv = spawn('node', ['server/index.js'], { cwd: process.cwd(),
  env: { ...process.env, PORT: String(PORT), TLS: 'off', HOST: '127.0.0.1', WORLD_STATE_PATH: '/tmp/af-ios.json' }, stdio: 'ignore' });
await new Promise(r=>setTimeout(r,1500));
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
const hs = await page.evaluate(()=>window.afTextHotspots?.chat || null);
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
await page.screenshot({ path: 'build/screenshots/safari-채팅.png' }).catch(() => {});
await browser.close();
srv.kill();

const failed = results.filter((r) => !r.ok);
console.log('');
if (failed.length) {
  console.error(`❌ 사파리 입력 테스트 실패 ${failed.length}건`);
  process.exit(1);
}
console.log('✅ 사파리 입력 테스트 통과 — 이름·채팅 입력이 제스처 안에서 포커스된다');
