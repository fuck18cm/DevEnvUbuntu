#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/modules/versions.env"

PASS=0; FAIL=0
row() {
  local status="$1" name="$2" detail="$3"
  printf '[%s]  %-22s %s\n' "$status" "$name" "$detail"
  [[ "$status" == "OK" ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
}

echo "=== DevEnvUbuntu 安装结果 ==="

check_cmd() {
  local cmd="$1" name="$2"
  if v=$(as_login_shell "$cmd" 2>&1); then
    row OK "$name" "${v%$'\n'*}"
  else
    row FAIL "$name" "未在 PATH 中找到或无法执行: $cmd"
  fi
}

check_cmd 'git --version'        'git'
check_cmd 'java -version 2>&1 | head -1' 'java (default)'
check_cmd "sdk list java 2>/dev/null | grep -E 'installed.*${JDK17_VERSION}' | head -1" "java 17 可切换"
check_cmd 'mvn -v | head -1'     'mvn'
check_cmd 'node -v'              'node'
check_cmd 'npm -v'               'npm'
check_cmd 'python --version'     'python'
check_cmd 'pip --version'        'pip'
check_cmd 'claude --version 2>&1 | head -1' 'claude'
check_cmd 'clautel --version 2>&1 | head -1' 'clautel'

if has_systemd; then
  if systemctl --user is-active clautel.service >/dev/null 2>&1; then
    row OK 'clautel.service' "$(systemctl --user is-active clautel.service)"
  else
    row FAIL 'clautel.service' '未激活；运行 bash install.sh --only 12-keepalive'
  fi
  if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes$'; then
    row OK 'loginctl linger' 'enabled'
  else
    row FAIL 'loginctl linger' '未启用；运行 sudo loginctl enable-linger $USER'
  fi
else
  row FAIL 'systemd' '未运行（WSL 用户请检查 /etc/wsl.conf）'
fi

if is_wsl; then
  if [[ -f "$HOME/.local/state/devenv/windows-keepalive-installed" ]]; then
    row OK 'wsl-keepalive 任务' '已注册(标记文件存在)'

    # 进一步: 读 Windows 侧 heartbeat.log 看最近一次状态
    WIN_USER=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n ')
    WIN_LOG="/mnt/c/Users/${WIN_USER}/AppData/Local/DevEnvUbuntu/heartbeat.log"
    if [[ -f "$WIN_LOG" ]]; then
      last_line=$(tail -50 "$WIN_LOG" 2>/dev/null | grep -E '\[(OK|INFO|WARN)\]' | tail -1 || true)
      if [[ "$last_line" == *"[OK]"* ]]; then
        row OK 'wsl-keepalive 心跳' "${last_line:0:40}"
      elif [[ "$last_line" == *"[INFO]"* ]]; then
        row OK 'wsl-keepalive 心跳' "${last_line:0:40}"
      elif [[ "$last_line" == *"[WARN]"* ]]; then
        printf '[%s]  %-22s %s\n' 'WARN' 'wsl-keepalive 心跳' "${last_line:0:60}"
        FAIL=$((FAIL+1))
      else
        printf '[%s]  %-22s %s\n' 'TODO' 'wsl-keepalive 心跳' '日志还没行,等 5 分钟再看'
      fi
    else
      printf '[%s]  %-22s %s\n' 'TODO' 'wsl-keepalive 心跳' '日志文件未生成'
    fi
  else
    # Windows 端待办,不是 Linux 侧能修的,标 TODO 不计入 FAIL
    printf '[%s]  %-22s %s\n' 'TODO' 'wsl-keepalive 任务' '请到 Windows 端双击 windows\run-as-admin.bat'
  fi
fi

echo "================================"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]]
