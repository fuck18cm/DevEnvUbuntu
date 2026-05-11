# VM Holder：用持续在线的 wsl.exe 子进程取代 5min 轮询心跳

**Status:** Draft
**Author:** hbslover / Claude
**Date:** 2026-05-11
**Supersedes section of:** [2026-05-10-clautel-systemd-handoff-design.md](2026-05-10-clautel-systemd-handoff-design.md)、[2026-05-11-keepalive-prelogin-startup-design.md](2026-05-11-keepalive-prelogin-startup-design.md)

---

## 1. 问题

v2 (clautel-systemd-handoff) 的设计假设：`vmIdleTimeout=2147483647` + `loginctl enable-linger` + `clautel install-service` + 每 5min 心跳 = clautel 24/7 在线。

实测在 Windows 11 Home (build 26200) + WSL 2.7.3.0 + Ubuntu-24.04 上，**这个假设不成立**。

### 1.1 用户观测的症状

「我刚启动系统的时候，clautel 绑定的机器人可以回消息，但是在几分钟后就无法回消息了。之后我进系统启动 WSL 后，又可以回消息了。」

### 1.2 表象与真相的偏差

`%LOCALAPPDATA%\DevEnvUbuntu\heartbeat.log` 长时间显示每 5min 一条 `[OK] clautel.service active`，看起来一切正常。

但 `journalctl --user -u clautel.service` 显示真实情况：每次心跳都触发一次完整的 `Started → 16 秒后 Stopping → Stopped` 循环：

```
08:15:33 Started clautel.service
08:15:48 Stopping clautel.service        # 15s 后被停
08:16:29 Started clautel.service
08:16:45 Stopping clautel.service        # 16s 后被停
08:21:29 Started ... 08:21:45 Stopping
08:25:00 Started ... 08:25:16 Stopping
08:26:29 Started ...                     # 当前实例
```

外加 `-- Boot <uuid> --` 行表明 systemd user manager 多次销毁重建。同时 `uptime --since` 显示 WSL VM 仅 13 分钟 uptime，但 heartbeat.log 显示心跳已连续运行 9.5+ 小时——证明 VM **在两次心跳之间反复关停**。

### 1.3 真相

1. VBS 心跳每 5min 跑 `wsl.exe ... systemctl --user is-active clautel.service`
2. 这个 wsl.exe 调用拉起 VM → systemd user manager 起 → enable-linger 让 clautel.service 自动起 → systemctl 报 `active` → VBS 写 `[OK]`
3. **wsl.exe 调用结束后 ~16s**，VM 因为没有任何 wsl.exe 客户端 attach 而被关停（vmIdleTimeout=INT_MAX 未生效，疑似 WSL 2.7 行为/上限问题，本 spec 不深究底层原因）
4. VM 关停时 systemd 给 clautel.service 发 SIGTERM，clautel 优雅退出 (`Shutting down...`)
5. 接下来 ~4min 30s 里 clautel 进程不存在，Telegram 三条 TLS 长连接断开（observed: ESTAB 到 149.154.166.110:443）
6. 用户在这 4min 30s 里发的消息躺在 Telegram 服务端、没人取
7. 下次心跳来又重新一遍 1-6

心跳记录的 `[OK]` 是真的，但只覆盖每 5min 周期里的 ~16 秒——业务可用率约 **5%**，不是 100%。

clautel 自身完全无问题：日志显示业务流程正常（收消息、query Claude、回复），重启序列干净（无 retry/backoff），SIGTERM 是 systemd 在 VM 关停前清扫所有 service 发的优雅信号。

---

## 2. 改动概要

抛弃"5min 轮询拉起"这条路线，改为**让 Windows 侧始终持有一个 `wsl.exe --exec /bin/sleep infinity` 子进程**——给 WSL VM 一个永久 attach 的客户端，VM 因此始终活着，clautel.service 因此 24/7 在线。

合并现有"5min 心跳"任务进新的"VM Holder"任务，所有 keepalive 逻辑集中到一个 VBS、一个任务、一个日志文件。

---

## 3. 架构

### 3.1 任务计划

| 任务名 | 状态 | 说明 |
|---|---|---|
| `DevEnvUbuntu-WSL-Keepalive` | **删除** | 原 5min 心跳任务 |
| `DevEnvUbuntu-WSL-VMHolder` | **新增** | AtStartup 触发一次,内部 do-while 永不退出 |

