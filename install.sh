#!/usr/bin/env bash
# DevEnvUbuntu 一键安装入口
# 用法: bash install.sh [--only NAME ...] [--skip NAME ...] [--mirror]
#                      [--skip-keepalive] [--git-user NAME] [--git-email ADDR]
#                      [--status] [--yes]
# 默认走官方上游(api.sdkman.io / nodejs.org / pypi.org / 等)。
# 想用国内镜像加速请显式加 --mirror。
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source lib/common.sh
# shellcheck disable=SC1091
source modules/versions.env

# CLI 参数
declare -a ONLY=() SKIP=()
export DEVENV_USE_MIRROR=0          # 默认: 不用镜像,走上游
export DEVENV_SKIP_KEEPALIVE=0
export DEVENV_GIT_USER=""
export DEVENV_GIT_EMAIL=""
STATUS_ONLY=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY+=("$2"); shift 2 ;;
    --skip) SKIP+=("$2"); shift 2 ;;
    --mirror) DEVENV_USE_MIRROR=1; shift ;;
    --no-mirror) DEVENV_USE_MIRROR=0; shift ;;     # 兼容旧用法
    --skip-keepalive) DEVENV_SKIP_KEEPALIVE=1; shift ;;
    --git-user) DEVENV_GIT_USER="$2"; shift 2 ;;
    --git-email) DEVENV_GIT_EMAIL="$2"; shift 2 ;;
    --status) STATUS_ONLY=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help)
      sed -n '2,8p' "$0"; exit 0 ;;
    *) log_error "未知参数: $1"; exit 2 ;;
  esac
done

# ---- 状态扫描 ---------------------------------------------------------------
# 输出三列: 状态 / 工具 / 详情
# 状态: ✓ 已装  ✗ 未装  ⊘ 不适用
print_status_table() {
  local fmt='  %-3s %-16s %s\n'
  printf "$fmt" "  " "工具" "状态/详情"
  printf "$fmt" "──" "────" "──────────"

  # git
  if command -v git >/dev/null 2>&1; then
    printf "$fmt" "✓" "git" "$(git --version 2>/dev/null | awk '{print $3}')"
  else
    printf "$fmt" "✗" "git" "未装"
  fi

  # SDKMAN
  if [[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]]; then
    printf "$fmt" "✓" "SDKMAN" "$HOME/.sdkman"
  else
    printf "$fmt" "✗" "SDKMAN" "未装"
  fi

  # JDK
  if [[ -d "$HOME/.sdkman/candidates/java" ]]; then
    local jdks
    jdks=$(ls "$HOME/.sdkman/candidates/java" 2>/dev/null | grep -v '^current$' | tr '\n' ' ')
    if [[ -n "$jdks" ]]; then
      printf "$fmt" "✓" "JDK" "$jdks"
    else
      printf "$fmt" "✗" "JDK" "未装"
    fi
  else
    printf "$fmt" "✗" "JDK" "未装"
  fi

  # Maven
  if [[ -d "$HOME/.sdkman/candidates/maven" ]]; then
    local mvns
    mvns=$(ls "$HOME/.sdkman/candidates/maven" 2>/dev/null | grep -v '^current$' | tr '\n' ' ')
    if [[ -n "$mvns" ]]; then
      printf "$fmt" "✓" "Maven" "$mvns"
    else
      printf "$fmt" "✗" "Maven" "未装"
    fi
  else
    printf "$fmt" "✗" "Maven" "未装"
  fi

  # nvm
  if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    printf "$fmt" "✓" "nvm" "$HOME/.nvm"
  else
    printf "$fmt" "✗" "nvm" "未装"
  fi

  # Node
  if [[ -d "$HOME/.nvm/versions/node" ]]; then
    local nodes
    nodes=$(ls "$HOME/.nvm/versions/node" 2>/dev/null | tr '\n' ' ')
    if [[ -n "$nodes" ]]; then
      printf "$fmt" "✓" "Node" "$nodes"
    else
      printf "$fmt" "✗" "Node" "未装"
    fi
  else
    printf "$fmt" "✗" "Node" "未装"
  fi

  # pyenv
  if [[ -d "$HOME/.pyenv/.git" ]]; then
    printf "$fmt" "✓" "pyenv" "$HOME/.pyenv"
  else
    printf "$fmt" "✗" "pyenv" "未装"
  fi

  # Python
  if [[ -d "$HOME/.pyenv/versions" ]]; then
    local pys
    pys=$(ls "$HOME/.pyenv/versions" 2>/dev/null | tr '\n' ' ')
    if [[ -n "$pys" ]]; then
      printf "$fmt" "✓" "Python" "$pys"
    else
      printf "$fmt" "✗" "Python" "未装"
    fi
  else
    printf "$fmt" "✗" "Python" "未装"
  fi

  # claude-code / clautel (依赖 npm; 必须用 as_login_shell 才能拿到 nvm 注入的 npm)
  local npm_globals
  npm_globals=$(as_login_shell 'command -v npm >/dev/null 2>&1 && npm ls -g --depth=0 2>/dev/null' 2>/dev/null || true)
  if [[ -n "$npm_globals" ]]; then
    if printf '%s' "$npm_globals" | grep -q '@anthropic-ai/claude-code@'; then
      local v
      v=$(printf '%s' "$npm_globals" | grep -oE '@anthropic-ai/claude-code@[^ ]+' | head -1 | sed 's/.*@//')
      printf "$fmt" "✓" "claude-code" "$v"
    else
      printf "$fmt" "✗" "claude-code" "未装"
    fi
    if printf '%s' "$npm_globals" | grep -qE '(^|[^A-Za-z])clautel@'; then
      local v
      v=$(printf '%s' "$npm_globals" | grep -oE '(^|[^A-Za-z])clautel@[^ ]+' | head -1 | sed 's/.*clautel@//')
      printf "$fmt" "✓" "clautel" "$v"
    else
      printf "$fmt" "✗" "clautel" "未装"
    fi
  else
    printf "$fmt" "⊘" "claude-code" "需要 Node/npm 先就位"
    printf "$fmt" "⊘" "clautel" "需要 Node/npm 先就位"
  fi

  # systemd 与 keepalive
  if [[ -d /run/systemd/system ]]; then
    if systemctl --user is-active clautel.service >/dev/null 2>&1; then
      printf "$fmt" "✓" "clautel.service" "active"
    else
      printf "$fmt" "✗" "clautel.service" "未启用 (systemd 已就绪)"
    fi
  else
    printf "$fmt" "⊘" "clautel.service" "systemd 未运行 (WSL 需启用)"
  fi
}

