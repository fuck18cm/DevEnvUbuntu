# Keepalive Prelogin Startup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Windows keepalive 任务从"用户登录后触发"改成"开机即触发"，让 clautel 不再依赖人工登录。

**Architecture:** 在不引入新进程/新依赖的前提下，对 `windows/setup-keepalive.ps1` 做三处改动：
1. 触发器 `AtLogOn` → `AtStartup`；2. principal 加 `-LogonType S4U`（不存密码）；3. 注册后追加配置断言，避免后续维护者无意中把 trigger/principal 改回去。
VBS 探活、`.wslconfig`、5 分钟心跳 trigger 全部不动；只做最小入侵 + 文档同步。

**Tech Stack:** PowerShell 5.1（Task Scheduler cmdlet `New-ScheduledTaskTrigger` / `Register-ScheduledTask`）、bash（`99-verify.sh` 注释更新）、markdown 文档同步。

**关联设计文档：** [2026-05-11-keepalive-prelogin-startup-design.md](../specs/2026-05-11-keepalive-prelogin-startup-design.md)

---

## 文件改动概览

| 文件 | 改动类型 | 责任 |
|---|---|---|
| `windows/setup-keepalive.ps1` | 修改 | 核心：改 trigger、改 principal、改文案、加配置断言 |
| `modules/99-verify.sh` | 修改 | 加一行注释说明心跳可能在登录前就开始写日志 |
| `CLAUDE.md` | 修改 | "始终在线"架构小节第 4 条 trigger 描述更新 |
| `README.md` | 修改 | keepalive 段 trigger 描述更新 |
| `docs/superpowers/specs/2026-05-10-clautel-systemd-handoff-design.md` | 修改 | 末尾追加"§ 10 修订记录"指向新 spec |

无新建源代码文件（plan 文件本身除外）。

---

## 关键约定

**LF/CRLF 行尾：** 仓库 `.gitattributes` 强制 `*.sh` = LF，`*.ps1` / `*.bat` = CRLF。编辑器保存时务必尊重这套行尾。若 Edit 工具的 string match 因换行差异失败，重新 Read 文件确认实际字节。

**Commit 风格：** 沿用仓库现有 conventional commits（`fix(windows):`, `docs:`, `feat:` 等）。每个 Task 末尾单独一次 commit。

---

## Task 1: `setup-keepalive.ps1` — trigger / principal / 文案 / 配置断言

**Files:**
- Modify: `windows/setup-keepalive.ps1:202-203` (trigger 1：移除 logon、新增 startup)
- Modify: `windows/setup-keepalive.ps1:216-217` (principal：加 S4U)
- Modify: `windows/setup-keepalive.ps1:220-223` (Register 调用：trigger 数组改名)
- Modify: `windows/setup-keepalive.ps1:224` (Write-Host 提示文案)
- Modify: `windows/setup-keepalive.ps1:240-244` (完成 banner 文案)
- Insert: `windows/setup-keepalive.ps1` 在 Register-ScheduledTask 后、Start-ScheduledTask 前（约第 224 行后）插入配置断言块

- [ ] **Step 1.1: Read 当前 setup-keepalive.ps1 锚定字节**

```bash
# 用 Read 工具读 windows/setup-keepalive.ps1，目标确认 195-250 行的现状跟下面"旧值"一致。
```

旧值（202-203 行）：

```powershell
  $triggerLogon = New-ScheduledTaskTrigger -AtLogOn `
    -User "$env:USERDOMAIN\$env:USERNAME"
```

旧值（216-217 行）：

```powershell
  $principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest
```

旧值（220-223 行）：

```powershell
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Register-ScheduledTask -TaskName $taskName `
    -Action $action `
    -Trigger @($triggerLogon, $triggerHeartbeat) `
    -Settings $settings -Principal $principal | Out-Null
  Write-Host "[OK] 已注册任务计划: $taskName (AtLogOn + 5min, MultipleInstances=IgnoreNew)"
```

如果文件已经偏离旧值，停止并提示用户排查（可能是别人已经动过这段）。

- [ ] **Step 1.2: 改 trigger — `$triggerLogon` → `$triggerStartup`**

Edit 替换 202-203 行：

```powershell
  $triggerStartup = New-ScheduledTaskTrigger -AtStartup
```

注意：
- `AtStartup` trigger 不需要 `-User`（因为"启动时跑"是机器级事件而非用户级）。
- 心跳 trigger（206-208 行）**不动**。