`DevEnvUbuntu-WSL-VMHolder` 配置：

```
Trigger:           AtStartup (单一 trigger,没有 5min 心跳)
Principal:         hbslo, S4U logon, RunLevel=Highest
Action:            wscript.exe "%LOCALAPPDATA%\DevEnvUbuntu\vm-holder.vbs"
MultipleInstances: IgnoreNew (任务计划层面的排他)
RestartOnFailure:  Count=∞, Interval=30s (VBS 异常退出时由任务计划兜底重启)
```

### 3.2 运行时文件

```
%LOCALAPPDATA%\DevEnvUbuntu\
├── vm-holder.vbs        # 新增:setup-keepalive.ps1 here-string 生成
├── holder.log           # 新增:统一日志(取代 heartbeat.log)
├── holder.log.1         # >1MB 自动轮转
├── wsl-heartbeat.vbs    # **删除**(已合并)
└── heartbeat.log        # **保留但不再写入**(留作历史归档,setup 时不删)
```

### 3.3 vm-holder.vbs 内部逻辑

VBS 没有原生线程，且 `WshShell.Exec` 因 SW_SHOWNORMAL 限制会闪黑窗（见 [keepalive-hide-probe-window-design](2026-05-10-keepalive-hide-probe-window-design.md)），因此持有用 `WshShell.Run cmd, 0, False` (vbHide, fire-and-forget) spawn、靠 WMI 查 `wsl.exe` 命令行签名做存活检测；探活也走 `Run + cmd.exe` 重定向 + 临时文件，跟当前 `wsl-heartbeat.vbs` 完全一致。

```vbs
' --- 全局常量 (这一段由 setup-keepalive.ps1 here-string 填入) ---
Const DISTRO       = "Ubuntu-24.04"
Const WSL_USER     = "<wsl-user>"
Const LOG_PATH     = "<%LOCALAPPDATA%>\DevEnvUbuntu\holder.log"
Const HOLDER_SIG   = "DevEnvUbuntu-vm-holder-sleep-infinity"
Const PROBE_TMP    = "<%LOCALAPPDATA%>\DevEnvUbuntu\probe.tmp"
Const MAX_LOG_BYTES = 1048576    ' 1 MB rotate

' --- 启动时一次 ---
' wscript 排他兜底 (WMI 查 wscript.exe 跑 vm-holder.vbs 的实例数, >1 则退出)
LogLine "INFO", "vm-holder started, pid=" & WScript.PID

' --- 持有 + 监控主循环 ---
Dim sh : Set sh = CreateObject("WScript.Shell")
Dim holdCmd
' 用 bash -c 注入签名注释,Windows 侧 WMI 能在 wsl.exe CommandLine 看到 HOLDER_SIG
holdCmd = "wsl.exe -d " & DISTRO & " -u " & WSL_USER & _
          " -e /bin/bash -c ""exec /bin/sleep infinity # " & HOLDER_SIG & """"

Do While True
    ' (a) 检查持有进程是否还活着 (WMI 查 wsl.exe CommandLine 含 HOLDER_SIG)
    If Not IsHolderAlive() Then
        LogLine "WARN", "holder child not found, respawning"
        sh.Run holdCmd, 0, False   ' 0=vbHide, False=fire-and-forget
        LogLine "INFO", "vm holder attached (sleep infinity spawned)"
        WScript.Sleep 10000  ' 给 wsl.exe attach + VM cold start (首次 AtStartup 触发可能慢)
    End If

    ' (b) 探活 clautel.service: 完全沿用 wsl-heartbeat.vbs 的 Run+tempfile 方式
    Dim coreCmd, probeCmd, exitCode, statusOutput
    coreCmd  = "wsl.exe -d " & DISTRO & " -u " & WSL_USER & _
               " -e systemctl --user is-active clautel.service"
    probeCmd = "cmd.exe /c """ & coreCmd & " > """ & PROBE_TMP & """ 2>&1"""
    exitCode = sh.Run(probeCmd, 0, True)   ' 0=vbHide, True=同步等待
    statusOutput = ReadAndDeleteProbeTemp()

    ' (c) 三态分流
    If exitCode = 0 And statusOutput = "active" Then
        LogLine "OK", "clautel.service active"
    ElseIf statusOutput = "activating" Then
        LogLine "INFO", "clautel.service activating, give it time"
    Else
        LogLine "WARN", "clautel down (status='" & statusOutput & _
                         "', exit=" & exitCode & "), bootstrapping"
        Dim bootCmd
        bootCmd = "wsl.exe -d " & DISTRO & " -u " & WSL_USER & _
                  " -e systemctl --user start clautel.service"
        sh.Run bootCmd, 0, False
        LogLine "INFO", "boot trigger fired"
    End If

    ' (d) 睡 5 分钟
    WScript.Sleep 300000
Loop

' --- helpers ---
' Function IsHolderAlive(): WMI query Win32_Process where Name='wsl.exe' 
'   and CommandLine LIKE '%<HOLDER_SIG>%' → return True if any match.
' Sub LogLine(level, msg): FSO append + 1MB rotate (参考 setup-keepalive.ps1:106-121 in git history).
' Function ReadAndDeleteProbeTemp(): FSO ReadAll + DeleteFile, 剥换行后返回.
```

