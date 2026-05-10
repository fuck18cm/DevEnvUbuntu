# DevEnvUbuntu 一键开发环境安装器 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在干净的 Ubuntu 22.04+（含 WSL2 Ubuntu）上一键安装 JDK 8/17、Node 20、Python 3.12、Git、Maven、Claude Code CLI、`clautel`，并保证四层"始终在线"。

**Architecture:** `install.sh` 主入口按字典序顺序运行 `modules/NN-*.sh`，每个模块自检"已就绪"则跳过；公共函数集中在 `lib/common.sh`。WSL 端用 systemd user service 让 `clautel` 常驻；Windows 端通过 `run-as-admin.bat` 提权后调 `setup-keepalive.ps1` 注册任务计划保活 WSL。

**Tech Stack:** Bash / SDKMAN / nvm / pyenv / systemd user services / PowerShell + 任务计划程序 / Docker（仅用于本地测试 Linux 模块）

**参考 spec:** [docs/superpowers/specs/2026-05-10-dev-env-installer-design.md](../specs/2026-05-10-dev-env-installer-design.md)

---

## 文件结构

按职责分文件，每个文件单一职责。模块脚本按数字前缀决定执行顺序。

```
DevEnvUbuntu/
├── README.md                       # 用法、参数、FAQ、冒烟测试
├── .gitignore                      # 排除 ~/.local 状态、docker volume 等
├── install.sh                      # 主入口；解析 CLI 参数；按字典序运行 modules/*.sh
├── lib/
│   └── common.sh                   # log_*, append_once, idempotent_apt_install, is_wsl, has_systemd, as_login_shell
├── modules/
│   ├── versions.env                # 集中版本号
│   ├── 00-detect.sh                # 探测环境，写 .env.detected
│   ├── 01-base.sh                  # apt 镜像 + 基础包
│   ├── 02-git.sh                   # git 配置（按参数）
│   ├── 03-sdkman.sh                # 安装 SDKMAN + bfsu 镜像
│   ├── 04-jdk.sh                   # JDK 8 + 17
│   ├── 05-maven.sh                 # Maven + 阿里云 settings.xml
│   ├── 06-nvm.sh                   # 安装 nvm + Node 镜像变量
│   ├── 07-node.sh                  # Node 20 + npmmirror
│   ├── 08-pyenv.sh                 # 安装 pyenv + 编译依赖
│   ├── 09-python.sh                # Python 3.12 + pip 清华
│   ├── 10-claude-code.sh           # @anthropic-ai/claude-code
│   ├── 11-clautel.sh               # clautel
│   ├── 12-keepalive.sh             # 部署 systemd user services
│   └── 99-verify.sh                # 全量验证
├── systemd/
│   ├── clautel.service
│   ├── net-keepalive.service
│   └── net-keepalive.timer
├── windows/
│   ├── run-as-admin.bat
│   ├── setup-keepalive.ps1
│   └── wslconfig.template
├── tests/
│   ├── run-in-docker.sh            # 一键起 Ubuntu 22.04 容器跑 install.sh（除 keepalive）
│   ├── test-common.sh              # lib/common.sh 关键函数的小型断言脚本
│   └── smoke.sh                    # 调 99-verify.sh 后做扩展断言
└── docs/superpowers/
    ├── specs/2026-05-10-dev-env-installer-design.md
    └── plans/2026-05-10-dev-env-installer.md   # 本文件
```

## 测试约定

- **Linux 模块**：每完成一个模块，在 `docker run --rm -v $(pwd):/work -w /work ubuntu:22.04 bash -c "apt update -qq && apt install -y -qq sudo && bash install.sh --only <module> --skip-keepalive"` 内验证一次（容器无 systemd 所以 keepalive 必须 skip）。
- **lib/common.sh 函数**：`tests/test-common.sh` 用 bash 内置断言（`[[ ... ]] || { echo FAIL; exit 1; }`）做小型自测。
- **systemd 模块（12-keepalive）**：必须在真实 WSL2 或物理 Ubuntu 上测试，Docker 不行。
- **Windows 脚本**：必须在真实 Windows 11 上测试。
- **幂等性**：每个模块完成后必须连跑两次 `bash install.sh --only <module>`，第二次必须秒过且不修改任何文件（用 `git status` 或 `find ~ -newer /tmp/marker` 验证）。

---

## Task 1: 仓库骨架与 .gitignore

**Files:**
- Create: `.gitignore`
- Create: `README.md`（占位，最终任务会重写）
- Create: `tests/run-in-docker.sh`
- Create: `modules/versions.env`

- [ ] **Step 1: 写 `.gitignore`**

```gitignore
# Editor / OS
.vscode/
.idea/
.DS_Store
Thumbs.db

# Local install state（防止把测试痕迹提交进来）
.env.detected
*.log

# Test scratch
tests/scratch/
```

- [ ] **Step 2: 写占位 `README.md`**

```markdown
# DevEnvUbuntu

一键安装 Ubuntu 22.04+（含 WSL2）开发环境：JDK 8/17、Node 20、Python 3.12、Git、Maven、Claude Code CLI、clautel。

详细设计见 [docs/superpowers/specs/2026-05-10-dev-env-installer-design.md](docs/superpowers/specs/2026-05-10-dev-env-installer-design.md)。

> 安装与 FAQ 待 Task 16 补全。
```

- [ ] **Step 3: 写 `tests/run-in-docker.sh`**

```bash
#!/usr/bin/env bash
# 用法: tests/run-in-docker.sh [install.sh 的参数...]
set -euo pipefail
cd "$(dirname "$0")/.."
docker run --rm -v "$(pwd)":/work -w /work ubuntu:22.04 bash -c '
  apt-get update -qq
  apt-get install -y -qq sudo curl ca-certificates >/dev/null
  bash install.sh --skip-keepalive "$@"
' bash "$@"
```

- [ ] **Step 4: 写 `modules/versions.env`**

```bash
# 集中管理工具版本，install.sh 会 source 这个文件
JDK8_VERSION=8.0.422-tem
JDK17_VERSION=17.0.13-tem
MAVEN_VERSION=3.9.9
NODE_LTS=20
PYTHON_VERSION=3.12.7
```

- [ ] **Step 5: 设置可执行位**

```bash
chmod +x tests/run-in-docker.sh
```

- [ ] **Step 6: 验证文件存在**

```bash
ls -la .gitignore README.md tests/run-in-docker.sh modules/versions.env
```
Expected: 四个文件都存在。

- [ ] **Step 7: 提交**

```bash
git add .gitignore README.md tests/run-in-docker.sh modules/versions.env
git commit -m "chore: scaffold repo with versions, gitignore, docker test helper"
```

---

## Task 2: lib/common.sh 公共函数及其自测

**Files:**
- Create: `lib/common.sh`
- Create: `tests/test-common.sh`

- [ ] **Step 1: 先写测试 `tests/test-common.sh`**

