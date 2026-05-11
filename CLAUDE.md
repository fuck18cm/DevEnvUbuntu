# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目本质

DevEnvUbuntu 是一个 **bash 安装器仓库**,一键给 Ubuntu 22.04+(含 WSL2)装齐 JDK 8/17、Node 20、Python 3.12、Maven、git、Claude Code CLI、`clautel`,并在 WSL2 下让 clautel 作为 systemd user service 始终在线。没有编译产物、没有运行时框架,所有逻辑都是 shell 脚本 + 由 `clautel install-service` 生成的 systemd unit + 一段 PowerShell + 运行时生成的一份 VBS。

仓库本体在 Windows 上(`D:\dev_env\DevEnvUbuntu\`),但脚本运行目标是 WSL/Ubuntu。修改 `*.sh` 时必须保持 LF 行尾;`*.bat` / `*.ps1` 保持 CRLF。这一点由 `.gitattributes` 强制。

## 常用命令

所有命令都在 WSL/Ubuntu 端运行(在 Windows PowerShell 里调用需 `wsl -- bash -lc '...'`)。

```bash
# 一键全装 (默认走官方上游;国内不能科学上网加 --mirror)
bash install.sh
bash install.sh --mirror              # 切到 USTC/bfsu/npmmirror/清华/阿里云/gitee
bash install.sh --status              # 只看不装,打印当前状态表后退出
bash install.sh -y                    # 跳过确认提示

# 只跑 / 跳过特定模块 (按文件名前缀匹配)
bash install.sh --only 04-jdk --only 05-maven
bash install.sh --skip 12-keepalive
bash install.sh --skip-keepalive      # CI 场景便捷别名

# 单独执行某模块 (每个模块都能独立工作,自己 source common.sh + versions.env)
bash modules/04-jdk.sh
bash modules/12-keepalive.sh

# 校验 / 冒烟
bash modules/99-verify.sh             # 工具齐备性 + service 状态对照表
bash tests/smoke.sh                   # 99-verify + JDK 8↔17 切换 + mirror 配置检查
bash tests/test-common.sh             # lib/common.sh 单元测试 (log_*/append_once/is_wsl)

# 干净环境端到端 (需要 docker)
bash tests/run-in-docker.sh           # 在全新 ubuntu:22.04 容器里跑 install.sh --skip-keepalive
```

Windows 端只有一步:文件资源管理器双击 `windows\run-as-admin.bat`(它会 UAC 自提权 → `setup-keepalive.ps1` → 写 `%USERPROFILE%\.wslconfig` + 注册任务计划 `DevEnvUbuntu-WSL-Keepalive` + 在 WSL 内 touch `~/.local/state/devenv/windows-keepalive-installed`)。

仓库没有 lint/build/test 框架。"重跑两次 install.sh 第二次秒过且产物 diff 为空" 是事实上的幂等断言。

## 架构(读多个文件才看得清的地方)

### 主流程
`install.sh` 顺序扫 `modules/[0-9][0-9]-*.sh`(按数字字典序)、应用 `--only`/`--skip` 过滤、逐个 `bash <module>`。安装前后各打一次 `print_status_table`(它直接探文件系统状态,不依赖模块自报)。任一模块失败 `set -Eeuo pipefail` + `trap ERR` 立即整体退出,日志 `tee` 到 `~/.local/state/devenv/install-<ts>.log`。

### 模块编号语义
| 段 | 用途 |
|---|---|
| 00 | 探测 (`is_wsl`、Ubuntu 版本、systemd),写 `.env.detected` |
| 01-02 | apt + git 基础层 |
| 03-09 | 版本管理器 + 语言:SDKMAN→JDK→Maven、nvm→Node、pyenv→Python (依赖关系按编号串行) |
| 10-11 | npm 全局工具:claude-code、clautel (依赖 07-node) |
| 12 | systemd user services (依赖 11-clautel) |
| 99 | verify |

新增模块时遵循"管理器在前、产物在后"。

### `lib/common.sh` 是所有模块的共享心脏
模块顶部统一:
```bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib/common.sh"
source "$HERE/modules/versions.env"   # 仅在需要版本号的模块
```

关键函数(改它们要小心,所有模块都会受影响):

- **`as_login_shell <cmd...>`** — 在已加载 SDKMAN/nvm/pyenv 的子 shell 里执行命令。**重点:它不用 `bash -ilc`**。`-i` 在脚本子进程里启用 job control 会触发 SIGTTOU 把整个安装器停成 `[N]+ Stopped`。改用 `bash -c` 显式 `source` 已知 init 脚本(绕开 `~/.bashrc` 顶部 `case $- in *i*) ;; *) return;; esac` 的非交互短路)。
- **`append_once <file> <marker> <content>`** — 维护一对 `# >>> $marker >>>` ... `# <<< $marker <<<` 注释块。块内重复调用整块替换,marker 不会重复出现。所有写 `~/.bashrc` 的模块只走这条路径,不要用 `>>` 直接追加。已用的 marker:`DevEnvUbuntu SDKMAN`、`DevEnvUbuntu nvm`、`DevEnvUbuntu pyenv`。
- **`idempotent_apt_install <pkgs...>`** — 用 `dpkg -s` 过滤已装包。安装前还会检查 sudo,所以模块里直接调即可。
- **`log_info`/`log_warn`/`log_error`** — 带颜色和时间戳;`log_warn`/`log_error` 写 stderr。
- **`is_wsl`** / **`has_systemd`** — 探测函数,只 grep `/proc/version` 和 `/run/systemd/system`。

