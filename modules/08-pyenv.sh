#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"

# Python 编译依赖
idempotent_apt_install \
  make libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
  libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev \
  liblzma-dev

if [[ -d "$PYENV_ROOT/.git" ]]; then
  log_info "pyenv 已安装于 $PYENV_ROOT"
else
  if [[ "${DEVENV_USE_MIRROR:-0}" == "1" ]]; then
    git clone --depth=1 https://gitee.com/mirrors/pyenv "$PYENV_ROOT"
  else
    git clone --depth=1 https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
  fi
fi

append_once "$HOME/.bashrc" "DevEnvUbuntu pyenv" "$(cat <<'EOF'
export PYENV_ROOT="$HOME/.pyenv"
[[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - bash 2>/dev/null || true)"
EOF
)"

as_login_shell 'pyenv --version' || { log_error "pyenv 加载失败"; exit 1; }
log_info "pyenv 就绪"
