# DevEnvUbuntu 一键开发环境安装器 — 设计文档

- 日期：2026-05-10
- 目标平台：Windows 11 + WSL2 Ubuntu 22.04+；同样支持纯 Ubuntu 22.04+ 物理机/虚拟机
- 范围：JDK 8/17、Node.js 20 LTS、Python 3.12、Git、Maven 3.9.x、Claude Code CLI、`clautel` npm 包；以及在 WSL2 下保持"始终在线"

---

## 1. 目标与非目标

### 目标
1. 单条命令在干净的 Ubuntu 22.04+ 上完成全部开发工具安装，且所有命令进入 PATH 立即可用。
2. JDK 8 与 17 同时安装、可在线切换；Node 与 Python 通过版本管理器装单一默认版本，需要时再装其他。
3. 默认走国内镜像加速。
4. 在 WSL2 下达成四层"始终在线"：Windows 开机自启 WSL、WSL 不被空闲超时关闭、`clautel` 常驻并崩溃后自动拉起、网络保活检测（不主动重启网络）。
5. 所有模块幂等：重复运行不报错、不重复安装。

### 非目标
- 不替用户登录 Anthropic 账号（用户自己运行 `claude login`）。
- 不安装 IDE、浏览器、Docker、Kubernetes 等扩展工具。
- 不配置 Git `user.name` / `user.email`（除非通过命令行参数显式注入）。
- 不在 v1 实现"网络断开 → Windows 端自动重启 WSL"，本期仅记录日志。
- 不上单元测试框架（bats 等），靠端到端"重跑无变化"作为幂等性断言。

---

## 2. 关键决策（已与用户确认）

| 决策点 | 选择 | 备注 |
|---|---|---|
| `clautel` 来源 | npm 全局包，包名即 `clautel` | `npm i -g clautel` |
| 多版本管理 | SDKMAN（JDK/Maven）+ nvm（Node）+ pyenv（Python） | 与 apt/update-alternatives 相比更灵活 |
| 默认激活版本 | JDK 8 + Node 20 LTS + Python 3.12 + Maven 3.9.x | JDK 17 同时装但默认不激活，`sdk use java 17.x` 切换 |
| 国内镜像 | 默认启用，可用 `--no-mirror` 关掉 | apt USTC、SDKMAN bfsu、Node npmmirror、PyPI 清华、Maven 阿里云、pyenv/nvm gitee |
| Claude 认证 | 仅装 CLI，认证留给用户手动 `claude login` | — |
| 始终在线层面 | 4 层全开：Windows 自启 / 不空闲超时 / clautel 自拉起 / 网络保活 | — |
| 交付形态 | `install.sh` 主入口 + `modules/` 数字前缀子模块 + `windows/` 提权 bat 与 ps1 | — |

---

## 3. 整体架构与目录结构

```
DevEnvUbuntu/
├── README.md                           # 用法、参数、FAQ、冒烟测试步骤
├── install.sh                          # WSL/Ubuntu 侧主入口
├── lib/
│   └── common.sh                       # log/require/idempotent_*/append_once/is_wsl/has_systemd
├── modules/                            # 按数字顺序顺序执行
│   ├── versions.env                    # 集中管理版本号
│   ├── 00-detect.sh                    # 探测 WSL / Ubuntu 版本 / 架构 / systemd
│   ├── 01-base.sh                      # apt 切 USTC + 装基础包
│   ├── 02-git.sh                       # git 配置（不强制 user.name/email）
│   ├── 03-sdkman.sh                    # 安装 SDKMAN 并切 bfsu 镜像
│   ├── 04-jdk.sh                       # JDK 8 + 17，默认 8
│   ├── 05-maven.sh                     # Maven 3.9.x + 阿里云 settings.xml
│   ├── 06-nvm.sh                       # 安装 nvm + Node 镜像环境变量
│   ├── 07-node.sh                      # Node 20 LTS + npm 走 npmmirror
│   ├── 08-pyenv.sh                     # pyenv（gitee 镜像）+ 编译依赖
│   ├── 09-python.sh                    # Python 3.12 + pip 走清华
│   ├── 10-claude-code.sh               # npm i -g @anthropic-ai/claude-code
│   ├── 11-clautel.sh                   # npm i -g clautel
│   ├── 12-keepalive.sh                 # 部署 systemd user services + enable-linger
│   └── 99-verify.sh                    # 校验全部命令在 PATH 中可用
├── systemd/
│   ├── clautel.service
│   ├── net-keepalive.service
│   └── net-keepalive.timer
└── windows/                            # 仅 WSL2 用户使用
    ├── run-as-admin.bat                # UAC 自我提权 → 调 ps1
    ├── setup-keepalive.ps1             # 注册任务计划 + 部署 .wslconfig
    └── wslconfig.template
```

