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
4. Node.js 20+ 설치(서버 실행용). 서버가 WebSocket(`ws`)을 쓰므로 **의존성 설치가 필요하다** — `deploy.bat`이 `npm ci --omit=dev`(실패 시 `npm install --omit=dev`)로 처리한다.
5. 포트: **3001** (connect_dise가 3000을 쓰므로 충돌을 피한다). 바꾸려면 `GAME_PORT` 환경변수 또는 `deploy.bat` 기본값을 수정.

버전 고정의 단일 출처는 저장소 루트의 **`.godot-version`** 파일이다(`deploy.bat`, `scripts/build-web.sh`, `scripts/verify-project.sh`가 모두 이 파일을 읽는다). 엔진 버전을 올릴 때는 (a) `.godot-version`, (b) 서버의 실제 바이너리·템플릿, (c) `project.godot`의 `config/features`를 함께 올린다.

## 3. 웹 export와 브라우저 헤더

- 현재 export 프리셋은 **nothreads**(`export_presets.cfg`의 `variant/thread_support=false`)다. 스레드 빌드는 `SharedArrayBuffer`를 요구해 **COOP/COEP 헤더 없이는 아예 실행되지 않고**, iOS Safari 등에서 실패율이 높다.
- 그래도 `server/index.js`는 `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp`를 **미리 보낸다**. 나중에 스레드 빌드로 전환할 때 서버를 다시 건드리지 않기 위함이다. 대신 이 헤더가 켜져 있으면 외부 도메인 리소스(CDN 이미지/폰트/iframe)가 차단되므로, 외부 리소스를 쓰게 되면 그 시점에 재검토해야 한다.
- WebSocket은 정적 파일과 **같은 포트의 `/ws`** 로 붙는다. 클라이언트는 페이지를 서빙한 origin에서 주소를 유도하므로(`net.gd::default_url`) 별도 설정이 없다 — https면 `wss://`가 되고, 리버스 프록시를 쓸 경우 `/ws` 업그레이드를 통과시켜야 한다.
- `.wasm`은 `application/wasm`, `.pck`는 `application/octet-stream`으로 서빙한다. MIME이 틀리면 브라우저가 스트리밍 컴파일을 거부해 로딩이 느려지거나 실패한다.

### 보안 컨텍스트(HTTPS) 요구와 http 지원

Godot 4의 **기본 HTML 셸은 보안 컨텍스트가 아니면 실행을 거부한다** — 폰에서 `http://192.168.x.x`로 붙으면 "Secure Context - Check web server configuration (use HTTPS)"만 뜬다(2026-09-04 실기 확인). `localhost`는 브라우저가 보안 컨텍스트로 취급하므로 PC 테스트에서는 절대 재현되지 않는다.

`web/shell.html`(커스텀 셸)에서 이 제약을 **필요한 만큼만** 풀었다:

- `Secure Context` 항목만 경고로 낮춘다. 다른 누락(WebGL2 등)은 그대로 실패로 둔다.
- 비보안 컨텍스트에서는 `AudioWorklet`이 아예 없어(`audioContext.audioWorklet === undefined`) Godot 오디오 초기화가 예외를 던지고 **엔진 시작 자체가 멈춘다.** 그래서 (a) `--audio-driver Dummy`를 엔진 인자로 넣고(반드시 `new Engine()` **앞에서** — 뒤에서 바꾸면 무시된다) (b) `addModule`이 reject하는 스텁을 심어 예외 대신 실패로 흘려보낸다.
- **대가: http로 열면 소리가 나지 않는다.** 사운드를 넣기 시작하면 HTTPS가 사실상 필수가 되므로 그때 이 완화를 거둔다.
- 서버는 http로 서빙할 때 COOP/COEP를 보내지 않는다 — 브라우저가 "untrustworthy origin이라 무시했다"는 오류로 콘솔을 채워 진짜 오류를 가린다.
- 개발용 HTTPS가 필요하면 `./scripts/make-dev-cert.sh`로 자체 서명 인증서를 만든다(LAN IP를 SAN에 넣는다 — SAN이 없으면 최신 브라우저가 예외 허용조차 거부한다). `TLS=off`로 강제 http 기동도 된다.
- 검증: `npm run test:insecure` — **LAN IP로 접속해** 비보안 컨텍스트에서 화면이 그려지는지 본다(localhost로는 재현 불가).

