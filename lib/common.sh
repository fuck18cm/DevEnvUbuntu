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

# as_login_shell <command...>: 在 SDKMAN / nvm / pyenv 都已加载的子 shell 中跑命令.
#
# 之前用 `bash -ilc`,但 -i (interactive) 在脚本子进程里会启用 job control,内层
# bash 试图抢前台进程组 → 触发 SIGTTOU → 整个安装脚本被停在 [N]+ Stopped.
# 第一波 SDKMAN/nvm 调用碰巧没踩坑(子命令本身耗时,bash 已完成 init 转移),但
# 等到第二个 as_login_shell 调用就不一定那么走运了.
#
# 改用 `bash -c` 显式 source 已知的 init 脚本(绕开 ~/.bashrc 顶部的
# `case $- in *i*) ;; *) return;; esac` 非交互短路).这样既不依赖 -i 也能拿到
# 完整的 PATH/函数定义.
as_login_shell() {
  DEVENV_AS_LOGIN_CMD="$*" bash -c '
    [[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && . "$HOME/.sdkman/bin/sdkman-init.sh"
    [[ -s "$HOME/.nvm/nvm.sh" ]] && . "$HOME/.nvm/nvm.sh"
    [[ -s "$HOME/.nvm/bash_completion" ]] && . "$HOME/.nvm/bash_completion"
    if [[ -d "$HOME/.pyenv/bin" ]]; then
      export PYENV_ROOT="$HOME/.pyenv"
      export PATH="$PYENV_ROOT/bin:$PATH"
      eval "$(pyenv init - bash 2>/dev/null || true)"
    fi
    eval "$DEVENV_AS_LOGIN_CMD"
  '
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
