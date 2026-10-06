@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions
title NoGZ tee 刷入工具 - 开 KVM

set "PS1=%~dp0flash-tee.ps1"

echo.
echo ==================================================================
echo   NoGZ tee 刷入工具  --  给 MTK 手机开 KVM
echo ==================================================================
echo.
echo   用途: 把一个签好名的 tee 补丁刷进 tee_a，让 /dev/kvm 出现
echo.
echo   前置:
echo     - 手机已解锁 Bootloader
echo     - 手机已 root (KernelSU / Magisk)
echo     - 已打开 USB 调试，且电脑上点了"允许"
echo.
echo   ⚠️ 刷完重启后会卡在第二屏 1~2 分钟 -- 这是正常的，等 3 分钟
echo.

if not exist "%PS1%" (
    echo   [XX] 找不到 flash-tee.ps1
    echo        它应该和这个 bat 放在同一个目录里
    echo.
    pause
    exit /b 1
)

if "%~1"=="--help" goto :usage
if "%~1"=="-h"     goto :usage

rem ---- 找 powershell ----
where powershell >nul 2>&1
if errorlevel 1 (
    echo   [XX] 找不到 powershell
    pause
    exit /b 1
)

echo ------------------------------------------------------------------
echo   即将运行 flash-tee.ps1
echo   参数: %*
echo ------------------------------------------------------------------
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set RC=%ERRORLEVEL%

echo.
if "%RC%"=="0" (
    echo ==================================================================
    echo   脚本正常结束
    echo ==================================================================
    echo.
    echo   别忘了：
    echo     重启后卡第二屏是正常的，等 3 分钟
    echo     验证： adb shell su -c "ls -l /dev/kvm"
    echo.
) else (
    echo ==================================================================
    echo   脚本退出码 %RC%  --  上面应该写了原因
    echo ==================================================================
    echo.
)

pause
exit /b %RC%

:usage
echo   用法:
echo     flash-tee.bat                              自动匹配基座，交互确认
echo     flash-tee.bat -Patch tee\tee_nogz_rk_5M.img
echo     flash-tee.bat -Serial 192.168.31.145:33445
echo     flash-tee.bat -SkipFastboot               跳过 fastboot 往返检查
echo     flash-tee.bat -Yes                        全部自动确认（录屏慎用）
echo.
echo   常用场景:
echo     [录课时]  flash-tee.bat
echo              ^  会先问你要不要做 fastboot 往返检查（证明"能救"）
echo.
pause
exit /b 0