### 设计约束
- 模块**必须幂等**：开头检测"已就绪"快返回；重跑两次第二次应秒过且产物 diff 为空。
- 模块**支持单独执行**：`bash modules/04-jdk.sh` 必须能独立工作（自行 `source lib/common.sh` 与 `versions.env`）。
- `install.sh` 支持参数：
  - `--only <module>`：只跑指定模块（可多次传）
  - `--skip <module>`：跳过指定模块（可多次传）
  - `--no-mirror`：关闭国内镜像
  - `--git-user <name>` / `--git-email <addr>`：注入 Git 全局配置
  - `--skip-keepalive`：CI 场景跳过 systemd user service 部署

---

## 4. 模块职责与 PATH 注入

| # | 模块 | 安装方式 | 进入 PATH 的命令 |
|---|---|---|---|
| 00 | detect | 写 `.env.detected`，检测 `/proc/version` 含 `microsoft` 判 WSL；`lsb_release -rs` 验 ≥22.04 | — |
| 01 | base | `sed -i` 改 `/etc/apt/sources.list` 为 USTC，`apt install -y curl wget zip unzip git ca-certificates build-essential jq` | — |
| 02 | git | 已被 01 装，本模块仅按参数做 `git config --global` | `git` |
| 03 | sdkman | `curl -s "https://get.sdkman.io" \| bash`，patch `~/.sdkman/etc/config` 加 `SDKMAN_CANDIDATES_API=https://sdkman.bfsu.edu.cn/candidates` | `sdk`（source 后） |
| 04 | jdk | `sdk install java 8.0.422-tem` + `17.0.13-tem`；`sdk default java 8.0.422-tem` | `java`、`javac` |
| 05 | maven | `sdk install maven 3.9.9`；生成 `~/.m2/settings.xml` 配阿里云 mirror | `mvn` |
| 06 | nvm | `curl ...nvm/install.sh \| bash`（gitee 镜像），写 `NVM_NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node/` 到 `~/.bashrc` | `nvm`（source 后） |
| 07 | node | `nvm install 20 --lts`、`nvm alias default 20`；`npm config set registry https://registry.npmmirror.com` | `node`、`npm`、`npx` |
| 08 | pyenv | `git clone https://gitee.com/mirrors/pyenv ~/.pyenv`；`apt install` pyenv 编译依赖 | `pyenv` |
| 09 | python | `PYTHON_BUILD_MIRROR_URL=https://npmmirror.com/mirrors/python/ pyenv install 3.12.7`；`pyenv global 3.12.7`；写 `~/.pip/pip.conf` 走清华 | `python`、`pip` |
| 10 | claude-code | `npm i -g @anthropic-ai/claude-code` | `claude` |
| 11 | clautel | `npm i -g clautel` | `clautel` |
| 12 | keepalive | 见 §5 | — |
| 99 | verify | 逐一 `command -v` + `--version`，输出对照表 | — |

### PATH 注入策略
所有工具的 init 行（`source ~/.sdkman/bin/sdkman-init.sh`、nvm、pyenv 等）写到 `~/.bashrc` 末尾的统一 marker 块：
```
# >>> DevEnvUbuntu managed >>>
# (auto-generated; do not edit between markers)
...
# <<< DevEnvUbuntu managed <<<
```
重装时整块替换而不是追加。

### 版本号集中管理
`modules/versions.env`：
```bash
JDK8_VERSION=8.0.422-tem
JDK17_VERSION=17.0.13-tem
MAVEN_VERSION=3.9.9
NODE_LTS=20
PYTHON_VERSION=3.12.7
```
未来升级版本只改这一处。