关键点：

- **持有用 `Run cmd, 0, False` (vbHide, fire-and-forget)**:不是 `WshShell.Exec`。Exec 强制 SW_SHOWNORMAL 会闪黑窗，由 [keepalive-hide-probe-window-design](2026-05-10-keepalive-hide-probe-window-design.md) 实测确认。
- **存活检测靠 WMI + 命令行签名**:Run 拿不到子进程 handle，所以用 `Win32_Process` 查命令行含 `HOLDER_SIG` 的 `wsl.exe`。签名通过 `bash -c "exec /bin/sleep infinity # <sig>"` 注入到 wsl.exe 的命令行参数里（`#` 之后是 shell 注释，对 sleep 无副作用）。
- **探活完全沿用旧 heartbeat 模式**: `cmd.exe /c "... > probe.tmp 2>&1"` + `Run cmd, 0, True` + 读 probe.tmp，逐字与 wsl-heartbeat.vbs 探活段(由 [windows/setup-keepalive.ps1](../../../windows/setup-keepalive.ps1) 行 144-188 生成) 一致 — 包括 `vbCrLf/vbLf/vbCr` 剥离。
- **bootstrap 在 holder 模式下应是无路可走的**:VM 一直在,clautel 不会被 SIGTERM。如果还是看到 [WARN] bootstrapping,说明 clautel 自身配置出错（license/network/auth）,这时让心跳照样写 [WARN] 提供线索,跟 v2 行为一致。

### 3.4 双层兜底

| 层 | 触发 | 动作 |
|---|---|---|
| 内层 (VBS 自身) | `IsHolderAlive() = False` (WMI 找不到含 HOLDER_SIG 的 wsl.exe) | `Run holdCmd, 0, False` 重新 spawn sleep infinity |
| 外层 (任务计划) | wscript.exe 进程崩溃 | `RestartOnFailure Count=∞ Interval=30s` 重新拉起整个 VBS |

如果 WSL 整体故障(比如 LxssManager 服务挂了)导致 sleep infinity 持续 spawn 失败,VBS 不会无限快速 spawn——主循环固定 5 分钟节奏(`WScript.Sleep 300000` 在每轮尾部),内层重 spawn 跟着这个节奏走,最快也是每 5 分钟一次,不会 fork bomb。

---

## 4. 改动范围

仅一个文件的代码改动 + 文档:

### 4.1 `windows/setup-keepalive.ps1`

| 区段 | 改动 |
|---|---|
| 行 88-102 (生成 wsl-heartbeat.vbs 的 here-string) | **整段删除** |
| 行 88 起替换为 | 新增 vm-holder.vbs here-string (含 §3.3 逻辑,DISTRO/WSL_USER/LOG_PATH 仍由 PS 烘焙) |
| 行 ~200 注册 ScheduledTask 那段 | 任务名 `DevEnvUbuntu-WSL-Keepalive` → `DevEnvUbuntu-WSL-VMHolder`;triggers 数组从 `@($triggerStartup, $triggerHeartbeat)` 改为 `@($triggerStartup)`;新增 `Settings.RestartOnFailure` |
| 清理段(行 68-86) | 增加:删旧任务 `DevEnvUbuntu-WSL-Keepalive` (如果存在);删旧 VBS `wsl-heartbeat.vbs` (如果存在);不删 `heartbeat.log` (留作历史) |
| 立即触发 + 自检(行 ~226-238) | `Start-ScheduledTask` 改任务名;读末行从 heartbeat.log 改成 holder.log |
| 末尾提示文案 | "AtStartup + 5min (S4U)" → "AtStartup, persistent (S4U, holds wsl.exe child)" |

