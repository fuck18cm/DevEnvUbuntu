# DevEnvUbuntu v2 — clautel systemd handoff 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 `clautel install-service` 替代手写 systemd unit；Windows 侧改成"一个任务 + 两个 trigger（AtLogOn / 5min 心跳）+ 一个智能 VBS"；同时清理 v1 的 keepalive 残留。

**Architecture:** Linux 侧把 daemon 管理彻底交还给 clautel 自己；Windows 侧只负责"开机首次拉起 + 定期巡检 + 掉了重新触发"，所有触发都走 wscript+VBS 隐藏窗口。

**Tech Stack:** Bash / systemd user services / clautel CLI / PowerShell + Windows Task Scheduler / VBScript / WMI

**参考 spec:** [docs/superpowers/specs/2026-05-10-clautel-systemd-handoff-design.md](../specs/2026-05-10-clautel-systemd-handoff-design.md)

---

## 文件结构

```
DevEnvUbuntu/
├── modules/
│   ├── 12-keepalive.sh             # 重写: 不再 cp unit; 调 clautel install-service
│   └── 99-verify.sh                # 增: 读 /mnt/c/.../heartbeat.log 行
├── windows/
│   ├── run-as-admin.bat            # 不变
│   ├── setup-keepalive.ps1         # 重写: 双 trigger、生成 wsl-heartbeat.vbs、清旧
│   └── wslconfig.template          # 不变
├── systemd/                        # ★ 整目录删除
│   ├── clautel.service             # 删
│   ├── net-keepalive.service       # 删
│   └── net-keepalive.timer         # 删
└── README.md                       # 更新架构 + 卸载说明
```

运行时生成（不进 git）：

```
%LOCALAPPDATA%\DevEnvUbuntu\
├── wsl-heartbeat.vbs               # setup-keepalive.ps1 生成
└── heartbeat.log                   # VBS 运行时累积
```

## 测试约定

- **Bash 模块**：`bash -n <file>` 语法检查 + 在 WSL 真机上单跑模块验证
- **PowerShell**：用 `[scriptblock]::Create((Get-Content x.ps1 -Raw))` 解析，不真跑（真跑需要管理员 + WSL）
- **VBS**：用 `cscript //NoLogo //X x.vbs` 语法检查（不实际跑）
- **真机端到端**：必须在你这台 WSL2 + Windows 11 上手工跑一遍 README 列的冒烟步骤

---

## Task 1: 删除仓库里的 `systemd/` 目录

**Files:**
- Delete: `systemd/clautel.service`
- Delete: `systemd/net-keepalive.service`
- Delete: `systemd/net-keepalive.timer`
- Delete: `systemd/` (空目录)

- [ ] **Step 1: 确认要删的文件存在**

```bash
ls -la systemd/
```
Expected: 看到 3 个文件。

- [ ] **Step 2: git rm 三个文件**

```bash
git rm systemd/clautel.service systemd/net-keepalive.service systemd/net-keepalive.timer
```

- [ ] **Step 3: 删空目录**

```bash
rmdir systemd 2>/dev/null || rm -rf systemd
```

- [ ] **Step 4: 确认仓库里已无 systemd 目录**

```bash
ls -la systemd/ 2>&1 | head -3
```
Expected: `ls: cannot access 'systemd/': No such file or directory`

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "chore: drop hand-written systemd templates (clautel install-service replaces them)"
```

---

## Task 2: 重写 `modules/12-keepalive.sh`

**Files:**
- Modify: `modules/12-keepalive.sh`（整体替换）

- [ ] **Step 1: 整体覆盖 `modules/12-keepalive.sh`**

```bash
#!/usr/bin/env bash
# v2: 不再手写 systemd unit, 直接调 clautel install-service.
# 本模块职责: 确保 systemd 启用 + linger + 清旧残留 + clautel install-service.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

# (1) 在 WSL 下确保 /etc/wsl.conf 启用了 systemd
if is_wsl; then
  if ! grep -qE '^\s*systemd\s*=\s*true' /etc/wsl.conf 2>/dev/null; then
    log_info "向 /etc/wsl.conf 写入 [boot] systemd=true"
    sudo tee -a /etc/wsl.conf >/dev/null <<'EOF'

