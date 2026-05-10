# DevEnvUbuntu v2 — 把 clautel 守护交还给 clautel 自带的 systemd 集成

- 日期：2026-05-10
- 关联前文：[2026-05-10-dev-env-installer-design.md](2026-05-10-dev-env-installer-design.md)
- 状态：替换 v1 中的 §5 keepalive 部分

---

## 1. 背景与动机

v1 设计假定 clautel 是个普通 npm CLI，需要我们手写一个 `clautel.service` 把它包成 systemd user service。装完之后用户 [@hbslover] 探到：

```
$ clautel --help | grep -A1 install-service
  install-service    Install as a system service (macOS launchd / Linux systemd)
```

**clautel 自带 `install-service` 子命令，已经支持 Linux systemd**（官网文档站说"only macOS"是 stale 文案）。在用户机器上实测：

- `clautel install-service` 写出的 unit 文件路径是 `~/.config/systemd/user/clautel.service`（systemd user，不是 launchd plist）
- 内容是教科书式 systemd unit：`Type=simple`、`Restart=always`、`Environment=PATH=...` 把所有依赖路径烘焙进去、`WantedBy=default.target`
- `systemctl --user list-unit-files | grep clautel` 显示 `enabled enabled`，`is-active` 返回 `active`

所以 v1 里我们手写的那份 `systemd/clautel.service` 是重复造轮子，且容易跟 clautel 上游分叉（路径变了我们要追改）。本次重设计把这块责任**完全交还给 `clautel install-service`**。

同时重新审视 Windows 侧：

- v1 的 `wsl.exe ... sleep infinity` 是为了"占住进程让 WSL VM 不空闲超时"；但只要 clautel daemon 一直在跑（systemd user service + linger），systemd 自身的 PID 1 + clautel daemon 就保证了 VM 内永远有进程，VM 自然不会空闲超时
- v1 的 `net-keepalive.timer` 只是定时 ping + 写日志，从不主动恢复任何东西，价值低，删
- v1 的 `wsl-keepalive.vbs` + AtLogOn 任务是"启动一次 WSL"，方向对，但缺少"事后掉了怎么办"的机制

新方向：Windows 侧改成**一个任务挂两个 trigger**（AtLogOn + 每 5 分钟），跑同一个 VBS，VBS 自己判断"开机首次"还是"心跳"。

---

## 2. 关键决策（已与用户确认）

| 决策点 | 选择 | 备注 |
|---|---|---|
| Linux 守护进程 | `clautel install-service`（v2 不再手写 unit） | clautel CLI 自带，写出的 unit 比我们手写的更对 |
| Windows 触发频率 | AtLogOn + 每 5 分钟心跳 | 一次冷启动 + 持续巡检 |
| 心跳掉了的动作 | 重新 `wsl.exe ...` 触发；事件追加到本地 heartbeat.log | 不写 Windows 事件日志（实现复杂、用户更习惯看文件） |
| 排他性 | 任务计划 `MultipleInstances=IgnoreNew` + VBS 内 wscript 进程数检查 | 双保险 |
| `loginctl enable-linger` | 保留 | 没登录时 systemd user manager 也跑，clautel 才能在没人 wsl.exe 连着的间隙也活着 |
| `wsl.conf` 写入 `[boot] systemd=true` | 保留 | 前置条件，clautel install-service 依赖 systemd |
| 仓库里 `systemd/` 整目录 | 删除 | 不再分发任何 unit 模板 |
| `net-keepalive.timer/service` | 删除 | 价值低，且与新心跳设计重叠 |

---

## 3. 整体架构

