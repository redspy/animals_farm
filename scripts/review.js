import { execFileSync } from 'child_process';
import { runClaude, runCodex, HeadlessCLIError } from './cli-runner.js';

// 헤드리스 리뷰 게이트의 단일 진입점.
//
// 예전에는 리뷰 프롬프트와 `claude` 호출이 package.json / pre-commit /
// AGENTS.md 세 곳에 각각 복사돼 있었고, 그 사본들에는 `--session-id`가 빠져
// 있어 docs/agents/roles.md §0의 "검증용 Claude는 이 세션과 분리된 별도
// 세션으로 기동한다"는 규칙이 실제로는 지켜지지 않았다(2026-09-03 첫 커밋의
// pre-commit Codex 감사 지적). 프롬프트도 사본마다 조금씩 달라져 문서가
// 주장하는 리뷰 범위와 실제 실행 범위가 어긋났다.
//
// 그래서 프롬프트와 호출을 이 파일 하나로 모은다. cli-runner.js의 runClaude가
// 매번 새 --session-id를 붙이므로 자기검증 편향도 구조적으로 막힌다.
//
// 사용법:
//   node scripts/review.js --staged   # 스테이징된 변경 리뷰 (pre-commit)
//   node scripts/review.js --last     # 직전 커밋 리뷰 (npm run review:code)
//   node scripts/review.js --docs     # Codex 문서 정합성 감사

export const CODE_REVIEW_PROMPT =
  '게임 로직 정확성, 상태 동기화/세이브 데이터 정합성, 밸런스 데이터 유효범위, ' +
  '성능(프레임/GC/할당), 시크릿 하드코딩 여부 리뷰';

export const DOC_SYNC_PROMPT =
  '설계 문서(AGENTS.md, docs/design.md, docs/deploy.md)와 소스 코드 간 정합성 감사';

// diff가 커서 리뷰 시간만 늘어나는 자동생성 파일은 제외한다.
const DIFF_EXCLUDES = [
  '--', '.',
  ':(exclude)*.lock',
  ':(exclude)package-lock.json',
  ':(exclude)*.min.js',
  ':(exclude)build/**',
  ':(exclude).godot/**',
];

// 인증/쿼터/프로바이더 일시 장애는 fail-open(AGENTS.md §4) — CLI 문제 하나로
// 개발 전체가 멈추지 않게 한다. 그 외 실패는 fail-closed로 커밋을 막는다.
const SKIP_PATTERN = /Not logged in|Please run \/login|Authentication|session limit|usage limit|rate limit|limit reached|quota|API Error: 5\d\d|Internal server error|Overloaded/i;

// 타임아웃도 fail-open으로 처리한다 — 리뷰가 안 끝난 것은 결함을 찾은 것이
// 아니고, 이걸로 커밋을 막으면 큰 커밋일수록 게이트를 우회(--no-verify)하게
// 만들어 오히려 검증이 줄어든다. 대신 "리뷰가 완료되지 않았다"를 크게 알려
// 사람이 직접 확인하게 한다.
const TIMEOUT_PATTERN = /타임아웃/;

// 프롬프트에 diff를 그대로 실어 보내므로 상한을 둔다. 잘렸으면 반드시 알린다
// (조용한 truncation은 "전부 봤다"는 오해를 만든다).
const MAX_DIFF_CHARS = 180_000;

// 큰 diff는 리뷰에 몇 분이 걸린다 — cli-runner 기본 180초로는 실제로
// 타임아웃이 났다(2026-09-03 Godot 스캐폴드 커밋에서 실측). 넉넉히 잡는다.
const REVIEW_TIMEOUT_MS = 600_000;

function git(args) {
  return execFileSync('git', args, { encoding: 'utf-8', maxBuffer: 64 * 1024 * 1024 });
}

function stagedDiff() {
  return git(['diff', '--cached', ...DIFF_EXCLUDES]);
}

function lastCommitDiff() {
  let base;
  try {
    git(['rev-parse', '--verify', 'HEAD~1']);
    base = 'HEAD~1';
  } catch {
    base = git(['hash-object', '-t', 'tree', '/dev/null']).trim(); // 최초 커밋
  }
  return git(['diff', base, ...DIFF_EXCLUDES]);
}

function report(label, ok, body) {
  console.log('==========================================================');
  console.log(`${ok ? '🔍' : '⚠️'} [review] ${label}`);
  console.log('==========================================================');
  console.log(body);
}

async function reviewCode(diff, label) {
  if (!diff.trim()) {
    console.log(`ℹ️ [review] ${label}: 변경 없음 — 리뷰 건너뜀.`);
    return 0;
  }
  let payload = diff;
  let note = '';
  if (payload.length > MAX_DIFF_CHARS) {
    note = `\n\n⚠️ diff가 ${diff.length}자여서 앞 ${MAX_DIFF_CHARS}자만 리뷰에 포함됨(뒷부분 미검토).`;
    payload = payload.slice(0, MAX_DIFF_CHARS);
  }
  try {
    const out = await runClaude(
      `${CODE_REVIEW_PROMPT}\n\n다음 diff를 리뷰해줘:\n\n${payload}`,
      { timeout: REVIEW_TIMEOUT_MS },
    );
    report(`${label} — Claude 코드 리뷰`, true, out + note);
    return 0;
  } catch (e) {
    if (e instanceof HeadlessCLIError && SKIP_PATTERN.test(e.message)) {
      report(`${label} — Claude 미인증/쿼터/일시장애로 건너뜀(fail-open)`, false, e.message);
      return 0;
    }
    if (e instanceof HeadlessCLIError && TIMEOUT_PATTERN.test(e.message)) {
      report(
        `${label} — Claude 리뷰 타임아웃(fail-open)`,
        false,
        `${e.message}\n\n⚠️ 이 커밋의 코드 리뷰는 완료되지 않았습니다. 커밋은 진행되지만 변경분을 직접 확인하세요.`,
      );
      return 0;
    }
    report(`${label} — Claude 리뷰 실패(커밋 중단)`, false, e.message);
    return 1;
  }
}

async function reviewDocs() {
  try {
    const out = await runCodex(DOC_SYNC_PROMPT, { timeout: REVIEW_TIMEOUT_MS });
    report('Codex 문서 정합성 감사', true, out);
    return 0;
  } catch (e) {
    if (e instanceof HeadlessCLIError && (SKIP_PATTERN.test(e.message) || TIMEOUT_PATTERN.test(e.message))) {
      report('Codex 미인증/쿼터/일시장애/타임아웃으로 건너뜀(fail-open)', false, e.message);
      return 0;
    }
    report('Codex 문서 정합성 감사 실패(커밋 중단)', false, e.message);
    return 1;
  }
}

const mode = process.argv[2];
let code = 0;
if (mode === '--staged') code = await reviewCode(stagedDiff(), '스테이징된 변경');
else if (mode === '--last') code = await reviewCode(lastCommitDiff(), '직전 커밋');
else if (mode === '--docs') code = await reviewDocs();
else {
  console.error('사용법: node scripts/review.js --staged | --last | --docs');
  code = 1;
}
process.exit(code);
