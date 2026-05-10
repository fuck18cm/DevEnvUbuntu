#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/modules/versions.env"

require_cmd curl

# SDKMAN 必须在登录 shell 里才生效
as_login_shell "
  set -e
  if ! sdk list java 2>/dev/null | grep -qE 'installed.*${JDK8_VERSION}'; then
    sdk install java ${JDK8_VERSION} <<<n
  else
    echo 'JDK ${JDK8_VERSION} 已安装'
  fi
  if ! sdk list java 2>/dev/null | grep -qE 'installed.*${JDK17_VERSION}'; then
    sdk install java ${JDK17_VERSION} <<<n
  else
    echo 'JDK ${JDK17_VERSION} 已安装'
  fi
  sdk default java ${JDK8_VERSION}
  java -version 2>&1 | head -1
"
log_info "JDK 8 + 17 就绪，默认 ${JDK8_VERSION}"
