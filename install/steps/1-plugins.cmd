@echo off
REM ASCII-ONLY launcher. Real logic is in 1-plugins.ps1 (UTF-8 BOM).
setlocal
cd /d "%~dp0.."

set "PS=powershell"
where pwsh >nul 2>&1 && set "PS=pwsh"

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo   [!] Administrator required for this step.
  echo       Requesting UAC...
  %PS% -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

%PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp01-plugins.ps1"
set RC=%errorlevel%
if not "%RC%"=="0" (
  echo.
  echo   [xx] exited with code %RC%
  pause
)
