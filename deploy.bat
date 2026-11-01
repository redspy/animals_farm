@echo off
REM ============================================================
REM  animals_farm 배포 스크립트 (Windows self-hosted 러너에서 실행)
REM  connect_dise/deploy.bat과 동일한 구조:
REM    서버 중지 → 빌드 → schtasks로 독립 프로세스 기동 → 실제 응답 검증
REM  차이점: 빌드가 npm이 아니라 Godot 웹 export다.
REM ============================================================
cd /d %~dp0

REM 배포 서버에서 쓸 Godot 버전을 여기서 고정한다. mono(.NET) 빌드는 웹
REM export 템플릿이 없으므로 반드시 표준 빌드를 쓴다(docs/deploy.md §2).
REM Godot 버전의 단일 출처는 저장소 루트의 .godot-version 파일이다 —
REM 예전엔 이 값이 deploy.bat / build-web.sh / verify-project.sh에 각각
REM 하드코딩돼 독립적으로 드리프트할 수 있었다(2026-09-03 Codex 감사 지적).
if "%GODOT_VERSION%"=="" set /p GODOT_VERSION=<.godot-version
if "%GODOT_HOME%"=="" set GODOT_HOME=D:\tools\godot\%GODOT_VERSION%
if "%GAME_PORT%"=="" set GAME_PORT=3001
set GODOT_EXE=%GODOT_HOME%\Godot_v%GODOT_VERSION%-stable_win64.exe

echo [Step 1] Verifying the build-error gate (server still up)...
REM **서버를 멈추기 전에 끝낼 수 있는 검사는 다 여기서 한다**(Step 1~3).
REM Step 4가 서버를 멈추므로, 그 뒤 어느 단계가 실패하든 `exit /b 1`은 **서버가
REM 꺼진 채로** 끝난다 — 구버전이 남는 stale이 아니라 아이들이 아예 못 들어가는
REM 다운이고, 다시 뜨는 것은 Step 8이다.
REM
REM 그래서 Step 4 뒤에 남겨 둔 것은 **서버가 쥔 파일을 건드려야 하는 둘뿐**이다:
REM `npm ci`(실행 중인 node가 node_modules를 쥔다)와 export(build\web을 비운다).
REM 패턴 무결성·Godot 존재·리소스 임포트는 전부 그와 무관해서 앞으로 옮겼다
REM (2026-11-01. 처음엔 패턴 검사만 옮겼는데 리뷰가 나머지 둘도 같은 부류라고 짚었다).
REM build\ 는 여기서 만든다 — 뒤 단계들이 로그를 그 안에 쓴다.
if not exist build mkdir build
if not exist scripts\error-patterns.txt (
    echo ERROR: scripts\error-patterns.txt not found - cannot verify build log
    exit /b 1
)
REM 0바이트로 체크아웃되면 findstr /G: 가 errorlevel 1을 주고, 아래 검사는 그걸
REM "오류 없음"으로 읽는다 — sh 쪽 `[ -s ]`와 같은 이유로 크기도 본다(리뷰 지적).
for %%A in (scripts\error-patterns.txt) do if %%~zA equ 0 (
    echo ERROR: scripts\error-patterns.txt is empty - cannot verify build log
    exit /b 1
)
REM 바이트 위생 — **CI가 실제로 도는 건 이 파일 하나다**(.github/workflows/deploy.yml).
REM sh 쪽 검사 3종은 로컬 전용이라 배포 판정에 관여하지 않는다. 전각 공백이나
REM 스마트 따옴표가 한 줄에 섞이면 그 패턴만 조용히 죽고, 카나리아는 첫 패턴만
REM 보므로 통과한다 — 컴파일 에러 섞인 export가 초록불로 배포된다(리뷰 지적).
REM LF/CR만 허용하고 BOM·탭·제어문자·비ASCII를 막는다(sh 검사 1과 같은 기준).
REM 빈 줄·공백뿐인 줄도 함께 본다 — 그건 출력 가능 ASCII라 바이트 검사를 통과하고
REM 카나리아 줄에도 매치되는데, findstr /L은 로그의 **모든 줄**에 매치해서 정상
REM 빌드를 "script errors"로 죽인다. 게이트가 뚫리는 건 아니지만 원인을 알 수 없는
REM 형태로 배포가 막힌다(2026-09-16 리뷰 지적).
REM 위반 위치(바이트 오프셋·줄 번호)도 찍는다 — CI에서 유일하게 도는 게이트라
REM 여기야말로 진단 정보가 필요하다.
powershell -NoProfile -Command "$p='scripts\error-patterns.txt'; $b=[IO.File]::ReadAllBytes($p); $bad=@(); for($i=0;$i -lt $b.Length -and $bad.Count -lt 21;$i++){ $x=$b[$i]; if((($x -lt 32) -and ($x -ne 10) -and ($x -ne 13)) -or ($x -gt 126)){ $bad += $i } }; if($bad.Count -gt 0){ $sfx=''; $show=$bad; if($bad.Count -gt 20){ $sfx=' (first 20)'; $show=$bad[0..19] }; Write-Host ('  bad bytes at offsets: ' + ($show -join ',') + $sfx); exit 1 }; $n=0; foreach($l in [IO.File]::ReadAllLines($p)){ $n++; if($l.Trim() -eq ''){ Write-Host ('  blank pattern line: ' + $n); exit 1 } }; exit 0"
if %ERRORLEVEL% neq 0 (
    echo ERROR: error-patterns.txt is unusable ^(non-ASCII byte or blank line, see above^) - patterns are dead
    exit /b 1
)

