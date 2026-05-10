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

CONFIG="$SDKMAN_DIR/etc/config"

# 不论是否使用镜像,始终关闭以下几项:
#   - sdkman_healthcheck_enable: bash 层 startup 探活,失败会让进程进 offline
#   - sdkman_selfupdate_feature/sdkman_auto_selfupdate: selfupdate 端点对镜像不友好
#   - sdkman_native_enable: SDKMAN 5.18+ 默认启用的 Rust 原生 CLI; 它自己有
#     一套独立的探活逻辑,不读 bash 层 healthcheck 开关,对软路由/fake-ip/严格
#     防火墙等场景容易误判 INTERNET NOT REACHABLE. 强制走 bash 实现绕过.
# 关掉它们后,真正的网络失败会在 sdk install 时直接以 curl 错误暴露,信息更直接.
for key in sdkman_healthcheck_enable sdkman_selfupdate_feature sdkman_auto_selfupdate sdkman_native_enable; do
  if grep -qE "^${key}=" "$CONFIG" 2>/dev/null; then
    sed -i "s/^${key}=.*/${key}=false/" "$CONFIG"
  else
    echo "${key}=false" >> "$CONFIG"
  fi
done
log_info "已关闭 SDKMAN healthcheck/selfupdate/native(避免误报离线 + 兼容性最大化)"

# Candidates API: --mirror 用 bfsu, 否则清掉并走上游 api.sdkman.io
if [[ "${DEVENV_USE_MIRROR:-0}" == "1" ]]; then
  if ! grep -q 'sdkman.bfsu.edu.cn' "$CONFIG" 2>/dev/null; then
    log_info "切换 SDKMAN candidates 到 bfsu 镜像"
    sed -i '/^SDKMAN_CANDIDATES_API=/d' "$CONFIG"
    echo "SDKMAN_CANDIDATES_API=https://sdkman.bfsu.edu.cn/candidates" >> "$CONFIG"
  fi
else
  if grep -q '^SDKMAN_CANDIDATES_API=' "$CONFIG" 2>/dev/null; then
    sed -i '/^SDKMAN_CANDIDATES_API=/d' "$CONFIG"
    log_info "已移除 SDKMAN candidates 镜像,改走上游 api.sdkman.io"
  fi
fi

# 注入 ~/.bashrc(统一 marker 块)
append_once "$HOME/.bashrc" "DevEnvUbuntu SDKMAN" "$(cat <<'EOF'
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
EOF
)"

# 验证(在子 shell 里 source)
as_login_shell 'sdk version' || { log_error "SDKMAN 安装失败"; exit 1; }

# 进一步验证: 确认能从当前 candidates API 拉到 java 列表(若不行,提示用户切换源)
if ! as_login_shell 'sdk list java 2>/dev/null | grep -q "Available Java Versions"'; then
  log_warn "可以拿到 'sdk version' 但 'sdk list java' 输出异常。"
  if [[ "${DEVENV_USE_MIRROR:-1}" == "1" ]]; then
    log_warn "可能是 bfsu 镜像不可达;如果你能科学上网,改用上游重试:"
    log_warn "  bash install.sh --no-mirror --only 03-sdkman --only 04-jdk --only 05-maven"
  else
    log_warn "上游 api.sdkman.io 也无响应。检查代理或网络。"
  fi
fi

log_info "SDKMAN 就绪"
