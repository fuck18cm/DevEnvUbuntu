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