```bash
#!/usr/bin/env bash
# 测试 lib/common.sh 的关键函数
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source lib/common.sh

PASS=0
FAIL=0
assert() {
  local desc="$1"; shift
  if eval "$@"; then echo "  PASS: $desc"; PASS=$((PASS+1));
  else echo "  FAIL: $desc"; FAIL=$((FAIL+1)); fi
}

# --- log_* 函数应有输出 ---
out=$(log_info "hello" 2>&1) || true
assert "log_info 输出包含 hello" '[[ "$out" == *hello* ]]'

# --- append_once 幂等：写两次内容只出现一次 ---
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
append_once "$tmp" "TEST_MARK" $'export FOO=bar\nexport BAZ=qux'
append_once "$tmp" "TEST_MARK" $'export FOO=bar\nexport BAZ=qux'
assert "append_once 幂等" '[[ $(grep -c "export FOO=bar" "$tmp") == "1" ]]'
assert "append_once 写入 marker" 'grep -q "TEST_MARK" "$tmp"'

# --- append_once 内容变化时整块替换 ---
append_once "$tmp" "TEST_MARK" 'export FOO=changed'
assert "append_once 替换旧块" '[[ $(grep -c "export FOO=changed" "$tmp") == "1" ]]'
assert "append_once 删除旧 FOO=bar" '! grep -q "FOO=bar" "$tmp"'

# --- is_wsl 应不报错 ---
is_wsl; rc=$?
assert "is_wsl 返回 0 或 1" '[[ "$rc" == "0" || "$rc" == "1" ]]'

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]]
```

- [ ] **Step 2: 跑测试，确认失败（lib/common.sh 还不存在）**

```bash
chmod +x tests/test-common.sh
bash tests/test-common.sh
```
Expected: `bash: lib/common.sh: No such file or directory`

- [ ] **Step 3: 实现 `lib/common.sh`**

```bash
#!/usr/bin/env bash
# DevEnvUbuntu 公共函数库；模块顶部用 `source lib/common.sh`
# 不要 set -e 在这里，调用方决定 errexit 策略

if [[ -n "${_DEVENV_COMMON_LOADED:-}" ]]; then return 0; fi
_DEVENV_COMMON_LOADED=1

_DEVENV_COLOR_RESET=$'\033[0m'
_DEVENV_COLOR_INFO=$'\033[36m'
_DEVENV_COLOR_WARN=$'\033[33m'
_DEVENV_COLOR_ERROR=$'\033[31m'

_devenv_ts() { date +'%Y-%m-%dT%H:%M:%S'; }

log_info()  { printf '%s[INFO ] %s%s %s\n'  "$_DEVENV_COLOR_INFO"  "$(_devenv_ts)" "$_DEVENV_COLOR_RESET" "$*"; }
log_warn()  { printf '%s[WARN ] %s%s %s\n'  "$_DEVENV_COLOR_WARN"  "$(_devenv_ts)" "$_DEVENV_COLOR_RESET" "$*" >&2; }
log_error() { printf '%s[ERROR] %s%s %s\n'  "$_DEVENV_COLOR_ERROR" "$(_devenv_ts)" "$_DEVENV_COLOR_RESET" "$*" >&2; }

# require_cmd <cmd> [安装提示]
require_cmd() {
  local cmd="$1" hint="${2:-}"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  log_error "缺少命令: $cmd${hint:+，请先运行: $hint}"
  return 1
}

# is_wsl: 检测是否在 WSL 中。WSL 返回 0，否则返回 1。
is_wsl() {
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}

# has_systemd: 检测当前系统是否启用了 systemd 作为 PID 1。
has_systemd() {
  [[ -d /run/systemd/system ]]
}

# as_login_shell <command...>: 用 `bash -lc` 跑，让 nvm/sdk 等 init 脚本生效。
as_login_shell() {
  bash -lc "$*"
}

# append_once <file> <marker> <content>
# 在 file 中维护一对 marker 注释块。块内内容由 content 决定，重复调用相同 marker
# 会整块替换；marker 不重复出现。content 是多行字符串，会原样写入。
append_once() {
  local file="$1" marker="$2" content="$3"
  local begin="# >>> ${marker} >>>"
  local end="# <<< ${marker} <<<"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -qF "$begin" "$file"; then
    # 整块删除再写入
    local tmp; tmp=$(mktemp)
    awk -v b="$begin" -v e="$end" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      !skip {print}
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  fi
  printf '\n%s\n%s\n%s\n' "$begin" "$content" "$end" >> "$file"
}

# idempotent_apt_install <pkg...>: 仅安装尚未安装的包。
idempotent_apt_install() {
  local pkgs=() p
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p")
  done
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    log_info "apt 包已满足: $*"
    return 0
  fi
  log_info "apt 安装: ${pkgs[*]}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
}
```

- [ ] **Step 4: 跑测试，确认通过**

```bash
bash tests/test-common.sh
```
Expected: 输出末尾 `PASS=N FAIL=0`，退出码 0。

- [ ] **Step 5: 提交**

```bash
git add lib/common.sh tests/test-common.sh
git commit -m "feat: add lib/common.sh with log/idempotency helpers and tests"
```

---

## Task 3: install.sh 主入口与参数解析

**Files:**
- Create: `install.sh`

- [ ] **Step 1: 实现 `install.sh`**

```bash
#!/usr/bin/env bash
# DevEnvUbuntu 一键安装入口
# 用法: bash install.sh [--only NAME ...] [--skip NAME ...] [--no-mirror]
#                      [--skip-keepalive] [--git-user NAME] [--git-email ADDR]
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source lib/common.sh
# shellcheck disable=SC1091
source modules/versions.env

# CLI 参数
declare -a ONLY=() SKIP=()
export DEVENV_USE_MIRROR=1
export DEVENV_SKIP_KEEPALIVE=0
export DEVENV_GIT_USER=""
export DEVENV_GIT_EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY+=("$2"); shift 2 ;;
    --skip) SKIP+=("$2"); shift 2 ;;
    --no-mirror) DEVENV_USE_MIRROR=0; shift ;;
    --skip-keepalive) DEVENV_SKIP_KEEPALIVE=1; shift ;;
    --git-user) DEVENV_GIT_USER="$2"; shift 2 ;;
    --git-email) DEVENV_GIT_EMAIL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,5p' "$0"; exit 0 ;;
    *) log_error "未知参数: $1"; exit 2 ;;
  esac
done

# 日志目录
LOG_DIR="$HOME/.local/state/devenv"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"

# 主日志通过 tee 同时落到文件和终端
exec > >(tee -a "$LOG_FILE") 2>&1
log_info "DevEnvUbuntu 安装开始; 日志: $LOG_FILE"
log_info "参数: ONLY=[${ONLY[*]:-}], SKIP=[${SKIP[*]:-}], MIRROR=$DEVENV_USE_MIRROR, SKIP_KEEPALIVE=$DEVENV_SKIP_KEEPALIVE"

# 模块过滤逻辑
should_run() {
  local name="$1"
  if [[ ${#ONLY[@]} -gt 0 ]]; then
    local m
    for m in "${ONLY[@]}"; do [[ "$name" == "$m" || "$name" == "$m"* ]] && return 0; done
    return 1
  fi
  local m
  for m in "${SKIP[@]:-}"; do [[ "$name" == "$m" || "$name" == "$m"* ]] && return 1; done
  if [[ "$DEVENV_SKIP_KEEPALIVE" == "1" && "$name" == "12-keepalive" ]]; then return 1; fi
  return 0
}

trap 'log_error "失败于 $0:$LINENO（exit=$?）。日志: $LOG_FILE"' ERR

# 顺序执行
shopt -s nullglob
for module in modules/[0-9][0-9]-*.sh; do
  name="$(basename "$module" .sh)"
  if should_run "$name"; then
    log_info "▶ 运行模块 $name"
    bash "$module"
    log_info "✓ 完成 $name"
  else
    log_info "⏭  跳过 $name"
  fi
done

log_info "全部完成。如果在 WSL 下使用，请到 Windows 端运行 windows\\run-as-admin.bat"
```

