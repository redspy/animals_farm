import { createServer as createHttpServer } from 'http';
import { createServer as createHttpsServer } from 'https';
import { WebSocketServer } from 'ws';
import { WorldState } from './world.js';
import { createReadStream, statSync, existsSync, readFileSync } from 'fs';
import { gzipSync, brotliCompressSync, constants as zlibConstants } from 'zlib';
import { extname, join, normalize, resolve } from 'path';
import { fileURLToPath } from 'url';
import { dirname } from 'path';

// Godot 웹 export 결과물(build/web/)을 정적 서빙하고, 같은 포트에서 /ws
// WebSocket으로 실시간 멀티플레이를 중계하는 서버.
//
// 의존성은 `ws` 하나뿐이다: Node에는 WebSocket 서버 구현이 없고 RFC6455를
// 직접 쓸 이유는 없다. express/socket.io까지 갈 이유도 아직 없다 — 정적 파일
// + 헤더 + JSON 메시지 중계가 전부다(docs/protocol.md §0).
//
// 상태와 규칙은 server/world.js가 갖는다. 여기서는 전송만 다룬다.
//
// 두 가지 헤더가 핵심이다(docs/deploy.md §3):
//  1) COOP/COEP — Godot 웹 export가 스레드를 쓰는 빌드일 때 SharedArrayBuffer가
//     필요해 이 헤더 없이는 아예 실행되지 않는다. 현재 export 프리셋은
//     nothreads라 없어도 되지만, 스레드 빌드로 전환할 때 서버를 다시 건드리지
//     않도록 미리 넣어둔다. 대신 이 헤더가 켜지면 외부 iframe/이미지 로드가
//     막히므로, 외부 리소스를 쓰게 되면 그때 재검토해야 한다.
//  2) .wasm/.pck의 MIME — application/wasm이 아니면 브라우저가 스트리밍
//     컴파일을 거부하고 로딩이 느려지거나 실패한다.

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(join(__dirname, '..', 'build', 'web'));
const PORT = Number(process.env.PORT || 3001);
const HOST = process.env.HOST || '0.0.0.0';

// Godot 웹 빌드는 **보안 컨텍스트가 아니면 실행 자체를 거부**한다
// ("Secure Context - Check web server configuration (use HTTPS)"). localhost는
// 브라우저가 보안 컨텍스트로 취급하지만, 같은 와이파이의 폰에서 http://192.168.x.x로
// 붙으면 아니다 — 그래서 개발 중에도 HTTPS가 필요하다(2026-09-04 실기 확인).
//
// 인증서가 있으면 https로, 없으면 http로 뜬다. 개발용 인증서는
// ./scripts/make-dev-cert.sh 로 만든다.
const TLS_CERT = process.env.TLS_CERT || join(__dirname, 'certs', 'dev-cert.pem');
const TLS_KEY = process.env.TLS_KEY || join(__dirname, 'certs', 'dev-key.pem');
// TLS=off 로 강제로 http 기동(비보안 컨텍스트 동작을 검증할 때 쓴다).
const useTls = process.env.TLS !== 'off' && existsSync(TLS_CERT) && existsSync(TLS_KEY);

// gzip으로 보낼 확장자. wasm이 39MB, pck가 4MB라 무압축으로 보내면 폰에서
// 최초 로딩이 수십 초로 늘어난다(2026-09-04 사용자 보고). wasm/js는 gzip이
// 특히 잘 먹는다(실측 4배 이상).
const COMPRESSIBLE = new Set(['.wasm', '.js', '.html', '.json', '.pck', '.svg', '.txt']);
/** 압축 결과 캐시: 경로+인코딩 → { mtimeMs, buffer }. 매 요청마다 39MB를 다시
 *  압축하면 첫 접속자마다 CPU를 태운다. 파일이 바뀌면(mtime) 자동 무효화된다. */
const compressCache = new Map();

function compressed(path, encoding) {
  const stat = statSync(path);
  const key = `${encoding}:${path}`;
  const hit = compressCache.get(key);
  if (hit && hit.mtimeMs === stat.mtimeMs) return hit.buffer;
  const raw = readFileSync(path);
  // brotli가 gzip보다 20~30% 더 작다(엔진 wasm에서 특히 차이가 크다). 대신
  // 압축이 느려서 처음 한 번만 하고 캐시한다.
  const buffer = encoding === 'br'
    ? brotliCompressSync(raw, { params: { [zlibConstants.BROTLI_PARAM_QUALITY]: 5 } })
    : gzipSync(raw, { level: 6 });
  compressCache.set(key, { mtimeMs: stat.mtimeMs, buffer });
  return buffer;
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.pck': 'application/octet-stream',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.json': 'application/json; charset=utf-8',
  '.ogg': 'audio/ogg',
  '.wav': 'audio/wav',
  '.woff2': 'font/woff2',
};

