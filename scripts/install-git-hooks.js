import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

// `npm install` postinstall로 실행되어 scripts/git-hooks/* 를 .git/hooks/ 로
// 설치한다. .git/hooks/ 는 git 추적 대상이 아니라서 clone 직후에는 훅이
// 비어있는데, 이 스크립트가 그 간극을 메운다.

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');
const srcDir = path.join(rootDir, 'scripts', 'git-hooks');
const destDir = path.join(rootDir, '.git', 'hooks');

if (!fs.existsSync(path.join(rootDir, '.git'))) {
  console.log('[install-git-hooks] .git 디렉터리가 없음 — git 저장소가 아닌 환경(예: CI 아티팩트)으로 판단, 건너뜀.');
  process.exit(0);
}

for (const file of fs.readdirSync(srcDir)) {
  const src = path.join(srcDir, file);
  const dest = path.join(destDir, file);
  fs.copyFileSync(src, dest);
  fs.chmodSync(dest, 0o755);
  console.log(`[install-git-hooks] 설치됨: .git/hooks/${file}`);
}
