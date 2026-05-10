#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

if ! has_systemd; then
  log_error "systemd 未运行；如在 WSL 内，请编辑 /etc/wsl.conf 加入：\n[boot]\nsystemd=true\n然后在 PowerShell 跑 wsl --shutdown，再重新打开 WSL 后重跑本模块。"
  exit 1
fi

# 在 WSL 下顺便确保 /etc/wsl.conf 启用了 systemd（写入但不重启）
if is_wsl; then
  if ! grep -qE '^\s*systemd\s*=\s*true' /etc/wsl.conf 2>/dev/null; then
    log_info "向 /etc/wsl.conf 写入 [boot] systemd=true"
    sudo tee -a /etc/wsl.conf >/dev/null <<'EOF'

[boot]
systemd=true
EOF
    log_warn "已写入 wsl.conf，但当前会话仍是旧状态。下次 wsl --shutdown 后才会完全生效。"
  fi
fi

mkdir -p "$HOME/.local/state/clautel"
mkdir -p "$HOME/.config/systemd/user"

cp "$HERE/systemd/clautel.service"        "$HOME/.config/systemd/user/clautel.service"
cp "$HERE/systemd/net-keepalive.service"  "$HOME/.config/systemd/user/net-keepalive.service"
cp "$HERE/systemd/net-keepalive.timer"    "$HOME/.config/systemd/user/net-keepalive.timer"

systemctl --user daemon-reload
systemctl --user enable --now clautel.service net-keepalive.timer

# 让用户没登录时也跑（关键）
sudo loginctl enable-linger "$USER" 2>/dev/null || log_warn "loginctl enable-linger 失败，可能需要 root 权限"

systemctl --user is-active clautel.service     >/dev/null && log_info "clautel.service 活跃"
systemctl --user is-active net-keepalive.timer >/dev/null && log_info "net-keepalive.timer 活跃"
log_info "keepalive 就绪"