---

## 5. 四层"始终在线"实现

### 层 1：Windows 开机自启 WSL（Windows 端）

**`windows/run-as-admin.bat`**（UAC 自我提权）：
```bat
@echo off
fltmc >nul 2>&1 || (
  powershell -Command "Start-Process '%~dpnx0' -Verb RunAs"
  exit /b
)
powershell -ExecutionPolicy Bypass -File "%~dp0setup-keepalive.ps1" %*
pause
```
逻辑：`fltmc` 仅管理员能跑，非管理员失败 → `Start-Process -Verb RunAs` 弹 UAC 自身重启 → 已是管理员则调 ps1。

**`setup-keepalive.ps1`** 完成三件事：
1. 渲染 `wslconfig.template` 写入 `$env:USERPROFILE\.wslconfig`，关键键值：
   ```ini
   [wsl2]
   vmIdleTimeout=2147483647   # 约 24.8 天,实际由 sleep infinity 保活,这里只是兜底
   guiApplications=true
   ```
   （备注：WSL2 `vmIdleTimeout` 单位是毫秒，负值行为未文档化，本设计取 32 位有符号整型最大值作为保守"近乎永不"。真正阻止空闲超时的关键还是层 1 的 `sleep infinity` 进程。）
2. `Register-ScheduledTask` 注册 `DevEnvUbuntu-WSL-Keepalive`：
   - 触发器：用户登录时
   - 操作：`wsl.exe -d Ubuntu -u <user> --exec /bin/bash -lic "exec sleep infinity"`
   - 设置：失败 1 分钟重启、不设结束时间、隐藏窗口
3. 立即运行一次任务，让当前会话生效；成功后通过 `wsl.exe -e touch ~/.local/state/devenv/windows-keepalive-installed` 写标记，供 WSL 端 `99-verify.sh` 读取。

### 层 2：WSL 不被空闲超时关闭

由层 1 的 `vmIdleTimeout=2147483647` + `sleep infinity` 进程双重保证（后者是主力，前者兜底）。

### 层 3：clautel 常驻 + 崩溃自拉起（WSL 端）

`~/.config/systemd/user/clautel.service`：
```ini
[Unit]
Description=Clautel daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -lc 'exec clautel'
Restart=always
RestartSec=5s
StandardOutput=append:%h/.local/state/clautel/clautel.log
StandardError=append:%h/.local/state/clautel/clautel.log

[Install]
WantedBy=default.target
```

`12-keepalive.sh` 顺序：
1. 检测 `/etc/wsl.conf` 是否含 `[boot]\nsystemd=true`，没有就写入并提示用户 `wsl --shutdown` 后重跑。
2. `mkdir -p ~/.local/state/clautel ~/.config/systemd/user`
3. 复制 service / timer 模板
4. `systemctl --user daemon-reload`
5. `systemctl --user enable --now clautel.service net-keepalive.timer`
6. `sudo loginctl enable-linger $USER`（让用户未登录时 service 也运行）

### 层 4：网络保活

`~/.config/systemd/user/net-keepalive.timer`：每 5 分钟触发 `net-keepalive.service`，执行：
```bash
ping -c1 -W3 1.1.1.1 >/dev/null && exit 0
ping -c1 -W3 8.8.8.8 >/dev/null && exit 0
echo "$(date -Iseconds) network unreachable" >> ~/.local/state/clautel/net.log
exit 0
```
**坦白边界**：v1 不主动重启 WSL 网络，仅记录日志（WSL 内难以可靠"重置网络"）。后续若需要，可在断网时往一个 Windows 可见路径写信号文件，由 Windows 任务计划监听后 `wsl --shutdown` 重启。

---

## 6. 错误处理、幂等性、日志

### 错误处理
- 全局 `set -Eeuo pipefail`
- 每个模块顶部 `trap 'on_error $LINENO $?' ERR`，打印行号 + 退出码 + 模块名 + 重跑提示
- `install.sh` 主循环按字典序跑模块，任一失败立即退出非零（不"尽力跑完"）

