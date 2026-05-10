#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/modules/versions.env"

as_login_shell "
  set -e
  if ! sdk list maven 2>/dev/null | grep -qE 'installed.*${MAVEN_VERSION}'; then
    sdk install maven ${MAVEN_VERSION} <<<y
  else
    echo 'Maven ${MAVEN_VERSION} 已安装'
  fi
  mvn -v | head -1
"

# 写阿里云 mirror 到 ~/.m2/settings.xml
if [[ "${DEVENV_USE_MIRROR:-1}" == "1" ]]; then
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
fi

log_info "Maven 就绪"