```
┌───────────────────────────────────────────────────────────────┐
│                     Windows 11 宿主                            │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ 任务计划: DevEnvUbuntu-WSL-Keepalive                      │ │
│  │   ├── Trigger 1: AtLogOn (用户登录)                        │ │
│  │   ├── Trigger 2: 每 5 分钟 (开机后 2 分钟首次)              │ │
│  │   ├── Action:    wscript.exe wsl-heartbeat.vbs           │ │
│  │   └── Settings:  Hidden, MultipleInstances=IgnoreNew     │ │
│  └────────────────────────┬─────────────────────────────────┘ │
│                           │ 触发                                │
│                           ▼                                    │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ %LOCALAPPDATA%\DevEnvUbuntu\wsl-heartbeat.vbs            │ │
│  │   1. wscript 自检 (排他性兜底)                              │ │
│  │   2. wsl.exe -e systemctl --user is-active clautel.service│ │
│  │   3. 三态分流:                                             │ │
│  │      active     → 写 [OK] 到 heartbeat.log,退出           │ │
│  │      activating → 写 [INFO],退出                          │ │
│  │      else       → 写 [WARN],触发 wsl 启动 + start service │ │
│  │   4. 大于 1 MB 时滚动 heartbeat.log → heartbeat.log.1     │ │
│  └────────────────────────┬─────────────────────────────────┘ │
│                           │ Run cmd, vbHide=0, no wait        │
│                           ▼                                    │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ wsl.exe -d <distro> -u <user> -e ...                     │ │
│  │   (隐藏窗口启动 distro 或发命令)                             │ │
│  └────────────────────────┬─────────────────────────────────┘ │
└────────────────────────────┼──────────────────────────────────┘
                             │
                             ▼
┌───────────────────────────────────────────────────────────────┐
│                   WSL2 Ubuntu (内核 + systemd)                  │
│  systemd PID 1                                                │
│    └─ user@<uid>.service (lingered)                           │
│         └─ clautel.service (Type=simple, Restart=always)      │
│              └─ node /path/to/clautel/dist/daemon.js          │
│                   └─ Telegram bridge,长跑                       │
└───────────────────────────────────────────────────────────────┘
```

### 持久存在的属性

- **VM 不会空闲超时**：systemd PID 1 + lingered user manager + clautel daemon 任意一个都是常驻进程，WSL2 vmIdleTimeout 永远不会触发
- **clautel singleton**：systemd user service 天然单例，不论开多少 wsl.exe 终端，clautel 只跑一份
- **挂了自动恢复**：clautel daemon 进程崩 → systemd `Restart=always` 自动拉起；WSL VM 整个挂 / 用户 `wsl --shutdown` → 5 分钟内心跳触发新启动

---

## 4. Linux 侧详细设计

### 4.1 仓库变更

**删除**：

```
systemd/clautel.service
systemd/net-keepalive.service
systemd/net-keepalive.timer
systemd/                       # 空目录,一并删
```

**重写** `modules/12-keepalive.sh`（详见 §1 设计稿）：

- 不再 `cp` 任何 systemd unit
- 在 WSL 下确保 `/etc/wsl.conf` 含 `[boot] systemd=true`，没有就写入并提示用户 `wsl --shutdown`
- 检查 `has_systemd`，否则报错退出
- `sudo loginctl enable-linger $USER`
- 清理上一版的 `net-keepalive.{service,timer}`（`disable --now` 后 `rm -f`）
- `require_cmd clautel`（11-clautel 已装）
- 调 `clautel install-service`
- 验证 `systemctl --user is-active clautel.service`

### 4.2 模块顺序

模块编号不变。现在的依赖链：

```
00-detect → 01-base → ... → 06-nvm → 07-node → 11-clautel(npm i -g) → 12-keepalive(clautel install-service)
```

`clautel install-service` 必须在 11-clautel 之后，所以保留 12 的位置。

### 4.3 升级路径（已有 v1 安装的机器）

`12-keepalive.sh` 顶部加一段一次性清理：

```bash
for stale in net-keepalive.service net-keepalive.timer; do
  if systemctl --user is-enabled "$stale" >/dev/null 2>&1; then
    log_info "清理旧 unit: $stale"
    systemctl --user disable --now "$stale" 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/$stale"
  fi
done
systemctl --user daemon-reload
```

`clautel install-service` 会原地覆盖旧的 `~/.config/systemd/user/clautel.service`，不需要单独清。

---

## 5. Windows 侧详细设计

### 5.1 文件结构

```
windows/
├── run-as-admin.bat            # 不变,仍是 UAC 自提权 → 调 ps1
├── setup-keepalive.ps1         # 重写
└── wslconfig.template          # 不变
```

`setup-keepalive.ps1` 在用户机器上**生成**：

```
%LOCALAPPDATA%\DevEnvUbuntu\
├── wsl-heartbeat.vbs           # 唯一 VBS,内含每机生成的 distro/user 常量
└── heartbeat.log               # 心跳日志(运行时累积)
```

不在仓库里；distro / user 在生成时插值，每台机器各自一份。

