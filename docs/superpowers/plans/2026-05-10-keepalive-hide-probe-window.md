# Keepalive 隐藏探活窗口 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 v2 keepalive 每 5 分钟（及登录时）的探活不再弹黑色 cmd 窗口。

**Architecture:** 仅替换 `windows/setup-keepalive.ps1` 内 here-string 模板里"探活"那段 VBS 代码，把 `WshShell.Exec`（强制 SW_SHOWNORMAL，无法隐藏）换成 `WshShell.Run(cmd, 0, True)`（vbHide + 同步等待）+ cmd.exe 重定向到临时文件捕获 stdout。三态判断、日志、boot 触发、任务计划注册全部不动。

**Tech Stack:** PowerShell 5.1+（Windows 11 自带）、VBScript（wscript.exe 解释）、cmd.exe（仅做重定向）。

**Spec:** [docs/superpowers/specs/2026-05-10-keepalive-hide-probe-window-design.md](../specs/2026-05-10-keepalive-hide-probe-window-design.md)

---

## 文件结构

只动一个文件：

| 文件 | 动作 | 说明 |
|---|---|---|
| `windows/setup-keepalive.ps1` | 修改 here-string 内第 144–161 行对应的 VBS 片段 | 替换探活分支；其余 VBS 段（顶部声明 / LogLine / wscript 自查重 / 三态分流 / boot 触发）逐字不变 |

无新增文件、无测试文件（项目无自动化测试框架；spec §5 有手动验证清单）。

---

### Task 1: 替换 VBS 探活段为隐藏 Run + 临时文件

**Files:**
- Modify: `windows/setup-keepalive.ps1` 内 here-string 第 144–161 行对应 VBS 块（即 `' --- (b) 探活` 到 `exitCode = probeExec.ExitCode` 之间）

**Context:** here-string 是 PowerShell 的 `@"..."@`，里面的 `$Distro`、`$WslUser`、`$signature`、`$logPath` 会被 PS 在生成阶段插值；其余 `$` 引用必须用反引号 `` ` `` 转义或确保不存在。本次改动**不引入任何新的 PS 插值变量**，所有新增逻辑都是纯 VBS。

- [ ] **Step 1: 执行替换**

打开 `windows/setup-keepalive.ps1`，定位到 here-string 内的"--- (b) 探活"段（约第 144–161 行的 VBS 部分；PS 文件本身行号约对应这一区间）。把整块替换为：

```vbs
' --- (b) 探活: 隐藏窗口运行 wsl.exe 并把 stdout 重定向到临时文件 ----------
' WshShell.Exec 强制 SW_SHOWNORMAL,会闪黑窗;改用 Run(cmd, 0, True),
' 0=vbHide,True=同步等待,返回 wsl.exe 的 exit code.
Dim sh : Set sh = CreateObject("WScript.Shell")
Dim tempFile, coreCmd, probeCmd, exitCode, statusOutput
tempFile = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & _
           "\DevEnvUbuntu\probe.tmp"
coreCmd  = "wsl.exe -d " & DISTRO & " -u " & WSL_USER & _
           " -e systemctl --user is-active clautel.service"
' cmd.exe /c "..." 双双引号包整串,内层引号保护 tempFile 路径里可能的空格
probeCmd = "cmd.exe /c """ & coreCmd & " > """ & tempFile & """ 2>&1"""
exitCode = sh.Run(probeCmd, 0, True)

' 读临时文件 (不存在时 statusOutput 留空,自然落 WARN 分支触发 boot)
Dim fso, f2
Set fso = CreateObject("Scripting.FileSystemObject")
statusOutput = ""
If fso.FileExists(tempFile) Then
  Set f2 = fso.OpenTextFile(tempFile, 1)   ' 1=ForReading
  If Not f2.AtEndOfStream Then statusOutput = f2.ReadAll()
  f2.Close
  fso.DeleteFile tempFile, True
