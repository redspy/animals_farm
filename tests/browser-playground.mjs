// 운동장 E2E — 실제 브라우저에서 운동 버튼·모습 변경·속도·공을 확인한다.
//
// 왜 브라우저인가: 운동 상태는 (a) 버튼 UI, (b) 스프라이트 교체, (c) 이동 속도,
// (d) 서버 브로드캐스트가 맞물려 동작한다. 서버 단위 테스트(tests/server-world)는
// 규칙만 보고, 헤드리스 Godot 검증은 파싱만 본다 — 실제로 눌러 봐야 아는 것들이
// 여기 모여 있다.
//
// 남의 화면에 어떻게 보이는지는 **WS 옵저버**로 판정한다(채팅·이모티콘 테스트와
// 같은 방식). 브라우저 두 개를 띄우는 것보다 빠르고, 판정 기준이 프로토콜이라
// 화면 렌더 타이밍에 흔들리지 않는다.
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import WebSocket from 'ws';
import { readFileSync } from 'node:fs';
import { tapGodot, godotPoint } from './godot-tap.mjs';

const PORT = Number(process.env.PORT || 3193);
// 트랙·축구장 위치는 **데이터에서 읽는다.** 좌표를 박아 두면 맵 크기를 바꿀
// 때마다 깨진다(섬을 1.5배로 키우자 트랙 중심이 -13 → -19.5로 옮겨졌다).
const PG = JSON.parse(readFileSync('data/world.json', 'utf-8')).playground;
const TRACK_X = Number(PG.track.x);
const FIELD_X = Number(PG.field.x);
const OUT = process.env.SHOT_DIR || 'build/screenshots/playground';
const results = [];
const check = (ok, label) => {
  results.push({ ok, label });
  console.log(`  ${ok ? 'ok ' : '❌ '} — ${label}`);
};

const statePath = join(mkdtempSync(join(tmpdir(), 'af-playground-')), 'world.json');
const srv = spawn('node', ['server/index.js'], {
  env: { ...process.env, PORT: String(PORT), TLS: 'off', HOST: '127.0.0.1', WORLD_STATE_PATH: statePath },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let srvLog = '';
srv.stdout.on('data', (d) => { srvLog += d.toString(); });
srv.stderr.on('data', (d) => { srvLog += d.toString(); });
const stop = () => { try { srv.kill(); } catch { /* 이미 종료 */ } };
process.on('exit', stop);

// 우리 프로세스가 스스로 떴다고 말할 때까지 기다린다(포트를 남이 잡고 있으면
// healthz만으로는 엉뚱한 서버에 붙는다 — server-reconnect 테스트와 같은 이유).
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

// --- 관찰자: 남의 화면에 무엇이 전달되는지 본다 ---
const OBSERVER = '99999999-9999-4999-8999-999999999999';
const observer = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
const seen = [];
observer.on('message', (raw) => seen.push(JSON.parse(raw.toString('utf-8'))));
await new Promise((r) => observer.on('open', r));
observer.send(JSON.stringify({ t: 'join', token: OBSERVER, name: 'Watcher', preset: 'f1' }));
const waitFor = (pred, ms = 5000) => new Promise((resolve) => {
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
  // 서버가 거절한 경우도 콘솔 경고로 나온다 — 조작 실패를 놓치지 않게 모은다.
  if (m.type() === 'error' || text.includes('서버 오류')) errors.push(text.slice(0, 200));
});
await page.goto(`http://127.0.0.1:${PORT}/`);
await page.waitForFunction(() => window.afTest?.points?.slot1, null, { timeout: 60000 });

// 캐릭터 만들기
await tapGodot(page, 'slot1');
await page.waitForTimeout(400);
await tapGodot(page, 'preset1');
// 이름 화면이 **실제로 자리를 잡을 때까지** 기다린다. 고정 대기로는 부족했다:
// 이름 입력은 캔버스 위에 겹친 DOM <input>이고(사파리 키보드 대응), 컨테이너
// 레이아웃이 계산된 뒤에야 그 자리에 놓인다. 그 전에 누르면 클릭이 캔버스로
// 새어 포커스가 걸리지 않고, 이름이 빈 채로 제출된다(2026-09-05 실측).
await page.waitForFunction(() => {
  const el = document.getElementById('af-name-input');
  if (!el || el.style.display === 'none') return false;
  const r = el.getBoundingClientRect();
  if (!(r.width > 200 && r.height > 10 && r.top > 5)) return false;
  // **자리가 안정됐는지**까지 본다. 컨테이너 레이아웃은 여러 프레임에 걸쳐
  // 값이 바뀌어서(실측: 폭 80 → 700) 중간값에 눌러 놓치는 일이 있었다.
  const key = `${Math.round(r.left)},${Math.round(r.top)},${Math.round(r.width)}`;
  const same = window.__afNameRect === key;
  window.__afNameRect = key;
  return same;
}, null, { timeout: 20000 });
await tapGodot(page, 'nameField');
await page.keyboard.type('Athlete', { delay: 40 });
// 글자가 실제로 들어갔는지 확인하고 제출한다.
await page.waitForFunction(
  () => (document.getElementById('af-name-input')?.value ?? '').length >= 7,
  null, { timeout: 10000 });
await tapGodot(page, 'startButton');
try {
  await page.waitForFunction(() => window.afTest?.points?.playerScreen, null, { timeout: 40000 });
} catch (e) {
  // 월드에 못 들어가면 그 뒤 판정이 전부 무의미하다 — 왜 막혔는지 남긴다.
  const diag = await page.evaluate(() => {
    const el = document.getElementById('af-name-input');
    const r = el ? el.getBoundingClientRect() : null;
    return {
      hooks: Object.keys(window.afTest?.points || {}),
      input: el ? { value: el.value, display: el.style.display,
                    rect: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)],
                    focused: document.activeElement === el } : null,
    };
  });
  console.error('월드 진입 실패 진단:', JSON.stringify(diag));
  console.error('브라우저 오류:', errors.slice(0, 5).join(' | '));
  await page.screenshot({ path: `${OUT}/0-진입실패.png` }).catch(() => {});
  throw e;
}
await page.waitForTimeout(1500);