### 첫 로딩 시간 (2026-09-04 실측)

폰에서 첫 로딩이 오래 걸린다는 보고를 받고 전송량을 재보니 **두 가지가 비정상이었다.**

| 항목 | 문제 | 조치 후 |
|---|---|---|
| `index.pck` | **28MB** — `node_modules`의 playwright 아이콘·폰트까지 Godot이 리소스로 임포트해 넣고 있었다 | **3MB** (`.gdignore`로 스캔 제외, `npm ci`가 지워도 postinstall이 다시 심는다) |
| 전송 압축 | 없음 — 39MB wasm을 그대로 보냈다 | brotli/gzip (**wasm 39MB → br 약 7MB, gzip 9MB**), 첫 압축 결과를 mtime 키로 캐시 |

정리하면 **총 전송량 약 71MB → 약 12MB**다. 남은 9MB는 Godot 엔진 wasm 자체이고 이건 정상 범위다(Godot 웹 빌드의 고정 비용). 더 줄이려면 (a) 폰트 서브셋(현재 KR 전체 4.6MB), (b) 엔진 기능 축소 빌드가 필요하다.

- `index.html`은 `no-cache`- `index.html`은 `no-cache`, 나머지 산출물은 `max-age=300`. 배포 직후 구버전 HTML이 캐시에 남는 문제를 막는다.

## 4. 로컬에서 같은 빌드 재현

이 개발 머신에는 표준 4.7.1 빌드가 `~/tools/godot/4.7.1/`에 있다(시스템 `godot`은 4.6.3 **mono**여서 웹 export가 불가하므로 건드리지 않고 따로 뒀다).

```bash
export GODOT_BIN="$HOME/tools/godot/4.7.1/Godot.app/Contents/MacOS/Godot"
./scripts/verify-project.sh     # 임포트 + 세이브 마이그레이션 테스트 + 기동
./scripts/build-web.sh          # → build/web/ (index.html, index.wasm, index.pck ...)
node server/index.js            # http://localhost:3001
curl -s localhost:3001/healthz  # {"ok":true,...}
```

```bash
npm run test:browser            # build/web를 서버에 올려 Chromium으로 기동·입력·채집·판매 확인
```

두 Godot 스크립트는 (a) mono 빌드, (b) `.godot-version`과 다른 버전, (c) 출력에 섞인 GDScript 오류를 각각 감지해 실패한다. (c)가 필요한 이유: **Godot은 GDScript 컴파일/런타임 오류가 있어도 종료 코드 0으로 끝난다** — 실제로 `game_clock.gd`의 컴파일 에러를 초기 게이트가 "통과"로 보고했다(2026-09-04 실측).

### 실측으로 확인된 웹 전용 함정

- **한글이 두부(□)로 렌더링**: Godot 기본 폰트에는 한글 글리프가 없고 **웹에는 시스템 폰트 폴백이 없다**. `assets/fonts/NotoSansKR-Regular.otf`(OFL)를 임베드하고 `project.godot`의 `gui/theme/custom_font`로 지정해 해결했다. 데스크톱 헤드리스 검증에서는 드러나지 않고 브라우저에서만 보이는 문제라, `npm run test:browser`가 이 계층을 담당한다.
  - 대가: 폰트 때문에 `index.pck`가 약 4MB로 늘었다. 첫 로딩이 문제되면 필요한 글리프만 서브셋한 폰트로 교체하는 것이 다음 단계다(현재는 전체 KR 서브셋 OTF).

### 실측으로 확인된 export 함정