REM 카나리아 — 패턴이 **진짜 오류 줄을 잡는지** 확인한다. 위 검사가 바이트를 보는
REM 것과 달리 이건 findstr가 실제로 매치하는지를 본다.
REM ⚠️ 한계: 첫 패턴 계열이 살아 있는지까지만 말한다(sh 쪽과 같다).
REM 직전 실행의 canary.txt가 남아 있으면 쓰기가 실패해도 아래 검사를 통과한다
REM (build\ 는 정리되지 않는다 — 지우는 건 build\web 뿐이다. 리뷰 지적).
REM `/f`가 없으면 **읽기 전용 속성**을 못 지운다 — 가능한 실패 원인 중 하나이고,
REM 그것 하나로 배포가 수동 개입까지 영구 차단된다.
REM 다른 프로세스가 물고 있는 진짜 위험 케이스는 `/f`로도 안 지워져 아래 `if exist`가
REM 그대로 잡는다 — 게이트 강도 손실 없이 오탐만 준다(리뷰 지적).
del /f /q build\canary.txt >nul 2>&1
REM `del`의 결과를 **`if exist`로** 확인한다 — 읽기 전용이거나 다른 프로세스가
REM 물고 있으면 del도 이어지는 리다이렉션도 실패하는데, 스크립트가 ERRORLEVEL이
REM 아니라 존재만 보므로 **옛 파일이 그대로 남아 검사를 통과**한다(리뷰 지적).
if exist build\canary.txt (
    echo ERROR: stale build\canary.txt could not be removed - cannot verify the gate
    exit /b 1
)
echo SCRIPT ERROR: canary> build\canary.txt
if not exist build\canary.txt (
    echo ERROR: could not write build\canary.txt - cannot verify the gate
    exit /b 1
)
findstr /L /G:scripts\error-patterns.txt build\canary.txt >nul
if %ERRORLEVEL% neq 0 (
    echo ERROR: error-patterns.txt does not match a known Godot error line - the gate is dead
    exit /b 1
)

