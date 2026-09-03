# 배포 (CI/CD) 설계 — connect_dise와 동일한 서버 직배포 방식

## 1. 전체 구조

```
개발 머신(macOS)                GitHub                    배포 서버(Windows)
─────────────────               ──────                    ──────────────────
git push origin main  ──────▶  push 이벤트  ──────▶  self-hosted 러너가 픽업
                                                      │
                                                      ├ git fetch + reset --hard origin/main
                                                      ├ deploy.bat
                                                      │   ├ 기존 서버 프로세스 중지
                                                      │   ├ Godot 헤드리스 --import
                                                      │   ├ Godot 헤드리스 Web export → build/web/
                                                      │   ├ 산출물 검증(index.html + .wasm)
                                                      │   ├ schtasks로 정적 서버 독립 기동
                                                      │   └ /healthz 200 재시도 검증
                                                      ▼
                                              http://<서버>:3001 에서 즉시 플레이
```

connect_dise와 **의도적으로 동일한** 선택들:

- **클라우드 빌더를 쓰지 않는다.** 배포 서버 자체가 빌드 머신이다(`runs-on: self-hosted`). 아티팩트 전송·시크릿 배포 경로가 없어 구조가 단순하고, 서버가 곧 최신 소스 트리라 문제 재현이 쉽다.
- **`git reset --hard origin/main`**: 서버의 로컬 변경을 신뢰하지 않고 항상 원격 상태로 강제 동기화한다. 단 `reset --hard`는 추적되지 않는 `build/`를 지우지 않으므로, 배포 결과가 push된 커밋과 1:1로 대응하려면 **export 직전에 `build/web`을 삭제**해야 한다(`deploy.bat` Step 4가 그 일을 한다 — 없으면 export 실패 시 구버전 산출물이 남아 검사를 통과한다).
- **`schtasks`로 서버 기동**: `start`/`Start-Process`로 띄운 프로세스는 GitHub Actions 러너의 Job Object에 묶여 **job이 끝나는 순간 함께 죽는다**(connect_dise에서 실측, 헬스체크는 job 진행 중이라 통과하는데 직후에 포트가 죽어 있었다). 작업 스케줄러가 관리하는 태스크는 러너와 무관한 독립 프로세스다.
- **배포 성공 판정 = 실제 HTTP 200**: 프로세스 기동 명령이 성공했다는 것은 서버가 살아 있다는 뜻이 아니다. `/healthz`를 **10회 재시도**(각 요청 타임아웃 3초 + 간격 2초 → 즉시 거절되면 약 20초, 요청이 매번 타임아웃되면 최대 약 50초)로 확인하고, 실패하면 `server_error.log`를 출력하고 exit 1로 배포를 실패시킨다.

animals_farm에서 **달라지는 점**은 빌드 단계뿐이다: `npm install && npm run build`(Vite) 대신 **Godot 헤드리스 웹 export**를 돌린다. 서버는 npm 의존성이 0개인 정적 서버(`server/index.js`)라 배포 중 `npm install` 실패 지점이 아예 없다.

## 2. 배포 서버 1회 준비

전제: connect_dise가 쓰는 것과 같은 Windows 서버, self-hosted 러너가 이미 등록되어 있음.

1. 저장소 클론: `D:\Source\animals_farm` (경로가 다르면 `.github/workflows/deploy.yml`과 `deploy.bat`의 경로를 함께 고쳐야 한다)
2. **Godot 표준(non-mono) 빌드** 설치 — `D:\tools\godot\4.7.1\Godot_v4.7.1-stable_win64.exe`
   - ⚠️ **mono(.NET) 빌드는 쓸 수 없다**: 웹 export 템플릿이 존재하지 않고, 헤드리스 실행도 .NET 초기화 단계에서 멈춘다(2026-09-03 개발 머신의 4.6.3-mono에서 실측).
3. **export 템플릿 설치** — 같은 버전(4.7.1)의 `Godot_v4.7.1-stable_export_templates.tpz`를 에디터에서 한 번 임포트하거나 `%APPDATA%\Godot\export_templates\4.7.1.stable\`에 풀어둔다. 템플릿이 없으면 export가 실패한다.
4. Node.js 20+ 설치(정적 서버 실행용).
5. 포트: **3001** (connect_dise가 3000을 쓰므로 충돌을 피한다). 바꾸려면 `GAME_PORT` 환경변수 또는 `deploy.bat` 기본값을 수정.

버전 고정의 단일 출처는 저장소 루트의 **`.godot-version`** 파일이다(`deploy.bat`, `scripts/build-web.sh`, `scripts/verify-project.sh`가 모두 이 파일을 읽는다). 엔진 버전을 올릴 때는 (a) `.godot-version`, (b) 서버의 실제 바이너리·템플릿, (c) `project.godot`의 `config/features`를 함께 올린다.

## 3. 웹 export와 브라우저 헤더

- 현재 export 프리셋은 **nothreads**(`export_presets.cfg`의 `variant/thread_support=false`)다. 스레드 빌드는 `SharedArrayBuffer`를 요구해 **COOP/COEP 헤더 없이는 아예 실행되지 않고**, iOS Safari 등에서 실패율이 높다.
- 그래도 `server/index.js`는 `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp`를 **미리 보낸다**. 나중에 스레드 빌드로 전환할 때 서버를 다시 건드리지 않기 위함이다. 대신 이 헤더가 켜져 있으면 외부 도메인 리소스(CDN 이미지/폰트/iframe)가 차단되므로, 외부 리소스를 쓰게 되면 그 시점에 재검토해야 한다.
- `.wasm`은 `application/wasm`, `.pck`는 `application/octet-stream`으로 서빙한다. MIME이 틀리면 브라우저가 스트리밍 컴파일을 거부해 로딩이 느려지거나 실패한다.
- `index.html`은 `no-cache`, 나머지 산출물은 `max-age=300`. 배포 직후 구버전 HTML이 캐시에 남는 문제를 막는다.

## 4. 로컬에서 같은 빌드 재현

```bash
GODOT_BIN=/path/to/Godot_v4.7.1-stable_macos.universal ./scripts/build-web.sh
node server/index.js            # http://localhost:3001
curl -s localhost:3001/healthz  # {"ok":true,...}
```

`scripts/build-web.sh`는 mono 빌드를 감지하면 즉시 실패하며 이유를 알려준다.

## 5. 리뷰 게이트와의 관계

배포 워크플로(`deploy.yml`)와 감사 워크플로(`review-ci.yml`)는 **분리되어 있고, 감사가 배포를 막지 않는다**. 이유는 AGENTS.md §4의 fail-open 정책과 같다 — CLI 인증/쿼터/일시 장애로 배포 자체가 멈추는 것이 더 큰 손실이다. 대신 두 워크플로 모두 main push에서 함께 돌아 감사 결과는 항상 남는다.

되돌릴 수 없는 변경(세이브 스키마)은 이 게이트에 의존하지 말고 `docs/agents/roles.md` §4의 3단계 확인을 거칠 것.

## 6. 롤백

배포는 항상 `origin/main`의 상태를 그대로 반영하므로, 롤백은 **되돌리는 커밋을 push하는 것**이다(`git revert <sha> && git push`). 서버에서 수동으로 파일을 고치면 다음 배포의 `reset --hard`에 덮여 사라진다.