### `--mirror` 开关的作用面
`DEVENV_USE_MIRROR=0/1` 在 `install.sh` 里 export,所有模块统一读它。**默认 0(走上游)**,`--mirror` 才切镜像。每个模块除了"开启镜像写入"还要"关闭镜像清理":比如 `09-python.sh` 在 `--mirror=0` 时若发现旧 `~/.pip/pip.conf` 含 `tsinghua` 会主动 `rm`,让用户从镜像态切回上游不留残渣。新增镜像配置必须同时实现两个方向。

### SDKMAN 的特殊处理(踩过的坑)
`03-sdkman.sh` 不论是否启用镜像,**始终强制关闭这四项**:
- `sdkman_healthcheck_enable`(bash 层探活,失败会进 offline)
- `sdkman_selfupdate_feature` / `sdkman_auto_selfupdate`(对镜像不友好)
- `sdkman_native_enable`(SDKMAN 5.18+ 的 Rust 原生 CLI;它有独立探活逻辑,不读 bash 开关,在软路由/fake-ip/严格防火墙下容易误判 `INTERNET NOT REACHABLE`,强制走 bash 实现绕过)

`04-jdk.sh` / `05-maven.sh` 调 `sdk list` 时**必须** `2>&1` 合并输出 — SDKMAN 5.18+ 的 native CLI 把表格打到 stderr,用 `2>/dev/null` 会拿到空字符串。

JDK/Maven 解析逻辑:先精确匹配 `versions.env` 中的 pin,匹配不到就降级到该大版本下的最新 `-tem` / `3.x` 版本(`pick_latest_tem`)。candidates 完全空时把 `sdk list` 完整输出 dump 到 `~/.local/state/devenv/sdk-list-*-<ts>.txt` 让用户贴回。

### "始终在线"架构 (v3 — VM Holder 模式,只在 WSL 下完整生效)

