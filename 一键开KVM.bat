@echo off
chcp 65001 >nul
echo.
echo  ==================================================
echo   XAGA KVM 一键开 KVM（发行版入口）
echo  ==================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-oneclick.ps1" %*
echo.
echo  按任意键退出...
pause >nul
