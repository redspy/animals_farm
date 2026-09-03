import { execFile } from 'child_process';
import { randomUUID } from 'crypto';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

// Claude / Codex / Gemini(Antigravity `agy`) 헤드리스 CLI 공통 실행 유틸.
// docs/agents/roles.md §0 원칙: "정답이 있는 검증 작업"은 가상 페르소나 1인이
// 아니라 실제 3개 독립 프로세스로 교차검증한다. 이 세션(Claude Code)과
// 컨텍스트가 섞이면 자기검증 편향이 생기므로 항상 새 서브프로세스로 실행하고,
// Claude 호출은 매번 새 --session-id를 붙인다.
//
// 사용 예:
//   import { runClaude, runCodex, runGemini, runPanel } from './cli-runner.js';
//   const reports = await runPanel('이 세이브 데이터 마이그레이션 로직의 결함을 찾아줘');

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');

function loadEnv() {
  const envPath = path.join(rootDir, '.env');
  if (!fs.existsSync(envPath)) return;
  for (const line of fs.readFileSync(envPath, 'utf-8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    if (!(key in process.env)) process.env[key] = trimmed.slice(eq + 1).trim();
  }
}
loadEnv();

// CLI 경로 해석 순서: 환경변수 → 이 머신의 알려진 절대경로 → PATH의 bare 이름.
// bare 이름 폴백이 필요한 이유: CI 러너(ubuntu)에는 로컬 절대경로가 존재하지
// 않고 전역 설치된 실행 파일만 PATH에 있다. 반대로 Claude Code 훅처럼 로그인
// 셸을 거치지 않는 환경에서는 PATH가 비어 절대경로가 필요하다.
function resolveCli(envVar, knownPath, bareName) {
  const fromEnv = process.env[envVar];
  if (fromEnv) return fromEnv;
  if (fs.existsSync(knownPath)) return knownPath;
  return bareName;
}

export const CLI_PATHS = {
  claude: resolveCli('CLAUDE_CLI_PATH', '/Users/soul/.local/bin/claude', 'claude'),
  codex: resolveCli('CODEX_CLI_PATH', '/usr/local/bin/codex', 'codex'),
  gemini: resolveCli('GEMINI_CLI_PATH', '/Users/soul/.local/bin/agy', 'agy'),
};

export class HeadlessCLIError extends Error {}

function run(cmd, args, { timeout = 120_000, stdinText = null } = {}) {
  return new Promise((resolve, reject) => {
    const child = execFile(cmd, args, { timeout, maxBuffer: 32 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) {
        const reason = err.killed ? `타임아웃(${timeout}ms)` : `exit=${err.code}`;
        reject(new HeadlessCLIError(`헤드리스 CLI 실패(${reason}): ${cmd}\nstderr: ${String(stderr).slice(0, 2000)}`));
        return;
      }
      resolve(String(stdout).trim());
    });
    // codex는 stdin을 명시적으로 닫지 않으면 "Reading additional input from
    // stdin..."에서 무한 대기한다(trading/connect_dise에서 실측).
    if (child.stdin) child.stdin.end(stdinText ?? '');
  });
}

export function runClaude(prompt, { model, timeout = 180_000, allowedTools = 'Read' } = {}) {
  const args = ['-p', prompt, '--session-id', randomUUID(), '--allowedTools', allowedTools];
  if (model) args.push('--model', model);
  return run(CLI_PATHS.claude, args, { timeout });
}

export function runCodex(prompt, { timeout = 240_000 } = {}) {
  return run(CLI_PATHS.codex, ['exec', prompt], { timeout, stdinText: '' });
}

export function runGemini(prompt, { model = 'gemini-3.1-pro-high', timeout = 180_000 } = {}) {
  return run(CLI_PATHS.gemini, ['-p', prompt, '--model', model], { timeout });
}

// 3종 CLI를 병렬로 기동해 각자의 리포트를 모은다. 한 CLI가 인증/쿼터로
// 실패해도 나머지 결과는 살린다(fail-open — AGENTS.md §4와 동일 정책).
export async function runPanel(prompt, options = {}) {
  const jobs = [
    ['claude', () => runClaude(prompt, options.claude)],
    ['codex', () => runCodex(prompt, options.codex)],
    ['gemini', () => runGemini(prompt, options.gemini)],
  ];
  const settled = await Promise.all(jobs.map(async ([name, fn]) => {
    try {
      return { cli: name, ok: true, output: await fn() };
    } catch (e) {
      return { cli: name, ok: false, error: e.message };
    }
  }));
  return settled;
}

// CLI로 직접 실행: node scripts/cli-runner.js "프롬프트"
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const prompt = process.argv[2];
  if (!prompt) {
    console.error('사용법: node scripts/cli-runner.js "3종 CLI에 보낼 프롬프트"');
    process.exit(1);
  }
  const results = await runPanel(prompt);
  for (const r of results) {
    console.log(`\n===== ${r.cli} =====`);
    console.log(r.ok ? r.output : `⚠️ 실패: ${r.error}`);
  }
  // 교차검증의 의미는 "서로 독립된 관점 2개 이상"에서 나온다. 전부(또는 2개
  // 이상) 실패했는데 exit 0으로 끝나면 호출한 쪽이 "3종 교차검증을 했다"고
  // 오인한다 — 실제로 3종 모두 권한 문제로 실패했는데 성공으로 보였다
  // (2026-09-03 Codex 감사 지적). quorum(2종) 미달이면 실패로 종료한다.
  const ok = results.filter((r) => r.ok).length;
  console.log(`\n===== 요약 =====\n성공 ${ok}/3`);
  if (ok < 2) {
    console.error(`❌ 교차검증 quorum 미달(성공 ${ok}/3) — 최소 2종의 독립 리포트가 필요합니다.`);
    process.exit(1);
  }
}
