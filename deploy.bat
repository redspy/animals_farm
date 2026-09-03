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

echo [Step 1] Stopping server task...
schtasks /Delete /TN "AnimalsFarmServer" /F >nul 2>&1
for /f "tokens=5" %%a in ('netstat -ano ^| findstr :%GAME_PORT% ^| findstr LISTENING') do (
    taskkill /F /PID %%a >nul 2>&1
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
"%GODOT_EXE%" --headless --path . --import
if %ERRORLEVEL% neq 0 (
    echo ERROR: godot --import failed
    exit /b 1
)

echo [Step 4] Exporting Web build...
REM 이전 빌드를 먼저 지운다 — git reset --hard는 추적되지 않는 build/를
REM 지우지 않아서, export가 실패해도 구버전 index.html/.wasm이 남아 Step 5의
REM 산출물 검사를 통과해버릴 수 있었다(2026-09-03 Codex 감사 지적).
if exist build\web rmdir /s /q build\web
mkdir build\web
"%GODOT_EXE%" --headless --path . --export-release "Web" build\web\index.html
if %ERRORLEVEL% neq 0 (
    echo ERROR: web export failed
    exit /b 1
)

echo [Step 5] Verifying build artifacts...
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

echo [Step 6] Starting static server on :%GAME_PORT%...
REM Start-Process로 띄운 프로세스는 GitHub Actions 러너의 Job Object에 묶여
REM job 종료 시 함께 죽는다(connect_dise에서 실측). 작업 스케줄러로 띄우면
REM 러너 job과 무관한 독립 프로세스가 되어 살아남는다.
schtasks /Create /TN "AnimalsFarmServer" /TR "cmd /c cd /d %cd% && set PORT=%GAME_PORT% && node server\index.js > server.log 2>server_error.log" /SC ONCE /ST 23:59 /F >nul 2>&1
schtasks /Run /TN "AnimalsFarmServer"
if %ERRORLEVEL% neq 0 (
    echo ERROR: schtasks failed to launch server task
    exit /b 1
)

echo [Step 7] Verifying server actually responds...
REM schtasks /Run은 비동기라 node가 시작 직후 크래시해도 여기까지 도달한다 —
REM /healthz가 실제로 200을 주는지 재시도로 확인해야 "배포 성공"이 의미를 가진다.
powershell -Command "$ok=$false; for ($i=0; $i -lt 10; $i++) { try { $r = Invoke-WebRequest -Uri ('http://localhost:' + $env:GAME_PORT + '/healthz') -UseBasicParsing -TimeoutSec 3; if ($r.StatusCode -eq 200) { $ok=$true; break } } catch {} ; Start-Sleep -Seconds 2 }; if (-not $ok) { Write-Host 'ERROR: server did not respond on /healthz after 20s'; exit 1 } else { Write-Host 'Server responded 200 OK' }"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Server health check failed after deploy - see server_error.log
    type server_error.log
    exit /b 1
)

echo ========================================
echo  Deploy complete! (web export + server verified)
echo ========================================
