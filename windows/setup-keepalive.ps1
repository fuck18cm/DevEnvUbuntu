# 注册任务计划: 登录时启动 wsl 并跑 sleep infinity
# 同时把 wslconfig.template 写入 $env:USERPROFILE\.wslconfig
[CmdletBinding()]
param(
  [string]$Distro,        # 不指定则自动检测默认 distro
  [string]$WslUser        # 不指定则在 distro 里跑 whoami 取
)

$ErrorActionPreference = "Stop"

# 校验管理员
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Error "请用管理员权限运行(双击 run-as-admin.bat)"
  exit 1
}

# wsl.exe 默认输出 UTF-16 LE,在 PS5.1 里读出来是乱码;让它走 UTF-8
# (Windows 11 22H2+ / WSL 2.0+ 支持; 旧版本忽略此变量)
$env:WSL_UTF8 = "1"
$prevConsoleOut = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

try {

  # 1) 写 .wslconfig
  $repoRoot = Split-Path -Parent $PSCommandPath
  $src = Join-Path $repoRoot "wslconfig.template"
  $dst = Join-Path $env:USERPROFILE ".wslconfig"
  Copy-Item $src $dst -Force
  Write-Host "[OK] 已写入 $dst"

  # 2) 自动检测 WSL distro 名(用户没显式传 -Distro 时)
  if (-not $Distro) {
    $rawList = & wsl.exe -l -q 2>&1
    $candidates = @()
    foreach ($line in $rawList) {
      $clean = ($line.ToString() -replace "`0", "").Trim()
      # 只接受合法 distro 名: 字母开头, 后面字母/数字/点/横线/下划线
      if ($clean -match '^[A-Za-z][A-Za-z0-9._-]*$') { $candidates += $clean }
    }
    if (-not $candidates) {
      Write-Host "[ERROR] wsl -l -q 没列出任何 distro,原始输出:" -ForegroundColor Red
      $rawList | ForEach-Object { Write-Host "  > $_" }
      Write-Error "找不到 WSL distro。先安装一个: wsl --install -d Ubuntu"
      exit 1
    }
    # 优先选 Ubuntu 系,否则取第一个
    $ubuntuLike = $candidates | Where-Object { $_ -match '^Ubuntu' }
    if ($ubuntuLike) { $Distro = $ubuntuLike[0] } else { $Distro = $candidates[0] }
    Write-Host "[INFO] 检测到 distro 候选: $($candidates -join ', '); 使用: $Distro"
  } else {
    Write-Host "[INFO] 使用指定 distro: $Distro"
  }

  # 3) 决定 wsl 用户
  if (-not $WslUser) {
    $rawUser = & wsl.exe -d $Distro -e whoami 2>&1
    $WslUser = ($rawUser | Out-String).Trim()
  }
  if (-not ($WslUser -match '^[a-z_][a-z0-9_-]*\$?$')) {
    Write-Host "[ERROR] 拿到的 WSL user 不是合法 unix 用户名: '$WslUser'" -ForegroundColor Red
    Write-Host "         如果上面是中文乱码,说明 wsl.exe 输出了中文错误信息(WSL_E_*)" -ForegroundColor Red
    Write-Host "         检查: wsl -l -v   或者手动指定: -Distro <name> -WslUser <user>" -ForegroundColor Red
    Write-Error "无法解析 WSL 用户名"
    exit 1
  }
  Write-Host "[INFO] 目标 distro=$Distro user=$WslUser"

  # 4) 注册任务计划
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

  # 5) 立即跑一次
  Start-ScheduledTask -TaskName $taskName
  Start-Sleep -Seconds 2
  Write-Host "[OK] 任务已触发;从任务管理器应能看到 wsl.exe 进程"

  # 6) 在 WSL 里写标记文件,供 99-verify.sh 读取
  & wsl.exe -d $Distro -u $WslUser -e bash -c "mkdir -p ~/.local/state/devenv && touch ~/.local/state/devenv/windows-keepalive-installed"
  Write-Host "[OK] WSL 端已写入标记文件"

  Write-Host ""
  Write-Host "=== 完成 ===" -ForegroundColor Green
  Write-Host "如需停止保活,删除任务计划 '$taskName' 即可。"

} finally {
  [Console]::OutputEncoding = $prevConsoleOut
}
