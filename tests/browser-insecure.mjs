import { chromium } from 'playwright';
import { spawn } from 'child_process';
import { existsSync } from 'fs';
import { networkInterfaces } from 'os';

// **비보안 컨텍스트(http, localhost 아님)에서도 게임이 뜨는지** 검증한다.
//
// 배경: Godot 4의 기본 HTML 셸은 보안 컨텍스트가 아니면 실행을 아예 거부한다
// ("Secure Context - Check web server configuration (use HTTPS)"). 폰에서
// http://192.168.x.x 로 붙었을 때 실제로 그 화면이 떴다(2026-09-04 사용자 보고).
// localhost는 브라우저가 보안 컨텍스트로 취급하므로 기존 테스트로는 절대
// 재현되지 않는다 — 그래서 **LAN IP로** 접속하는 테스트를 따로 둔다.
//
// 실행: npm run test:insecure   (사전에 ./scripts/build-web.sh 필요)

const PORT = Number(process.env.PORT || 3117);

function lanAddress() {
  for (const list of Object.values(networkInterfaces())) {
    for (const net of list || []) {
      if (net.family === 'IPv4' && !net.internal) return net.address;
    }
  }
  return null;
}

if (!existsSync('build/web/index.html')) {
  console.error('ERROR: build/web/index.html이 없습니다 — 먼저 ./scripts/build-web.sh를 실행하세요.');
  process.exit(1);
}
const host = lanAddress();
if (!host) {
  console.error('SKIP: LAN IPv4 주소를 찾지 못해 비보안 컨텍스트를 재현할 수 없습니다.');
  process.exit(0);
}

const failures = [];
const check = (cond, what) => {
  if (cond) console.log(`  ok  — ${what}`);
  else { failures.push(what); console.error(`  FAIL — ${what}`); }
};

// TLS=off로 강제 http 기동 — 인증서가 있어도 http를 검증할 수 있어야 한다.
const server = spawn('node', ['server/index.js'], {
  env: { ...process.env, PORT: String(PORT), TLS: 'off' }, stdio: ['ignore', 'pipe', 'pipe'],
});
let log = '';
server.stdout.on('data', (d) => { log += d.toString(); });
server.stderr.on('data', (d) => { log += d.toString(); });
process.on('exit', () => { try { server.kill(); } catch { /* 이미 종료 */ } });
for (let i = 0; i < 40; i++) {
  try { if ((await fetch(`http://${host}:${PORT}/healthz`)).ok) break; } catch { /* 아직 */ }
  await new Promise((r) => setTimeout(r, 250));
}

const browser = await chromium.launch({
  args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
});
const page = await browser.newPage({ viewport: { width: 960, height: 540 } });
const errors = [];
const consoleLines = [];
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
page.on('console', (m) => {
  consoleLines.push(`[${m.type()}] ${m.text()}`);
  if (m.type() === 'error') errors.push(`console.error: ${m.text()}`);
});

const url = `http://${host}:${PORT}/`;
console.log(`\n비보안 컨텍스트 접속: ${url}`);
const t0 = Date.now();
await page.goto(url, { waitUntil: 'load', timeout: 30000 });
check((await page.evaluate(() => window.isSecureContext)) === false, '보안 컨텍스트가 아니다(테스트 전제)');

await page.waitForSelector('canvas', { timeout: 30000 });
let drawn = false;
for (let i = 0; i < 60; i++) {
  const len = await page.evaluate(() => {
    const c = document.querySelector('canvas');
    try { return c ? c.toDataURL('image/png').length : 0; } catch { return 0; }
  });
  if (len > 20000) { drawn = true; break; }
  await page.waitForTimeout(500);
}
const elapsed = ((Date.now() - t0) / 1000).toFixed(1);
check(drawn, `http(비보안)에서도 게임 화면이 그려진다 (${elapsed}초)`);

// 기본 셸이라면 이 문구가 화면/DOM에 남는다.
const pageText = await page.evaluate(() => document.body.innerText || '');
check(!/Secure Context/.test(pageText), '"Secure Context" 실패 화면이 뜨지 않는다');
// 우리 셸이 남기는 경고는 정상(소리만 못 쓴다는 안내).
const warned = consoleLines.some((l) => l.includes('보안 컨텍스트가 아닙니다'));
check(warned, '보안 컨텍스트 경고를 콘솔에 남긴다(소리 제약 안내)');

await page.screenshot({ path: 'build/screenshots/insecure-http.png' });
await browser.close();
server.kill();

if (errors.length) {
  console.log('\n=== 브라우저 오류 ===');
  console.log(errors.join('\n'));
}
if (failures.length) {
  console.error(`\n❌ 비보안 컨텍스트 테스트 실패 ${failures.length}건`);
  console.error('\n--- 서버 로그 ---\n' + log.slice(-800));
  process.exit(1);
}
console.log('\n✅ http(비보안 컨텍스트)에서도 실행됨 — 폰에서 https 없이 접속 가능');
console.log('   ⚠️ 다만 소리(AudioWorklet)는 보안 컨텍스트가 필요해 http에서는 동작하지 않을 수 있다');