1. **`/etc/wsl.conf`** 启用 systemd(`12-keepalive.sh` 写入但需用户 `wsl --shutdown` 一次)。
2. **`loginctl enable-linger`** — 让 systemd user manager 在你未登录时也跑,clautel 才能在没人 wsl.exe 连着的间隙也活着(本身在 v3 里这条不再是必需 — 但保留作为防御深度)。
3. **`clautel install-service`** 生成 `~/.config/systemd/user/clautel.service` 并 enable + start。这份 unit **由 clautel 自己维护**,我们仓库不再保留手写模板;它的 ExecStart 直接调 node + daemon.js,Environment=PATH 烘焙进去,Restart=always。
4. **Windows 任务计划** `DevEnvUbuntu-WSL-VMHolder` (`setup-keepalive.ps1` 注册) — **单 trigger AtStartup,S4U 主体,RestartOnFailure 兜底**:
   - 调用 `wscript.exe %LOCALAPPDATA%\DevEnvUbuntu\vm-holder.vbs`(运行时生成,distro/user/signature 烘焙入 VBS 常量)
   - VBS 启动后 spawn 一个隐藏的 `wsl.exe -d <distro> -u <user> -e /bin/bash -c "exec /bin/sleep infinity # DevEnvUbuntu-vm-holder-sleep-infinity"`,这个 wsl.exe 长期 attach,VM 因此 24/7 在线
   - VBS 进入 `Do While True` 主循环,每 5 分钟:
     1. WMI 查 `Win32_Process` 看 wsl.exe CommandLine 是否还包含 HOLDER_SIG,不在则重 spawn(内层兜底)
     2. 探活 `systemctl --user is-active clautel.service`,active 写 [OK]、activating 写 [INFO]、其它写 [WARN] 并 fire-and-forget `systemctl --user start`
     3. 日志写到 `%LOCALAPPDATA%\DevEnvUbuntu\holder.log`(>1MB 滚到 `.log.1`)
   - 任务计划 `MultipleInstances=IgnoreNew` + VBS 内 wscript 进程数检查双层排他
   - **外层兜底**: `RestartCount=999, RestartInterval=60s` (PT1M, Task Scheduler 最小允许值) — VBS 自身崩溃时任务计划 60s 后重启
   - 隐藏窗口靠 `wscript.exe` + 所有 wsl.exe 调用都用 `WshShell.Run cmd, 0, False/True`(`0`=vbHide)。**不要用 `WshShell.Exec`** — 它强制 SW_SHOWNORMAL 会闪窗,见 [keepalive-hide-probe-window 设计](docs/superpowers/specs/2026-05-10-keepalive-hide-probe-window-design.md)。

心跳/持有日志 `%LOCALAPPDATA%\DevEnvUbuntu\holder.log`,>1MB 自动轮转到 `.log.1`。v2 时代的 `heartbeat.log` 保留在原位作历史归档,setup 不删它。

`12-keepalive.sh` 在没有 systemd 时直接 `exit 1`,不会退化执行。`99-verify.sh` 里 `wsl-keepalive 任务` 在 marker 文件不存在时标 `TODO` 而非 `FAIL`(Linux 侧没法修 Windows 端,不应阻塞 verify 退出码);marker 在时进一步从 `/mnt/c/Users/.../holder.log` 读最近一行作为心跳健康度,`[WARN]` 行才计入 FAIL。如果用户从 v2 升级但还没重跑 `run-as-admin.bat`,verify 会看到 heartbeat.log 但没有 holder.log,标 WARN 提示升级。

### 版本号集中点
所有版本写在 `modules/versions.env`,升级只改这一处。当前:`JDK8_VERSION=8.0.422-tem`、`JDK17_VERSION=17.0.13-tem`、`MAVEN_VERSION=3.9.9`、`NODE_LTS=20`、`PYTHON_VERSION=3.12.7`。

## 写代码时的硬约束

- **每个模块必须幂等**:开头先用"已就绪"判据快速返回(参考 `03-sdkman.sh` 的 `[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]]`)。重复运行相同命令必须不报错、不重复写入。
- **每个模块必须能单独跑**:开头自己 `source` `lib/common.sh` 和 `modules/versions.env`,不要假设有外部环境变量(除了 `DEVENV_USE_MIRROR` / `DEVENV_GIT_USER` 等明确文档化的开关)。
- **写 `~/.bashrc` 只走 `append_once`**,marker 命名 `DevEnvUbuntu <Component>`。
- **新增镜像配置必须双向**:开启 `--mirror` 时写入,关闭 `--mirror` 时清理残留。
- **更新 `print_status_table`**:在 `install.sh` 里加新工具的状态行。
- **更新 `99-verify.sh`**:加新工具的 `check_cmd`。
- **不要在 `install.sh` 顶层添加新参数而不文档化**:在 `--help`(`sed -n '2,8p' "$0"`)和 README 参数表里同步。

## 设计文档

完整设计动机、决策记录、未实现的扩展见 `docs/superpowers/specs/2026-05-10-dev-env-installer-design.md`(执行计划 `docs/superpowers/plans/2026-05-10-dev-env-installer.md`)。

v2 keepalive 重构(把 daemon 管理交还给 `clautel install-service`、Windows 侧改成单任务双 trigger)的设计与实施见 `docs/superpowers/specs/2026-05-10-clautel-systemd-handoff-design.md` 和 `docs/superpowers/plans/2026-05-10-clautel-systemd-handoff.md`。