[boot]
systemd=true
EOF
    log_warn "已写入 wsl.conf,需要 wsl --shutdown 后重新打开 WSL 一次再回来跑本模块"
    exit 0
  fi
fi

# (2) systemd 必须在跑
if ! has_systemd; then
  log_error "systemd 未启用 —— 请先 wsl --shutdown 然后重开 WSL 再跑本模块"
  exit 1
fi

# (3) enable-linger: 让 systemd user manager 在你没登录时也能跑
sudo loginctl enable-linger "$USER" 2>/dev/null \
  || log_warn "loginctl enable-linger 失败,可能需要先 sudo 一次让密码缓存"

# (4) 清掉 v1 残留: net-keepalive.timer / .service
for stale in net-keepalive.service net-keepalive.timer; do
  if systemctl --user is-enabled "$stale" >/dev/null 2>&1; then
    log_info "清理 v1 旧 unit: $stale"
    systemctl --user disable --now "$stale" 2>/dev/null || true
  fi
  rm -f "$HOME/.config/systemd/user/$stale"
done
systemctl --user daemon-reload

# (5) 调 clautel install-service (它自己写 unit + enable --now)
require_cmd clautel "请先运行 modules/11-clautel.sh"
log_info "调用 clautel install-service (会写出/覆盖 ~/.config/systemd/user/clautel.service)"
clautel install-service

# (6) 校验
if systemctl --user is-active clautel.service >/dev/null 2>&1; then
  log_info "clautel.service 活跃"
else
  log_warn "clautel.service 未激活,跑 systemctl --user status clautel.service 看原因"
  log_warn "(常见: clautel 未 setup,license 过期,网络问题)"
fi
log_info "Linux 侧 keepalive 就绪 (clautel 由 systemd user service 守护)"
```

- [ ] **Step 2: 语法检查**

```bash
bash -n modules/12-keepalive.sh && echo "syntax OK"
```
Expected: `syntax OK`

- [ ] **Step 3: 确认可执行位**

```bash
git update-index --chmod=+x modules/12-keepalive.sh
git ls-files --stage modules/12-keepalive.sh
```
Expected: 模式 `100755`

- [ ] **Step 4: 在你机器上跑一遍验证幂等**

> 这步必须在 WSL 真机跑,Docker 没 systemd。

```bash
cp /mnt/d/dev_env/DevEnvUbuntu/modules/12-keepalive.sh ~/DevEnvUbuntu/modules/12-keepalive.sh
cd ~/DevEnvUbuntu
bash modules/12-keepalive.sh
```
Expected: 输出包含 `clautel.service 活跃` 和 `Linux 侧 keepalive 就绪`,无报错。
Note: 第二次重跑应该秒过(systemctl --user is-enabled 已 enabled,clautel install-service 自身幂等)。

- [ ] **Step 5: 提交**

```bash
git add modules/12-keepalive.sh
git commit -m "feat(12-keepalive): delegate clautel daemon to clautel install-service

Drops the manual cp of clautel.service / net-keepalive.{service,timer}
in favor of clautel's own install-service subcommand which produces a
better unit file (correct ExecStart node binary, full Environment=PATH,
follows clautel's daemon path conventions).

Module now: writes wsl.conf systemd=true if missing -> requires
systemd active -> enable-linger -> cleans up v1 residue -> calls
clautel install-service -> verifies is-active.

Migration: anyone whose previous v1 run wrote net-keepalive.* to
~/.config/systemd/user/ gets those auto-disabled and removed."
```

---

## Task 3: 重写 `windows/setup-keepalive.ps1`

**Files:**
- Modify: `windows/setup-keepalive.ps1`（整体替换）

- [ ] **Step 1: 用下面这份完整内容覆盖 `windows/setup-keepalive.ps1`**

注意：写入后需要再加 UTF-8 BOM（Step 2 处理）。

```powershell
# DevEnvUbuntu v2: WSL keepalive setup
# 注册任务计划: 一个任务,两个 trigger (AtLogOn + 每 5 分钟),
# 跑同一个 wsl-heartbeat.vbs (智能心跳: active->记日志, 否则触发 boot)
[CmdletBinding()]
param(
  [string]$Distro,        # 不指定则自动检测默认 distro
  [string]$WslUser        # 不指定则在 distro 里 whoami
)

$ErrorActionPreference = "Stop"

# 校验管理员
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Error "请用管理员权限运行(双击 run-as-admin.bat)"
  exit 1
}