- [ ] **Step 2: 设置可执行位**

```bash
chmod +x install.sh
```

- [ ] **Step 3: 试跑空配置（暂无任何模块文件，应直接结束）**

```bash
bash install.sh --skip-keepalive
```
Expected: 输出"全部完成"，无报错（modules/ 下还没有 NN-*.sh，循环空过）。

- [ ] **Step 4: 试跑 `--help`**

```bash
bash install.sh --help
```
Expected: 输出脚本顶部用法行。

- [ ] **Step 5: 提交**

```bash
git add install.sh
git commit -m "feat: add install.sh entry with arg parsing and module loop"
```

---

## Task 4: modules/00-detect.sh + 01-base.sh + 02-git.sh

**Files:**
- Create: `modules/00-detect.sh`
- Create: `modules/01-base.sh`
- Create: `modules/02-git.sh`

- [ ] **Step 1: 写 `modules/00-detect.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

UBU_VER=$(lsb_release -rs 2>/dev/null || echo "0")
log_info "Ubuntu 版本: $UBU_VER"
if ! awk -v v="$UBU_VER" 'BEGIN{exit !(v+0 >= 22.04)}'; then
  log_error "需要 Ubuntu 22.04 或更高，当前 $UBU_VER"
  exit 1
fi

if is_wsl; then
  log_info "运行环境: WSL"
  echo "DEVENV_IS_WSL=1" > "$HERE/.env.detected"
else
  log_info "运行环境: 原生 Linux"
  echo "DEVENV_IS_WSL=0" > "$HERE/.env.detected"
fi

if has_systemd; then
  log_info "systemd 已就绪"
  echo "DEVENV_HAS_SYSTEMD=1" >> "$HERE/.env.detected"
else
  log_warn "systemd 未启用；keepalive 模块需要 systemd（WSL 下请在 /etc/wsl.conf 加 [boot]\\nsystemd=true 后 wsl --shutdown 重启）"
  echo "DEVENV_HAS_SYSTEMD=0" >> "$HERE/.env.detected"
fi
```

- [ ] **Step 2: 写 `modules/01-base.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

if [[ "${DEVENV_USE_MIRROR:-1}" == "1" ]]; then
  if ! grep -q 'mirrors.ustc.edu.cn' /etc/apt/sources.list 2>/dev/null; then
    log_info "切换 apt 源到 USTC"
    sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak.devenv 2>/dev/null || true
    sudo sed -i 's|http://archive.ubuntu.com|https://mirrors.ustc.edu.cn|g; s|http://security.ubuntu.com|https://mirrors.ustc.edu.cn|g' /etc/apt/sources.list
  else
    log_info "apt 已是 USTC 源"
  fi
fi

log_info "apt update"
sudo apt-get update -qq

idempotent_apt_install \
  curl wget zip unzip git ca-certificates build-essential jq \
  software-properties-common gnupg lsb-release
```

- [ ] **Step 3: 写 `modules/02-git.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

require_cmd git "请先运行 modules/01-base.sh"

if [[ -n "${DEVENV_GIT_USER:-}" ]]; then
  git config --global user.name  "$DEVENV_GIT_USER"
  log_info "git user.name = $DEVENV_GIT_USER"
fi
if [[ -n "${DEVENV_GIT_EMAIL:-}" ]]; then
  git config --global user.email "$DEVENV_GIT_EMAIL"
  log_info "git user.email = $DEVENV_GIT_EMAIL"
fi
git config --global init.defaultBranch main
git config --global pull.rebase false
log_info "git 全局配置完成；当前 user.name=$(git config --global user.name || echo '<未设置>')"
```

- [ ] **Step 4: 设置可执行位 + Docker 中跑这三个模块**

```bash
chmod +x modules/00-detect.sh modules/01-base.sh modules/02-git.sh
bash tests/run-in-docker.sh --only 00-detect --only 01-base --only 02-git
```
Expected: 容器内三个模块全部走完，最后 `git --version` 在容器中可用（虽然容器测试看不到这一行，但 install.sh 应输出"全部完成"）。

- [ ] **Step 5: 在容器里再跑一次验证幂等**

```bash
docker run --rm -v "$(pwd)":/work -w /work ubuntu:22.04 bash -c '
  apt-get update -qq && apt-get install -y -qq sudo curl >/dev/null
  bash install.sh --only 00-detect --only 01-base --only 02-git --skip-keepalive
  echo "--- 第二次 ---"
  bash install.sh --only 00-detect --only 01-base --only 02-git --skip-keepalive
'
```
Expected: 第二次输出包含 `apt 包已满足:` 和 `apt 已是 USTC 源`，没有重复安装。

- [ ] **Step 6: 提交**

```bash
git add modules/00-detect.sh modules/01-base.sh modules/02-git.sh
git commit -m "feat: add detect, apt mirror swap + base packages, git config modules"
```

---

## Task 5: modules/03-sdkman.sh

**Files:**
- Create: `modules/03-sdkman.sh`

- [ ] **Step 1: 实现 `modules/03-sdkman.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"

if [[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]]; then
  log_info "SDKMAN 已安装于 $SDKMAN_DIR"
else
  log_info "安装 SDKMAN"
  curl -fsSL https://get.sdkman.io | bash
fi

# 镜像
if [[ "${DEVENV_USE_MIRROR:-1}" == "1" ]]; then
  CONFIG="$SDKMAN_DIR/etc/config"
  if ! grep -q 'sdkman.bfsu.edu.cn' "$CONFIG" 2>/dev/null; then
    log_info "切换 SDKMAN candidates 到 bfsu 镜像"
    echo "SDKMAN_CANDIDATES_API=https://sdkman.bfsu.edu.cn/candidates" >> "$CONFIG"
  fi
fi

# 注入 ~/.bashrc（统一 marker 块）
append_once "$HOME/.bashrc" "DevEnvUbuntu SDKMAN" "$(cat <<'EOF'
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
EOF
)"

# 验证（在子 shell 里 source）
as_login_shell 'sdk version' || { log_error "SDKMAN 安装失败"; exit 1; }
log_info "SDKMAN 就绪"
```