const state = async () => await page.evaluate(() => ({
  x: Number(window.afTest?.state?.x ?? 0),
  z: Number(window.afTest?.state?.z ?? 0),
  act: String(window.afTest?.state?.activity ?? '?'),
  trick: String(window.afTest?.state?.trick ?? '?'),
}));
const buttons = async (prefix) => await page.evaluate((p) =>
  Object.keys(window.afTest?.points || {}).filter((k) => k.startsWith(p)).length, prefix);

/**
 * 조건이 맞을 때까지 상태를 다시 읽는다.
 *
 * 고정 시간(예: 900ms)을 기다리면 안 된다(실측): 게임 상태는 0.25초 주기
 * 블록에서 갱신되고 window.afTest는 0.4초 주기로 게시되므로, 최악의 경우
 * 0.65초까지 옛 값이 보인다. 그 창에 걸리면 "버튼을 눌렀는데 상태가 안 바뀜"
 * 처럼 보여 테스트가 무작위로 실패한다.
 */
const waitState = async (pred, ms = 4000) => {
  const t0 = Date.now();
  let last = await state();
  while (Date.now() - t0 < ms) {
    if (pred(last)) return last;
    await page.waitForTimeout(150);
    last = await state();
  }
  return last;
};
/**
 * 좌표가 더 이상 바뀌지 않을 때까지 기다린 뒤 위치를 돌려준다.
 * 이동 거리를 재기 전에 필요하다 — 게시 지연 때문에 홀드 직후 읽으면
 * 홀드 전 값이 그대로 나와 이동 거리가 0으로 측정된다(실측).
 */
const settled = async (ms = 4000) => {
  const t0 = Date.now();
  let a = await state();
  while (Date.now() - t0 < ms) {
    await page.waitForTimeout(450);
    const b = await state();
    if (Math.abs(b.x - a.x) < 0.01 && Math.abs(b.z - a.z) < 0.01) return b;
    a = b;
  }
  return a;
};

/** 버튼 개수도 UI 재구성 + 게시를 기다린다. */
const waitButtons = async (prefix, want, ms = 4000) => {
  const t0 = Date.now();
  let n = await buttons(prefix);
  while (Date.now() - t0 < ms && n !== want) {
    await page.waitForTimeout(150);
    n = await buttons(prefix);
  }
  return n;
};
const hold = async (key, ms) => {
  await page.keyboard.down(key);
  await page.waitForTimeout(ms);
  await page.keyboard.up(key);
  await page.waitForTimeout(250);
};

/**
 * 목표 좌표에 **도달할 때까지** 키를 나눠 누른다.
 *
 * 시간으로 거리를 가정하면 안 된다(실측): 소프트웨어 렌더(swiftshader)에서는
 * 프레임이 밀려 실제 이동이 명목 속도의 60% 정도이고, 줄넘기(1.4)처럼 느린
 * 운동에서는 그 오차가 몇 유닛씩 벌어진다. 좌표를 보고 멈추면 속도와
 * 프레임률에 상관없이 같은 자리에 선다.
 */