echo [Step 2] Checking Godot %GODOT_VERSION% (standard build)...
if not exist "%GODOT_EXE%" (
    echo ERROR: Godot not found at %GODOT_EXE%
    echo        Install the STANDARD ^(non-mono^) build and its export templates:
    echo        https://github.com/godotengine/godot/releases/tag/%GODOT_VERSION%-stable
    echo        See docs/deploy.md section 2 for the one-time setup.
    exit /b 1
)

echo [Step 3] Importing project resources...
REM export 전에 리소스 임포트를 한 번 돌려야 .godot/ 캐시가 생성된다.
REM (clone 직후 .godot/은 git 추적 대상이 아니라 비어 있음)
REM import 출력도 검사한다 — 리소스/스크립트 오류 중에는 import 단계에서만
REM 드러나는 것이 있다(`Failed to load script`). 예전에는 export만 검사해서
REM 커버리지가 절반이었다(2026-09-16 리뷰 지적).
REM ⚠️ `type`을 검사 **앞**에 두면 안 된다 — type이 성공하면서 ERRORLEVEL을 0으로
REM 덮어써 godot의 종료 코드 검사가 죽는다(2026-09-16 리뷰 지적: 커버리지를 늘리려다
REM 기존 게이트 하나를 없앨 뻔했다).
"%GODOT_EXE%" --headless --path . --import > build\import.log 2>&1
if %ERRORLEVEL% neq 0 (
    type build\import.log
    echo ERROR: godot --import failed
    exit /b 1
)
type build\import.log

REM /L = 리터럴. sh 쪽은 `grep -F`(리터럴)라, 여기만 기본 정규식으로 두면 파일은
REM 하나인데 판정이 갈린다(메타문자가 들어간 패턴을 나중에 추가하는 순간).
findstr /L /G:scripts\error-patterns.txt build\import.log >nul
if %ERRORLEVEL% equ 0 (
    echo ERROR: import log contains script errors ^(exit code was 0 - see above^)
    exit /b 1
)

echo [Step 4] Stopping server task...
schtasks /Delete /TN "AnimalsFarmServer" /F >nul 2>&1
for /f "tokens=5" %%a in ('netstat -ano ^| findstr :%GAME_PORT% ^| findstr LISTENING') do (
    taskkill /F /PID %%a >nul 2>&1
)

echo [Step 5] Installing server dependencies...
REM 서버가 WebSocket(ws)을 쓰게 되면서 의존성이 생겼다 — 예전에는 의존성 0개라
REM 이 단계가 없었다(docs/protocol.md §0). devDependencies(playwright)는 배포에
REM 필요 없으므로 --omit=dev 로 받는다.
call npm ci --omit=dev
if %ERRORLEVEL% neq 0 (
    echo WARN: npm ci failed, falling back to npm install --omit=dev
    call npm install --omit=dev
    if %ERRORLEVEL% neq 0 (
        echo ERROR: dependency install failed
        exit /b 1
    )
)

echo [Step 6] Exporting Web build...
REM 이전 빌드를 먼저 지운다 — git reset --hard는 추적되지 않는 build/를
REM 지우지 않아서, export가 실패해도 구버전 index.html/.wasm이 남아 Step 6의
REM 산출물 검사를 통과해버릴 수 있었다(2026-09-03 Codex 감사 지적).
if exist build\web rmdir /s /q build\web
mkdir build\web
REM 출력을 로그로 받는다 — Godot은 **GDScript 오류에도 종료 코드 0을 준다**
REM (docs/deploy.md 4장). 로컬 스크립트(verify-project.sh / build-web.sh)는 이미
REM 로그를 검사하는데 배포만 종료 코드와 산출물 존재로 판정해서, 오류가 섞인
REM export가 파일만 만들면 배포가 성공으로 찍혔다(2026-09-16 Codex 감사 지적).
"%GODOT_EXE%" --headless --path . --export-release "Web" build\web\index.html > build\export.log 2>&1
if %ERRORLEVEL% neq 0 (
    type build\export.log
    echo ERROR: web export failed
    exit /b 1
)
REM 패턴 목록의 단일 출처는 scripts/error-patterns.txt다(sh 스크립트도 같은 파일을
REM `grep -F -f`로 읽는다) — 세 곳에 복사해 두면 조용히 갈라진다.
findstr /L /G:scripts\error-patterns.txt build\export.log >nul
if %ERRORLEVEL% equ 0 (
    type build\export.log
    echo ERROR: export log contains script errors ^(exit code was 0 - see above^)
    exit /b 1
)

