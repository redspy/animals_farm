import { writeFileSync, existsSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

// Godot이 스캔하면 안 되는 폴더에 .gdignore를 심는다.
//
// 왜 필요한가: Godot은 프로젝트 폴더 전체를 리소스로 임포트한다. node_modules
// 안의 playwright 아이콘(SVG)과 폰트(codicon.ttf)까지 임포트되어 **웹 export의
// index.pck가 5MB → 28MB로 부풀었다**(2026-09-04 실측 — 폰에서 첫 로딩이 느린
// 원인 중 하나였다). build/ 안의 테스트 스크린샷도 같은 문제를 만든다.
//
// npm ci는 node_modules를 지우고 다시 만들기 때문에 .gdignore도 사라진다 —
// 그래서 postinstall에서 매번 다시 심는다.

const __dirname = dirname(fileURLToPath(import.meta.url));
const rootDir = join(__dirname, '..');
const targets = ['node_modules', 'build', 'server/certs'];

for (const rel of targets) {
  const dir = join(rootDir, rel);
  if (!existsSync(dir)) {
    if (rel === 'build') mkdirSync(dir, { recursive: true });
    else continue;
  }
  const marker = join(dir, '.gdignore');
  if (existsSync(marker)) continue;
  writeFileSync(marker, '');
  console.log(`[godot-ignore] 심음: ${rel}/.gdignore`);
}
