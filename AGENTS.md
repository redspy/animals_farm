# AGENTS.md — animals_farm (게임 프로젝트)

이 문서는 이 저장소에서 작업하는 모든 에이전트(메인, 서브, 가상 페르소나, 헤드리스 CLI)가 따라야 하는 개발 규칙을 정의한다. `trading` 프로젝트의 개발 프로세스를 이식했고, 도메인 특성만 게임에 맞게 조정했다.

## 프로젝트 개요

- **목표**: 게임 개발. 장르·기술스택·플랫폼은 **아직 미확정**이다(2026-09-03 기준). 이 저장소는 먼저 **개발 프로세스(모델별 페르소나 + 텔레그램 푸쉬 + 3종 CLI 교차검증)**만 이식한 상태다.
- **확정된 것**: 원격 저장소 `https://github.com/redspy/animals_farm.git`, 에이전트 역할 정의(`docs/agents/roles.md`), 텔레그램 알림 파이프라인(`scripts/telegram-*.js`), 헤드리스 CLI 러너(`scripts/cli-runner.js`).
- **미확정된 것**: 게임 장르/코어 루프, 엔진·언어, 디렉터리 구조, 빌드/실행 스크립트. 확정 전까지 `docs/design.md`는 "미확정" 상태를 정직하게 표시한다 — 빈 문서를 억지로 채우지 않는다.

## 알림 (텔레그램 푸쉬)

- `scripts/telegram-ask.js`가 단일 진입점이며 세 가지 모드로 동작한다.
  - `--notify "메시지"`: 응답 대기 없이 단방향 전송(작업 완료 알림 등). `npm run notify "메시지"`.
  - `"질문" "옵션1" "옵션2" [--timeout=분]`: 인라인 버튼으로 질문을 보내고 사용자가 누를 때까지 대기해 선택값을 stdout(JSON)으로 반환. `npm run ask -- "질문" "A" "B"`.
  - `--get-chat-id`: 봇 최초 설정 시 CHAT_ID 확인.
- Claude Code 훅 연결(`.claude/settings.local.json`):
  - **Stop 훅** → `scripts/telegram-stop-hook.js`: 응답 턴이 끝나면 transcript의 마지막 assistant 텍스트를 500자로 잘라 전송.
  - **Notification 훅** → `scripts/telegram-notification-hook.js`: 권한 승인 대기·`AskUserQuestion` 대기처럼 **턴 중간에 멈춰서 기다리는 시점**을 잡는다(Stop은 턴이 완전히 끝날 때만 발동해서 이 시점을 못 잡음 — connect_dise/trading에서 실측).
  - 두 훅 모두 실패해도 exit 0으로 종료해 Claude 진행을 막지 않는다.
