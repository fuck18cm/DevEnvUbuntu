#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/modules/versions.env"

DEBUG_DIR="$HOME/.local/state/devenv"
mkdir -p "$DEBUG_DIR"

# 一次性抓 sdk list maven,后续从这块文本里 grep
SDK_MVN_LIST="$(as_login_shell 'sdk list maven 2>&1' || true)"
if [[ -z "$SDK_MVN_LIST" ]]; then
  log_error "sdk list maven 输出为空。"
  log_error "请手动跑一次确认: bash -ilc 'sdk list maven | head -20'"
  exit 1
fi

# 解析 Maven 版本: pin 在 candidates 里则用 pin,否则取最新 3.x
resolve_maven_version() {
  local pin="$1"
  if printf '%s\n' "$SDK_MVN_LIST" | grep -qF -- "$pin"; then
    printf '%s' "$pin"
    return 0
  fi
  local latest=""
  latest="$(printf '%s\n' "$SDK_MVN_LIST" \
    | grep -oE '(^|[^0-9.a-zA-Z])3\.[0-9]+\.[0-9]+' \
    | grep -oE '3\.[0-9]+\.[0-9]+' \
    | sort -uV \
    | tail -1 || true)"
  if [[ -z "$latest" ]]; then
    local dump="$DEBUG_DIR/sdk-list-maven-$(date +%Y%m%d-%H%M%S).txt"
    printf '%s\n' "$SDK_MVN_LIST" > "$dump"
    log_error "找不到任何 3.x.x Maven 版本。"
    log_error "已把 sdk list maven 完整输出存到: $dump"
    log_error "请把它前 30 行贴给我;或手动:"
    log_error "  bash -ilc 'sdk list maven | head -20'"
    log_error "  bash -ilc 'sdk install maven <版本号>'"
    log_error "然后在 modules/versions.env 里把 MAVEN_VERSION 改成你装的那个再重跑。"
    return 1
  fi
  log_warn "MAVEN_VERSION=${pin} 在 candidates 里不可用,降级到最新可用: ${latest}"
  printf '%s' "$latest"
}

MVN_RESOLVED="$(resolve_maven_version "$MAVEN_VERSION")"
log_info "将安装 Maven = ${MVN_RESOLVED}"

as_login_shell "
  set -e
  if ! sdk list maven 2>&1 | grep -qE 'installed.*${MVN_RESOLVED}'; then
    sdk install maven ${MVN_RESOLVED} <<<y
  else
    echo 'Maven ${MVN_RESOLVED} 已安装'
  fi
  mvn -v | head -1
"

# settings.xml: --mirror 时写阿里云,否则若旧文件含 aliyun 则清成上游默认
if [[ "${DEVENV_USE_MIRROR:-0}" == "1" ]]; then
  mkdir -p "$HOME/.m2"
  if [[ ! -f "$HOME/.m2/settings.xml" ]] || ! grep -q 'aliyun' "$HOME/.m2/settings.xml" 2>/dev/null; then
    log_info "写入阿里云 Maven mirror"
    cat > "$HOME/.m2/settings.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <mirrors>
    <mirror>
      <id>aliyun</id>
      <name>aliyun maven</name>
      <url>https://maven.aliyun.com/repository/public</url>
      <mirrorOf>central</mirrorOf>
    </mirror>
  </mirrors>
</settings>
EOF
  else
    log_info "Maven settings.xml 已含 aliyun mirror"
  fi
else
  if [[ -f "$HOME/.m2/settings.xml" ]] && grep -q 'aliyun' "$HOME/.m2/settings.xml" 2>/dev/null; then
    log_info "移除 ~/.m2/settings.xml 中的 aliyun mirror,走 Maven Central 上游"
    rm -f "$HOME/.m2/settings.xml"
  fi
fi

log_info "Maven 就绪"
