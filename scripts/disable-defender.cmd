@echo off
REM ASCII-only launcher -> runs option 3 (full disable) via PowerShell
setlocal
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo.
  echo   [X] Administrator required.
  echo       Right-click --^> "Run as administrator"
  echo.
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

echo.
echo   ============================================================
echo    Full Defender disable
echo   ============================================================
echo.
set /p GO=  Type YES to confirm:
if /i not "%GO%"=="YES" (
  echo   Cancelled.
  pause
  exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$s = Join-Path '%~dp0' 'windows-security-config.ps1';" ^
  "$c = Get-Content $s -Raw;" ^
  "$c = $c -replace '(?s)while \(\$true\) \{.*$', 'Disable-AllDefender-Batch';" ^
  "Invoke-Expression $c" 

echo.
pause
