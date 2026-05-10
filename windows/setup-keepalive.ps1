# 注册任务计划：登录时启动 wsl 并跑 sleep infinity
# 同时把 wslconfig.template 写入 $env:USERPROFILE\.wslconfig
[CmdletBinding()]
param(
  [string]$Distro = "Ubuntu",
  [string]$WslUser
)

$ErrorActionPreference = "Stop"

# 校验管理员
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Error "请用管理员权限运行（双击 run-as-admin.bat）"
  exit 1
}

# 1) 写 .wslconfig
$repoRoot = Split-Path -Parent $PSCommandPath
$src = Join-Path $repoRoot "wslconfig.template"
$dst = Join-Path $env:USERPROFILE ".wslconfig"
Copy-Item $src $dst -Force
Write-Host "[OK] 已写入 $dst"

# 2) 决定 wsl 用户
if (-not $WslUser) {
  $WslUser = (wsl.exe -d $Distro -e whoami).Trim()
}
Write-Host "[INFO] 目标 distro=$Distro user=$WslUser"

# 3) 注册任务计划
$taskName = "DevEnvUbuntu-WSL-Keepalive"
$action = New-ScheduledTaskAction -Execute "wsl.exe" `
  -Argument "-d $Distro -u $WslUser --exec /bin/bash -lic ""exec sleep infinity"""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest

# 已存在则覆盖
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
Write-Host "[OK] 已注册任务计划: $taskName"

# 4) 立即跑一次
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
Write-Host "[OK] 任务已触发；从任务管理器应能看到 wsl.exe 进程"

# 5) 在 WSL 里写标记文件，供 99-verify.sh 读取
& wsl.exe -d $Distro -u $WslUser -e bash -c "mkdir -p ~/.local/state/devenv && touch ~/.local/state/devenv/windows-keepalive-installed"
Write-Host "[OK] WSL 端已写入标记文件"

Write-Host ""
Write-Host "=== 完成 ===" -ForegroundColor Green
Write-Host "如需停止保活，删除任务计划 '$taskName' 即可。"
