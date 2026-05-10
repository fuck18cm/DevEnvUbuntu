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