`export_presets.cfg`의 `vram_texture_compression/for_desktop|for_mobile`을 켜두면 export가 **상세 사유 없이** `Cannot export project with preset "Web" due to configuration errors`로 실패한다(모바일 VRAM 압축은 프로젝트 설정 `rendering/textures/vram_compression/import_etc2_astc`를 요구). 이 게임은 2D + GL Compatibility라 VRAM 압축이 필요 없어 둘 다 끈 상태다. 텍스처 에셋을 도입할 때 이 옵션을 다시 켜려면 프로젝트 설정도 함께 켜야 한다.

## 5. 검증 상태 (2026-09-04)

| 항목 | 상태 |
|---|---|
| 리소스 임포트 / 메인 씬 헤드리스 기동 | ✅ 로컬 실측 통과(Godot 4.7.1 표준) |
| 세이브 마이그레이션 회귀 테스트 | ✅ 로컬 실측 통과 |
| 팔레트 정합성 테스트(코드 참조 키 전수) | ✅ 로컬 실측 통과 |
| 경로 계산(바위 우회) 테스트 7종 | ✅ 로컬 실측 통과(`tests/test_path.gd`) |
| 웹 export 산출물(index.html/.wasm/.pck) | ✅ 로컬 실측 생성 |
| 정적 서버 MIME·COOP/COEP·`/healthz` | ✅ 로컬 실측 통과 |
| 브라우저 기동·입력·채집·판매 1사이클 | ✅ 로컬 실측 통과(`npm run test:browser`, Chromium) |
| 서버 규칙(검증·소유권·레이트 리밋) | ✅ 유닛 테스트 17종 통과(`npm run test:server`) |
| 2기기 실시간 동기화(위치·채팅·이모티콘·드랍/줍기) | ✅ 로컬 실측 통과(`npm run test:multiplayer`, 2탭 + WS 옵저버) |
| 폰 터치 조작(조이스틱·버튼·이모티콘 시트·DOM 채팅 입력) | ✅ 로컬 실측 통과(`npm run test:mobile`, 세로 412×839 에뮬레이션) |
| 한글 IME 입력(이름·채팅) | ⚠️ **미검증** — 합성 키 이벤트로는 한글이 들어가지 않아 자동 테스트 불가. 실기(폰/PC 브라우저)에서 사람이 확인해야 한다 |
| 실제 다른 기기(공개 주소)에서의 접속 | ⚠️ 미검증 — 포트포워딩/도메인 설정 후 확인 필요 |
| 걷기 애니메이션 재생 | ✅ 섬 경계에 붙여 이동이 멈춘 상태에서 프레임이 바뀌는지로 판정(`test:browser`) |
| **배포 서버 파이프라인(deploy.bat 전체)** | ⚠️ **미검증** — Windows 서버에서 첫 배포를 돌려봐야 한다. 서버에 Godot 4.7.1 표준 + export 템플릿 설치가 선행 조건(§2) |
| 모바일 브라우저 / 터치 조작 | ✅ 세로 412×839 에뮬레이션에서 통과(`npm run test:mobile`). 실제 폰 실기는 미검증 |

## 6. 리뷰 게이트와의 관계

배포 워크플로(`deploy.yml`)와 감사 워크플로(`review-ci.yml`)는 **분리되어 있고, 감사가 배포를 막지 않는다**. 이유는 AGENTS.md §4의 fail-open 정책과 같다 — CLI 인증/쿼터/일시 장애로 배포 자체가 멈추는 것이 더 큰 손실이다. 대신 두 워크플로 모두 main push에서 함께 돌아 감사 결과는 항상 남는다.

되돌릴 수 없는 변경(세이브 스키마)은 이 게이트에 의존하지 말고 `docs/agents/roles.md` §4의 3단계 확인을 거칠 것.

## 7. 롤백

배포는 항상 `origin/main`의 상태를 그대로 반영하므로, 롤백은 **되돌리는 커밋을 push하는 것**이다(`git revert <sha> && git push`). 서버에서 수동으로 파일을 고치면 다음 배포의 `reset --hard`에 덮여 사라진다.
