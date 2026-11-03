@echo off
rem ============================================================
rem  AI Pose Gallery / Studio - one click launcher
rem  All args are passed to start.ps1, e.g.:
rem    start.bat -Mode preview -Lan
rem    start.bat -Port 5180 -NoBrowser
rem ============================================================
chcp 65001 >nul
title AI Pose Gallery - Studio
setlocal
cd /d "%~dp0"

set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"

if "%PS%"=="powershell" (
  echo Note: pwsh 7 not found, using Windows PowerShell 5.1 instead.
  echo.
)

"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
set "CODE=%ERRORLEVEL%"

if not "%CODE%"=="0" (
  echo.
  echo [FAILED] exit code %CODE% - see the red message above.
  echo.
  pause
)
exit /b %CODE%