# 模块过滤逻辑
should_run() {
  local name="$1"
  if [[ ${#ONLY[@]} -gt 0 ]]; then
    local m
    for m in "${ONLY[@]}"; do [[ "$name" == "$m" || "$name" == "$m"* ]] && return 0; done
    return 1
  fi
  if [[ ${#SKIP[@]} -gt 0 ]]; then
    local m
    for m in "${SKIP[@]}"; do [[ "$name" == "$m" || "$name" == "$m"* ]] && return 1; done
  fi
  if [[ "$DEVENV_SKIP_KEEPALIVE" == "1" && "$name" == "12-keepalive" ]]; then return 1; fi
  return 0
}

# 列出本次将执行的模块
list_planned_modules() {
  shopt -s nullglob
  local module name
  for module in modules/[0-9][0-9]-*.sh; do
    name="$(basename "$module" .sh)"
    if should_run "$name"; then
      printf "  ▶ %s\n" "$name"
    else
      printf "  ⏭  %s (跳过)\n" "$name"
    fi
  done
}

# ---- --status 模式: 只看不装 ------------------------------------------------
if [[ "$STATUS_ONLY" == "1" ]]; then
  echo "=== DevEnvUbuntu 当前状态 ==="
  print_status_table
  exit 0
fi

# 日志目录(--status 之后再建,避免误导)
LOG_DIR="$HOME/.local/state/devenv"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"

# 主日志通过 tee 同时落到文件和终端
exec > >(tee -a "$LOG_FILE") 2>&1
log_info "DevEnvUbuntu 安装开始; 日志: $LOG_FILE"
log_info "参数: ONLY=[${ONLY[*]:-}], SKIP=[${SKIP[*]:-}], MIRROR=$DEVENV_USE_MIRROR, SKIP_KEEPALIVE=$DEVENV_SKIP_KEEPALIVE"

# ---- 安装前 dashboard -----------------------------------------------------
echo
echo "=== 当前状态 ==="
print_status_table
echo
echo "=== 本次将执行的模块 ==="
list_planned_modules
echo
echo "提示:"
echo "  - 默认走官方上游;如需国内镜像加速:  bash install.sh --mirror"
echo "  - 只装某几项:    bash install.sh --only 04-jdk --only 05-maven"
echo "  - 跳过某几项:    bash install.sh --skip 12-keepalive"
echo "  - 只看不装:      bash install.sh --status"
echo

# 交互式确认(stdin 是 TTY 且未传 -y 时才问)
if [[ "$ASSUME_YES" != "1" && -t 0 ]]; then
  read -r -p "确认开始安装? [Y/n] " ans
  case "${ans:-Y}" in
    [Yy]|[Yy][Ee][Ss]|"") ;;
    *) log_info "已取消。"; exit 0 ;;
  esac
fi

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

echo
echo "=== 安装后状态 ==="
print_status_table
echo

log_info "全部完成。如果在 WSL 下使用,请到 Windows 端运行 windows\\run-as-admin.bat"
echo
echo "⚠️  当前终端是 install 之前打开的,PATH 还是旧的(node/claude/sdk 找不到)。"
echo "    请执行下面任一种让新工具生效:"
echo "      a) 关闭这个终端,开一个新的(推荐)"
echo "      b) 在当前终端执行: exec bash -l"
echo "      c) 或者: source ~/.bashrc"
echo