# wsl.exe 输出 UTF-8
$env:WSL_UTF8 = "1"
$prevConsoleOut = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

try {

  # === 1) 写 .wslconfig =====================================================
  $repoRoot = Split-Path -Parent $PSCommandPath
  $src = Join-Path $repoRoot "wslconfig.template"
  $dst = Join-Path $env:USERPROFILE ".wslconfig"
  Copy-Item $src $dst -Force
  Write-Host "[OK] 已写入 $dst"

  # === 2) 自动检测 WSL distro ==============================================
  if (-not $Distro) {
    $rawList = & wsl.exe -l -q 2>&1
    $candidates = @()
    foreach ($line in $rawList) {
      $clean = ($line.ToString() -replace "`0", "").Trim()
      if ($clean -match '^[A-Za-z][A-Za-z0-9._-]*$') { $candidates += $clean }
    }
    if (-not $candidates) {
      Write-Host "[ERROR] wsl -l -q 没列出任何 distro,原始输出:" -ForegroundColor Red
      $rawList | ForEach-Object { Write-Host "  > $_" }
      Write-Error "找不到 WSL distro。先安装一个: wsl --install -d Ubuntu"
      exit 1
    }
    $Distro = $candidates | Where-Object { $_ -match '^Ubuntu' } | Select-Object -First 1
    if (-not $Distro) { $Distro = $candidates | Select-Object -First 1 }
    Write-Host "[INFO] 检测到 distro 候选: $($candidates -join ', '); 使用: $Distro"
  } else {
    Write-Host "[INFO] 使用指定 distro: $Distro"
  }

  # === 3) 自动检测 WSL user ================================================
  if (-not $WslUser) {
    $rawUser = & wsl.exe -d $Distro -e whoami 2>&1
    $WslUser = ($rawUser | Out-String).Trim()
  }
  if (-not ($WslUser -match '^[a-z_][a-z0-9_-]*\$?$')) {
    Write-Host "[ERROR] 拿到的 WSL user 不合法: '$WslUser'" -ForegroundColor Red
    Write-Host "         如果上面是中文乱码,说明 wsl.exe 输出了错误信息" -ForegroundColor Red
    Write-Host "         检查: wsl -l -v   或手动 -Distro <name> -WslUser <user>" -ForegroundColor Red
    Write-Error "无法解析 WSL 用户名"
    exit 1
  }
  Write-Host "[INFO] 目标 distro=$Distro user=$WslUser"

  # === 4) 清理 v1 残留 ======================================================
  # 4a) 杀 v1 sleep-infinity 长跑进程
  $existingProcs = Get-CimInstance Win32_Process -Filter "Name = 'wsl.exe'" -ErrorAction SilentlyContinue
  foreach ($ep in $existingProcs) {
    if ($ep.CommandLine -and ($ep.CommandLine -match 'exec sleep infinity')) {
      Write-Host "[INFO] 终止 v1 残留保活进程 PID=$($ep.ProcessId)"
      Stop-Process -Id $ep.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
  # 4b) 删 v1 旧 VBS
  $launcherDir = Join-Path $env:LOCALAPPDATA "DevEnvUbuntu"
  if (-not (Test-Path $launcherDir)) {
    New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
  }
  $oldVbs = Join-Path $launcherDir "wsl-keepalive.vbs"
  if (Test-Path $oldVbs) {
    Remove-Item $oldVbs -Force
    Write-Host "[INFO] 删除 v1 VBS: $oldVbs"
  }

  # === 5) 生成 wsl-heartbeat.vbs ==========================================
  $vbsPath  = Join-Path $launcherDir "wsl-heartbeat.vbs"
  $logPath  = Join-Path $launcherDir "heartbeat.log"
  $signature = "DevEnvUbuntu-keepalive:${Distro}:${WslUser}"

  # PowerShell 字符串里 ` 是 escape, " 用 "" 转义; 用 here-string 简化
  $vbs = @"
' DevEnvUbuntu v2 wsl-heartbeat.vbs
' Auto-generated by setup-keepalive.ps1 - do not edit by hand
Option Explicit

Const DISTRO    = "$Distro"
Const WSL_USER  = "$WslUser"
Const SIGNATURE = "$signature"
Const LOG_PATH  = "$($logPath -replace '\\','\\')"
Const MAX_LOG_BYTES = 1048576    ' 1 MB rotate threshold

' --- helper: 追加一行带时间戳的日志 -----------------------------------------
Sub LogLine(level, msg)
  Dim fso, f
  Set fso = CreateObject("Scripting.FileSystemObject")
  ' rotate if too big
  If fso.FileExists(LOG_PATH) Then
    If fso.GetFile(LOG_PATH).Size > MAX_LOG_BYTES Then
      Dim rotated : rotated = LOG_PATH & ".1"
      If fso.FileExists(rotated) Then fso.DeleteFile rotated, True
      fso.MoveFile LOG_PATH, rotated
    End If
  End If
  Set f = fso.OpenTextFile(LOG_PATH, 8, True)   ' 8=ForAppending
  Dim ts : ts = FormatDateTime(Now, 0)
  f.WriteLine ts & " [" & level & "] " & msg
  f.Close
End Sub

' --- (a) wscript 排他兜底 (任务计划 MultipleInstances=IgnoreNew 是主防护) ---
Dim wmi, procs, p, dupCount, myPid
myPid = -1
On Error Resume Next
Set wmi = GetObject("winmgmts:\\.\root\cimv2")
Set procs = wmi.ExecQuery( _
  "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'wscript.exe'")
dupCount = 0
For Each p In procs
  If Not IsNull(p.CommandLine) Then
    If InStr(p.CommandLine, "wsl-heartbeat.vbs") > 0 Then
      dupCount = dupCount + 1
    End If
  End If
Next
On Error GoTo 0
If dupCount > 1 Then
  ' 已有别的 heartbeat 在跑,我退出 (任何一份都行)
  WScript.Quit 0
End If

' --- (b) 探活: wsl.exe -e systemctl --user is-active clautel.service -------
Dim sh : Set sh = CreateObject("WScript.Shell")
Dim probeCmd, probeExec, statusOutput, exitCode
probeCmd = "wsl.exe -d " & DISTRO & " -u " & WSL_USER & _
           " -e systemctl --user is-active clautel.service"

' Exec 能拿到 ExitCode 和 stdout; cmd.exe 包一层让 stderr 也走管道
Set probeExec = sh.Exec("cmd.exe /c """ & probeCmd & " 2>&1""")
Do While probeExec.Status = 0 : WScript.Sleep 100 : Loop
statusOutput = Trim(probeExec.StdOut.ReadAll())
exitCode = probeExec.ExitCode

' --- (c) 三态分流 ----------------------------------------------------------
If exitCode = 0 And statusOutput = "active" Then
  LogLine "OK", "clautel.service active"
ElseIf statusOutput = "activating" Then
  LogLine "INFO", "clautel.service activating, give it time"
Else
  LogLine "WARN", "clautel down (status='" & statusOutput & "', exit=" & exitCode & "), bootstrapping"

  Dim bootCmd
  bootCmd = "wsl.exe -d " & DISTRO & " -u " & WSL_USER & _
            " --exec /bin/bash -lic ""systemctl --user start clautel.service; exit 0  # " & SIGNATURE & """"

  ' 隐藏窗口启动,不等待
  sh.Run bootCmd, 0, False
  LogLine "INFO", "boot trigger fired"
End If
"@

  # 写文件 (ASCII 即可,不需要 BOM,wscript 都吃)
  $vbs | Set-Content -Path $vbsPath -Encoding Ascii -Force
  Write-Host "[OK] 已生成: $vbsPath"

  # === 6) 注册任务: 一个任务,两个 trigger ==================================
  $taskName = "DevEnvUbuntu-WSL-Keepalive"
  $wscript  = Join-Path $env:SystemRoot "System32\wscript.exe"

  $action = New-ScheduledTaskAction -Execute $wscript `
    -Argument ('"{0}"' -f $vbsPath)

  $triggerLogon = New-ScheduledTaskTrigger -AtLogOn `
    -User "$env:USERDOMAIN\$env:USERNAME"

  # 5 分钟一次心跳: 开机 2 分钟后第一次,然后每 5 分钟 (PowerShell 里 -Once -At + RepetitionInterval 是唯一支持周期触发的写法)
  $triggerHeartbeat = New-ScheduledTaskTrigger `
    -Once -At ((Get-Date).AddMinutes(2)) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)

  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden `
    -MultipleInstances IgnoreNew

  $principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest

  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Register-ScheduledTask -TaskName $taskName `
    -Action $action `
    -Trigger @($triggerLogon, $triggerHeartbeat) `
    -Settings $settings -Principal $principal | Out-Null
  Write-Host "[OK] 已注册任务计划: $taskName (AtLogOn + 5min, MultipleInstances=IgnoreNew)"

  # === 7) 立即触发一次 + 写 WSL 标记 =======================================
  Start-ScheduledTask -TaskName $taskName
  Start-Sleep -Seconds 5
  & wsl.exe -d $Distro -u $WslUser -e bash -c "mkdir -p ~/.local/state/devenv && touch ~/.local/state/devenv/windows-keepalive-installed"
  Write-Host "[OK] WSL 端已写入标记文件"

  # === 8) 自检 =============================================================
  if (Test-Path $logPath) {
    $lastLine = Get-Content $logPath -Tail 1 -ErrorAction SilentlyContinue
    Write-Host "[OK] heartbeat.log 末行: $lastLine"
  } else {
    Write-Host "[WARN] heartbeat.log 还没生成,几分钟后查 $logPath" -ForegroundColor Yellow
  }

  Write-Host ""
  Write-Host "=== 完成 ===" -ForegroundColor Green
  Write-Host "保活机制:"
  Write-Host "  AtLogOn 任务 + 每 5 分钟 -> wscript $vbsPath"
  Write-Host "  VBS 探活 clautel.service: active=记 OK / 否则 systemctl start"
  Write-Host "  日志: $logPath"
  Write-Host ""
  Write-Host "卸载: Unregister-ScheduledTask -TaskName $taskName -Confirm:`$false"
  Write-Host "      Remove-Item '$launcherDir' -Recurse"

} finally {
  [Console]::OutputEncoding = $prevConsoleOut
}
```

- [ ] **Step 2: 加 UTF-8 BOM（PS5.1 读 .ps1 才能正确解码中文）**

```bash
{ printf '\xEF\xBB\xBF'; cat windows/setup-keepalive.ps1; } > /tmp/p1
mv /tmp/p1 windows/setup-keepalive.ps1
head -c 3 windows/setup-keepalive.ps1 | od -c | head -1
```
Expected: `0000000 357 273 277` (即 EF BB BF)

- [ ] **Step 3: PowerShell 语法检查**

> 在 Windows 端 PowerShell 里跑（不需要 admin）

```powershell
$content = Get-Content 'd:\dev_env\DevEnvUbuntu\windows\setup-keepalive.ps1' -Raw
$null = [scriptblock]::Create($content)
Write-Host "PS1 syntax OK"
```
Expected: `PS1 syntax OK`，无 ParserError。

如果你不在 Windows 端，跳过这一步，留待手工测试时再发现。

- [ ] **Step 4: 提交**

```bash
git add windows/setup-keepalive.ps1
git commit -m "feat(windows): v2 keepalive — single task w/ 2 triggers + smart VBS heartbeat

The previous setup ran wsl.exe ... sleep infinity to keep WSL alive.
That's now redundant: clautel install-service installs a Linux systemd
user service that itself keeps a long-running daemon process inside
the distro, so WSL2's vmIdleTimeout never fires (PID 1 + lingered user
manager + clautel daemon all stay running).

This commit replaces the v1 keepalive layout:

  - Drops the wsl-keepalive.vbs (sleep infinity) launcher
  - Generates a wsl-heartbeat.vbs which probes
    \`systemctl --user is-active clautel.service\` and re-triggers
    \`systemctl --user start clautel.service\` if down
  - Single Scheduled Task with TWO triggers (AtLogOn + repeating
    every 5 minutes), MultipleInstances=IgnoreNew for exclusivity
  - Logs each heartbeat to %LOCALAPPDATA%\\DevEnvUbuntu\\heartbeat.log
    with size-based rotation (>1MB rolls to .log.1)
  - Migrates v1 users: kills any leftover sleep-infinity wsl.exe
    processes and removes the v1 VBS file"
```

---

## Task 4: 更新 `modules/99-verify.sh`

**Files:**
- Modify: `modules/99-verify.sh`

- [ ] **Step 1: 替换 `is_wsl` 那块旧的 wsl-keepalive 检查**

打开 `modules/99-verify.sh`，找到这段（约第 53-59 行）：

```bash
if is_wsl; then
  if [[ -f "$HOME/.local/state/devenv/windows-keepalive-installed" ]]; then
    row OK 'wsl-keepalive 任务' '已注册(标记文件存在)'
  else
    # Windows 端待办,不是 Linux 侧能修的,标 TODO 不计入 FAIL
    printf '[%s]  %-22s %s\n' 'TODO' 'wsl-keepalive 任务' '请到 Windows 端双击 windows\run-as-admin.bat'
  fi
fi
```

替换为：

```bash
if is_wsl; then
  if [[ -f "$HOME/.local/state/devenv/windows-keepalive-installed" ]]; then
    row OK 'wsl-keepalive 任务' '已注册(标记文件存在)'

    # 进一步: 读 Windows 侧 heartbeat.log 看最近一次状态
    WIN_USER=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n ')
    WIN_LOG="/mnt/c/Users/${WIN_USER}/AppData/Local/DevEnvUbuntu/heartbeat.log"
    if [[ -f "$WIN_LOG" ]]; then
      last_line=$(tail -50 "$WIN_LOG" 2>/dev/null | grep -E '\[(OK|INFO|WARN)\]' | tail -1 || true)
      if [[ "$last_line" == *"[OK]"* ]]; then
        row OK 'wsl-keepalive 心跳' "${last_line:0:40}"
      elif [[ "$last_line" == *"[INFO]"* ]]; then
        row OK 'wsl-keepalive 心跳' "${last_line:0:40}"
      elif [[ "$last_line" == *"[WARN]"* ]]; then
        printf '[%s]  %-22s %s\n' 'WARN' 'wsl-keepalive 心跳' "${last_line:0:60}"
        FAIL=$((FAIL+1))
      else
        printf '[%s]  %-22s %s\n' 'TODO' 'wsl-keepalive 心跳' '日志还没行,等 5 分钟再看'
      fi
    else
      printf '[%s]  %-22s %s\n' 'TODO' 'wsl-keepalive 心跳' '日志文件未生成'
    fi
  else
    # Windows 端待办,不是 Linux 侧能修的,标 TODO 不计入 FAIL
    printf '[%s]  %-22s %s\n' 'TODO' 'wsl-keepalive 任务' '请到 Windows 端双击 windows\run-as-admin.bat'
  fi
fi
```

- [ ] **Step 2: 语法检查**

```bash
bash -n modules/99-verify.sh && echo "syntax OK"
```
Expected: `syntax OK`

- [ ] **Step 3: 在你机器上跑一遍**

```bash
cp /mnt/d/dev_env/DevEnvUbuntu/modules/99-verify.sh ~/DevEnvUbuntu/modules/99-verify.sh
bash ~/DevEnvUbuntu/modules/99-verify.sh
```
Expected: 多了一行 `[OK] wsl-keepalive 心跳 ...` 或 `[TODO] wsl-keepalive 心跳 日志文件未生成`，整体 `FAIL=0`。

- [ ] **Step 4: 提交**

```bash
git add modules/99-verify.sh
git commit -m "feat(verify): read Windows heartbeat.log via /mnt/c for liveness check

Adds a second WSL-only check that tails
/mnt/c/Users/<USER>/AppData/Local/DevEnvUbuntu/heartbeat.log and
classifies the most recent line as OK/WARN/TODO. The dashboard now
shows whether the 5-minute heartbeat is actually firing on Windows
side without leaving the Linux terminal."
```

---

## Task 5: 更新 `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 找到 Windows 端那一节，替换为 v2 描述**

搜索：

```markdown
## Windows 端（仅 WSL2 用户）

完成 Linux 端安装后：
```

把整个 "## Windows 端" 直到 "## 验证" 之前的部分替换为：

```markdown
## Windows 端（仅 WSL2 用户）

完成 Linux 端安装后：

1. 在文件资源管理器中找到 `windows\run-as-admin.bat`，**双击**
2. UAC 弹窗 → 同意（脚本会自动以管理员重启）
3. 看到 "=== 完成 ===" 即成功

这一步会：

- 写入 `%USERPROFILE%\.wslconfig`（防止 WSL 空闲超时关闭）
- 在 `%LOCALAPPDATA%\DevEnvUbuntu\` 生成 `wsl-heartbeat.vbs`（按本机 distro/user 渲染）
- 注册 Windows 任务计划 `DevEnvUbuntu-WSL-Keepalive`，**两个 trigger**：
  - `AtLogOn` —— 用户登录时跑一次（冷启动 WSL）
  - 每 5 分钟一次心跳 —— 跑 wscript 调用 VBS，VBS 探 clautel.service 状态
- 心跳记录到 `%LOCALAPPDATA%\DevEnvUbuntu\heartbeat.log`（>1MB 自动轮转）

### 心跳行为

| 探到 | 动作 |
|---|---|
| `clautel.service active` | 写一行 `[OK]` 到日志，退出 |
| `clautel.service activating` | 写 `[INFO]`，退出（systemd 重启窗口期，不打扰） |
| 其他（inactive / failed / WSL 没起） | 写 `[WARN]` 详情，触发 `wsl ... systemctl --user start clautel.service`，再写一行 `[INFO] boot trigger fired` |

任务计划 `MultipleInstances=IgnoreNew` 保证两个 trigger 撞上时只跑一份；VBS 内 wscript 进程数检查作兜底。

```

- [ ] **Step 2: 找到 "## 卸载/清理" 那一节，更新为 v2 卸载步骤**

替换 "## 卸载/清理" 整段为：

```markdown
## 卸载/清理

```bash
# Linux 侧
clautel uninstall-service                # 卸 systemd unit
sudo loginctl disable-linger $USER       # 取消 lingering(可选)
rm -rf ~/.sdkman ~/.nvm ~/.pyenv         # 卸 SDKMAN/nvm/pyenv 本体
sed -i '/# >>> DevEnvUbuntu /,/# <<< DevEnvUbuntu /d' ~/.bashrc   # 清 bashrc 注入块
npm uninstall -g @anthropic-ai/claude-code clautel
```

```powershell
# Windows 侧
Unregister-ScheduledTask -TaskName 'DevEnvUbuntu-WSL-Keepalive' -Confirm:$false
Remove-Item "$env:LOCALAPPDATA\DevEnvUbuntu" -Recurse -Force
Remove-Item "$env:USERPROFILE\.wslconfig" -Force      # 如果只服务此项目
```

```

- [ ] **Step 3: 提交**

```bash
git add README.md
git commit -m "docs: README sync with v2 keepalive architecture

Documents the new AtLogOn + 5-min-heartbeat task, the smart VBS that
probes clautel.service via systemctl is-active, the heartbeat.log
location, and the 3-state classification (OK/INFO/WARN). Updates the
uninstall section to reference \`clautel uninstall-service\` instead
of removing hand-written systemd files."
```

---

## Task 6: 端到端冒烟测试（在你机器上手动跑）

**Files:** 无修改，纯验证

- [ ] **Step 1: 同步整个仓库到 WSL**

```bash
rsync -av --delete /mnt/d/dev_env/DevEnvUbuntu/ ~/DevEnvUbuntu/
cd ~/DevEnvUbuntu
ls systemd 2>&1
```
Expected: `ls: cannot access 'systemd': No such file or directory`（确认 systemd/ 已删）

- [ ] **Step 2: 在 WSL 跑 12-keepalive 一次**

```bash
bash modules/12-keepalive.sh 2>&1 | tail -10
```
Expected: 末尾包含 `clautel.service 活跃` 和 `Linux 侧 keepalive 就绪`。

- [ ] **Step 3: 验证 net-keepalive 残留已清掉**

```bash
ls ~/.config/systemd/user/net-keepalive* 2>&1
systemctl --user list-unit-files | grep net-keepalive 2>&1
```
Expected: 第一条 "No such file or directory"，第二条无输出（unit 已 disable + remove）。

- [ ] **Step 4: 验证 clautel.service 还在跑**

```bash
systemctl --user is-active clautel.service
systemctl --user status clautel.service --no-pager | head -10
```
Expected: `active`；status 头几行显示 enabled + active + ExecStart 是 clautel 自己装的版本（路径含 `/dist/daemon.js`）。

- [ ] **Step 5: 在 Windows 端双击 `windows\run-as-admin.bat`**

UAC → 是。看输出：
```
[OK] 已写入 ...wslconfig
[INFO] 检测到 distro 候选: Ubuntu-24.04; 使用: Ubuntu-24.04
[INFO] 目标 distro=Ubuntu-24.04 user=hbslover
[INFO] 终止 v1 残留保活进程 PID=...   ← 如果之前有 v1
[OK] 已生成: C:\Users\...\AppData\Local\DevEnvUbuntu\wsl-heartbeat.vbs
[OK] 已注册任务计划: DevEnvUbuntu-WSL-Keepalive (AtLogOn + 5min, MultipleInstances=IgnoreNew)
[OK] WSL 端已写入标记文件
[OK] heartbeat.log 末行: 2026-05-10 ... [OK] clautel.service active
=== 完成 ===
```

按任意键关闭。

- [ ] **Step 6: 验证心跳真的在跑**

回到 WSL：

```bash
WIN_USER=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n ')
tail -f /mnt/c/Users/${WIN_USER}/AppData/Local/DevEnvUbuntu/heartbeat.log
```
Expected: 当前已有 1-2 行 `[OK] clautel.service active`。等 5 分钟应再加一行。Ctrl+C 退出 tail。

- [ ] **Step 7: 测崩溃自恢复**

```bash
# 杀掉 clautel daemon 进程
sudo pkill -f 'clautel/dist/daemon.js'
sleep 12
# 看 systemd 是否自动拉起
systemctl --user is-active clautel.service
# 应该是 active (Restart=always RestartSec=10 在 12 秒内重新拉)
```
Expected: `active`

- [ ] **Step 8: 测 wsl --shutdown 后心跳恢复**

```powershell
# Windows PowerShell 跑
wsl --shutdown
# 等 5-6 分钟,等心跳触发恢复
Start-Sleep 360
# 看 wsl 是否被心跳重新拉起
wsl.exe -d Ubuntu-24.04 -e systemctl --user is-active clautel.service
```
Expected: `active` (心跳检测到 wsl 没起,自动调 wsl.exe boot,clautel.service 跟着起)。

- [ ] **Step 9: 跑 99-verify 看最终 dashboard**

```bash
bash ~/DevEnvUbuntu/modules/99-verify.sh
```
Expected: `PASS=14 FAIL=0` 类似（多了一行 `wsl-keepalive 心跳`），全 OK。

- [ ] **Step 10: 这一任务无 commit（验证步骤）**

如果上面任何一步失败，把日志贴回来一起调。

---

## 自检（Plan Self-Review）

**Spec coverage 对照：**

| Spec section | Plan task |
|---|---|
| §1 背景 / §2 决策 | 不需要任务,是设计文档 |
| §3 整体架构 | Task 2 (Linux) + Task 3 (Windows) |
| §4 Linux 侧详细 | Task 1 (删 systemd/) + Task 2 (重写 12-keepalive) |
| §5.1 windows/ 文件结构 | Task 3 (重写 setup-keepalive.ps1) |
| §5.2 任务计划双 trigger | Task 3 Step 1 §6 |
| §5.3 wsl-heartbeat.vbs 主流程 | Task 3 Step 1 §5 (VBS 生成块) |
| §5.4 日志格式与轮转 | Task 3 Step 1 §5 (LogLine + rotate) |
| §5.5 99-verify 集成 | Task 4 |
| §5.6 升级路径(Windows 侧) | Task 3 Step 1 §4 (清 v1 残留) |
| §6 错误处理 / 边界 | Task 2 + Task 3 各处实现 |
| §7 验证 | Task 6 |
| §8 卸载步骤 | Task 5 (README 更新) |

**Placeholder 扫描：** 全部步骤都有完整代码或命令，无 TBD。

**类型一致性：** signature 字符串在 Task 3 步骤 1 §5 (PS 端 `${signature}`) 与 VBS 内 `Const SIGNATURE` 一致；`logPath` 在 PS 与 VBS 间通过 here-string 转义传递。`taskName` 字符串在 PS 注册段、卸载提示、README 卸载段一致。`heartbeat.log` 路径在 VBS、99-verify、README 三处使用相同布局 `%LOCALAPPDATA%\DevEnvUbuntu\heartbeat.log` / `/mnt/c/Users/$USER/AppData/Local/DevEnvUbuntu/heartbeat.log`。