function send(res, status, body, headers = {}) {
  res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8', ...headers });
  res.end(body);
}

const handler = (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  // 배포 검증용 헬스체크 — deploy 스크립트가 이 엔드포인트로 "정말 떴는지"를
  // 확인한다(connect_dise deploy.bat의 재시도 루프와 동일한 역할).
  if (url.pathname === '/healthz') {
    const built = existsSync(join(ROOT, 'index.html'));
    send(res, built ? 200 : 503, JSON.stringify({
      ok: built,
      build: built ? 'present' : 'missing',
      root: ROOT,
      online: onlineCount(),
      world_items: world.items.size,
    }), { 'Content-Type': 'application/json; charset=utf-8' });
    return;
  }

  // 경로 탈출(../) 차단 — 정규화 후에도 ROOT 밖을 가리키면 거부한다.
  const rel = normalize(decodeURIComponent(url.pathname)).replace(/^([/\\])+/, '');
  const filePath = resolve(join(ROOT, rel === '' ? 'index.html' : rel));
  if (!filePath.startsWith(ROOT)) {
    send(res, 403, 'Forbidden');
    return;
  }

  let target = filePath;
  if (!existsSync(target)) {
    send(res, 404, 'Not Found');
    return;
  }
  if (statSync(target).isDirectory()) {
    target = join(target, 'index.html');
    if (!existsSync(target)) {
      send(res, 404, 'Not Found');
      return;
    }
  }

  const headers = {
    'Content-Type': MIME[extname(target).toLowerCase()] || 'application/octet-stream',
  };
  // COOP/COEP는 **보안 컨텍스트에서만 의미가 있다.** http로 서빙할 때 보내면
  // 브라우저가 "untrustworthy origin이라 무시했다"는 오류를 콘솔에 찍는다 —
  // 실제 동작에는 영향이 없지만, 진짜 오류를 가려 디버깅을 방해한다.
  if (useTls) {
    headers['Cross-Origin-Opener-Policy'] = 'same-origin';
    headers['Cross-Origin-Embedder-Policy'] = 'require-corp';
    headers['Cross-Origin-Resource-Policy'] = 'same-origin';
  }
  // 엔진/에셋 파일은 파일명이 바뀌지 않으므로 짧은 캐시만 걸고, index.html은
  // 항상 재검증하게 둬야 배포 직후 구버전이 남지 않는다.
  headers['Cache-Control'] = target.endsWith('index.html')
    ? 'no-cache'
    : 'public, max-age=300';

  const ext = extname(target).toLowerCase();
  const accept = String(req.headers['accept-encoding'] || '');
  const encoding = /\bbr\b/.test(accept) ? 'br' : (/\bgzip\b/.test(accept) ? 'gzip' : null);
  if (encoding && COMPRESSIBLE.has(ext)) {
    try {
      const body = compressed(target, encoding);
      res.writeHead(200, { ...headers, 'Content-Encoding': encoding, 'Content-Length': body.length, Vary: 'Accept-Encoding' });
      res.end(body);
      return;
    } catch (e) {
      // 압축에 실패하면 원본을 보낸다 — 로딩이 느려질 뿐 동작은 유지된다.
      console.error('[server] 압축 실패, 원본 전송:', target, e.message);
    }
  }
  res.writeHead(200, headers);
  createReadStream(target).pipe(res);
};

const server = useTls
  ? createHttpsServer({ cert: readFileSync(TLS_CERT), key: readFileSync(TLS_KEY) }, handler)
  : createHttpServer(handler);

// ---------------------------------------------------------------------------
// WebSocket 중계 (docs/protocol.md)
// ---------------------------------------------------------------------------

const world = new WorldState();
const wss = new WebSocketServer({ server, path: '/ws' });

/** token -> socket. 같은 토큰으로 다시 들어오면 이전 연결을 끊는다. */
const sockets = new Map();

function onlineCount() {
  return sockets.size;
}

function sendTo(ws, msg) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
}

