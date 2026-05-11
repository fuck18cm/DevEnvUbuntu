# DevEnvUbuntu — keepalive 任务在用户登录前启动

- 日期：2026-05-11
- 关联前文：
  - [2026-05-10-clautel-systemd-handoff-design.md](2026-05-10-clautel-systemd-handoff-design.md)（v2 keepalive 总体架构）
  - [2026-05-10-keepalive-hide-probe-window-design.md](2026-05-10-keepalive-hide-probe-window-design.md)（VBS 窗口隐藏）
- 状态：在 v2 keepalive 基础上把任务计划的触发时机从"用户登录后"提前到"Windows 启动后"；不改 VBS 三态分流、不改 `.wslconfig`、不引入新依赖

---

## 1. 背景

v2 keepalive 的任务计划 `DevEnvUbuntu-WSL-Keepalive` 当前用两个 trigger：

1. `AtLogOn`（[windows/setup-keepalive.ps1:202-203](../../../windows/setup-keepalive.ps1#L202-L203)）—— 用户登录时触发一次
2. 每 5 分钟一次心跳 —— bootstrap 兜底

并且 principal 跑在用户身份下、但 logon type 为默认（要求用户已登录）：

```powershell
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest
```

这意味着：**Windows 开机停在锁屏阶段，任务根本不会跑**，clautel 必须等用户首次登录后才会被拉起。用户 [@hbslover] 在 2026-05-11 重启测试时确认了这个行为。

需求很明确：clautel 应该在 Windows 一开机就跑起来，与用户是否登录解耦。

---

## 2. 关键决策

| 决策点 | 选择 | 备注 |
|---|---|---|
| 实现形态 | 继续用 Task Scheduler，**不引入** NSSM/真服务 | 改一行 trigger + 一行 principal 即可；NSSM 要新增 `windows/nssm.exe` 二进制、改 PowerShell 调用方式、卸载流程也要改，收益对不上 |
| AtLogOn → AtStartup | `New-ScheduledTaskTrigger -AtStartup` | Windows 启动后触发一次。S4U 任务 + AtStartup 是 Microsoft 文档化的"开机就跑、无人登录也跑"的标准组合 |
| Logon type | `S4U`（Service For User） | 不存密码；用户改 Windows 密码也不会让任务失效。代价：会话无网络凭据 —— 但 wsl.exe 走的是本地 COM/IPC 到 vmcompute，**不需要网络** |
| 心跳 trigger | **保留** | 作为安全网：AtStartup 那次失败（例如 LxssManager 还没初始化好），5 分钟后心跳兜底重试 |
| VBS 探活逻辑 | **不动** | 三态分流 + bootstrap 与"被谁触发、什么时候触发"完全无关 |
| `.wslconfig` | **不动** | 现有 `vmIdleTimeout=2147483647` 保证 VM 起来后常驻，与本次改动方向一致 |
| WSL distro / user 探测 | **不动** | `setup-keepalive.ps1` 第 33-66 行的探测逻辑在管理员上下文运行，与任务身份无关 |
| `wslconfig.template` 写入路径 | **不动** | 仍写 `$env:USERPROFILE\.wslconfig`，由调用 `run-as-admin.bat` 的用户决定 |

### 2.1 为什么 S4U 够用

S4U 创建的 logon token 有这些性质：

- ✅ 有用户的 SID，能访问 HKCU 注册表（WSL distro 注册在 `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss`，关键）
- ✅ 能访问用户 profile 路径（`%USERPROFILE%`）
- ✅ 能调本地 COM 服务（vmcompute、LxssManager 都是本地）
- ❌ 没有网络凭据（不能访问 `\\server\share`、不能 Kerberos 认证）

我们的任务只做一件事：调 `wsl.exe -d <distro> -u <wsl-user> --exec systemctl --user start clautel.service`（`<distro>` / `<wsl-user>` 在 `setup-keepalive.ps1` 探测后烘焙进 VBS 的 `Const DISTRO` / `Const WSL_USER`）。这条命令链上没有任何"以用户身份访问网络资源"的步骤，因此 S4U 不缺什么。

### 2.2 已知风险与缓解

**风险 1：AtStartup 触发瞬间，vmcompute / LxssManager 可能尚未就绪**

Windows 启动顺序里，Task Scheduler 服务和 LxssManager 都标 `auto-start`，但 LxssManager 完全 ready 接受 `wsl.exe` 调用可能晚于任务触发时刻几秒到几十秒。

缓解：保留 5 分钟心跳 trigger。即便 AtStartup 那次失败（VBS 探活拿到非 `active`），下一次心跳会触发 bootstrap，最坏延迟 5 分钟内 clautel 就起来。日志里会留下 `[WARN]` 行，方便后续 verify。

**风险 2：S4U + AtStartup 在某些组策略下可能被禁用**

某些企业域策略禁用 "Log on as a batch job" / S4U。本仓库目标是个人 Windows 11 Home，默认允许 S4U。

缓解：spec 里写明，若部署目标是受策略管控的企业机器，可降级为"DPAPI 存密码"模式（PowerShell 里把 `-LogonType S4U` 拿掉，`Register-ScheduledTask` 会 prompt 密码）。本仓库不实现这个降级路径；按需在文档里说明即可。

**风险 3：用户改 Windows 密码后任务失效**

S4U 模式下不存密码 → **不存在**这个风险。这正是选 S4U 的主要动机之一。

---

## 3. 改动范围

仅一个文件的代码改动：

- [windows/setup-keepalive.ps1](../../../windows/setup-keepalive.ps1)
  - 行 ~202-203：移除 `$triggerLogon`，新增 `$triggerStartup = New-ScheduledTaskTrigger -AtStartup`
  - 行 ~206-208：心跳 trigger **不变**
  - 行 ~216-217：principal 加 `-LogonType S4U`
  - 行 ~220-223：`Register-ScheduledTask` 的 `-Trigger` 数组从 `@($triggerLogon, $triggerHeartbeat)` 改为 `@($triggerStartup, $triggerHeartbeat)`
  - 行 ~224：成功提示文案 "AtLogOn + 5min" → "AtStartup + 5min (S4U)"
  - 行 ~242-244：完成提示里的描述同步

VBS here-string（行 94-189）、wslconfig 写入、v1 清理、立即触发、自检 —— **都不动**。

### 文档同步（必须）

- [README.md](../../../README.md)：找到"始终在线"相关段落，把 trigger 描述更新；如有"登录后才生效"字样必须改
- [CLAUDE.md](../../../CLAUDE.md) `### "始终在线"架构 (v2 — 只在 WSL 下完整生效)` 那节的第 4 条"Windows 任务计划"小节：trigger 描述更新；加一行 "principal: S4U logon type, 开机即触发不依赖登录"
- [docs/superpowers/specs/2026-05-10-clautel-systemd-handoff-design.md](2026-05-10-clautel-systemd-handoff-design.md)：在文末加一个 "§ 修订记录" 小节，指向本 spec，说明 trigger 已从 AtLogOn 切到 AtStartup
- 本 spec 文件 + 对应 plan：本任务产物

### `modules/99-verify.sh`（小调整，可选）

现有逻辑读 `/mnt/c/Users/.../heartbeat.log` 最后一行判 `[WARN]`，行为正确不需要改。但在 [heartbeat 检查附近的注释](../../../modules/99-verify.sh) 加一行：

```bash
# 注: heartbeat 可能在 Windows 用户登录前就开始写日志 (AtStartup + S4U trigger)
```

避免后续维护者误以为这是"用户登录后才有日志"。

---

## 4. 验证方案

### 4.1 单元层面（安装时）

`setup-keepalive.ps1` 末尾的"立即触发一次 + 自检"小节（行 226-238）已经会 `Start-ScheduledTask` 并读 `heartbeat.log` 末行。本次改动不影响这部分。

### 4.2 真正的"开机即跑"验证（人工，需用户重启）

写入 README 和本 spec 末尾：

1. Windows 管理员 PowerShell：`wsl --shutdown`
2. 重启 Windows（开始菜单 → 电源 → 重新启动）
3. **开机后停在锁屏 2-3 分钟，不要登录**（任务计划在 AtStartup 触发，5 分钟心跳也会跑至少一次）
4. 登录后第一时间在 WSL 里跑：
   ```bash
   systemctl --user is-active clautel.service
   # 预期: active
   tail -5 /mnt/c/Users/<你>/AppData/Local/DevEnvUbuntu/heartbeat.log
   # 预期: 至少有一行 [OK] 时间戳在你登录之前
   ```
5. 如果心跳日志里只有登录之后的行 → S4U + AtStartup 没起作用，按 4.3 回滚或诊断

### 4.3 回滚预案

如果 4.2 步骤 5 失败、或运行一段时间发现 S4U 有未预见的兼容性问题：

```powershell
# 在管理员 PowerShell:
$t = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$h = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2)) `
       -RepetitionInterval (New-TimeSpan -Minutes 5)
$p = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest
Set-ScheduledTask -TaskName "DevEnvUbuntu-WSL-Keepalive" `
  -Trigger @($t, $h) -Principal $p
```

回滚不需要重跑 `setup-keepalive.ps1`，也不会破坏 VBS / wslconfig / 标记文件。

---

## 5. 不在范围内

- ❌ NSSM 真服务方案（用户已选择留在 Task Scheduler）
- ❌ DPAPI 存密码模式（用户已选 S4U）
- ❌ Windows Auto-Login（不在仓库职责范围，且削弱安全）
- ❌ 重写 VBS 探活逻辑、改三态语义、改心跳频率
- ❌ 处理"多用户 Windows 机器，每个用户都要各自的 WSL distro 起来"的场景（v2 keepalive 整体就是单用户假设）

---

## 6. 影响面与兼容性

- **新装用户**：`bash install.sh` → 双击 `run-as-admin.bat` 流程不变，体验差异只是任务计划注册成 S4U + AtStartup
- **已装用户**：重跑 `windows\run-as-admin.bat` 即可（`Unregister-ScheduledTask` 后 `Register-ScheduledTask` 的现有逻辑会覆盖旧任务）
- **CI / Docker 测试**：本改动只影响 Windows 侧，`tests/run-in-docker.sh` 一律 `--skip-keepalive`，不受影响
- **Linux 侧 99-verify**：行为不变，只是加注释

---

## 7. 决策记录

- 2026-05-11：[@hbslover] 重启后发现 clautel 需登录才启动，要求改成开机即跑
- 2026-05-11：评估"真 Windows 服务 (NSSM)" vs "任务计划 + AtStartup"，用户选后者（理由：避免新依赖、PS 改动最小）
- 2026-05-11：评估"S4U 不存密码" vs "DPAPI 存密码"，用户选 S4U（理由：wsl.exe 是本地 IPC 不需要网络凭据，且改 Windows 密码不破任务）

---

## § 修订记录

- **2026-05-11**: 本 spec 引入的 AtStartup + S4U 触发器模型被 [vm-holder 设计](2026-05-11-vm-holder-design.md) 继承(同样 AtStartup + S4U),但触发的目标 VBS 从轮询心跳 `wsl-heartbeat.vbs` 改为持续持有 `vm-holder.vbs`,任务名也从 `DevEnvUbuntu-WSL-Keepalive` 改为 `DevEnvUbuntu-WSL-VMHolder`。本 spec 关于 S4U 性质、风险、回滚的分析仍然适用,不需要修改。