### 幂等检测套路
| 工具 | 已就绪判据 |
|---|---|
| apt 包 | `dpkg -s <pkg>` 退出 0 |
| SDKMAN candidate | `sdk current java` / `sdk list java \| grep -E 'installed.*<ver>'` |
| nvm node | `nvm ls 20 \| grep -q v20` |
| pyenv 版本 | `pyenv versions \| grep -q 3.12.7` |
| npm 全局包 | `npm ls -g --depth=0 \| grep -q '<pkg>@'` |
| systemd unit | `systemctl --user is-enabled clautel.service` |

### 日志
- 模块输出 `tee` 到 `~/.local/state/devenv/install-$(date +%Y%m%d-%H%M%S).log`
- 失败时把日志路径打到 stderr
- clautel 运行日志：`~/.local/state/clautel/clautel.log`（service 已配）
- 网络保活日志：`~/.local/state/clautel/net.log`

### `lib/common.sh` 工具函数
- `log_info / log_warn / log_error`（颜色 + 时间戳）
- `require_cmd <name>`：缺命令 fail 并提示装哪个模块
- `append_once <file> <marker> <content>`：marker 块整块替换
- `idempotent_apt_install <pkgs...>`：过滤已装包
- `is_wsl`、`has_systemd`、`as_login_shell <cmd>`（即 `bash -lc`，让 nvm/sdk PATH 生效）

---

## 7. 验证与测试策略

### `99-verify.sh` 自检对照表
逐项 `command -v <cmd>` + `<cmd> --version`，匹配 `versions.env` 中的期望值。同时检查：
- `systemctl --user is-active clautel.service`
- `loginctl show-user $USER \| grep Linger=yes`
- `~/.local/state/devenv/windows-keepalive-installed` 标记文件存在（仅 WSL 下检查；纯 Ubuntu 跳过）

输出示例：
```
=== DevEnvUbuntu 安装结果 ===
[OK]  git           2.43.0
[OK]  java (default) 1.8.0_422  (sdk: 8.0.422-tem)
[OK]  java 17 可切换  17.0.13   (sdk use java 17.0.13-tem)
[OK]  mvn           3.9.9
[OK]  node          v20.18.0
[OK]  python        3.12.7
[OK]  claude        x.y.z
[OK]  clautel       x.y.z
[OK]  clautel.service active (enabled, lingering)
[FAIL] wsl-keepalive scheduled task — 请在 Windows 端运行 windows\run-as-admin.bat
================================
```

### 手工冒烟测试（README 列出）
1. 关闭所有终端，10 分钟后从 PowerShell 跑 `wsl -e bash -c 'systemctl --user is-active clautel.service'` —— 应返回 `active`，证明 `vmIdleTimeout=-1` 起作用。
2. `kill $(pgrep -f clautel)`，5 秒后 `pgrep -f clautel` —— 应有新 PID（自动重启）。
3. Windows 重启后不开终端，等 1 分钟从任务管理器看是否有 `wsl.exe` 进程 —— 验证开机自启。

### CI（可选第二期）
GitHub Actions 用 `ubuntu-22.04` runner 跑 `bash install.sh --skip-keepalive`，最后断言 `99-verify.sh` 退 0。

### 单元测试
不引入框架。`lib/common.sh` 的关键函数（`append_once`、`idempotent_apt_install`）通过"重跑两次 install.sh、第二次秒过、`~/.bashrc` 与 `~/.m2/settings.xml` diff 为空"作为端到端断言。

---

## 8. 安全与边界

- 任何 `sudo` 调用都走 `sudo -n` 或显式提示用户输入密码，不嵌入明文密码。
- 不下载未经校验的二进制：所有工具走官方安装器（SDKMAN / nvm / pyenv 官方脚本，仅替换 candidates 镜像）。
- `windows/run-as-admin.bat` 仅做 UAC 自提权，不下载远程脚本。
- 不写 `ANTHROPIC_API_KEY` 到 shell rc。

---

## 9. 后续可能的扩展（非本期）

- 网络保活层 4 升级为"断网时由 Windows 任务计划重启 WSL"。
- 增加 `--profile <java|python|fullstack>` 预设组合，让用户挑选模板。
- 提供 `uninstall.sh` 干净卸载入口。
- 加入 IDE 模块（IntelliJ IDEA、VSCode WSL 扩展自动配置）。
