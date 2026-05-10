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
