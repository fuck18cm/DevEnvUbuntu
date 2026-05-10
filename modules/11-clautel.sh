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
