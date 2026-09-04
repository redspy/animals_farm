// 채팅 UI 상태별 캡쳐 도구(테스트가 아니라 문서용). UI를 고친 뒤 다시 돌려
// 캡쳐를 갱신한다 — 채팅은 상태(닫힘/열림/입력중/전송후/취소)가 있어서 글로
// 설명하기보다 그림이 빠르다.
//
// WS 봇을 옆에 세워 다른 캐릭터의 한글 채팅까지 화면에 띄운다: 브라우저에
// 합성 키로는 한글을 넣을 수 없지만(IME 필요), 서버를 거쳐 오는 한글은 정상
// 표시되므로 렌더링 확인에는 이 방법이 맞다.
//
// 실행: npm run capture:chat  (사전에 ./scripts/build-web.sh 필요)

import { chromium } from 'playwright';
import WebSocket from 'ws';
import { spawn } from 'child_process';
import { rmSync, existsSync, mkdirSync } from 'fs';

const PORT = 3114;
const OUT = process.env.SHOT_DIR || 'build/screenshots/chat-ui';
mkdirSync(OUT, { recursive: true });
if (existsSync('server/data/world.json')) rmSync('server/data/world.json');

const server = spawn('node', ['server/index.js'], { env: { ...process.env, PORT: String(PORT), TLS: 'off' }, stdio: 'ignore' });
process.on('exit', () => { try { server.kill(); } catch {} });
for (let i = 0; i < 40; i++) {
  try { if ((await fetch(`http://localhost:${PORT}/healthz`)).ok) break; } catch {}
  await new Promise((r) => setTimeout(r, 250));
}

const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const page = await browser.newPage({ viewport: { width: 960, height: 540 } });
await page.goto(`http://localhost:${PORT}/`, { waitUntil: 'load' });
await page.waitForSelector('canvas');
for (let i = 0; i < 40; i++) {
  const len = await page.evaluate(() => { const c = document.querySelector('canvas'); try { return c.toDataURL('image/png').length; } catch { return 0; } });
  if (len > 20000) break;
  await page.waitForTimeout(500);
}
await page.waitForTimeout(1200);

// 슬롯 → 프리셋 → 이름
await page.locator('canvas').click({ position: { x: 480, y: 270 } });
await page.locator('canvas').click({ position: { x: 420, y: 182 } });
await page.waitForTimeout(600);
await page.locator('canvas').click({ position: { x: 480, y: 182 } });
await page.waitForTimeout(600);
await page.locator('canvas').click({ position: { x: 480, y: 218 } });
await page.keyboard.type('Ara', { delay: 60 });
await page.keyboard.press('Enter');
await page.waitForTimeout(3000);

// WS 봇: 옆에 서 있는 다른 캐릭터 + 한글 채팅(서버를 거쳐 브라우저에 표시됨)
const bot = new WebSocket(`ws://localhost:${PORT}/ws`);
await new Promise((res, rej) => { bot.on('open', res); bot.on('error', rej); });
bot.send(JSON.stringify({ t: 'join', token: '77777777-7777-4777-8777-777777777777', name: '이웃하나', preset: 'm1' }));
await new Promise((r) => setTimeout(r, 400));
bot.send(JSON.stringify({ t: 'move', x: 1.6, z: 0.2, dir: 'down' }));
await new Promise((r) => setTimeout(r, 700));
bot.send(JSON.stringify({ t: 'chat', text: '안녕! 여기 광장에서 만나자' }));
await new Promise((r) => setTimeout(r, 900));
bot.send(JSON.stringify({ t: 'chat', text: '나무 필요하면 줄게' }));
await new Promise((r) => setTimeout(r, 900));

await page.locator('canvas').click({ position: { x: 480, y: 430 } });
await page.waitForTimeout(200);
await page.screenshot({ path: `${OUT}/1-평소(입력창 닫힘).png` });

// T: 입력창 열기 (플레이스홀더 보이는 상태)
await page.keyboard.press('KeyT');
await page.waitForTimeout(600);
await page.screenshot({ path: `${OUT}/2-T로 입력창 열림.png` });

// 타이핑 중
await page.keyboard.type('hello everyone', { delay: 55 });
await page.waitForTimeout(400);
await page.screenshot({ path: `${OUT}/3-입력중.png` });

// 전송 → 말풍선 + 로그
await page.keyboard.press('Enter');
await page.waitForTimeout(900);
await page.screenshot({ path: `${OUT}/4-전송후(말풍선).png` });

// 이모지 이모티콘도 캡쳐(폰트 폴백이 없으면 두부로 보인다).
// DOM 입력이 닫히면 포커스가 body로 가므로 캔버스를 눌러 포커스를 되돌린다.
await page.locator('canvas').click({ position: { x: 300, y: 300 } });
await page.waitForTimeout(400);
await page.keyboard.press('Digit1');
await page.waitForTimeout(900);
await page.screenshot({ path: `${OUT}/4b-이모지.png` });

// Esc 취소 동작도 캡쳐
await page.keyboard.press('KeyT');
await page.waitForTimeout(400);
await page.keyboard.type('cancel me', { delay: 40 });
await page.waitForTimeout(300);
await page.screenshot({ path: `${OUT}/5-Esc직전.png` });
await page.keyboard.press('Escape');
await page.waitForTimeout(500);
await page.screenshot({ path: `${OUT}/6-Esc취소후.png` });

bot.close();
await browser.close();
server.kill();
console.log('캡쳐 완료:', OUT);
