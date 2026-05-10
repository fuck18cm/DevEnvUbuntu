#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/modules/versions.env"

require_cmd curl

DEBUG_DIR="$HOME/.local/state/devenv"
mkdir -p "$DEBUG_DIR"

# 一次性抓 sdk list java,后续从这块文本里 grep
SDK_JAVA_LIST="$(as_login_shell 'sdk list java 2>/dev/null' || true)"
if [[ -z "$SDK_JAVA_LIST" ]]; then
  log_error "sdk list java 输出为空。可能 SDKMAN 没正确加载或网络不可达。"
  log_error "请手动跑一次确认: bash -ilc 'sdk list java | head -40'"
  exit 1
fi

# 把所有可见的 -tem identifier 都抽出来(robust 解析:不依赖列分隔符)
# 任何 token 形如 X.Y.Z-tem 或 X.Y-tem 且不是更长数字串的子串,都算候选
all_tem_versions() {
  printf '%s\n' "$SDK_JAVA_LIST" \
    | grep -oE '(^|[^0-9.a-zA-Z])[0-9]+(\.[0-9]+)+-tem' \
    | grep -oE '[0-9]+(\.[0-9]+)+-tem' \
    | sort -uV
}

# 从所有 -tem 候选里筛指定大版本下最新的
pick_latest_tem() {
  local major="$1"
  all_tem_versions | grep -E "^${major}\." | tail -1 || true
}

# resolve_jdk_version <pin> <major> <varname> → 输出真正可装的版本号到 stdout
resolve_jdk_version() {
  local pin="$1" major="$2" varname="$3"
  if printf '%s\n' "$SDK_JAVA_LIST" | grep -qF -- "$pin"; then
    printf '%s' "$pin"
    return 0
  fi
  local latest=""
  latest="$(pick_latest_tem "$major")"
  if [[ -z "$latest" ]]; then
    local dump="$DEBUG_DIR/sdk-list-java-$(date +%Y%m%d-%H%M%S).txt"
    printf '%s\n' "$SDK_JAVA_LIST" > "$dump"
    log_error "找不到任何 ${major}.x-tem 版本。"
    log_error "已把 sdk list java 完整输出存到: $dump"
    log_error "请把它前 50 行贴给我,或者你也可以直接挑一个版本手动跑:"
    log_error "  bash -ilc 'sdk list java | grep -E \"${major}\\.\" | head -10'"
    log_error "  bash -ilc 'sdk install java <版本号>'"
    log_error "然后在 modules/versions.env 里把 JDK${major}_VERSION 改成你装的那个,再重跑。"
    return 1
  fi
  log_warn "${varname}=${pin} 在 candidates 里不可用,降级到最新可用: ${latest}"
  printf '%s' "$latest"
}

JDK8_RESOLVED="$(resolve_jdk_version "$JDK8_VERSION" 8 JDK8_VERSION)"
JDK17_RESOLVED="$(resolve_jdk_version "$JDK17_VERSION" 17 JDK17_VERSION)"

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
