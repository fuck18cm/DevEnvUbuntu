#!/usr/bin/env bash
# v2: 不再手写 systemd unit, 直接调 clautel install-service.
# 本模块职责: 确保 systemd 启用 + linger + 清旧残留 + clautel install-service.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

# (1) 在 WSL 下确保 /etc/wsl.conf 启用了 systemd
if is_wsl; then
  if ! grep -qE '^\s*systemd\s*=\s*true' /etc/wsl.conf 2>/dev/null; then
    log_info "向 /etc/wsl.conf 写入 [boot] systemd=true"
    sudo tee -a /etc/wsl.conf >/dev/null <<'EOF'

[boot]
systemd=true
EOF
    log_warn "已写入 wsl.conf,需要 wsl --shutdown 后重新打开 WSL 一次再回来跑本模块"
    exit 0
  fi
fi

# (2) systemd 必须在跑
if ! has_systemd; then
  log_error "systemd 未启用 —— 请先 wsl --shutdown 然后重开 WSL 再跑本模块"
  exit 1
fi

# (3) enable-linger: 让 systemd user manager 在你没登录时也能跑
sudo loginctl enable-linger "$USER" 2>/dev/null \
  || log_warn "loginctl enable-linger 失败,可能需要先 sudo 一次让密码缓存"

# (4) 清掉 v1 残留: net-keepalive.timer / .service
for stale in net-keepalive.service net-keepalive.timer; do
  if systemctl --user is-enabled "$stale" >/dev/null 2>&1; then
    log_info "清理 v1 旧 unit: $stale"
    systemctl --user disable --now "$stale" 2>/dev/null || true
  fi
  rm -f "$HOME/.config/systemd/user/$stale"
done
systemctl --user daemon-reload

# (5) 调 clautel install-service (它自己写 unit + enable --now)
require_cmd clautel "请先运行 modules/11-clautel.sh"
log_info "调用 clautel install-service (会写出/覆盖 ~/.config/systemd/user/clautel.service)"
clautel install-service

# (6) 校验
if systemctl --user is-active clautel.service >/dev/null 2>&1; then
  log_info "clautel.service 活跃"
else
  log_warn "clautel.service 未激活,跑 systemctl --user status clautel.service 看原因"
  log_warn "(常见: clautel 未 setup,license 过期,网络问题)"
fi
log_info "Linux 侧 keepalive 就绪 (clautel 由 systemd user service 守护)"
