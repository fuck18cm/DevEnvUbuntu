#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  log_info "nvm 已安装于 $NVM_DIR"
else
  if [[ "${DEVENV_USE_MIRROR:-0}" == "1" ]]; then
    log_info "安装 nvm(gitee 镜像)"
    git clone --depth=1 -b v0.40.1 https://gitee.com/mirrors/nvm.git "$NVM_DIR"
  else
    log_info "安装 nvm(github 上游)"
    git clone --depth=1 -b v0.40.1 https://github.com/nvm-sh/nvm.git "$NVM_DIR"
  fi
fi

# Node 二进制源:--mirror 时走 npmmirror,否则走 nvm 默认上游
NODE_MIRROR_LINE=""
if [[ "${DEVENV_USE_MIRROR:-0}" == "1" ]]; then
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
