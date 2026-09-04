import { chromium } from 'playwright';
import { spawn } from 'child_process';
import { tapGodot, godotPoint } from './godot-tap.mjs';
import { mkdirSync, existsSync, statSync } from 'fs';
import { createHash } from 'crypto';
import { readFileSync } from 'fs';

// 브라우저 스모크 테스트 — 웹 export 산출물이 실제 브라우저에서 기동하고
// 입력이 게임에 전달되는지 확인한다.
//
// 이 테스트가 필요한 이유: 헤드리스 Godot 검증(verify-project.sh)은 데스크톱
// 런타임을 돌리는 것이라, 웹 export에서만 드러나는 문제를 못 잡는다. 실제로
// 첫 브라우저 실행에서 한글이 전부 두부(□)로 나오는 문제를 발견했다 —
// Godot 기본 폰트에 한글 글리프가 없고 웹에는 시스템 폰트 폴백이 없다
// (2026-09-04, assets/fonts/NotoSansKR 임베드로 해결).
//
// 실행: npm run test:browser   (사전에 ./scripts/build-web.sh 필요)
//
// HUD가 캔버스에 그려져서 DOM으로 텍스트를 읽을 수 없으므로, 게임 상태는
// 테스트 훅이 공개하는 값(window.afTest.state)으로 판정한다 — 화면 비교만으로
// 판정하면 "아무 일도 일어나지 않았는데 화면이 조금 달라져서" 통과한다
// (2026-09-05: 이 테스트가 외형 선택 화면에서 멈춘 채로 몇 달 통과했다).

const PORT = Number(process.env.PORT || 3112);
const OUT = process.env.SHOT_DIR || 'build/screenshots';
const BUILD = 'build/web/index.html';

if (!existsSync(BUILD)) {
  console.error(`ERROR: ${BUILD}이 없습니다 — 먼저 ./scripts/build-web.sh를 실행하세요.`);
  process.exit(1);
}
mkdirSync(OUT, { recursive: true });

const server = spawn('node', ['server/index.js'], {
  env: { ...process.env, PORT: String(PORT), TLS: 'off' },
  stdio: 'ignore',
});
const stopServer = () => { try { server.kill(); } catch { /* 이미 종료 */ } };
process.on('exit', stopServer);

const failures = [];
const shot = (name) => `${OUT}/${name}.png`;
/** 게임 상태(scripts/test_hooks.gd가 공개). HUD가 캔버스라 DOM으로 못 읽는다. */
const state = async () => await page.evaluate(() => ({
  bells: Number(window.afTest?.state?.bells ?? -1),
  bagCount: Number(window.afTest?.state?.bagCount ?? -1),
  z: Number(window.afTest?.state?.z ?? 0),
}));
const hash = (p) => createHash('sha1').update(readFileSync(p)).digest('hex');

const browser = await chromium.launch({
  args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
});
const page = await browser.newPage({ viewport: { width: 960, height: 540 } });

const errors = [];
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
page.on('requestfailed', (r) => errors.push(`requestfailed: ${r.url()} ${r.failure()?.errorText}`));
page.on('console', (m) => {
  if (m.type() === 'error') errors.push(`console.error: ${m.text()}`);
});

// 서버가 뜰 때까지 대기
let up = false;
for (let i = 0; i < 20; i++) {
  try {
    const r = await fetch(`http://localhost:${PORT}/healthz`);
    if (r.ok) { up = true; break; }
  } catch { /* 아직 안 뜸 */ }
  await new Promise((r) => setTimeout(r, 250));
}
if (!up) failures.push('서버가 /healthz에 응답하지 않음');

const resp = await page.goto(`http://localhost:${PORT}/`, { waitUntil: 'load', timeout: 30000 });
if (resp.status() !== 200) failures.push(`index.html 상태 ${resp.status()}`);
await page.waitForSelector('canvas', { timeout: 30000 });

// 캔버스가 실제로 그려졌는지 — 크기와 PNG 데이터 길이로 판정(단색이면 매우 짧다)
let started = false;
for (let i = 0; i < 40; i++) {
  const s = await page.evaluate(() => {
    const c = document.querySelector('canvas');
    if (!c || !c.width) return null;
    try { return { w: c.width, h: c.height, len: c.toDataURL('image/png').length }; }
    catch { return { w: c.width, h: c.height, len: 0 }; }
  });
  if (s && s.len > 20000) {
    console.log(`캔버스 기동 확인: ${s.w}x${s.h} (png len=${s.len})`);
    started = true;
    break;
  }
  await page.waitForTimeout(500);
}
if (!started) failures.push('캔버스가 20초 안에 그려지지 않음(엔진 기동 실패 가능)');

await page.waitForTimeout(1500);
await page.screenshot({ path: shot('00-캐릭터선택') });

// 캐릭터를 만들어 월드까지 들어간다.
//
// 예전에는 캔버스 중앙(480,270)을 그냥 클릭했는데, 그건 **외형 선택 화면을
// 클릭한 것**이어서 월드에 들어가지 못한 채로 아래 판정을 다 돌렸다. 화면이
// 캔버스라 "무슨 화면인지"가 코드에 안 보여 몇 달 동안 드러나지 않았고,
// 걷기·채집 판정이 조용히 실패로 남아 있었다(2026-09-05 확인).
// 좌표는 테스트 훅이 알려주는 실제 UI 위치를 쓴다(tests/godot-tap.mjs).
await page.waitForFunction(() => window.afTest?.points?.slot1, null, { timeout: 30000 });
await tapGodot(page, 'slot1');
await page.waitForTimeout(400);
await tapGodot(page, 'preset1');
await page.waitForTimeout(400);
await tapGodot(page, 'nameField');
await page.keyboard.type('Smoke', { delay: 50 });   // 한글은 합성 키로 안 들어간다
await tapGodot(page, 'startButton');
await page.waitForFunction(() => window.afTest?.points?.playerScreen, null, { timeout: 30000 });
await page.waitForTimeout(1200);
await page.screenshot({ path: shot('01-초기화면') });   // 월드 진입 상태로 다시 찍는다