- [ ] **Step 2: 设置可执行位 + Docker 中验证**

```bash
chmod +x modules/03-sdkman.sh
bash tests/run-in-docker.sh --only 00-detect --only 01-base --only 03-sdkman
```
Expected: 容器内输出 `SDKMAN x.y.z`（sdk version 的输出）+ `SDKMAN 就绪`。

- [ ] **Step 3: 验证幂等**

```bash
docker run --rm -v "$(pwd)":/work -w /work ubuntu:22.04 bash -c '
  apt-get update -qq && apt-get install -y -qq sudo curl >/dev/null
  bash install.sh --only 00-detect --only 01-base --only 03-sdkman --skip-keepalive
  bash install.sh --only 03-sdkman --skip-keepalive
'
```
Expected: 第二次输出 `SDKMAN 已安装于 ...`，没有重新安装。

- [ ] **Step 4: 提交**

```bash
git add modules/03-sdkman.sh
git commit -m "feat: install SDKMAN with bfsu mirror"
```

---

## Task 6: modules/04-jdk.sh

**Files:**
- Create: `modules/04-jdk.sh`

- [ ] **Step 1: 实现 `modules/04-jdk.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/modules/versions.env"

require_cmd curl

# SDKMAN 必须在登录 shell 里才生效
as_login_shell "
  set -e
  if ! sdk list java 2>/dev/null | grep -qE 'installed.*${JDK8_VERSION}'; then
    sdk install java ${JDK8_VERSION} <<<n
  else
    echo 'JDK ${JDK8_VERSION} 已安装'
  fi
  if ! sdk list java 2>/dev/null | grep -qE 'installed.*${JDK17_VERSION}'; then
    sdk install java ${JDK17_VERSION} <<<n
  else
    echo 'JDK ${JDK17_VERSION} 已安装'
  fi
  sdk default java ${JDK8_VERSION}
  java -version 2>&1 | head -1
"
log_info "JDK 8 + 17 就绪，默认 ${JDK8_VERSION}"
```

> 备注：`sdk install` 末尾的 `<<<n` 是把"是否设为默认"的提问回答 `no`，最后用 `sdk default` 显式切到 8。

- [ ] **Step 2: 设置可执行位 + Docker 中验证**

```bash
chmod +x modules/04-jdk.sh
bash tests/run-in-docker.sh --only 00-detect --only 01-base --only 03-sdkman --only 04-jdk
```
Expected: 容器内输出 `openjdk version "1.8.0_xxx"`（JDK 8 默认）。

- [ ] **Step 3: 验证幂等**

```bash
docker run --rm -v "$(pwd)":/work -w /work ubuntu:22.04 bash -c '
  apt-get update -qq && apt-get install -y -qq sudo curl >/dev/null
  bash install.sh --only 00-detect --only 01-base --only 03-sdkman --only 04-jdk --skip-keepalive
  echo "--- 第二次 ---"
  bash install.sh --only 04-jdk --skip-keepalive
'
```
Expected: 第二次输出 `JDK ... 已安装` 两次。

- [ ] **Step 4: 提交**

```bash
git add modules/04-jdk.sh
git commit -m "feat: install JDK 8 (default) and 17 via SDKMAN"
```

---

## Task 7: modules/05-maven.sh + 阿里云 settings.xml

**Files:**
- Create: `modules/05-maven.sh`

- [ ] **Step 1: 实现 `modules/05-maven.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/modules/versions.env"

as_login_shell "
  set -e
  if ! sdk list maven 2>/dev/null | grep -qE 'installed.*${MAVEN_VERSION}'; then
    sdk install maven ${MAVEN_VERSION} <<<y
  else
    echo 'Maven ${MAVEN_VERSION} 已安装'
  fi
  mvn -v | head -1
"

# 写阿里云 mirror 到 ~/.m2/settings.xml
if [[ "${DEVENV_USE_MIRROR:-1}" == "1" ]]; then
  mkdir -p "$HOME/.m2"
  if [[ ! -f "$HOME/.m2/settings.xml" ]] || ! grep -q 'aliyun' "$HOME/.m2/settings.xml" 2>/dev/null; then
    log_info "写入阿里云 Maven mirror"
    cat > "$HOME/.m2/settings.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <mirrors>
    <mirror>
      <id>aliyun</id>
      <name>aliyun maven</name>
      <url>https://maven.aliyun.com/repository/public</url>
      <mirrorOf>central</mirrorOf>
    </mirror>
  </mirrors>
</settings>
EOF
  else
    log_info "Maven settings.xml 已含 aliyun mirror"
  fi
fi

log_info "Maven 就绪"
```

- [ ] **Step 2: 设置可执行位 + Docker 中验证**

```bash
chmod +x modules/05-maven.sh
bash tests/run-in-docker.sh --only 00-detect --only 01-base --only 03-sdkman --only 04-jdk --only 05-maven
```
Expected: 输出 `Apache Maven 3.9.9`。

- [ ] **Step 3: 验证幂等**

```bash
docker run --rm -v "$(pwd)":/work -w /work ubuntu:22.04 bash -c '
  apt-get update -qq && apt-get install -y -qq sudo curl >/dev/null
  bash install.sh --only 00-detect --only 01-base --only 03-sdkman --only 04-jdk --only 05-maven --skip-keepalive
  echo "--- 第二次 ---"
  bash install.sh --only 05-maven --skip-keepalive
'
```
Expected: 第二次输出 `Maven ... 已安装` 和 `Maven settings.xml 已含 aliyun mirror`。

- [ ] **Step 4: 提交**

```bash
git add modules/05-maven.sh
git commit -m "feat: install Maven with aliyun mirror settings.xml"
```

---

## Task 8: modules/06-nvm.sh

**Files:**
- Create: `modules/06-nvm.sh`

- [ ] **Step 1: 实现 `modules/06-nvm.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  log_info "nvm 已安装于 $NVM_DIR"
else
  log_info "安装 nvm（gitee 镜像）"
  if [[ "${DEVENV_USE_MIRROR:-1}" == "1" ]]; then
    export NVM_SOURCE='https://gitee.com/mirrors/nvm.git'
    git clone --depth=1 -b v0.40.1 "$NVM_SOURCE" "$NVM_DIR"
  else
    git clone --depth=1 -b v0.40.1 https://github.com/nvm-sh/nvm.git "$NVM_DIR"
  fi
fi

# 注入到 ~/.bashrc，包含 Node 二进制镜像变量
NODE_MIRROR_LINE=""
if [[ "${DEVENV_USE_MIRROR:-1}" == "1" ]]; then
  NODE_MIRROR_LINE='export NVM_NODEJS_ORG_MIRROR="https://npmmirror.com/mirrors/node/"'
fi

append_once "$HOME/.bashrc" "DevEnvUbuntu nvm" "$(cat <<EOF
export NVM_DIR="\$HOME/.nvm"
[[ -s "\$NVM_DIR/nvm.sh" ]] && source "\$NVM_DIR/nvm.sh"
[[ -s "\$NVM_DIR/bash_completion" ]] && source "\$NVM_DIR/bash_completion"
${NODE_MIRROR_LINE}
EOF
)"

as_login_shell 'nvm --version' || { log_error "nvm 加载失败"; exit 1; }
log_info "nvm 就绪"
```