- 봇 자격증명은 `.env`(git 추적 제외)의 `TELEGRAM_ASK_BOT_TOKEN` / `TELEGRAM_ASK_CHAT_ID`. **trading·connect_dise와 동일한 봇을 재사용**하고, 메시지 접두어 `[animals_farm]`으로 프로젝트를 구분한다.
- 마크다운 파싱 실패(미완성 `*`, `_`, `` ` `` 등이 섞인 요약 전송) 시 일반 텍스트로 자동 재시도한다 — 실측으로 발견된 실패 모드다.

## 에이전트 협업 및 역할 준수 규칙

- **역할 정의서 준수**: 모든 에이전트는 [docs/agents/roles.md](docs/agents/roles.md)의 역할과 가이드라인을 엄격히 준수한다.
- **§0 원칙**: 창의/기획은 가상 페르소나(8인), **정답이 있는 검증은 실제 CLI 3종 병렬 기동**. 가상 페르소나 판정을 검증의 최종 근거로 쓰지 않는다.
- **화면 검증**: UI/화면을 구현·수정하면 브라우저 서브에이전트로 실제 동작을 확인하고 스크린샷을 남긴다.

## 코드 리뷰 및 문서 싱크 준수 규칙

기능 개발이 끝나면 스테이징/커밋 전에 아래 로컬 CLI를 **헤드리스(비대화형)**로 구동해 소스 품질과 문서 정합성을 검증한다. 상세 역할은 `docs/agents/roles.md` §3 참조.

### 1. Claude CLI — 게임 로직/보안 리뷰
```bash
git diff | claude -p "게임 로직 정확성, 상태 동기화/세이브 데이터 정합성, 밸런스 데이터 유효범위, 성능(프레임/GC/할당), 시크릿 하드코딩 여부 리뷰" --allowedTools "Read"
```
- ⚠️ **게이트의 실제 동작**: pre-commit 훅은 CLI의 **종료 코드**만 보고 판단한다. 리뷰 텍스트가 "치명적"이라고 지적해도 프로세스가 정상 종료(exit 0)하면 커밋은 진행된다 — 즉 이 리뷰는 자동 차단 게이트가 아니라 **읽고 판단해야 하는 조언**이다.

### 2. Codex CLI — 문서 정합성 싱크 검사
```bash
codex exec "설계 문서(AGENTS.md, docs/design.md)와 소스 코드 간 정합성 감사" < /dev/null
```
- 백그라운드 실행 시 stdin을 `< /dev/null`로 리다이렉트할 것(무한 대기 방지, 실측).

### 3. Gemini(`agy`) CLI — 비주얼 패리티 리뷰
- 게임 화면 스크린샷을 `docs/design.md` 비주얼 가이드라인과 대조. 가이드라인이 채워진 시점부터 필수 게이트로 승격(`docs/agents/roles.md` §3).

### 4. 3대 개발 프로세스 라이프사이클

1. **로컬 커밋 예방 단계**: `.git/hooks/pre-commit`이 자동 트리거되어 헤드리스 진단(원본은 `scripts/git-hooks/pre-commit`, `npm install`/`npm run hooks:install`이 복사).
2. **릴리즈 문서 동기화**: `npm run review:write`로 변경 사안을 문서에 반영.
3. **3종 병렬 패널**: `npm run panel "프롬프트"`로 Claude/Codex/Gemini를 동시 기동해 리포트 비교.

**의도적인 fail-open 정책**: CLI가 미인증이거나 쿼터를 초과하거나 프로바이더 일시 장애(`API Error: 5xx`, `Overloaded`)로 죽으면 해당 리뷰를 건너뛰고 커밋을 허용한다(5xx 패턴은 2026-09-03 첫 커밋이 실제로 500에 막혀서 추가함). CLI 인증 문제 하나로 개발 전체가 멈추는 것을 피하기 위함이다. **리스크**: 미검증 코드가 커밋될 수 있다 — 세이브 데이터 스키마 변경처럼 되돌릴 수 없는 변경은 이 게이트 하나에 의존하지 말고 `docs/agents/roles.md` §4의 3단계 확인을 반드시 함께 거칠 것.

### 5. 원격 푸쉬 규칙
- 모든 구현·검증이 끝나면 `git add` → `git commit` → `git push`로 `origin`(redspy/animals_farm)에 동기화한다.
- 로컬 셸 프로필 환경변수가 필요하면 `zsh -l -c "명령"`으로 랩핑한다.

## 버그 분석 및 해결 프로세스

1. **버그 상세 정의 및 재현 계획**: 현상, 재현 조건(시드/입력 시퀀스 포함), 수정 전/후 검증 시나리오를 먼저 정리.
2. **실제 병렬 CLI 분석 기동**: 원인분석을 가상 페르소나로 대체하지 않고 `npm run panel`로 3종 독립 프로세스를 기동(Claude는 별도 `--session-id`로 자기검증 편향 방지).
3. **결과 취합 및 다각도 해결 설계**: 각 리포트를 종합하고 수정안의 장단점을 대조.
4. **최종 방향 확정 및 구현**: 교차검증을 거쳐 가장 안전한 방향을 확정한 뒤 소스를 편집하고 회귀 테스트를 추가.