- [ ] **Step 1.3: 改 principal — 加 `-LogonType S4U`**

Edit 替换 216-217 行：

```powershell
  $principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest
```

- [ ] **Step 1.4: 改 Register-ScheduledTask 的 trigger 数组**

Edit 替换 220-223 行（注意 Write-Host 同时改）：

```powershell
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Register-ScheduledTask -TaskName $taskName `
    -Action $action `
    -Trigger @($triggerStartup, $triggerHeartbeat) `
    -Settings $settings -Principal $principal | Out-Null
  Write-Host "[OK] 已注册任务计划: $taskName (AtStartup + 5min, S4U, MultipleInstances=IgnoreNew)"
```

- [ ] **Step 1.5: 在 Register 后插入配置断言块**

在 Step 1.4 改完的那段之后、第 226 行 `# === 7) 立即触发一次` 之前插入：

```powershell
  # === 6b) 自检注册结果 (防止后续被人意外改回 AtLogOn 或丢掉 S4U) ============
  $registered = Get-ScheduledTask -TaskName $taskName
  $bootTrigger = $registered.Triggers | Where-Object {
    $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger'
  }
  if (-not $bootTrigger) {
    Write-Error "[ASSERT] 任务注册成功了, 但没找到 AtStartup (MSFT_TaskBootTrigger). 检查 setup-keepalive.ps1 中 trigger 写法."
    exit 1
  }
  if ($registered.Principal.LogonType -ne 'S4U') {
    Write-Error "[ASSERT] 任务 principal LogonType = '$($registered.Principal.LogonType)', 期望 S4U. 检查 New-ScheduledTaskPrincipal 参数."
    exit 1
  }
  Write-Host "[OK] 配置断言通过: AtStartup trigger + S4U principal"
```

设计说明：
- `MSFT_TaskBootTrigger` 是 PowerShell Task Scheduler cmdlet 对 AtStartup 的 CIM 类名（AtLogOn 是 `MSFT_TaskLogonTrigger`、Once 是 `MSFT_TaskTimeTrigger`）。CIM 类名比解析人类可读字符串更稳。
- 心跳 trigger 不在断言里检查 —— 如果未来想调整心跳间隔不应触发 assert 失败。
- 断言失败时 `Write-Error + exit 1`，跟脚本顶部 `$ErrorActionPreference = "Stop"` 配合，会立刻终止。

- [ ] **Step 1.6: 改完成 banner 文案**

Edit 替换 240-244 行（"=== 完成 ==="后面的多行 Write-Host）：

```powershell
  Write-Host ""
  Write-Host "=== 完成 ===" -ForegroundColor Green
  Write-Host "保活机制:"
  Write-Host "  AtStartup (S4U, 无密码) + 每 5 分钟 -> wscript $vbsPath"
  Write-Host "  VBS 探活 clautel.service: active=记 OK / 否则 systemctl start"
  Write-Host "  日志: $logPath"
```

- [ ] **Step 1.7: PowerShell 语法校验（无副作用）**

如果开发者所在终端能跑 PowerShell（Windows 上的 `powershell.exe` 或跨平台 `pwsh`）：

```powershell
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path d:\dev_env\DevEnvUbuntu\windows\setup-keepalive.ps1).Path,
  [ref]$null, [ref]$errs
) | Out-Null
if ($errs.Count -eq 0) { 'parse OK' } else { $errs | Format-List }
```

预期：`parse OK`。

如果开发者在 WSL 里、没有 `pwsh`，可跳过此 step；Step 1.8 的实际安装会同时暴露语法错误。

- [ ] **Step 1.8: 在管理员 PowerShell 跑一次完整安装（真实集成测试）**

```powershell
# 管理员 PowerShell:
cd D:\dev_env\DevEnvUbuntu\windows
.\run-as-admin.bat
# 或: powershell -ExecutionPolicy Bypass -File .\setup-keepalive.ps1
```

预期：脚本顺利跑完，控制台会打印 `[OK] 配置断言通过: AtStartup trigger + S4U principal`，最终 banner 显示 `AtStartup (S4U, 无密码) + 每 5 分钟`。

如果断言失败 → 回到 Step 1.2 - 1.5 检查具体哪一处没改对。

如果开发者目前不在 Windows 桌面环境（例如纯 WSL session），跳过此 step 留给用户在 reboot 验证时一并跑（Task 6）。

- [ ] **Step 1.9: Commit**

