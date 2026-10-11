@echo off
REM ================================================================
REM  DSH Red Team Workstation - Master Installer
REM
REM  THIS FILE IS ASCII-ONLY. DO NOT ADD NON-ASCII CHARACTERS.
REM  cmd.exe parses batch files byte-by-byte using the OEM code page,
REM  ignoring chcp. A UTF-8 multi-byte sequence (Chinese, box-drawing
REM  chars) shifts the parser and swallows line breaks, which makes the
REM  whole script die before it can even reach a pause statement.
REM
REM  All real logic lives in the *.ps1 files (UTF-8 WITH BOM).
REM ================================================================
setlocal EnableExtensions
cd /d "%~dp0"
title DSH Red Team Workstation

set "PS=powershell"
where pwsh >nul 2>&1 && set "PS=pwsh"

REM ---- admin check + self-elevate ----
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo.
  echo   [!] Not running as Administrator.
  echo       Steps 3, 4 and 5 need elevation ^(scheduled tasks, Defender, services^).
  echo.
  choice /C YN /M "   Re-launch elevated"
  if errorlevel 2 goto :menu
  echo   Requesting UAC...
  %PS% -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

:menu
cls
echo.
echo  ================================================================
echo    DSH Red Team Workstation  -  Installer
echo  ================================================================
echo.
echo    [1]  Install plugins into official DSH Desktop
echo    [2]  Deploy red-team toolchain   (15 tools, D: drive)
echo    [3]  Setup phone remote access   (Cloudflare tunnel + PIN)
echo    [4]  Configure Windows Defender  (exclusions / disable)
echo    [5]  Setup self-hosted VPS       (payloads + listeners)
echo    [6]  Verify everything           (read-only)
echo    [7]  Inject DeepSeek adapter prompt
echo.
echo    [A]  RUN ALL  (1 through 7, in order)
echo    [0]  Exit
echo.
set "CH="
set /p "CH=   Choose: "

if /i "%CH%"=="1" call "%~dp0steps-plugins.cmd"   & goto :menu
if /i "%CH%"=="2" call "%~dp0steps-toolchain.cmd" & goto :menu
if /i "%CH%"=="3" call "%~dp0steps-phone.cmd"     & goto :menu
if /i "%CH%"=="4" call "%~dp0steps-defender.cmd"  & goto :menu
if /i "%CH%"=="5" call "%~dp0steps-vps.cmd"       & goto :menu
if /i "%CH%"=="6" call "%~dp0steps-verify.cmd"    & goto :menu
if /i "%CH%"=="7" call "%~dp0steps-prompt.cmd"    & goto :menu
if /i "%CH%"=="A" goto :runall
if "%CH%"=="0" exit /b 0
goto :menu

:runall
cls
echo.
echo   ================================================================
echo     Running steps 1-7
echo   ================================================================
echo.
echo   Step 4 may ask questions about Defender. Step 3 needs Cloudflare
echo   env vars, step 5 needs a VPS. Press Ctrl+C to abort.
echo.
pause

call "%~dp0steps-plugins.cmd"
call "%~dp0steps-toolchain.cmd"
call "%~dp0steps-phone.cmd"
call "%~dp0steps-defender.cmd"
call "%~dp0steps-vps.cmd"
call "%~dp0steps-prompt.cmd"

echo.
echo   ================================================================
echo     Final verification
echo   ================================================================
echo.
call "%~dp0steps-verify.cmd"

echo.
echo   All steps finished. Press any key to return to the menu.
pause >nul
goto :menu
