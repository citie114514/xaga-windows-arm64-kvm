@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-oneclick.ps1" %*
echo.
pause >nul