```bash
git -C d:/dev_env/DevEnvUbuntu add windows/setup-keepalive.ps1
git -C d:/dev_env/DevEnvUbuntu commit -m "fix(windows): keepalive task fires at boot via AtStartup + S4U

Replace AtLogOn trigger with AtStartup so clautel starts when Windows boots
rather than after user login. Principal switched to S4U logon type to avoid
password storage. 5-min heartbeat trigger retained as safety net for the
edge case where LxssManager isn't ready at boot.

Added post-registration assertion to guard against accidental regression
of these two properties.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `99-verify.sh` — 加澄清注释

**Files:**
- Modify: `modules/99-verify.sh` (heartbeat 检查附近)

- [ ] **Step 2.1: 应用 Edit — 在 heartbeat 检查块前插入注释**

锚点位置：`modules/99-verify.sh` 第 57 行 "# 进一步: 读 Windows 侧 heartbeat.log 看最近一次状态"。

用 Edit 替换，old_string：

```bash
    # 进一步: 读 Windows 侧 heartbeat.log 看最近一次状态
    WIN_USER=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n ')
```

new_string：

```bash
    # 进一步: 读 Windows 侧 heartbeat.log 看最近一次状态
    # 注: heartbeat 可能在 Windows 用户登录前就开始写日志 (AtStartup + S4U trigger),
    #     所以最近一行 [OK] 时间戳可能早于 verify 时的登录时刻 - 这是预期行为.
    WIN_USER=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n ')
```

注释前的 4 个空格缩进必须保留（脚本里这段在 `if ... then` 块内）。

- [ ] **Step 2.2: bash 语法校验**

```bash
bash -n d:/dev_env/DevEnvUbuntu/modules/99-verify.sh
# 预期: 无输出 (语法 OK)
```

- [ ] **Step 2.3: 跑一遍 verify（可选）**

```bash
bash d:/dev_env/DevEnvUbuntu/modules/99-verify.sh
# 预期: 行为与改前一致, 注释只是注释
```

如果当前环境不能跑（例如缺工具），跳过；注释改动无 runtime 影响。

- [ ] **Step 2.4: Commit**

```bash
git -C d:/dev_env/DevEnvUbuntu add modules/99-verify.sh
git -C d:/dev_env/DevEnvUbuntu commit -m "docs(verify): note heartbeat may log before user login under AtStartup

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `CLAUDE.md` — "始终在线"架构小节同步

**Files:**
- Modify: `CLAUDE.md:94-97` (Windows 任务计划小节)

- [ ] **Step 3.1: 应用 Edit**

Edit `CLAUDE.md`，old_string：

```
4. **Windows 任务计划** `DevEnvUbuntu-WSL-Keepalive` (`setup-keepalive.ps1` 注册) — **一个任务,两个 trigger**:
   - `AtLogOn` 用户登录时跑一次(冷启动 WSL)
   - 每 5 分钟一次心跳
```

new_string：

```
4. **Windows 任务计划** `DevEnvUbuntu-WSL-Keepalive` (`setup-keepalive.ps1` 注册) — **一个任务,两个 trigger**:
   - `AtStartup` Windows 启动时跑一次 (principal: S4U logon type, 不依赖用户登录、不存密码)
   - 每 5 分钟一次心跳
```

- [ ] **Step 3.2: Commit**

```bash
git -C d:/dev_env/DevEnvUbuntu add CLAUDE.md
git -C d:/dev_env/DevEnvUbuntu commit -m "docs(claude-md): sync 'always-on' section to AtStartup + S4U trigger

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `README.md` — keepalive 段同步

**Files:**
- Modify: `README.md:50-52`

- [ ] **Step 4.1: 应用 Edit**

Edit `README.md`，old_string：

```
- 注册 Windows 任务计划 `DevEnvUbuntu-WSL-Keepalive`，**两个 trigger**：
  - `AtLogOn` —— 用户登录时跑一次（冷启动 WSL）
  - 每 5 分钟一次心跳 —— 跑 wscript 调用 VBS，VBS 探 clautel.service 状态
```

new_string：

```
- 注册 Windows 任务计划 `DevEnvUbuntu-WSL-Keepalive`，**两个 trigger**：
  - `AtStartup` —— Windows 启动时跑一次（principal 用 S4U logon type，不依赖你登录、不存密码，锁屏期间 clautel 就已经在跑）
  - 每 5 分钟一次心跳 —— 跑 wscript 调用 VBS，VBS 探 clautel.service 状态