- [ ] **Step 2: 设置可执行位 + Docker 中验证**

```bash
chmod +x modules/06-nvm.sh
bash tests/run-in-docker.sh --only 00-detect --only 01-base --only 06-nvm
```
Expected: 输出 `0.40.1`（nvm --version）。

- [ ] **Step 3: 验证幂等**

```bash
docker run --rm -v "$(pwd)":/work -w /work ubuntu:22.04 bash -c '
  apt-get update -qq && apt-get install -y -qq sudo curl >/dev/null
  bash install.sh --only 00-detect --only 01-base --only 06-nvm --skip-keepalive
  bash install.sh --only 06-nvm --skip-keepalive
'
```
Expected: 第二次输出 `nvm 已安装于 ...`。

- [ ] **Step 4: 提交**

```bash
git add modules/06-nvm.sh
git commit -m "feat: install nvm via gitee mirror with Node binary mirror env"
```

---

## Task 9: modules/07-node.sh

**Files:**
- Create: `modules/07-node.sh`

- [ ] **Step 1: 实现 `modules/07-node.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/modules/versions.env"

as_login_shell "
  set -e
  if ! nvm ls ${NODE_LTS} 2>/dev/null | grep -qE 'v${NODE_LTS}\\.'; then
    nvm install ${NODE_LTS} --lts
  else
    echo 'Node ${NODE_LTS} 已安装'
  fi
  nvm alias default ${NODE_LTS}
  node -v
  npm -v
"

# npm registry
if [[ "${DEVENV_USE_MIRROR:-1}" == "1" ]]; then
  as_login_shell '
    set -e
    current=$(npm config get registry)
    if [[ "$current" != *npmmirror.com* ]]; then
      npm config set registry https://registry.npmmirror.com
      echo "npm registry 已切换"
    else
      echo "npm registry 已是 npmmirror"
    fi
  '
fi

log_info "Node ${NODE_LTS} 就绪"
```

- [ ] **Step 2: 设置可执行位 + Docker 中验证**

```bash
chmod +x modules/07-node.sh
bash tests/run-in-docker.sh --only 00-detect --only 01-base --only 06-nvm --only 07-node
```
Expected: 输出 `v20.x.y` 和 `10.x.y`（npm）。

- [ ] **Step 3: 验证幂等**

```bash
docker run --rm -v "$(pwd)":/work -w /work ubuntu:22.04 bash -c '
  apt-get update -qq && apt-get install -y -qq sudo curl >/dev/null
  bash install.sh --only 00-detect --only 01-base --only 06-nvm --only 07-node --skip-keepalive
  bash install.sh --only 07-node --skip-keepalive
'
```
Expected: 第二次输出 `Node 20 已安装` 和 `npm registry 已是 npmmirror`。

- [ ] **Step 4: 提交**

```bash
git add modules/07-node.sh
git commit -m "feat: install Node 20 LTS via nvm with npmmirror registry"
```

---

## Task 10: modules/08-pyenv.sh

**Files:**
- Create: `modules/08-pyenv.sh`

- [ ] **Step 1: 实现 `modules/08-pyenv.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"

# Python 编译依赖
idempotent_apt_install \
  make libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
  libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev \
  liblzma-dev

if [[ -d "$PYENV_ROOT/.git" ]]; then
  log_info "pyenv 已安装于 $PYENV_ROOT"
else
  if [[ "${DEVENV_USE_MIRROR:-1}" == "1" ]]; then
    git clone --depth=1 https://gitee.com/mirrors/pyenv "$PYENV_ROOT"
  else
    git clone --depth=1 https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
  fi
fi

append_once "$HOME/.bashrc" "DevEnvUbuntu pyenv" "$(cat <<'EOF'
export PYENV_ROOT="$HOME/.pyenv"
[[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - bash 2>/dev/null || true)"
EOF
)"

as_login_shell 'pyenv --version' || { log_error "pyenv 加载失败"; exit 1; }
log_info "pyenv 就绪"
```

- [ ] **Step 2: 设置可执行位 + Docker 中验证**

```bash
chmod +x modules/08-pyenv.sh
bash tests/run-in-docker.sh --only 00-detect --only 01-base --only 08-pyenv
```
Expected: 输出 `pyenv 2.x.y`。

- [ ] **Step 3: 验证幂等**

```bash
docker run --rm -v "$(pwd)":/work -w /work ubuntu:22.04 bash -c '
  apt-get update -qq && apt-get install -y -qq sudo curl >/dev/null
  bash install.sh --only 00-detect --only 01-base --only 08-pyenv --skip-keepalive
  bash install.sh --only 08-pyenv --skip-keepalive
'
```
Expected: 第二次 `pyenv 已安装于 ...`，apt 包都已满足。

- [ ] **Step 4: 提交**

```bash
git add modules/08-pyenv.sh
git commit -m "feat: install pyenv via gitee mirror with build deps"
```

---

## Task 11: modules/09-python.sh

**Files:**
- Create: `modules/09-python.sh`

- [ ] **Step 1: 实现 `modules/09-python.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/modules/versions.env"

as_login_shell "
  set -e
  if ! pyenv versions 2>/dev/null | grep -qE '^\\s*\\*?\\s*${PYTHON_VERSION}'; then
    if [[ '${DEVENV_USE_MIRROR:-1}' == '1' ]]; then
      export PYTHON_BUILD_MIRROR_URL=https://npmmirror.com/mirrors/python/
      export PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM=0
    fi
    pyenv install ${PYTHON_VERSION}
  else
    echo 'Python ${PYTHON_VERSION} 已安装'
  fi
  pyenv global ${PYTHON_VERSION}
  python --version
  pip --version
"

# pip.conf 走清华
if [[ "${DEVENV_USE_MIRROR:-1}" == "1" ]]; then
  mkdir -p "$HOME/.pip"
  if [[ ! -f "$HOME/.pip/pip.conf" ]] || ! grep -q 'tsinghua' "$HOME/.pip/pip.conf" 2>/dev/null; then
    log_info "写入清华 PyPI 镜像到 ~/.pip/pip.conf"
    cat > "$HOME/.pip/pip.conf" <<'EOF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
EOF
  else
    log_info "pip.conf 已含清华镜像"
  fi
fi

log_info "Python ${PYTHON_VERSION} 就绪"
```

- [ ] **Step 2: 设置可执行位 + Docker 中验证**

```bash
chmod +x modules/09-python.sh
bash tests/run-in-docker.sh --only 00-detect --only 01-base --only 08-pyenv --only 09-python
```
Expected: 输出 `Python 3.12.7` 和 `pip 24.x`（pyenv install 编译比较慢，5-10 分钟正常）。

- [ ] **Step 3: 验证幂等**