End If
' VBS 的 Trim() 不剥换行;systemctl 输出是 "active\n",必须先去 CR/LF
statusOutput = Replace(statusOutput, vbCrLf, "")
statusOutput = Replace(statusOutput, vbLf,   "")
statusOutput = Replace(statusOutput, vbCr,   "")
statusOutput = Trim(statusOutput)
```

被替换的旧块（确认你删掉的就是这些）：

```vbs
' --- (b) 探活: wsl.exe -e systemctl --user is-active clautel.service -------
Dim sh : Set sh = CreateObject("WScript.Shell")
Dim probeCmd, probeExec, statusOutput, exitCode
probeCmd = "wsl.exe -d " & DISTRO & " -u " & WSL_USER & _
           " -e systemctl --user is-active clautel.service"

' Exec 能拿到 ExitCode 和 stdout; cmd.exe 包一层让 stderr 也走管道
Set probeExec = sh.Exec("cmd.exe /c """ & probeCmd & " 2>&1""")
Do While probeExec.Status = 0 : WScript.Sleep 100 : Loop
' VBS 的 Trim() 只剥空格,不剥换行!  systemctl is-active 输出是 "active\n",
' 直接 Trim 之后 statusOutput = "active" & Chr(10),三态判断永远落 Else 分支
' → 误报 WARN.  显式去 CR/LF 再 Trim.
statusOutput = probeExec.StdOut.ReadAll()
statusOutput = Replace(statusOutput, vbCrLf, "")
statusOutput = Replace(statusOutput, vbLf, "")
statusOutput = Replace(statusOutput, vbCr, "")
statusOutput = Trim(statusOutput)
exitCode = probeExec.ExitCode
```

**关键守恒**（替换前后必须保持一致）：
- `sh` 变量名不变（后续 `(c) 三态分流` 里 boot 分支的 `sh.Run bootCmd, 0, False` 还在用它）
- `statusOutput` 与 `exitCode` 两个变量都在；类型语义不变
- "--- (c) 三态分流" 段不动

- [ ] **Step 2: PS 语法静态校验**

在 PowerShell 里跑（不会真的执行脚本，只解析语法）：

```powershell
$null = [System.Management.Automation.Language.Parser]::ParseFile('windows\setup-keepalive.ps1', [ref]$null, [ref]$null)
'OK'
```

期望输出：`OK`（且无 ParseError 抛出）。如果有 here-string 引号没闭合 / 反引号转义不对，会立刻报错。

- [ ] **Step 3: 干跑提取 VBS 内容做语法目检**

在 PowerShell 里抽出 here-string，用插桩值跑一遍渲染（无副作用），看生成的 VBS 是否合法：

```powershell
# 把 ps 文件里 here-string 那段单独 dot-source 出 $vbs,
# 但因为脚本顶部有 admin 校验和 wsl 调用,不能直接 source.
# 改用纯文本提取:
$src = Get-Content -Raw windows\setup-keepalive.ps1
if ($src -notmatch '(?s)\$vbs\s*=\s*@"\r?\n(.*?)\r?\n"@') { throw 'VBS here-string not found' }
$tpl = $matches[1]
# 用假值替换插值
$Distro='Ubuntu'; $WslUser='hbslo'; $signature='DevEnvUbuntu-keepalive:Ubuntu:hbslo'
$logPath="C:\Users\hbslo\AppData\Local\DevEnvUbuntu\heartbeat.log"
$rendered = $ExecutionContext.InvokeCommand.ExpandString($tpl)
$out = "$env:TEMP\devenv-vbs-preview.vbs"
$rendered | Set-Content -Path $out -Encoding Ascii -Force
# 让 cscript 只做语法解析 (没有 -syntax-only,但解析失败会立刻报)
& $env:SystemRoot\System32\cscript.exe //Nologo //E:VBScript $out 2>&1 | Select-Object -First 5
```

期望：脚本会真的尝试运行（会探一次 systemctl，可能写一行日志，对宿主无害），不应输出 `Microsoft VBScript compilation error`。如果不便真跑，仅做"渲染后人工 grep"也可以：

```powershell
Select-String -Path $out -Pattern 'sh\.Run|sh\.Exec|probe\.tmp|FileSystemObject' -SimpleMatch:$false
```

期望出现 `sh.Run`、`probe.tmp`、`FileSystemObject`，**不出现** `sh.Exec` 字样。

- [ ] **Step 4: 提交**

```powershell
git add windows/setup-keepalive.ps1 docs/superpowers/specs/2026-05-10-keepalive-hide-probe-window-design.md docs/superpowers/plans/2026-05-10-keepalive-hide-probe-window.md
git commit -m "fix(windows): hide cmd window during keepalive heartbeat probe"
```

完整 commit message body（HEREDOC）：

```
fix(windows): hide cmd window during keepalive heartbeat probe

