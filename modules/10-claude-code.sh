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
