#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

UBU_VER=$(lsb_release -rs 2>/dev/null || echo "0")
log_info "Ubuntu 版本: $UBU_VER"
if ! awk -v v="$UBU_VER" 'BEGIN{exit !(v+0 >= 22.04)}'; then
  log_error "需要 Ubuntu 22.04 或更高，当前 $UBU_VER"
  exit 1
fi

if is_wsl; then
  log_info "运行环境: WSL"
  echo "DEVENV_IS_WSL=1" > "$HERE/.env.detected"
else
  log_info "运行环境: 原生 Linux"
  echo "DEVENV_IS_WSL=0" > "$HERE/.env.detected"
fi

if has_systemd; then
  log_info "systemd 已就绪"
  echo "DEVENV_HAS_SYSTEMD=1" >> "$HERE/.env.detected"
else
  log_warn "systemd 未启用；keepalive 模块需要 systemd（WSL 下请在 /etc/wsl.conf 加 [boot]\\nsystemd=true 后 wsl --shutdown 重启）"
  echo "DEVENV_HAS_SYSTEMD=0" >> "$HERE/.env.detected"
fi