WshShell.Exec forces SW_SHOWNORMAL — there's no flag to hide it —
so the every-5-min systemctl is-active probe was flashing a black
cmd window on the desktop. Switch to WshShell.Run(cmd, 0, True)
(vbHide + sync wait) and capture stdout via cmd.exe redirection
into %LOCALAPPDATA%\DevEnvUbuntu\probe.tmp.

Three-state semantics (active / activating / other), heartbeat.log
format, wscript dedupe, and the boot-trigger branch are all
untouched. No scheduled-task changes; users only need to rerun
windows\run-as-admin.bat to regenerate the VBS.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

### Task 2: 用户侧手动验证（一次性）

**Files:** 无代码改动；这一步是把 spec §5 验证清单转成可执行的检查命令。**用户在自己的 Windows 桌面上执行**；agentic worker 不要试图替用户跑（需要看屏幕确认窗口不闪）。

- [ ] **Step 1: 重跑 setup**

文件资源管理器里双击 `windows\run-as-admin.bat`，UAC 同意。期望末尾 `=== 完成 ===` 和 `[OK] 已生成: ...wsl-heartbeat.vbs`。

- [ ] **Step 2: 打开任务计划手动触发**

PowerShell 跑：

```powershell
Start-ScheduledTask -TaskName 'DevEnvUbuntu-WSL-Keepalive'
```

**用眼睛盯屏幕 2-3 秒**：不应看到任何黑色或白色 cmd / wsl 窗口闪现。

- [ ] **Step 3: 确认日志正常**

```powershell
Get-Content "$env:LOCALAPPDATA\DevEnvUbuntu\heartbeat.log" -Tail 3
```

期望最后一行形如 `<时间> [OK] clautel.service active`（或 `[INFO] activating ...` / `[WARN] ... bootstrapping`，取决于服务状态）。

- [ ] **Step 4: 确认临时文件被清理**

```powershell
Test-Path "$env:LOCALAPPDATA\DevEnvUbuntu\probe.tmp"
```

期望：`False`（VBS 在每次探活末尾 `fso.DeleteFile tempFile, True`）。

- [ ] **Step 5: 三态分流回归（可选但推荐）**

在 WSL 里 stop service，等下一次自动心跳（≤5 min）或手动触发：

```powershell
wsl.exe -- systemctl --user stop clautel.service
Start-ScheduledTask -TaskName 'DevEnvUbuntu-WSL-Keepalive'
Start-Sleep -Seconds 5
Get-Content "$env:LOCALAPPDATA\DevEnvUbuntu\heartbeat.log" -Tail 5
```

期望日志里出现 `[WARN] clautel down ... bootstrapping` 和 `[INFO] boot trigger fired`，且**整个过程仍然没有窗口闪现**（boot 触发用的 `sh.Run bootCmd, 0, False` 本来就是隐藏的）。再过几秒：

```powershell
wsl.exe -- systemctl --user is-active clautel.service
```

期望：`active`。

- [ ] **Step 6: WSL 端 verify 不退化**

```powershell
wsl.exe -- bash -lc 'cd /mnt/d/dev_env/DevEnvUbuntu && bash modules/99-verify.sh' 2>&1 | Select-String 'wsl-keepalive'
```

期望该行仍是 `[OK]`，不变成 `[WARN]` 或 `[FAIL]`。

---

## 完成判据

- Task 1 提交进 main 分支
- 用户在 Step 2 / Step 5 用肉眼确认无窗口闪现
- heartbeat.log 在 Step 3 / Step 5 的格式与改动前一致
- `bash modules/99-verify.sh` 仍然 PASS

如 Step 2 仍看到窗口闪现：检查 `Get-Content $env:LOCALAPPDATA\DevEnvUbuntu\wsl-heartbeat.vbs | Select-String 'sh\.Exec'`，若仍有 `sh.Exec` 说明 PS 没有重生成 VBS（可能 admin 权限失败或 here-string 解析出错），回 Task 1 Step 2/3 复查。