function broadcast(msg, exceptToken = null) {
  const payload = JSON.stringify(msg);
  for (const [token, ws] of sockets) {
    if (token === exceptToken) continue;
    if (ws.readyState === ws.OPEN) ws.send(payload);
  }
}

wss.on('connection', (ws) => {
  ws.token = null;
  ws.alive = true;
  ws.on('pong', () => { ws.alive = true; });

  ws.on('message', (raw) => {
    // 메시지 크기 상한 — 거대한 JSON으로 서버 파서를 태우는 것을 막는다.
    if (raw.length > 8192) {
      sendTo(ws, { t: 'error', code: 'too_large', message: '메시지가 너무 큽니다' });
      return;
    }
    let msg;
    try {
      msg = JSON.parse(raw.toString('utf-8'));
    } catch {
      sendTo(ws, { t: 'error', code: 'bad_json', message: 'JSON 파싱 실패' });
      return;
    }
    handle(ws, msg);
  });

  ws.on('close', () => {
    if (!ws.token) return;
    if (sockets.get(ws.token) === ws) sockets.delete(ws.token);
    const leaving = world.players.get(ws.token);
    world.leave(ws.token);
    broadcast({ t: 'leave', token: ws.token });
    if (leaving) {
      broadcast({ t: 'system', text: `${leaving.name} 님이 나갔습니다`, kind: 'leave', token: ws.token });
    }
  });

  ws.on('error', (e) => console.error('[ws] 소켓 오류:', e.message));
});

function handle(ws, msg) {
  const type = String(msg.t || '');

  if (type === 'join') {
    const result = world.join({ token: msg.token, name: msg.name, preset: msg.preset });
    if (result.error) {
      sendTo(ws, { t: 'error', ...result.error });
      return;
    }
    const p = result.player;
    // 같은 토큰의 기존 연결은 끊는다 — 두 기기가 한 캐릭터를 동시에 움직이면
    // 위치가 튀고 어느 쪽이 진짜인지 정할 수 없다.
    const prev = sockets.get(p.token);
    if (prev && prev !== ws) {
      sendTo(prev, { t: 'error', code: 'replaced', message: '다른 기기에서 이 캐릭터로 접속했습니다' });
      prev.close();
    }
    ws.token = p.token;
    sockets.set(p.token, ws);

    sendTo(ws, {
      t: 'welcome',
      you: {
        token: p.token, name: p.name, preset: p.preset,
        x: p.x, z: p.z, dir: p.dir,
        inventory: p.inventory, bells: p.bells,
      },
      world: { size_x: world.sizeX, size_z: world.sizeZ },
    });
    sendTo(ws, { t: 'snapshot', ...world.snapshot() });
    broadcast({ t: 'join', player: { token: p.token, name: p.name, preset: p.preset, x: p.x, z: p.z, dir: p.dir } }, p.token);
    // 입퇴장은 **서버가 알린다.** 예전에는 각 클라이언트가 join/leave를 보고
    // 자기 화면에만 문구를 넣어서, 알림 문구가 클라이언트마다 갈릴 수 있었다.
    // 본인에게는 보내지 않는다 — 자기 입장 알림은 "서버에 접속했습니다"와 겹친다.
    broadcast({ t: 'system', text: `${p.name} 님이 들어왔습니다`, kind: 'join', token: p.token }, p.token);
    return;
  }

  if (!ws.token) {
    sendTo(ws, { t: 'error', code: 'not_joined', message: '먼저 join이 필요합니다' });
    return;
  }

  switch (type) {
    case 'move': {
      const r = world.move(ws.token, msg);
      if (r.error) sendTo(ws, { t: 'error', ...r.error });
      // 성공한 이동은 개별 브로드캐스트하지 않고 tick에서 묶어 보낸다.
      break;
    }
    case 'chat': {
      const r = world.chat(ws.token, msg.text);
      if (r.error) { sendTo(ws, { t: 'error', ...r.error }); break; }
      broadcast({ t: 'chat', ...r.chat });
      break;
    }
    case 'emote': {
      const r = world.emote(ws.token, msg.emote);
      if (r.error) { sendTo(ws, { t: 'error', ...r.error }); break; }
      broadcast({ t: 'emote', ...r.emote });
      break;
    }
    case 'gather': {
      // 아이템 종류는 클라이언트 주장이 아니라 데이터에서 읽는다 — index만 받는다.
      const r = world.gather(ws.token, msg.index);
      if (r.error) { sendTo(ws, { t: 'error', ...r.error }); break; }
      sendTo(ws, { t: 'inventory', inventory: r.inventory });
      // 캔 채집물은 모두에게 숨겨야 한다(누가 캤는지도 함께).
      broadcast({ t: 'gathered', ...r.gathered, by: ws.token });
      break;
    }
    case 'resync': {
      // 다른 창에 갔다 돌아오면 브라우저가 프레임을 멈춰 클라이언트 상태가
      // 굳는다(내 위치·남의 위치·월드 아이템·채집물 재생 시각 전부). 재연결
      // 없이 **현재 진실을 다시 받아** 맞추는 경로다.
      const me = world.players.get(ws.token);
      if (!me) { sendTo(ws, { t: 'error', code: 'not_joined', message: '먼저 join이 필요합니다' }); break; }
      sendTo(ws, {
        t: 'welcome',
        you: {
          token: me.token, name: me.name, preset: me.preset,
          x: me.x, z: me.z, dir: me.dir,
          inventory: me.inventory, bells: me.bells,
        },
        world: { size_x: world.sizeX, size_z: world.sizeZ },
        resync: true,
      });
      sendTo(ws, { t: 'snapshot', ...world.snapshot() });
      break;
    }
    case 'sell': {
      const r = world.sell(ws.token, msg.item ?? null);
      if (r.error) { sendTo(ws, { t: 'error', ...r.error }); break; }
      sendTo(ws, { t: 'sold', sold: r.sold, total: r.total, bells: r.bells, inventory: r.inventory, unsold: r.unsold });
      break;
    }
    case 'drop': {
      const r = world.drop(ws.token, msg.item, msg.x, msg.z);
      if (r.error) { sendTo(ws, { t: 'error', ...r.error }); break; }
      sendTo(ws, { t: 'inventory', inventory: r.inventory });
      broadcast({ t: 'item_add', item: r.item });
      break;
    }
    case 'pickup': {
      const r = world.pickup(ws.token, msg.id);
      if (r.error) { sendTo(ws, { t: 'error', ...r.error }); break; }
      sendTo(ws, { t: 'inventory', inventory: r.inventory });
      broadcast({ t: 'item_remove', id: r.item.id, by: ws.token });
      break;
    }
    case 'rename': {
      const r = world.join({ token: ws.token, name: msg.name, preset: msg.preset });
      if (r.error) { sendTo(ws, { t: 'error', ...r.error }); break; }
      broadcast({ t: 'rename', token: ws.token, name: r.player.name });
      break;
    }
    default:
      sendTo(ws, { t: 'error', code: 'unknown_type', message: `알 수 없는 메시지: ${type}` });
  }
}

