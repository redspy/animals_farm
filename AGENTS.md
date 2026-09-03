# AGENTS.md — animals_farm (게임 프로젝트)

이 문서는 이 저장소에서 작업하는 모든 에이전트(메인, 서브, 가상 페르소나, 헤드리스 CLI)가 따라야 하는 개발 규칙을 정의한다. `trading` 프로젝트의 개발 프로세스를 이식했고, 도메인 특성만 게임에 맞게 조정했다.

## 프로젝트 개요

- **목표**: 닌텐도 스위치 『동물의 숲』을 모티브로 한 **브라우저 게임**. 원작 IP 자산(캐릭터·이름·에셋·음악)은 쓰지 않고 게임 구조만 차용한다(`docs/design.md` §0).
- **스택**: **Godot 4.7.1 표준(non-mono) 빌드 + GDScript + 웹(HTML5) export**. mono(.NET) 빌드는 웹 export 템플릿이 없어 사용 불가(2026-09-03 실측).
- **배포**: connect_dise와 동일한 **서버 직배포** — main push → self-hosted 러너 → `git reset --hard` → `deploy.bat`(Godot 웹 export → `schtasks` 독립 기동 → `/healthz` 검증). 상세는 `docs/deploy.md`.
- **원격 저장소**: `https://github.com/redspy/animals_farm.git`
- **현재 구현 상태**: 코어 루프 최소 1사이클 프로토타입(채집 → 가방 → 판매 → 자동 저장, 그레이박스). 이웃 동물/꾸미기/도감/멀티플레이·아트 톤은 미확정 — `docs/design.md`는 미확정 항목을 정직하게 "미확정"으로 남긴다(빈 문서를 억지로 채우면 Codex 문서 정합성 감사가 존재하지 않는 스펙으로 코드를 지적하게 된다).

## 디렉터리 구조

```
.godot-version       Godot 고정 버전의 단일 출처 (deploy.bat/build-web.sh/verify-project.sh가 읽음)
project.godot        Godot 프로젝트 (GL Compatibility 고정)
export_presets.cfg   Web export 프리셋 (nothreads)
scenes/main.tscn     진입 씬 — 나머지 노드는 scripts/main.gd가 코드로 조립
tests/               헤드리스 테스트 + 픽스처 (세이브 마이그레이션 회귀)
scripts/*.gd         게임 코드 (main / player / gatherable / save_manager / game_clock / balance)
data/*.json          밸런스·배치 데이터 (유효범위 포함, 코드가 클램프)
server/index.js      웹 빌드 정적 서버 (의존성 0개, COOP/COEP + wasm MIME + /healthz)
scripts/*.js         개발 프로세스 툴링 (텔레그램, CLI 러너, 리뷰 게이트)
deploy.bat           배포 서버에서 실행되는 배포 스크립트
```

## 실행/빌드

```bash
godot --path .                       # 에디터로 열기 (표준 빌드 필요)
GODOT_BIN=<표준빌드> ./scripts/build-web.sh   # 웹 export → build/web/
node server/index.js                 # http://localhost:3001 로 웹 빌드 서빙
```

## 알림 (텔레그램 푸쉬)

- `scripts/telegram-ask.js`가 단일 진입점이며 세 가지 모드로 동작한다.
  - `--notify "메시지"`: 응답 대기 없이 단방향 전송(작업 완료 알림 등). `npm run notify "메시지"`.
  - `"질문" "옵션1" "옵션2" [--timeout=분]`: 인라인 버튼으로 질문을 보내고 사용자가 누를 때까지 대기해 선택값을 stdout(JSON)으로 반환. `npm run ask -- "질문" "A" "B"`.
  - `--get-chat-id`: 봇 최초 설정 시 CHAT_ID 확인.
