@echo off
chcp 65001 >nul
REM DevEnvUbuntu - 一键申请管理员权限并执行 setup-keepalive.ps1
fltmc >nul 2>&1
if %errorlevel% neq 0 (
  echo 申请管理员权限...
  powershell -Command "Start-Process -FilePath '%~dpnx0' -Verb RunAs"
  exit /b
)
echo 已是管理员权限,执行 setup-keepalive.ps1...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-keepalive.ps1" %*
echo.
echo === 按任意键关闭 ===
pause >nul
