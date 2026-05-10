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