```bash
docker run --rm -v "$(pwd)":/work -w /work ubuntu:22.04 bash -c '
  apt-get update -qq && apt-get install -y -qq sudo curl >/dev/null
  bash install.sh --only 00-detect --only 01-base --only 08-pyenv --only 09-python --skip-keepalive
  echo "--- 第二次 ---"
  bash install.sh --only 09-python --skip-keepalive
'
```
Expected: 第二次输出 `Python 3.12.7 已安装` 和 `pip.conf 已含清华镜像`。

- [ ] **Step 4: 提交**

```bash
git add modules/09-python.sh
git commit -m "feat: install Python 3.12 via pyenv with tsinghua pip mirror"
```

---

## Task 12: modules/10-claude-code.sh + 11-clautel.sh

**Files:**
- Create: `modules/10-claude-code.sh`
- Create: `modules/11-clautel.sh`

- [ ] **Step 1: 实现 `modules/10-claude-code.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

as_login_shell '
  set -e
  if npm ls -g --depth=0 2>/dev/null | grep -q "@anthropic-ai/claude-code@"; then
    echo "claude-code 已安装"
  else
    npm i -g @anthropic-ai/claude-code
  fi
  command -v claude && claude --version || true
'
log_info "Claude Code CLI 就绪。请稍后手动运行 claude login 完成认证。"
```

- [ ] **Step 2: 实现 `modules/11-clautel.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

as_login_shell '
  set -e
  if npm ls -g --depth=0 2>/dev/null | grep -q " clautel@"; then
    echo "clautel 已安装"
  else
    npm i -g clautel
  fi
  command -v clautel && clautel --version || true
'
log_info "clautel 就绪"
```

- [ ] **Step 3: 设置可执行位 + Docker 中验证**

```bash
chmod +x modules/10-claude-code.sh modules/11-clautel.sh
bash tests/run-in-docker.sh --only 00-detect --only 01-base --only 06-nvm --only 07-node --only 10-claude-code --only 11-clautel
```
Expected: 输出 `claude X.Y.Z` 与 `clautel X.Y.Z`，PATH 中两条命令都可用。

- [ ] **Step 4: 验证幂等**

```bash
docker run --rm -v "$(pwd)":/work -w /work ubuntu:22.04 bash -c '
  apt-get update -qq && apt-get install -y -qq sudo curl >/dev/null
  bash install.sh --only 00-detect --only 01-base --only 06-nvm --only 07-node --only 10-claude-code --only 11-clautel --skip-keepalive
  bash install.sh --only 10-claude-code --only 11-clautel --skip-keepalive
'
```
Expected: 第二次两个模块都输出 `已安装`。

- [ ] **Step 5: 提交**

```bash
git add modules/10-claude-code.sh modules/11-clautel.sh
git commit -m "feat: install claude-code CLI and clautel via npm"
```

---

## Task 13: systemd/ 模板 + modules/12-keepalive.sh

**Files:**
- Create: `systemd/clautel.service`
- Create: `systemd/net-keepalive.service`
- Create: `systemd/net-keepalive.timer`
- Create: `modules/12-keepalive.sh`

- [ ] **Step 1: 写 `systemd/clautel.service`**

```ini
[Unit]
Description=Clautel daemon (DevEnvUbuntu)
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

- [ ] **Step 2: 写 `systemd/net-keepalive.service`**

```ini
[Unit]
Description=DevEnvUbuntu network liveness probe

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'ping -c1 -W3 1.1.1.1 >/dev/null || ping -c1 -W3 8.8.8.8 >/dev/null || echo "$(date -Iseconds) network unreachable" >> %h/.local/state/clautel/net.log; exit 0'
```

- [ ] **Step 3: 写 `systemd/net-keepalive.timer`**

```ini
[Unit]
Description=Run net-keepalive every 5 min

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=net-keepalive.service

[Install]
WantedBy=timers.target
```

- [ ] **Step 4: 实现 `modules/12-keepalive.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

if ! has_systemd; then
  log_error "systemd 未运行；如在 WSL 内，请编辑 /etc/wsl.conf 加入：\n[boot]\nsystemd=true\n然后在 PowerShell 跑 wsl --shutdown，再重新打开 WSL 后重跑本模块。"
  exit 1
fi

# 在 WSL 下顺便确保 /etc/wsl.conf 启用了 systemd（写入但不重启）
if is_wsl; then
  if ! grep -qE '^\s*systemd\s*=\s*true' /etc/wsl.conf 2>/dev/null; then
    log_info "向 /etc/wsl.conf 写入 [boot] systemd=true"
    sudo tee -a /etc/wsl.conf >/dev/null <<'EOF'

[boot]
systemd=true
EOF
    log_warn "已写入 wsl.conf，但当前会话仍是旧状态。下次 wsl --shutdown 后才会完全生效。"
  fi
fi

mkdir -p "$HOME/.local/state/clautel"
mkdir -p "$HOME/.config/systemd/user"

cp "$HERE/systemd/clautel.service"        "$HOME/.config/systemd/user/clautel.service"
cp "$HERE/systemd/net-keepalive.service"  "$HOME/.config/systemd/user/net-keepalive.service"
cp "$HERE/systemd/net-keepalive.timer"    "$HOME/.config/systemd/user/net-keepalive.timer"

systemctl --user daemon-reload
systemctl --user enable --now clautel.service net-keepalive.timer

# 让用户没登录时也跑（关键）
sudo loginctl enable-linger "$USER" 2>/dev/null || log_warn "loginctl enable-linger 失败，可能需要 root 权限"

systemctl --user is-active clautel.service     >/dev/null && log_info "clautel.service 活跃"
systemctl --user is-active net-keepalive.timer >/dev/null && log_info "net-keepalive.timer 活跃"
log_info "keepalive 就绪"
```

- [ ] **Step 5: 设置可执行位**

```bash
chmod +x modules/12-keepalive.sh
```

- [ ] **Step 6: 在真实 WSL2 / Ubuntu（非 Docker）上验证**

> Docker 没 systemd，本任务**必须在真实环境验证**。

```bash
# 在 WSL2 里：
bash install.sh --only 12-keepalive
systemctl --user status clautel.service --no-pager
systemctl --user list-timers --user
```
Expected: `clautel.service` 状态 `active (running)`；`net-keepalive.timer` 出现在 list-timers 中。

- [ ] **Step 7: 验证崩溃自拉起**

```bash
PID=$(pgrep -f "exec clautel" | head -1)
kill "$PID"
sleep 8
pgrep -f "exec clautel"
```
Expected: 输出新的 PID（与原 PID 不同）。

- [ ] **Step 8: 提交**

```bash
git add systemd/ modules/12-keepalive.sh
git commit -m "feat: deploy clautel + net-keepalive systemd user services"
```

---

## Task 14: Windows 端脚本（run-as-admin.bat、setup-keepalive.ps1、wslconfig.template）

**Files:**
- Create: `windows/run-as-admin.bat`
- Create: `windows/setup-keepalive.ps1`
- Create: `windows/wslconfig.template`

- [ ] **Step 1: 写 `windows/wslconfig.template`**

```ini
# 由 DevEnvUbuntu setup-keepalive.ps1 自动写入 %USERPROFILE%\.wslconfig
# 如需手动修改，请保留 [wsl2] 段
[wsl2]
vmIdleTimeout=2147483647
guiApplications=true
```

- [ ] **Step 2: 写 `windows/setup-keepalive.ps1`**

```powershell
# 注册任务计划：登录时启动 wsl 并跑 sleep infinity
# 同时把 wslconfig.template 写入 $env:USERPROFILE\.wslconfig
[CmdletBinding()]
param(
  [string]$Distro = "Ubuntu",
  [string]$WslUser
)