const walkTo = async (axis, target, { timeoutMs = 75000 } = {}) => {
  const t0 = Date.now();
  let last = null;
  let stuck = 0;
  while (Date.now() - t0 < timeoutMs) {
    const s = await state();
    const cur = axis === 'x' ? s.x : s.z;
    if (Math.abs(cur - target) < 1.2) return s;
    const key = axis === 'x'
      ? (cur < target ? 'ArrowRight' : 'ArrowLeft')
      : (cur < target ? 'ArrowDown' : 'ArrowUp');
    await hold(key, 450);
    const after = await state();
    const moved = Math.abs((axis === 'x' ? after.x : after.z) - cur);
    // 벽·바위에 막혀 제자리면 포기한다 — 무한 반복으로 테스트를 세우지 않는다.
    // 8회로 잡은 이유: 상태 게시가 늦어 같은 값을 두세 번 연속 읽는 일이
    // 흔하고, 그걸 "막혔다"로 보면 이동이 중간에 끊긴다(실측).
    // 시간 여유도 넉넉히 준다 — 소프트웨어 렌더에서는 한 번 누를 때 0.5유닛만
    // 움직이는 경우가 있어 짧은 제한 시간이 곧 실패가 된다.
    stuck = moved < 0.05 ? stuck + 1 : 0;
    if (stuck >= 8) break;
    last = after;
  }
  return last ?? await state();
};

// --- 1. 운동장 밖에서는 킥보드만 ---
console.log('\n[검증] 운동장 밖/안의 운동 버튼');
check((await buttons('exercise')) === 1,
  `운동장 밖에서는 운동 버튼이 1개(킥보드)만 보인다 (실제 ${await buttons('exercise')}개)`);

// 킥보드는 운동장 밖에서도 탈 수 있다(사용자 지정)
await tapGodot(page, 'exercise1');
const onBoard = await waitState((s) => s.act === 'kickboard');
check(onBoard.act === 'kickboard', `운동장 밖에서 킥보드를 탈 수 있다 (${onBoard.act})`);
const kickboardSeen = await waitFor((m) => m.t === 'activity' && m.activity === 'kickboard');
check(!!kickboardSeen, '킥보드 상태가 다른 기기에도 전달된다');
await tapGodot(page, 'exercise1');
const offBoard = await waitState((s) => s.act === '');
check(offBoard.act === '', `같은 버튼을 다시 누르면 원래대로 돌아온다 (${offBoard.act})`);

// --- 2. 트랙 진입 ---
await walkTo('x', TRACK_X, { timeoutMs: 120000 });
const atTrack = await state();
check(Math.abs(atTrack.x - TRACK_X) < 4.0, `트랙 안으로 이동했다 (x=${atTrack.x}, 트랙 ${TRACK_X})`);
const trackButtons = await waitButtons('exercise', 5);
check(trackButtons === 5, `운동장에서는 운동 버튼 5개가 보인다 (실제 ${trackButtons}개)`);
await page.screenshot({ path: `${OUT}/1-트랙.png` }).catch(() => {});

// --- 3. 자전거가 걷기보다 빠르다 ---
console.log('\n[검증] 운동별 이동 속도');
const before1 = await settled();
await hold('ArrowLeft', 1200);
const walked = Math.abs((await settled()).x - before1.x);
await hold('ArrowRight', 1200);
await settled();
await tapGodot(page, 'exercise3');          // 자전거
const onBike = await waitState((s) => s.act === 'bike');
check(onBike.act === 'bike', `자전거를 타면 상태가 bike다 (${onBike.act})`);
const before2 = await settled();
await hold('ArrowLeft', 1200);
const biked = Math.abs((await settled()).x - before2.x);
check(biked > walked * 1.3,
  `자전거가 걷기보다 빠르다 (걷기 ${walked.toFixed(2)} → 자전거 ${biked.toFixed(2)})`);
await page.screenshot({ path: `${OUT}/2-자전거.png` }).catch(() => {});
await tapGodot(page, 'exercise3');
await page.waitForTimeout(700);

