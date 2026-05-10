#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/modules/versions.env"

require_cmd curl

# 解析 sdk list java 的输出,挑出指定大版本下的最新可用 -tem 版本号
# 用法: pick_latest_tem <major>     例如 pick_latest_tem 8  /  pick_latest_tem 17
# 输出形如 "8.0.432-tem" 或空字符串(找不到时)
pick_latest_tem() {
  local major="$1"
  as_login_shell 'sdk list java 2>/dev/null' \
    | grep -oE "${major}\.[0-9]+\.[0-9]+-tem" \
    | sort -V \
    | tail -1
}

resolve_jdk_version() {
  local pin="$1" major="$2" varname="$3"
  if as_login_shell "sdk list java 2>/dev/null | grep -qE '\\b${pin}\\b'"; then
    printf '%s' "$pin"
    return 0
  fi
  local latest
  latest=$(pick_latest_tem "$major")
  if [[ -z "$latest" ]]; then
    log_error "镜像 candidates 里既没有 ${pin},也找不到任何 ${major}.x-tem 版本。请检查网络或临时改用 --no-mirror"
    return 1
  fi
  log_warn "${varname}=${pin} 在 candidates 里不可用,降级到最新可用: ${latest}"
  printf '%s' "$latest"
}

JDK8_RESOLVED=$(resolve_jdk_version "$JDK8_VERSION" 8 JDK8_VERSION)
JDK17_RESOLVED=$(resolve_jdk_version "$JDK17_VERSION" 17 JDK17_VERSION)

log_info "将安装 JDK 8 = ${JDK8_RESOLVED},  JDK 17 = ${JDK17_RESOLVED} (默认: 8)"

as_login_shell "
  set -e
  if ! sdk list java 2>/dev/null | grep -qE 'installed.*${JDK8_RESOLVED}'; then
    sdk install java ${JDK8_RESOLVED} <<<n
  else
    echo 'JDK ${JDK8_RESOLVED} 已安装'
  fi
  if ! sdk list java 2>/dev/null | grep -qE 'installed.*${JDK17_RESOLVED}'; then
    sdk install java ${JDK17_RESOLVED} <<<n
  else
    echo 'JDK ${JDK17_RESOLVED} 已安装'
  fi
  sdk default java ${JDK8_RESOLVED}
  java -version 2>&1 | head -1
"
log_info "JDK 8 + 17 就绪,默认 ${JDK8_RESOLVED}"