echo [Step 7] Verifying build artifacts...
REM export가 exit 0이어도 산출물이 비어 있는 경우가 있어 실제 파일을 확인한다.
if not exist build\web\index.html (
    echo ERROR: build\web\index.html missing after export
    exit /b 1
)
dir /b build\web\*.wasm >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: no .wasm in build\web — export produced an incomplete build
    exit /b 1
)

echo [Step 8] Starting server (static + WebSocket) on :%GAME_PORT%...
REM Start-Process로 띄운 프로세스는 GitHub Actions 러너의 Job Object에 묶여
REM job 종료 시 함께 죽는다(connect_dise에서 실측). 작업 스케줄러로 띄우면
REM 러너 job과 무관한 독립 프로세스가 되어 살아남는다.
REM TLS=off로 **스킴을 고정한다.** server/index.js는 인증서가 있으면 자동으로
REM https로 뜨는데(개발 편의), server/certs/는 추적되지 않아 git reset --hard로도
REM 지워지지 않는다 — 배포 서버에 인증서가 한 번 남으면 서버는 정상 기동하는데
REM Step 8의 http 헬스체크만 실패해서 "배포 실패"로 보이고, server_error.log에는
REM 아무 단서가 없다(2026-09-08 Codex 감사 지적). https로 서비스하려면 여기와
REM Step 8의 URL을 함께 바꿔야 한다.
REM
REM ⚠️ `set VAR=값 && cmd` 형태는 **&& 앞 공백까지 값에 포함된다** — TLS가 "off "가
REM 되어 서버의 `!== 'off'` 비교를 통과하고, 이 줄이 있는데도 https로 떴다(리뷰
REM 지적). 그래서 `%GAME_PORT%&&`처럼 공백 없이 붙인다. 서버도 값을 trim해
REM 정규화하므로 한쪽만 어긋나도 동작한다(server/index.js).
schtasks /Create /TN "AnimalsFarmServer" /TR "cmd /c cd /d %cd% && set PORT=%GAME_PORT%&& set TLS=off&& node server\index.js > server.log 2>server_error.log" /SC ONCE /ST 23:59 /F >nul 2>&1
schtasks /Run /TN "AnimalsFarmServer"
if %ERRORLEVEL% neq 0 (
    echo ERROR: schtasks failed to launch server task
    exit /b 1
)

echo [Step 9] Verifying server actually responds...
REM schtasks /Run은 비동기라 node가 시작 직후 크래시해도 여기까지 도달한다 —
REM /healthz가 실제로 200을 주는지 재시도로 확인해야 "배포 성공"이 의미를 가진다.
powershell -Command "$ok=$false; for ($i=0; $i -lt 10; $i++) { try { $r = Invoke-WebRequest -Uri ('http://localhost:' + $env:GAME_PORT + '/healthz') -UseBasicParsing -TimeoutSec 3; if ($r.StatusCode -eq 200) { $ok=$true; break } } catch {} ; Start-Sleep -Seconds 2 }; if (-not $ok) { Write-Host 'ERROR: server did not respond on /healthz (10 tries, up to ~50s)'; exit 1 } else { Write-Host 'Server responded 200 OK' }"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Server health check failed after deploy - see server_error.log
    type server_error.log
    exit /b 1
)

echo ========================================
echo  Deploy complete! (web export + server verified)
echo ========================================