```

- [ ] **Step 4.2: Commit**

```bash
git -C d:/dev_env/DevEnvUbuntu add README.md
git -C d:/dev_env/DevEnvUbuntu commit -m "docs(readme): describe AtStartup + S4U keepalive trigger

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: 老 spec 文末追加修订记录

**Files:**
- Modify: `docs/superpowers/specs/2026-05-10-clautel-systemd-handoff-design.md` (在 line 358 之后追加)

- [ ] **Step 5.1: 用 Edit 在文末"## 9. 不做的事 / 边界声明"最后一行后追加新章节**

Edit 文件，old_string：

```
- **不做多 distro 支持**：v2 同 v1，只服务一个 distro；多 distro 需要重设计 signature/任务命名
```

new_string：

```
- **不做多 distro 支持**：v2 同 v1，只服务一个 distro；多 distro 需要重设计 signature/任务命名

---

## 10. 修订记录

- **2026-05-11**：任务计划 trigger 从 `AtLogOn` 切到 `AtStartup`，principal 加 `LogonType S4U`，让 clautel 开机即启动、不再等用户登录。详见 [2026-05-11-keepalive-prelogin-startup-design.md](2026-05-11-keepalive-prelogin-startup-design.md)。本节中"AtLogOn 用户登录时跑一次"以及相关字样已被新 spec 取代。
```

- [ ] **Step 5.2: Commit**

```bash
git -C d:/dev_env/DevEnvUbuntu add docs/superpowers/specs/2026-05-10-clautel-systemd-handoff-design.md
git -C d:/dev_env/DevEnvUbuntu commit -m "docs(spec): cross-link prelogin-startup revision in v2 handoff spec

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: 手工 reboot 验证（用户操作）

**Files:** 无文件改动。这步是给用户的操作清单，本任务由用户在 Windows 桌面环境下完成。

- [ ] **Step 6.1: 提示用户执行重启验证**

向用户输出以下文字（不要替用户执行重启）：

> 实施完成。请按以下步骤验证"开机即跑"是否生效：
>
> 1. 确认当前所有改动已 commit（`git status` 应该是 clean）
> 2. 管理员 PowerShell 跑一次 `windows\run-as-admin.bat`，应看到 `[OK] 配置断言通过: AtStartup trigger + S4U principal`
> 3. 管理员 PowerShell：`wsl --shutdown`
> 4. 重启 Windows（开始菜单 → 电源 → 重新启动）
> 5. **开机后停在锁屏 2-3 分钟，不要登录**
> 6. 登录后第一时间在 WSL 里跑：
>    ```bash
>    systemctl --user is-active clautel.service
>    # 预期: active
>    tail -5 /mnt/c/Users/<你>/AppData/Local/DevEnvUbuntu/heartbeat.log
>    # 预期: 至少有一行 [OK] 时间戳早于你登录时刻
>    ```
> 7. 如果心跳日志里只有登录之后的行，按 spec § 4.3 回滚或反馈给我诊断

- [ ] **Step 6.2: 等待用户反馈**

- 用户反馈"通过" → 这个任务标记完成
- 用户反馈"失败"（日志只有登录后的行）→ 不要直接回滚；先用 `Get-ScheduledTask -TaskName DevEnvUbuntu-WSL-Keepalive | Get-ScheduledTaskInfo` 收集 `LastTaskResult`，把它和 heartbeat.log 末 20 行一起反馈，再决定走 spec § 4.3 的回滚还是诊断别的成因（例如 Group Policy 禁止 S4U）

---

## 验证摘要

- **静态校验**：PowerShell parse-check（Task 1.7）+ bash `-n`（Task 2.3）+ Edit 工具自身保证 string 精确匹配
- **安装时自检**：Task 1.5 加的 assertion 块 —— 每次 `setup-keepalive.ps1` 跑完都会重新验证 trigger 类型和 LogonType
- **运行时验证**：Task 6 reboot 验证 —— 唯一能证明"开机就跑"的端到端测试

`tests/smoke.sh` 和 `99-verify.sh` 不需要新增 case：smoke.sh 跑在 WSL 上看不到 Windows 任务，99-verify.sh 的 heartbeat 日志检查已经覆盖了"心跳正常"的判定。

---

## 不在范围内

- 自动化 Windows 侧测试（PowerShell Pester 单元测试）——本仓库没有此基建，引入 Pester 是单独的工作
- 多 distro / 多用户支持
- 替代实现（NSSM 真服务、DPAPI 存密码）——spec § 5 已声明
