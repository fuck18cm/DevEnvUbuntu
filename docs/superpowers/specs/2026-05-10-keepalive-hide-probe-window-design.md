# DevEnvUbuntu — 隐藏 keepalive 心跳探活的黑色 cmd 窗口

- 日期：2026-05-10
- 关联前文：[2026-05-10-clautel-systemd-handoff-design.md](2026-05-10-clautel-systemd-handoff-design.md)
- 状态：v2 keepalive 的微调；仅修补 `wsl-heartbeat.vbs` 探活分支的窗口可见性问题，不改任务计划、不改触发频率、不改三态语义

---

## 1. 背景

v2 keepalive 上线后，用户 [@hbslover] 反馈：每 5 分钟（以及登录时）屏幕上会闪一个黑色 cmd 窗口，明显影响体验。

定位到 [windows/setup-keepalive.ps1:151](../../../windows/setup-keepalive.ps1#L151)（生成的 `wsl-heartbeat.vbs` 中的探活分支）：

```vbs
Set probeExec = sh.Exec("cmd.exe /c """ & probeCmd & " 2>&1""")
```

`WshShell.Exec` 在 WSH 里**强制 `SW_SHOWNORMAL`**，无法通过任何参数隐藏窗口。这是已知行为，没有"加个 flag"的解法 —— 只能换成 `WshShell.Run(cmd, 0, True)`（`0` = vbHide，`True` = 同步等待退出）。

同一脚本里 boot 兜底用的是 `sh.Run bootCmd, 0, False`（[setup-keepalive.ps1:176](../../../windows/setup-keepalive.ps1#L176)），那条路径已经是隐藏的，所以用户只看到探活弹窗，看不到 service 启动弹窗。

---

## 2. 关键决策

| 决策点 | 选择 | 备注 |
|---|---|---|
| 隐藏机制 | `sh.Run(cmd, 0, True)` | `0` = vbHide；`True` = 等待退出，这样能拿到 `wsl.exe` 的 exit code |
| 捕获 stdout 方式 | cmd.exe 重定向到临时文件 | `Run` 拿不到 stdout 流；只能落盘再读回 |
| 临时文件位置 | `%LOCALAPPDATA%\DevEnvUbuntu\probe.tmp` | 与 VBS、log 同目录，已存在；不依赖 `%TEMP%` |
| 三态语义 | 不变（active / activating / 其他） | 因此**必须**捕获 stdout，纯 exit code 无法区分 activating 与 inactive |
| 单实例并发 | 复用既有保护 | 任务计划 `MultipleInstances=IgnoreNew` + VBS 内 wscript 自查重，单实例已有保证，不需要给 probe.tmp 加锁 |
| 失败兜底 | 临时文件不存在 → `statusOutput = ""` | 自然落到 WARN 分支并触发 boot，与当前 `Exec` 失败时语义一致 |
| 任务计划 / 触发频率 / 卸载流程 | 全部不动 | 改动只局限在 PS 模板里那几行 here-string |

---

## 3. 改动范围

只改一个文件：[windows/setup-keepalive.ps1](../../../windows/setup-keepalive.ps1)。

具体到 here-string 内部（生成的 `wsl-heartbeat.vbs`），替换"--- (b) 探活"那段（约第 144–161 行的 VBS 片段）。其他 VBS 段（日志、wscript 自查重、三态判断、boot 触发、LogLine）**逐字不变**。

伪代码：

```vbs
' --- (b) 探活: 隐藏窗口运行 wsl.exe -e systemctl --user is-active ----------
Dim sh : Set sh = CreateObject("WScript.Shell")
Dim tempFile, coreCmd, probeCmd, exitCode, statusOutput
tempFile = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & _
           "\DevEnvUbuntu\probe.tmp"
coreCmd  = "wsl.exe -d " & DISTRO & " -u " & WSL_USER & _
           " -e systemctl --user is-active clautel.service"
' cmd.exe /c "..." 双双引号包整串,内层引号保护 tempFile 路径里的空格
probeCmd = "cmd.exe /c """ & coreCmd & " > """ & tempFile & """ 2>&1"""
exitCode = sh.Run(probeCmd, 0, True)   ' 0=vbHide, True=同步等待

' 读取临时文件内容
Dim fso, f2
Set fso = CreateObject("Scripting.FileSystemObject")
statusOutput = ""
If fso.FileExists(tempFile) Then
  Set f2 = fso.OpenTextFile(tempFile, 1)   ' 1=ForReading
  If Not f2.AtEndOfStream Then statusOutput = f2.ReadAll()
  f2.Close
  fso.DeleteFile tempFile, True
End If
' 三态判断需要纯净字符串(VBS 的 Trim 不剥换行)
statusOutput = Replace(statusOutput, vbCrLf, "")
statusOutput = Replace(statusOutput, vbLf,   "")
statusOutput = Replace(statusOutput, vbCr,   "")
statusOutput = Trim(statusOutput)

' --- (c) 三态分流 ---  (← 完全不改)
```

---

## 4. 升级路径

1. 用户拉新代码后双击 `windows\run-as-admin.bat` 重跑一次。
2. PS 走既有的 `Unregister-ScheduledTask ... ; Register-ScheduledTask ...` 流程，新模板覆盖旧 VBS（`Set-Content -Force`），任务被重注册。
3. 立即执行一次 `Start-ScheduledTask` 自检；用户也可以手动 `taskschd.msc` 右键 Run。
4. 之后每 5 分钟心跳和登录时心跳都不再有窗口。

---

## 5. 验证

由于这是 Windows 端 + 视觉行为变更，自动化校验有限。验证清单：

- [ ] 重跑 `run-as-admin.bat` 不报错；脚本末尾打印的 heartbeat.log 末行依然能正常追加
- [ ] `taskschd.msc` 中右键 `DevEnvUbuntu-WSL-Keepalive` → Run 一次：**桌面无任何窗口闪现**
- [ ] `heartbeat.log` 末行仍是合法日志（`[OK] clautel.service active` 或 `[INFO] activating ...`）
- [ ] 手动 `systemctl --user stop clautel.service`，等下一次心跳，确认 `[WARN] ... bootstrapping` 出现 + 后续 `[OK]` 恢复
- [ ] `probe.tmp` 在心跳完成后已被删除（`Get-ChildItem $env:LOCALAPPDATA\DevEnvUbuntu\probe.tmp -ErrorAction SilentlyContinue` 应为空）
- [ ] WSL 端 `bash modules/99-verify.sh` 中 `wsl-keepalive 任务` 行仍为 `OK [last:...]`，不退化到 WARN/FAIL

---

## 6. 不做什么（YAGNI）

- 不改任务计划注册逻辑
- 不改触发频率（仍 AtLogOn + 5min）
- 不改 `12-keepalive.sh`（Linux 侧无关）
- 不改 `99-verify.sh`（验证逻辑读 heartbeat.log 与本次窗口可见性无关）
- 不引入 PowerShell 替代方案（`-WindowStyle Hidden` 仍会闪窗口，得不偿失）
- 不给 probe.tmp 加锁或 PID 后缀（已有双层单实例保护）
