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
