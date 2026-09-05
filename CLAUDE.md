# Claude Code 가이드

전체 개요·개발 규칙은 `AGENTS.md`, 게임 설계는 `docs/design.md`, 배포는 `docs/deploy.md`, 에이전트 역할은 `docs/agents/roles.md` 참조.

## 핵심 요약

- **무엇**: 『동물의 숲』 모티브 브라우저 게임. **Godot 4.7.1 표준(non-mono) + GDScript + 웹 export**. mono 빌드는 웹 export 불가.
- **현재 상태**: 멀티플레이 코어 루프(채집→가방→판매→자동저장) + 채팅·이모티콘·드랍/줍기 + 폰 터치 조작 + **운동장**(트랙/축구장, 운동 5종, 서버 소유 축구공) + 화면 크기 +/− 조절. 섬은 76×42.75. 이웃 동물/꾸미기/도감은 미구현.
- **빌드/실행** (표준 빌드 경로: `~/tools/godot/4.7.1/Godot.app/Contents/MacOS/Godot`, 시스템 `godot`은 mono라 웹 export 불가):
  - `export GODOT_BIN="$HOME/tools/godot/4.7.1/Godot.app/Contents/MacOS/Godot"`
  - `./scripts/verify-project.sh` → 임포트 + 세이브 마이그레이션 테스트 + 기동
  - `./scripts/build-web.sh` → `build/web/`
  - `node server/index.js` → http://localhost:3001 (COOP/COEP + wasm MIME + `/healthz`)
- **배포**: main push → self-hosted 러너 → `deploy.bat`(export → schtasks 기동 → `/healthz` 검증). connect_dise와 동일 방식.
- **텔레그램 알림**: `scripts/telegram-ask.js` (Stop/Notification 훅 연결, 접두어 `[animals_farm]`)
  - 단방향: `npm run notify "메시지"` / 버튼 질문: `npm run ask -- "질문" "A" "B"`
- **모델별 페르소나**: 창의/기획은 가상 페르소나 8인(`docs/agents/roles.md` §1), 정답이 있는 검증은 실제 CLI 3종 병렬(`npm run panel "프롬프트"`).
- **리뷰 게이트**: 프롬프트·세션ID·fail-open 판정의 단일 출처는 `scripts/review.js`. **`claude -p`를 스크립트에서 직접 호출하지 말 것.**