// --- 4. 줄넘기 기술 ---
console.log('\n[검증] 줄넘기와 기술 버튼');
await tapGodot(page, 'exercise1');          // 운동장 안에서는 1번이 줄넘기
const onRope = await waitState((s) => s.act === 'jumprope');
check(onRope.act === 'jumprope', `줄넘기 상태가 된다 (${onRope.act})`);
const trickCount = await waitButtons('trick', 4);
check(trickCount === 4, `기술 버튼이 4개 나온다 (실제 ${trickCount}개)`);
await tapGodot(page, 'trick2');
const onDouble = await waitState((s) => s.trick === 'double');
check(onDouble.trick === 'double', `기술을 고르면 상태가 바뀐다 (${onDouble.trick})`);
const trickSeen = await waitFor((m) => m.t === 'activity' && m.trick === 'double');
check(!!trickSeen, '고른 기술이 다른 기기에도 전달된다');
await page.screenshot({ path: `${OUT}/3-줄넘기.png` }).catch(() => {});

// --- 5. 운동장을 벗어나면 자동으로 그만둔다 ---
console.log('\n[검증] 운동장 이탈');
// 줄넘기는 느리다(1.4) — 시간이 아니라 좌표로 벗어난다.
await walkTo('z', -12.0, { timeoutMs: 120000 });
const outside = await waitState((s) => s.act === '');
check(outside.act === '',
  `운동장을 벗어나면 줄넘기가 자동으로 끝난다 (z=${outside.z}, 상태 "${outside.act}")`);
check((await waitButtons('trick', 0)) === 0, '기술 버튼도 함께 사라진다');

// --- 6. 축구: 공이 나오고, 찬 것이 남에게 전달된다 ---
console.log('\n[검증] 축구 — 골대·공·차기');
await walkTo('z', 0.0, { timeoutMs: 60000 });
await walkTo('x', FIELD_X, { timeoutMs: 150000 });
const atField = await state();
check(Math.abs(atField.x - FIELD_X) < 4.0, `축구장 안으로 이동했다 (x=${atField.x}, 축구장 ${FIELD_X})`);
const fieldButtons = await waitButtons('exercise', 5);
check(fieldButtons === 5, `축구장에서도 운동 버튼 5개 (실제 ${fieldButtons}개)`);

seen.length = 0;
await tapGodot(page, 'exercise2');          // 축구
const onSoccer = await waitState((s) => s.act === 'soccer');
check(onSoccer.act === 'soccer', `축구 상태가 된다 (${onSoccer.act})`);
const ballMsg = await waitFor((m) => m.t === 'ball' && m.ball != null);
check(!!ballMsg, '축구를 시작하면 공이 나온다(다른 기기에도 전달)');
// 공 좌표는 0.4초 주기로 게시되고, 그 전에 서버의 ball 메시지가 도착해야 한다.
const ballVisible = await (async () => {
  const t0 = Date.now();
  while (Date.now() - t0 < 5000) {
    const ok = await page.evaluate(() => {
      const p = window.afTest?.points?.soccerBall;
      return Array.isArray(p) && p[0] >= 0;
    });
    if (ok) return true;
    await page.waitForTimeout(200);
  }
  return false;
})();
check(ballVisible, '내 화면에도 공이 그려진다');
await page.screenshot({ path: `${OUT}/4-축구장.png` }).catch(() => {});

// 공까지 걸어가서 찬다 → 공이 움직인 것이 관찰자에게 전달돼야 한다(= 패스)
const ballBefore = ballMsg.ball;
const bp = await godotPoint(page, 'soccerBall');
await page.mouse.click(bp.x, bp.y);
const moved = await waitFor(
  (m) => m.t === 'ball' && m.ball != null
    && (Math.abs(m.ball.x - ballBefore.x) > 0.5 || Math.abs(m.ball.z - ballBefore.z) > 0.5),
  9000);
check(!!moved, `찬 공이 실제로 움직이고 그 위치가 전달된다 (${ballBefore.x} → ${moved?.ball?.x ?? '변화 없음'})`);
await page.screenshot({ path: `${OUT}/5-공차기.png` }).catch(() => {});

// --- 7. 축구를 그만두면 공이 사라진다 ---
await tapGodot(page, 'exercise2');
await page.waitForTimeout(1200);
const ballGone = await waitFor((m) => m.t === 'ball' && m.ball == null, 4000);
check(!!ballGone, '아무도 축구를 하지 않으면 공을 치운다');

check(errors.length === 0, `브라우저 오류·서버 거절 0건 (실제 ${errors.length}건)`);
if (errors.length) console.log(errors.slice(0, 6).join('\n'));

await browser.close();
observer.close();
stop();

const failed = results.filter((r) => !r.ok);
console.log('');
if (failed.length) {
  console.error(`❌ 운동장 테스트 실패 ${failed.length}건`);
  process.exit(1);
}
console.log('✅ 운동장 테스트 통과 — 운동 버튼·모습·속도·줄넘기 기술·축구공이 동작');