$ErrorActionPreference = "Stop"

# 校验管理员
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Error "请用管理员权限运行（双击 run-as-admin.bat）"
  exit 1
}

# 1) 写 .wslconfig
$repoRoot = Split-Path -Parent $PSCommandPath
$src = Join-Path $repoRoot "wslconfig.template"
$dst = Join-Path $env:USERPROFILE ".wslconfig"
Copy-Item $src $dst -Force
Write-Host "[OK] 已写入 $dst"

# 2) 决定 wsl 用户
if (-not $WslUser) {
  $WslUser = (wsl.exe -d $Distro -e whoami).Trim()
}
Write-Host "[INFO] 目标 distro=$Distro user=$WslUser"

# 3) 注册任务计划
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

# 4) 立即跑一次
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
Write-Host "[OK] 任务已触发；从任务管理器应能看到 wsl.exe 进程"

# 5) 在 WSL 里写标记文件，供 99-verify.sh 读取
& wsl.exe -d $Distro -u $WslUser -e bash -c "mkdir -p ~/.local/state/devenv && touch ~/.local/state/devenv/windows-keepalive-installed"
Write-Host "[OK] WSL 端已写入标记文件"

Write-Host ""
Write-Host "=== 完成 ===" -ForegroundColor Green
Write-Host "如需停止保活，删除任务计划 '$taskName' 即可。"
```

- [ ] **Step 3: 写 `windows/run-as-admin.bat`**

```bat
@echo off
REM DevEnvUbuntu - 一键申请管理员权限并执行 setup-keepalive.ps1
fltmc >nul 2>&1
if %errorlevel% neq 0 (
  echo 申请管理员权限...
  powershell -Command "Start-Process -FilePath '%~dpnx0' -ArgumentList '%*' -Verb RunAs"
  exit /b
)
echo 已是管理员权限,执行 setup-keepalive.ps1...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-keepalive.ps1" %*
echo.
echo === 按任意键关闭 ===
pause >nul
```

- [ ] **Step 4: 在真实 Windows 11 上验证**

> 必须在真实 Windows 11 + 已装好 WSL2 + 已跑过 Linux 端 install.sh 的环境验证。

```
1. 双击 windows\run-as-admin.bat
2. UAC 弹窗 → 同意
3. 应看到三行 [OK] 输出 + "完成"
4. 打开任务管理器 → 详细信息 → 找 wsl.exe 进程，应该存在
5. 在 WSL 里跑：ls ~/.local/state/devenv/windows-keepalive-installed → 文件存在
```

- [ ] **Step 5: 验证开机自启（可选，需要重启 Windows）**

```
1. 重启 Windows
2. 不开任何终端，等 1 分钟
3. 任务管理器看是否有 wsl.exe 进程
4. PowerShell 里跑：Get-ScheduledTaskInfo -TaskName DevEnvUbuntu-WSL-Keepalive
   应输出 LastTaskResult=0
```

- [ ] **Step 6: 提交**

```bash
git add windows/
git commit -m "feat: add Windows UAC bat + ps1 to register WSL keepalive task"
```

---

## Task 15: modules/99-verify.sh

**Files:**
- Create: `modules/99-verify.sh`

- [ ] **Step 1: 实现 `modules/99-verify.sh`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/modules/versions.env"

PASS=0; FAIL=0
row() {
  local status="$1" name="$2" detail="$3"
  printf '[%s]  %-22s %s\n' "$status" "$name" "$detail"
  [[ "$status" == "OK" ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
}

echo "=== DevEnvUbuntu 安装结果 ==="

check_cmd() {
  local cmd="$1" name="$2"
  if v=$(as_login_shell "$cmd" 2>&1); then
    row OK "$name" "${v%$'\n'*}"
  else
    row FAIL "$name" "未在 PATH 中找到或无法执行: $cmd"
  fi
}

check_cmd 'git --version'        'git'
check_cmd 'java -version 2>&1 | head -1' 'java (default)'
check_cmd "sdk list java 2>/dev/null | grep -E 'installed.*${JDK17_VERSION}' | head -1" "java 17 可切换"
check_cmd 'mvn -v | head -1'     'mvn'
check_cmd 'node -v'              'node'
check_cmd 'npm -v'               'npm'
check_cmd 'python --version'     'python'
check_cmd 'pip --version'        'pip'
check_cmd 'claude --version 2>&1 | head -1' 'claude'
check_cmd 'clautel --version 2>&1 | head -1' 'clautel'

if has_systemd; then
  if systemctl --user is-active clautel.service >/dev/null 2>&1; then
    row OK 'clautel.service' "$(systemctl --user is-active clautel.service)"
  else
    row FAIL 'clautel.service' '未激活；运行 bash install.sh --only 12-keepalive'
  fi
  if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes$'; then
    row OK 'loginctl linger' 'enabled'
  else
    row FAIL 'loginctl linger' '未启用；运行 sudo loginctl enable-linger $USER'
  fi
else
  row FAIL 'systemd' '未运行（WSL 用户请检查 /etc/wsl.conf）'
fi

if is_wsl; then
  if [[ -f "$HOME/.local/state/devenv/windows-keepalive-installed" ]]; then
    row OK 'wsl-keepalive 任务' '已注册（标记文件存在）'
  else
    row FAIL 'wsl-keepalive 任务' '请到 Windows 端运行 windows\\run-as-admin.bat'
  fi
fi

echo "================================"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]]
```

- [ ] **Step 2: 设置可执行位 + 在 Docker 中跑全流程（除 keepalive）**

```bash
chmod +x modules/99-verify.sh
docker run --rm -v "$(pwd)":/work -w /work ubuntu:22.04 bash -c '
  apt-get update -qq && apt-get install -y -qq sudo curl >/dev/null
  bash install.sh --skip-keepalive
'
```
Expected: 末尾打印对照表，`PASS>=10`，`FAIL` 仅来自缺失的 keepalive/linger 项（在 Docker 里没 systemd 是预期的）。

- [ ] **Step 3: 在真实 WSL/Ubuntu 上跑全流程**

```bash
bash install.sh
```
Expected: `FAIL=0` 或仅 `wsl-keepalive 任务` 一项失败（之后手动跑 Windows 端脚本即可补齐）。

- [ ] **Step 4: 提交**

```bash
git add modules/99-verify.sh
git commit -m "feat: verify all tools in PATH and services active"
```

---

## Task 16: README + 端到端冒烟测试 + tests/smoke.sh

