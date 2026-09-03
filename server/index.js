import { createServer } from 'http';
import { createReadStream, statSync, existsSync } from 'fs';
import { extname, join, normalize, resolve } from 'path';
import { fileURLToPath } from 'url';
import { dirname } from 'path';

// Godot 웹 export 결과물(build/web/)을 정적 서빙하는 의존성 0개 서버.
//
// npm 의존성을 두지 않은 이유: 배포 서버(self-hosted 러너)에서 `npm install`
// 실패가 배포 실패의 흔한 원인이고, 이 서버가 하는 일은 정적 파일 + 헤더
// 뿐이라 express가 필요 없다. 나중에 멀티플레이(소켓)가 붙는 시점에
// connect_dise처럼 express+socket.io로 승격한다.
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

const server = createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  // 배포 검증용 헬스체크 — deploy 스크립트가 이 엔드포인트로 "정말 떴는지"를
  // 확인한다(connect_dise deploy.bat의 재시도 루프와 동일한 역할).
  if (url.pathname === '/healthz') {
    const built = existsSync(join(ROOT, 'index.html'));
    send(res, built ? 200 : 503, JSON.stringify({
      ok: built,
      build: built ? 'present' : 'missing',
      root: ROOT,
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
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Embedder-Policy': 'require-corp',
    'Cross-Origin-Resource-Policy': 'same-origin',
  };
  // 엔진/에셋 파일은 파일명이 바뀌지 않으므로 짧은 캐시만 걸고, index.html은
  // 항상 재검증하게 둬야 배포 직후 구버전이 남지 않는다.
  headers['Cache-Control'] = target.endsWith('index.html')
    ? 'no-cache'
    : 'public, max-age=300';

  res.writeHead(200, headers);
  createReadStream(target).pipe(res);
});

server.listen(PORT, HOST, () => {
  console.log(`[animals_farm] 정적 서버 기동: http://${HOST}:${PORT}  (root=${ROOT})`);
});