// 이동은 10Hz로 묶어 브로드캐스트한다 — 개별 전송하면 N명이 동시에 움직일 때
// 메시지 수가 N²로 늘어난다.
const TICK_MS = 100;
setInterval(() => {
  const moves = world.takeMoves();
  if (moves.length > 0) broadcast({ t: 'move', moves });
}, TICK_MS);

// 죽은 연결 정리 — 브라우저 탭이 그냥 사라지면 close 이벤트가 안 올 수 있다.
setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.alive) { ws.terminate(); continue; }
    ws.alive = false;
    try { ws.ping(); } catch { /* 이미 닫힘 */ }
  }
}, 30000);

// 주기 저장(디바운스와 별개로 30초마다) + 종료 시 저장
setInterval(() => world.save(), 30000);
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    world.save();
    process.exit(0);
  });
}

server.listen(PORT, HOST, () => {
  const scheme = useTls ? 'https' : 'http';
  const wsScheme = useTls ? 'wss' : 'ws';
  console.log(`[animals_farm] 서버 기동: ${scheme}://${HOST}:${PORT}  (root=${ROOT})`);
  console.log(`[animals_farm] WebSocket: ${wsScheme}://${HOST}:${PORT}/ws  월드 ${world.sizeX} x ${world.sizeZ}`);
  if (!useTls) {
    // 조용히 http로 뜨면 "폰에서 왜 안 되지"로 시간을 버린다 — 기동 시점에 알린다.
    console.log('[animals_farm] ⚠️  TLS 인증서가 없어 http로 기동했습니다.');
    console.log('[animals_farm]    localhost에서는 동작하지만 **폰/다른 기기에서는 Godot이 실행을 거부**합니다');
    console.log('[animals_farm]    (Secure Context 요구). ./scripts/make-dev-cert.sh 로 인증서를 만드세요.');
  }
});