**Files:**
- Create: `tests/smoke.sh`
- Modify: `README.md`（重写）

- [ ] **Step 1: 写 `tests/smoke.sh`**

```bash
#!/usr/bin/env bash
# 在已经跑过 install.sh 的环境上做扩展冒烟检查
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

bash "$HERE/modules/99-verify.sh" || true

# 1) JDK 切换：8 ↔ 17 都能跑
as_login_shell '
  set -e
  echo "--- 切到 17 ---"
  sdk use java 17.0.13-tem
  java -version 2>&1 | head -1
  echo "--- 切回 8 ---"
  sdk use java 8.0.422-tem
  java -version 2>&1 | head -1
'

# 2) npm 全局命令在 PATH 中
as_login_shell 'command -v claude && command -v clautel'

# 3) maven 能解析阿里云 mirror
grep -q 'aliyun' "$HOME/.m2/settings.xml" && echo "[OK] Maven mirror=aliyun"

# 4) pip 走清华
grep -q 'tsinghua' "$HOME/.pip/pip.conf" && echo "[OK] pip mirror=tsinghua"

echo "smoke 完成"
```

- [ ] **Step 2: 重写 `README.md`**

````markdown
# DevEnvUbuntu

一键安装 Ubuntu 22.04+（含 Windows 11 WSL2）开发环境：

- **JDK 8（默认）+ JDK 17**（SDKMAN 管理，`sdk use java 17.0.13-tem` 切换）
- **Node.js 20 LTS**（nvm，npm 走 npmmirror）
- **Python 3.12**（pyenv，pip 走清华）
- **Git**、**Maven 3.9.x**（settings.xml 走阿里云）
- **Claude Code CLI** + **clautel**（npm 全局）
- WSL2 下"始终在线"四件套：Windows 开机自启 WSL、不空闲超时、clautel 崩溃自拉起、网络保活记录

## 一键安装（Linux/WSL 端）

```bash
git clone https://github.com/<you>/DevEnvUbuntu.git
cd DevEnvUbuntu
bash install.sh
```

可选参数：
| 参数 | 说明 |
|---|---|
| `--no-mirror` | 关闭国内镜像（apt/SDKMAN/npm/pip/Maven 走官方） |
| `--skip-keepalive` | 跳过 systemd user services 部署（CI 场景） |
| `--only NAME` | 只跑指定模块；可多次传 |
| `--skip NAME` | 跳过指定模块；可多次传 |
| `--git-user NAME` `--git-email ADDR` | 写入 git 全局 user.name/email |

完成后请运行 `claude login` 完成 Claude 认证。

## Windows 端（仅 WSL2 用户）

完成 Linux 端安装后：

1. 在文件资源管理器中找到 `windows\run-as-admin.bat`，**双击**
2. UAC 弹窗 → 同意（脚本会自动以管理员重启）
3. 看到 "=== 完成 ===" 即成功

这一步会：
- 写入 `%USERPROFILE%\.wslconfig`（防止 WSL 空闲超时关闭）
- 注册 Windows 任务计划 `DevEnvUbuntu-WSL-Keepalive`，登录时跑 `wsl ... sleep infinity` 维持 WSL 在线

## 验证

```bash
bash modules/99-verify.sh
# 或扩展冒烟测试
bash tests/smoke.sh
```

## WSL 启用 systemd

`12-keepalive` 模块需要 systemd。如果你的 WSL 还没启用：

1. 编辑 `/etc/wsl.conf`，加入：
   ```ini
   [boot]
   systemd=true
   ```
2. 在 PowerShell 跑 `wsl --shutdown`
3. 重新打开 WSL 终端，再跑 `bash install.sh --only 12-keepalive`

（`12-keepalive` 模块会自动写入这段配置，但需要你手动 `wsl --shutdown` 一次。）

## 卸载/清理

- SDKMAN：`rm -rf ~/.sdkman` 并清掉 `~/.bashrc` 中 `# >>> DevEnvUbuntu SDKMAN >>>` 块
- nvm / pyenv 同理：`rm -rf ~/.nvm ~/.pyenv` + 清块
- npm 全局：`npm uninstall -g @anthropic-ai/claude-code clautel`
- systemd 服务：`systemctl --user disable --now clautel.service net-keepalive.timer && rm ~/.config/systemd/user/{clautel,net-keepalive}.{service,timer}`
- Windows 任务：`Unregister-ScheduledTask -TaskName DevEnvUbuntu-WSL-Keepalive -Confirm:$false`

## 常见问题

**Q：第二次跑 install.sh 会重复装吗？**
A：不会。每个模块开头都有"已就绪"判断，重跑只会快速核对。

**Q：在公司内网无法访问 github 怎么办？**
A：默认就走国内镜像（USTC/bfsu/gitee/npmmirror/清华/阿里云）。如果连 gitee 也不通，可设置 HTTP 代理：`https_proxy=http://your-proxy ALL_PROXY=http://your-proxy bash install.sh`。

**Q：clautel 启动时怎么传配置/key？**
A：本项目只负责把 `clautel` 装到 PATH。具体启动参数/认证方式见 clautel 自身文档；如果它需要环境变量，在 `~/.config/systemd/user/clautel.service.d/env.conf`（drop-in 目录）中追加 `Environment=KEY=VALUE`。

## 详细设计

[docs/superpowers/specs/2026-05-10-dev-env-installer-design.md](docs/superpowers/specs/2026-05-10-dev-env-installer-design.md)
````

- [ ] **Step 3: 设置可执行位**

```bash
chmod +x tests/smoke.sh
```

- [ ] **Step 4: 端到端冒烟（在真实 WSL/Ubuntu）**

```bash
bash install.sh
bash tests/smoke.sh
```
Expected: `99-verify.sh` 输出 `FAIL=0`（如已跑 Windows 端脚本）；JDK 切换 8↔17 输出预期版本；最后 `smoke 完成`。

- [ ] **Step 5: 提交**

```bash
git add README.md tests/smoke.sh
git commit -m "docs: README + tests/smoke.sh end-to-end check"
```

---

## 自检（Plan Self-Review）

| 关卡 | 状态 |
|---|---|
| Spec §1 目标与非目标 → 全部覆盖 | ✓ |
| Spec §3 目录结构 → Task 1/3/13/14/15 实现 | ✓ |
| Spec §4 模块职责表（00-99）→ Task 4–15 一一对应 | ✓ |
| Spec §5 四层始终在线 → Task 13（systemd）+ Task 14（Windows） | ✓ |
| Spec §6 错误处理/幂等/日志 → Task 2 lib/common.sh + Task 3 install.sh + 各模块开头检测 | ✓ |
| Spec §7 验证 → Task 15 99-verify.sh + Task 16 smoke.sh | ✓ |
| 类型/方法签名一致性：`append_once`、`idempotent_apt_install`、`as_login_shell`、`is_wsl`、`has_systemd` 在 Task 2 定义后被各模块调用，命名一致 | ✓ |
| 占位符扫描：无 TBD/TODO；每步都给出完整 code/cmd/expected | ✓ |