### 5.2 任务计划

```powershell
$taskName = "DevEnvUbuntu-WSL-Keepalive"
$wscript  = Join-Path $env:SystemRoot "System32\wscript.exe"

$action = New-ScheduledTaskAction -Execute $wscript `
  -Argument ('"{0}"' -f $vbsPath)

$triggerLogon = New-ScheduledTaskTrigger -AtLogOn `
  -User "$env:USERDOMAIN\$env:USERNAME"

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

Register-ScheduledTask -TaskName $taskName `
  -Action $action `
  -Trigger @($triggerLogon, $triggerHeartbeat) `
  -Settings $settings -Principal $principal
```

关键点：

- 一个任务，两个 trigger 数组传入 `-Trigger`
- `MultipleInstances=IgnoreNew` 兜底排他
- 5 分钟 trigger 用 `-Once -At ... -RepetitionInterval`（PowerShell 唯一支持的"开机后周期触发"写法）

### 5.3 wsl-heartbeat.vbs 主流程

伪码：

```vbs
Const DISTRO    = "<生成时插入>"
Const WSL_USER  = "<生成时插入>"
Const SIGNATURE = "DevEnvUbuntu-keepalive:" & DISTRO & ":" & WSL_USER
Const LOG_PATH  = "<生成时插入: %LOCALAPPDATA%\DevEnvUbuntu\heartbeat.log>"
Const MAX_LOG_BYTES = 1048576    ' 1 MB

' 1) 排他兜底: 数 wscript 进程,wsl-heartbeat.vbs 在命令行的, > 1 个就退出
'    (任务计划 MultipleInstances=IgnoreNew 是主防护,这是次防护)

' 2) 日志轮转: heartbeat.log 大于 1MB 时, 滚到 .log.1 (最多 2 档)

' 3) 探活: wsl.exe -d $DISTRO -u $WSL_USER -e systemctl --user is-active clautel.service
'    (这条命令本身会让 WSL distro 启动 — 是探测也是 wakeup)
'    捕获 stdout 与 exit code

' 4) 三态分流:
'    active     → LogLine "OK", "clautel.service active"; 退出
'    activating → LogLine "INFO", "activating, give it time"; 退出
'    其他      → LogLine "WARN", 详情;
'                 sh.Run "wsl.exe -d $D -u $U --exec /bin/bash -lic ""systemctl --user start clautel.service; exit 0  # $SIGNATURE""", 0, False
'                 LogLine "INFO", "boot trigger fired"
```

### 5.4 日志格式

每行：`yyyy-MM-dd HH:mm:ss [LEVEL] message`

levels: `OK` / `INFO` / `WARN`

示例：

```
2026-05-10 21:42:13 [OK]   clautel.service active
2026-05-10 21:47:13 [OK]   clautel.service active
2026-05-10 21:52:13 [WARN] clautel down (status='inactive', exit=3), bootstrapping
2026-05-10 21:52:14 [INFO] boot trigger fired
2026-05-10 21:57:13 [OK]   clautel.service active
```

轮转：单文件 > 1 MB 时整体改名 `heartbeat.log.1`（旧的 `.log.1` 删掉），下一次写 OpenTextFile 创建新文件。

### 5.5 99-verify 集成

`modules/99-verify.sh` 加一段：

```bash
if is_wsl; then
  WIN_USER=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n ')
  WIN_LOG="/mnt/c/Users/${WIN_USER}/AppData/Local/DevEnvUbuntu/heartbeat.log"
  if [[ -f "$WIN_LOG" ]]; then
    last_ok=$(tail -50 "$WIN_LOG" | grep '\[OK\]' | tail -1)
    if [[ -n "$last_ok" ]]; then
      row OK 'wsl-keepalive 心跳' "${last_ok:0:30}..."
    else
      row FAIL 'wsl-keepalive 心跳' '日志里最近没 OK 行,clautel 可能挂了'
    fi
  else
    printf '[%s]  %-22s %s\n' 'TODO' 'wsl-keepalive 心跳' \
      '请到 Windows 端双击 windows\run-as-admin.bat'
  fi