- Claude Code 훅 연결(`.claude/settings.local.json` — **이 파일은 `.gitignore` 대상이라 clone에 따라오지 않는다.** 추적되는 `.claude/settings.example.json`을 복사한 뒤 절대경로를 자기 환경에 맞게 고쳐 쓸 것. 절대경로를 쓰는 이유는 훅이 로그인 셸을 거치지 않아 PATH·cwd를 신뢰할 수 없기 때문이다):
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
npm run review:code      # 직전 커밋 리뷰
npm run review:staged    # 스테이징된 변경 리뷰 (pre-commit이 쓰는 것과 동일)
```
- 리뷰 프롬프트·CLI 호출·fail-open 판정은 **`scripts/review.js`가 유일한 출처**다. 예전에는 package.json / pre-commit / AGENTS.md에 프롬프트 사본이 흩어져 있었고 그 사본들에는 `--session-id`가 빠져 있어 "검증용 Claude는 별도 세션으로 기동한다"는 규칙(`docs/agents/roles.md` §0)이 실제로는 깨져 있었다(2026-09-03 pre-commit Codex 감사 지적). **어떤 스크립트에서도 `claude -p`를 직접 호출하지 말 것** — `scripts/cli-runner.js`의 `runClaude`가 매번 새 `--session-id`를 붙인다.
- ⚠️ **게이트의 실제 동작**: 게이트는 CLI의 **종료 코드**만 본다. 리뷰 텍스트가 "치명적"이라고 지적해도 프로세스가 정상 종료하면 커밋은 진행된다 — 즉 이 리뷰는 자동 차단 게이트가 아니라 **읽고 판단해야 하는 조언**이다.
- 리뷰 타임아웃은 10분이고, 타임아웃 시에도 커밋은 진행된다(fail-open) — 다만 "리뷰가 완료되지 않았다"를 명시해 사람이 직접 확인하게 한다. 타임아웃으로 커밋을 막으면 큰 커밋일수록 `--no-verify`로 게이트를 우회하게 되어 검증이 오히려 줄어든다.
- diff가 180,000자를 넘으면 앞부분만 리뷰에 포함되고, **잘렸다는 사실을 출력에 명시**한다(조용한 truncation은 "전부 봤다"는 오해를 만든다).

### 2. Codex CLI — 문서 정합성 싱크 검사
```bash
npm run review:docs
```
- `AGENTS.md`, `docs/design.md`, `docs/deploy.md`와 실제 코드를 대조한다. 백그라운드 실행 시 stdin이 닫혀야 무한 대기하지 않는다(`cli-runner.js`가 처리).
- ⚠️ 이 명령은 **Codex 단독**이며 그것으로 §0의 3종 교차검증이 충족되지는 않는다 — 어느 단계에 몇 종이 필요한지는 아래 §4 표가 단일 출처다. 3종이 필요한 작업은 `npm run panel`을 직접 기동해야 하고, panel은 2종 이상 성공하지 못하면 exit 1로 실패한다.

### 3. Gemini(`agy`) CLI — 비주얼 패리티 리뷰
- 게임 화면 스크린샷을 `docs/design.md` §5 비주얼 가이드라인과 대조. 가이드라인이 채워진 시점부터 필수 게이트로 승격(`docs/agents/roles.md` §3).

### 4. 어느 단계에 CLI 몇 종을 쓰는가 (원칙과 실제의 대응)

`docs/agents/roles.md` §0은 "정답이 있는 검증은 3종 CLI 교차검증"을 요구하지만, **자동 게이트(pre-commit/CI)는 2종(Claude 코드 리뷰 + Codex 문서 정합성)만 돌린다.** 이 차이는 의도된 것이며, 어긋난 상태로 두지 않기 위해 여기 명시한다(2026-09-03 Codex 감사 지적).

| 단계 | 실행되는 CLI | 기동 방식 |
|---|---|---|
| 커밋 게이트(pre-commit) | Claude + Codex (2종) | 자동 — 매 커밋마다 돌아야 하므로 3종은 비용/시간이 과하다 |
| 원격 CI(review-ci.yml) | Claude + Codex (2종) | 자동 |
| 버그 원인분석 | **3종 전체** | 수동 `npm run panel "..."` — 원인 판정은 정답이 있는 작업이라 3종 필수 |
| 세이브 스키마 변경 | **3종 전체** | 수동 `npm run panel "..."` — 되돌릴 수 없는 변경 |
| 스펙-구현 정합성 감사 (상시) | Codex (1종) | 자동 — 매 커밋/CI. 빠른 드리프트 감지가 목적이며 **정식 판정이 아니다** |
| 스펙-구현 정합성 **판정** (릴리즈 전, 문서 대규모 개정) | **3종 전체** | 수동 `npm run panel "설계 문서와 코드 정합성 감사"` — roles.md §0이 "반드시 3종"이라고 말하는 대상이 이 판정이다 |
| 화면 비주얼 검증 | Gemini(`agy`) | 수동 — `docs/design.md` §5가 채워지면 필수 게이트로 승격 |

즉 **3종 교차검증은 자동 게이트가 대신해 주지 않는다.** 위 표의 "3종 전체" 행에 해당하는 작업을 할 때는 반드시 직접 `npm run panel`을 기동할 것.

### 5. 개발 프로세스 라이프사이클

1. **로컬 커밋 예방 단계**: `.git/hooks/pre-commit`이 자동 트리거되어 헤드리스 진단(원본은 `scripts/git-hooks/pre-commit`, `npm install`/`npm run hooks:install`이 복사).
2. **릴리즈 문서 동기화**: `npm run review:write`로 변경 사안을 문서에 반영.
3. **3종 병렬 패널**: `npm run panel "프롬프트"`로 Claude/Codex/Gemini를 동시 기동해 리포트 비교.
4. **원격 감사 CI**: `.github/workflows/review-ci.yml`이 PR/push에서 같은 `scripts/review.js`를 돌린다.
5. **배포**: `.github/workflows/deploy.yml`(self-hosted) → `deploy.bat`. 감사 워크플로와 분리되어 있어 감사 실패가 배포를 막지 않는다(`docs/deploy.md` §5).

**의도적인 fail-open 정책**: CLI가 미인증이거나 쿼터를 초과하거나 프로바이더 일시 장애(`API Error: 5xx`, `Overloaded`)로 죽으면 해당 리뷰를 건너뛰고 커밋을 허용한다(5xx 패턴은 2026-09-03 첫 커밋이 실제로 500에 막혀서 추가함). CLI 인증 문제 하나로 개발 전체가 멈추는 것을 피하기 위함이다. **리스크**: 미검증 코드가 커밋될 수 있다 — 세이브 데이터 스키마 변경처럼 되돌릴 수 없는 변경은 이 게이트 하나에 의존하지 말고 `docs/agents/roles.md` §4의 3단계 확인을 반드시 함께 거칠 것.

### 6. 원격 푸쉬 규칙
- 모든 구현·검증이 끝나면 `git add` → `git commit` → `git push`로 `origin`(redspy/animals_farm)에 동기화한다.
- 로컬 셸 프로필 환경변수가 필요하면 `zsh -l -c "명령"`으로 랩핑한다.

## 버그 분석 및 해결 프로세스

1. **버그 상세 정의 및 재현 계획**: 현상, 재현 조건(시드/입력 시퀀스 포함), 수정 전/후 검증 시나리오를 먼저 정리.
2. **실제 병렬 CLI 분석 기동**: 원인분석을 가상 페르소나로 대체하지 않고 `npm run panel`로 3종 독립 프로세스를 기동(Claude는 별도 `--session-id`로 자기검증 편향 방지).
3. **결과 취합 및 다각도 해결 설계**: 각 리포트를 종합하고 수정안의 장단점을 대조.
4. **최종 방향 확정 및 구현**: 교차검증을 거쳐 가장 안전한 방향을 확정한 뒤 소스를 편집하고 회귀 테스트를 추가.
