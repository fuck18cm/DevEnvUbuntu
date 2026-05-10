#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

if [[ "${DEVENV_USE_MIRROR:-1}" == "1" ]]; then
  if ! grep -q 'mirrors.ustc.edu.cn' /etc/apt/sources.list 2>/dev/null; then
    log_info "切换 apt 源到 USTC"
    sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak.devenv 2>/dev/null || true
    sudo sed -i 's|http://archive.ubuntu.com|https://mirrors.ustc.edu.cn|g; s|http://security.ubuntu.com|https://mirrors.ustc.edu.cn|g' /etc/apt/sources.list
  else
    log_info "apt 已是 USTC 源"
  fi
fi

log_info "apt update"
sudo apt-get update -qq

idempotent_apt_install \
  curl wget zip unzip git ca-certificates build-essential jq \
  software-properties-common gnupg lsb-release