### 4.2 `modules/99-verify.sh`

第 57-65 行的 heartbeat.log 末行读取逻辑改成读 holder.log:

```bash
WIN_LOG="/mnt/c/Users/${WIN_USER}/AppData/Local/DevEnvUbuntu/holder.log"
# 兼容旧用户: 如果 holder.log 不存在但 heartbeat.log 存在, 提示用户重跑 run-as-admin.bat 升级
if [[ ! -f "$WIN_LOG" && -f "/mnt/c/Users/${WIN_USER}/AppData/Local/DevEnvUbuntu/heartbeat.log" ]]; then
    log_warn "检测到旧 v2 keepalive (只有 heartbeat.log),请在 Windows 上重跑 run-as-admin.bat 升级到 v3 VM holder"
fi
```

### 4.3 文档同步

- `README.md` 的"始终在线"段:trigger 描述从"AtStartup + 5min 心跳"改成"AtStartup 一次 + VBS 内部持有 wsl.exe 子进程,VM 24/7 在线";心跳日志路径从 heartbeat.log 改成 holder.log
- `CLAUDE.md` 的"始终在线"架构 (v2 - 只在 WSL 下完整生效) 小节:整体重写以反映 VM holder 模式;改名为 (v3 - VM 持续在线模式)
- `docs/superpowers/specs/2026-05-10-clautel-systemd-handoff-design.md` 末尾 § 修订记录:加一条指向本 spec,说明轮询心跳被替换为持有式
- `docs/superpowers/specs/2026-05-11-keepalive-prelogin-startup-design.md` 末尾加 § 修订记录:说明 AtStartup + S4U 模式被本 spec 继承(任务名变了,但 trigger 模型一致)

### 4.4 设计上不动

- `modules/12-keepalive.sh` (Linux 侧 systemd + linger + clautel install-service):**不动**。Linux 侧只要 VM 活着就正确。
- `windows/wslconfig.template` (`vmIdleTimeout=2147483647`):**保留**。属于无害冗余;真出现 holder 短暂掉、idle timeout 还能扛一会儿。
- `clautel.service` unit 文件本身的 PATH 引号问题:**不在本 spec 范围**,属于 clautel 上游 install-service 命令的 bug,反馈给 clautel 项目即可,不影响在线性。

---

## 5. 验证方案

### 5.1 安装后立即(setup-keepalive.ps1 末尾自检)

PS 脚本末尾跑 `Start-ScheduledTask DevEnvUbuntu-WSL-VMHolder`,等 10 秒,读 `holder.log` 末 3 行,预期看到:

```
... [INFO] vm-holder started, pid=N
... [INFO] vm holder attached (sleep infinity spawned)
... [OK] clautel.service active
```

### 5.2 持续在线验证(人工,需用户重启 + 等 1 小时)

1. Windows 管理员 PowerShell: `wsl --shutdown`
2. 重启 Windows
3. **开机后停在锁屏 5 分钟,不要登录**(验证 AtStartup + S4U + 持有逻辑在登录前就生效)
4. 登录后立即在 WSL 里跑:
   ```bash
   uptime --since                                                       # 预期: 时间戳接近 Windows 开机时刻
   systemctl --user is-active clautel.service                           # 预期: active
   systemctl --user show clautel.service -p NRestarts                   # 预期: NRestarts=0
   journalctl --user -u clautel.service | grep -c 'Stopping'            # 预期: 0 (或仅启动初的极少数)
   tail -10 /mnt/c/Users/<你>/AppData/Local/DevEnvUbuntu/holder.log
   # 预期: 每 5min 一条 [OK],无 [WARN]
   ```
5. **业务验证**:间隔 10 分钟、30 分钟、1 小时各发一条 Telegram 消息给机器人,**全部都应该立即被回**(无延迟、无失败)
6. 1 小时后再看 `journalctl --user -u clautel.service`:应该只有 1 个 `Started clautel.service`,没有任何 `Stopping`/`Stopped`

