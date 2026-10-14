@echo off
chcp 65001 >nul
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
title zapret2 WARP test agent
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test-warp.ps1" -Agent
echo.
pause