// 방향키가 게임에 전달되는지 — 화면 비교로만 보던 것을 좌표로 확인한다.
const beforeMove = await state();
await page.keyboard.down('ArrowDown');
await page.waitForTimeout(700);
await page.keyboard.up('ArrowDown');
await page.screenshot({ path: shot('02-이동후') });
const afterMove = await state();
if (!(Math.abs(afterMove.z - beforeMove.z) > 0.3)) {
  failures.push(`아래 방향키를 눌렀는데 z가 거의 그대로(${beforeMove.z} → ${afterMove.z})`);
}

// 채집 1사이클. 예전에는 "시작 위치 아래에 잡초가 있다"고 가정해 Space만
// 눌렀는데, 근처에 채집물이 없으면 아무 일도 일어나지 않고 화면만 조금
// 달라져서 통과했다 — 가방 개수를 실제로 확인한다.
const bush = await godotPoint(page, 'nearestGatherable');
await page.mouse.click(bush.x, bush.y);
let bagged = false;
for (let i = 0; i < 40; i++) {
  if ((await state()).bagCount > 0) { bagged = true; break; }
  await page.waitForTimeout(300);
}
await page.screenshot({ path: shot('03-채집') });
if (!bagged) failures.push('채집물을 클릭해도 가방이 늘지 않음 — 채집이 동작하지 않는다');

// 판매까지. S는 가방 화면을 열고, 거기서 전부 판매를 확정한다.
await page.keyboard.press('KeyS');
await page.waitForTimeout(500);
if (bagged) {
  await tapGodot(page, 'invSellAll');
  let sold = false;
  for (let i = 0; i < 30; i++) {
    if ((await state()).bells > 0) { sold = true; break; }
    await page.waitForTimeout(300);
  }
  if (!sold) failures.push('전부 판매를 눌렀는데 벨이 늘지 않음 — 판매가 동작하지 않는다');
}
await page.screenshot({ path: shot('04-판매후') });

// 걷기 애니메이션 검증: 방향키를 계속 누른 상태로 짧은 간격 프레임을 찍어
// 스프라이트 프레임이 실제로 교체되는지 본다. 카메라가 플레이어를 따라가므로
// "이동해서 화면이 달라진 것"과 구분되지 않을 수 있어, 벽(섬 경계)에 붙여
// 더 이상 움직이지 못하는 상태에서 찍는다 — 그때 달라지는 것은 애니메이션뿐이다.
await page.keyboard.down('ArrowRight');
await page.waitForTimeout(3000);          // 섬 오른쪽 끝까지 이동해 벽에 붙임
const walkShots = [];
for (let i = 0; i < 4; i++) {
  const p = shot(`05-걷기-${i}`);
  await page.screenshot({ path: p });
  walkShots.push(hash(p));
  await page.waitForTimeout(130);         // 8FPS 기준 한 프레임(125ms)보다 약간 길게
}
await page.keyboard.up('ArrowRight');
if (new Set(walkShots).size < 2) {
  failures.push('벽에 붙은 상태에서 프레임이 전혀 바뀌지 않음 — 걷기 애니메이션이 재생되지 않는다');
} else {
  console.log(`걷기 애니메이션 확인: 4장 중 서로 다른 화면 ${new Set(walkShots).size}종`);
}

// 입력이 실제로 게임에 전달됐는지 — 화면이 바뀌지 않았다면 입력이 먹지 않은 것
if (hash(shot('00-캐릭터선택')) === hash(shot('01-초기화면'))) {
  failures.push('캐릭터를 만들어도 화면이 그대로 — 월드에 진입하지 못했다');
}
if (hash(shot('01-초기화면')) === hash(shot('02-이동후'))) {
  failures.push('방향키 입력 전후 화면이 동일 — 입력이 게임에 전달되지 않음');
}
if (hash(shot('02-이동후')) === hash(shot('03-채집'))) {
  failures.push('채집 키 입력 전후 화면이 동일 — 채집 상호작용이 동작하지 않음');
}
for (const name of ['00-캐릭터선택', '01-초기화면', '02-이동후', '03-채집', '04-판매후']) {
  if (statSync(shot(name)).size < 2000) failures.push(`${name} 스크린샷이 비정상적으로 작음(렌더 실패 의심)`);
}

await browser.close();
stopServer();

console.log(`\n스크린샷: ${OUT}/`);
if (errors.length) {
  console.log('\n=== 브라우저 오류 ===');
  console.log(errors.join('\n'));
  failures.push(`브라우저 오류 ${errors.length}건`);
}
if (failures.length) {
  console.error('\n❌ 브라우저 스모크 실패:');
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}
console.log('\n✅ 브라우저 스모크 통과 — 기동/입력/채집/판매 사이클 정상, JS 오류 없음');
console.log('   (가방 개수·벨은 테스트 훅으로 확인했고, 스크린샷은 눈으로 볼 용도다)');