fi
```

直接读 `/mnt/c/...` 路径访问 Windows 文件系统，无需在 Windows 端装额外依赖。

### 5.6 升级路径（已有 v1 keepalive 的机器）

`setup-keepalive.ps1` 顶部加一次性清理：

```powershell
# 杀掉 v1 的 sleep-infinity 长跑进程
Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" -ErrorAction SilentlyContinue | Where-Object {
  $_.CommandLine -match 'exec sleep infinity'
} | ForEach-Object {
  Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

# 删 v1 的 VBS
Remove-Item "$env:LOCALAPPDATA\DevEnvUbuntu\wsl-keepalive.vbs" -Force -ErrorAction SilentlyContinue

# 任务计划同名,Unregister 后 Register 覆盖
Unregister-ScheduledTask -TaskName 'DevEnvUbuntu-WSL-Keepalive' -Confirm:$false -ErrorAction SilentlyContinue
```

---

## 6. 错误处理 / 边界

| 场景 | 行为 |
|---|---|
| WSL 没装/distro 名错 | setup-keepalive.ps1 已自动检测；找不到则报错并打印 wsl -l 输出 |
| systemd 没启用 | 12-keepalive.sh 自动写入 wsl.conf 后提示用户 `wsl --shutdown` 重启再跑一次 |
| `clautel install-service` 失败 | 12-keepalive.sh 退出非零，install.sh 全局 ERR trap 捕获 |
| 心跳期间 WSL 整个被人 `wsl --shutdown` | 下一次 5 分钟心跳的 wsl.exe 自动重新启动 distro，systemd 拉起 clautel |
| clautel daemon 启动后立刻崩 | systemd `Restart=always RestartSec=10` 重试；连续失败 5 次会进 `failed` 状态，下次心跳 `is-active` 返回非 `active` 触发 bootstrap（再走 `systemctl --user start`） |
| clautel license 过期 / 配置不全 | `is-active` 返回 `failed`，心跳每 5 分钟 bootstrap 一次（无害但日志里会持续 WARN）；用户看 heartbeat.log 自然会发现 |
| heartbeat.log 写满 1MB | 自动滚动到 `.log.1`，最多保留 ~2MB 历史 |

---

## 7. 验证

### 自动验证

`99-verify.sh` 输出新的对照行：

```
[OK]  wsl-keepalive 心跳   2026-05-10 21:57:13 [OK]   clautel.service ...
```

### 手工验证（README 列出）

1. 跑 `bash install.sh -y` + Windows 端双击 `run-as-admin.bat`
2. `tail -f /mnt/c/Users/$USER/AppData/Local/DevEnvUbuntu/heartbeat.log` —— 5 分钟内应出现一行 `[OK]`
3. WSL 里 `kill $(pgrep -f 'clautel/dist/daemon.js')`，10 秒后再 `pgrep -f clautel` —— 应有新 PID（systemd 自拉）
4. Windows 上 `wsl --shutdown`，等 5 分钟 —— heartbeat.log 应出现 `[WARN] ... bootstrapping` 接 `[INFO] boot trigger fired`，再下一次 `[OK]`
5. 任务管理器看 `wscript.exe` 与 `wsl.exe` 进程，命令行列里能看到 signature `DevEnvUbuntu-keepalive:<distro>:<user>`

---

## 8. 卸载步骤（README 同步）

```bash
# Linux 侧
clautel uninstall-service                # 卸 systemd unit
sudo loginctl disable-linger $USER       # 取消 lingering(可选)

# Windows 侧 (PowerShell 任意权限)
Unregister-ScheduledTask -TaskName 'DevEnvUbuntu-WSL-Keepalive' -Confirm:$false
Remove-Item "$env:LOCALAPPDATA\DevEnvUbuntu" -Recurse -Force
Remove-Item "$env:USERPROFILE\.wslconfig" -Force        # 如果只服务此项目
```

---

## 9. 不做的事 / 边界声明

- **不写 Windows 事件查看器日志**：实现复杂（注册 source 要 admin），用户更习惯文件 tail
- **不实现"连续 N 次失败弹通知"**：心跳本身已经在 log 里持续 WARN；要再加 toast 通知会引入 BurntToast 模块或 PowerShell 5.1 + Action Center 的复杂度，YAGNI
- **不做心跳间隔可配**：5 分钟够用；要改用户自己 `Set-ScheduledTask` 即可
- **不做多 distro 支持**：v2 同 v1，只服务一个 distro；多 distro 需要重设计 signature/任务命名
