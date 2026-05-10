#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/modules/versions.env"

as_login_shell "
  set -e
  if ! pyenv versions 2>/dev/null | grep -qE '^\\s*\\*?\\s*${PYTHON_VERSION}'; then
    if [[ '${DEVENV_USE_MIRROR:-1}' == '1' ]]; then
      export PYTHON_BUILD_MIRROR_URL=https://npmmirror.com/mirrors/python/
      export PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM=0
    fi
    pyenv install ${PYTHON_VERSION}
  else
    echo 'Python ${PYTHON_VERSION} 已安装'
  fi
  pyenv global ${PYTHON_VERSION}
  python --version
  pip --version
"

# pip.conf 走清华
if [[ "${DEVENV_USE_MIRROR:-1}" == "1" ]]; then
  mkdir -p "$HOME/.pip"
  if [[ ! -f "$HOME/.pip/pip.conf" ]] || ! grep -q 'tsinghua' "$HOME/.pip/pip.conf" 2>/dev/null; then
    log_info "写入清华 PyPI 镜像到 ~/.pip/pip.conf"
    cat > "$HOME/.pip/pip.conf" <<'EOF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
EOF
  else
    log_info "pip.conf 已含清华镜像"
  fi
fi

log_info "Python ${PYTHON_VERSION} 就绪"