### 5.3 holder 自愈验证

故意杀掉持有进程,验证内层兜底:

```bash
# 找到 holder 持有的 sleep infinity 进程
ps -ef | grep '[s]leep infinity'
# 杀掉
kill -9 <pid>
# 等 5 分钟内的下一轮探活
tail -f /mnt/c/Users/<你>/AppData/Local/DevEnvUbuntu/holder.log
# 预期: 出现 [WARN] sleep infinity child exited 紧接 [INFO] vm holder attached
```

故意杀掉 VBS,验证外层兜底:

```powershell
Get-Process wscript | Where-Object { $_.MainWindowTitle -eq '' -and $_.CommandLine -like '*vm-holder.vbs*' } | Stop-Process -Force
# 等 30 秒
Get-ScheduledTask DevEnvUbuntu-WSL-VMHolder | Get-ScheduledTaskInfo
# 预期: LastTaskResult=0, 任务已被 RestartOnFailure 重新拉起
```

---

## 6. 回滚预案

如果 v3 VM holder 出问题(比如某些 Windows 11 版本上 wscript.exe Exec 子进程有窗口闪烁、或 sleep infinity 总在几分钟被外力 SIGKILL),回滚到 v2 (轮询心跳):

```powershell
# 1. 卸载新任务
Unregister-ScheduledTask -TaskName DevEnvUbuntu-WSL-VMHolder -Confirm:$false

# 2. 删除 vm-holder.vbs
Remove-Item "$env:LOCALAPPDATA\DevEnvUbuntu\vm-holder.vbs" -Force

# 3. git checkout 上一个 commit 的 setup-keepalive.ps1
git checkout HEAD~1 -- windows/setup-keepalive.ps1

# 4. 重跑 run-as-admin.bat 恢复 v2 心跳任务
```

回滚到 v2 = 已知问题(VM 在心跳间隙关停、业务 5% 可用率),但至少 setup 流程是验证过的。

---

## 7. 已知风险与缓解

| 风险 | 概率 | 缓解 |
|---|---|---|
| `WshShell.Run cmd, 0, False` 触发 cmd.exe / wsl.exe 子进程闪窗口(老 Windows 版本) | 极低(已由 hide-probe-window spec 实测 vbHide 不闪窗) | 实测确认;如有问题,提示用户升级 Windows 11 23H2+ |
| sleep infinity 被 Windows defender / EDR 误报 | 极低(标准 GNU coreutils) | 实测中如出现,提示用户加白名单;不改设计 |
| WSL 2.7 在某些资源压力下强制关停所有 VM(无视客户端) | 未观测 | 内外双层兜底 + 5min 探活兜底,最坏情况降级到 v2 行为 |
| 用户改 Windows 密码 | N/A | S4U 不存密码,不受影响 |
| GPO 禁用 S4U logon type | 低(企业域) | 文档说明降级路径(用任务计划 InteractiveToken trigger,但需要用户登录) |
| holder.log 写满磁盘 | 极低 | >1MB 滚到 .log.1,理论上磁盘占用 ≤ 2MB |

---

## 8. 度量目标

实施后用户应满足:

- ✅ 重启 Windows 后,**不需要打开 WSL 终端**,机器人立即可用
- ✅ 24 小时内,Telegram 给机器人发 100 条随机消息,**100 条都被及时回复**(无 5min 内空窗)
- ✅ `journalctl --user -u clautel.service` 24 小时内只有 1 条 `Started`,无 `Stopping`/`Stopped` 循环
- ✅ `uptime --since` 在 WSL 里显示的 VM 启动时刻 ≈ Windows 开机时刻(差距 < 1 分钟)

---

## 9. 范围之外

- clautel.service unit 文件的 PATH 引号问题(`Invalid environment assignment, ignoring: VS / Code: ...`):反馈给 clautel 上游,本 spec 不修
- 替换 `vmIdleTimeout=INT_MAX` 为更小的值(比如 1 天):无必要,留作冗余
- 监控告警(holder 死了通知用户):本 spec 不引入;后续可考虑 Windows 通知中心 toast,需另写 spec
- WSL 2.7 vmIdleTimeout 失效的底层原因:本 spec 不深究,工程上绕开即可
