# Claude Code 가이드

이 프로젝트의 전체 개요, 개발 규칙, 에이전트 역할은 `AGENTS.md`와 `docs/agents/roles.md`를 참조.

## 핵심 요약

- **상태**: 게임 장르/스택 **미확정**. 현재는 개발 프로세스(페르소나 + 텔레그램 푸쉬 + 3종 CLI 교차검증)만 이식된 스캐폴드.
- **원격 저장소**: `https://github.com/redspy/animals_farm.git`
- **텔레그램 알림**: `scripts/telegram-ask.js` (Stop/Notification 훅에 연결됨, trading·connect_dise와 동일 봇 재사용, 접두어 `[animals_farm]`)
  - 단방향 알림: `npm run notify "메시지"`
  - 버튼 질문(응답 대기): `npm run ask -- "질문" "옵션A" "옵션B"`
- **모델별 페르소나**: 창의/기획은 가상 페르소나 8인(`docs/agents/roles.md` §1), 정답이 있는 검증은 실제 CLI 3종 병렬(`npm run panel "프롬프트"`).
- **커밋 게이트**: `npm run hooks:install` 후 pre-commit이 Claude(로직)+Codex(문서 정합성) 헤드리스 리뷰를 자동 실행(fail-open).
