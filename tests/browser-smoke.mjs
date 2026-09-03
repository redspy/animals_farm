import { chromium } from 'playwright';
import { spawn } from 'child_process';
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
// ⚠️ 한계: HUD가 캔버스에 그려져서 DOM으로 텍스트를 읽을 수 없다. 그래서
// 이 테스트는 (a) 캔버스 기동, (b) JS 오류 0건, (c) 입력 전후 화면이 실제로
// 바뀌었는지까지만 자동 판정하고, 벨/가방 숫자 같은 게임 상태는 저장된
// 스크린샷을 사람이 확인한다.

const PORT = Number(process.env.PORT || 3112);
const OUT = process.env.SHOT_DIR || 'build/screenshots';
const BUILD = 'build/web/index.html';

if (!existsSync(BUILD)) {
  console.error(`ERROR: ${BUILD}이 없습니다 — 먼저 ./scripts/build-web.sh를 실행하세요.`);
  process.exit(1);
}
mkdirSync(OUT, { recursive: true });

const server = spawn('node', ['server/index.js'], {
  env: { ...process.env, PORT: String(PORT) },
  stdio: 'ignore',
});
const stopServer = () => { try { server.kill(); } catch { /* 이미 종료 */ } };
process.on('exit', stopServer);

const failures = [];
const shot = (name) => `${OUT}/${name}.png`;
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
await page.screenshot({ path: shot('01-초기화면') });

// 시작 위치(480,280) 바로 아래 잡초(480,430)로 내려가 채집 → 판매까지 1사이클
await page.locator('canvas').click({ position: { x: 480, y: 270 } });
await page.keyboard.down('ArrowDown');
await page.waitForTimeout(700);
await page.keyboard.up('ArrowDown');
await page.screenshot({ path: shot('02-이동후') });

await page.keyboard.press('Space');
await page.waitForTimeout(700);
await page.screenshot({ path: shot('03-채집') });

await page.keyboard.press('KeyS');
await page.waitForTimeout(700);
await page.screenshot({ path: shot('04-판매후') });

// 입력이 실제로 게임에 전달됐는지 — 화면이 바뀌지 않았다면 입력이 먹지 않은 것
if (hash(shot('01-초기화면')) === hash(shot('02-이동후'))) {
  failures.push('방향키 입력 전후 화면이 동일 — 입력이 게임에 전달되지 않음');
}
if (hash(shot('02-이동후')) === hash(shot('03-채집'))) {
  failures.push('채집 키 입력 전후 화면이 동일 — 채집 상호작용이 동작하지 않음');
}
for (const name of ['01-초기화면', '02-이동후', '03-채집', '04-판매후']) {
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
console.log('   (벨·가방 숫자 등 게임 상태는 위 스크린샷으로 눈으로 확인할 것)');
