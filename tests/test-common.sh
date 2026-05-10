#!/usr/bin/env bash
# 测试 lib/common.sh 的关键函数
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source lib/common.sh

PASS=0
FAIL=0
assert() {
  local desc="$1"; shift
  if eval "$@"; then echo "  PASS: $desc"; PASS=$((PASS+1));
  else echo "  FAIL: $desc"; FAIL=$((FAIL+1)); fi
}

# --- log_* 函数应有输出 ---
out=$(log_info "hello" 2>&1) || true
assert "log_info 输出包含 hello" '[[ "$out" == *hello* ]]'

# --- append_once 幂等：写两次内容只出现一次 ---
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
append_once "$tmp" "TEST_MARK" $'export FOO=bar\nexport BAZ=qux'
append_once "$tmp" "TEST_MARK" $'export FOO=bar\nexport BAZ=qux'
assert "append_once 幂等" '[[ $(grep -c "export FOO=bar" "$tmp") == "1" ]]'
assert "append_once 写入 marker" 'grep -q "TEST_MARK" "$tmp"'

# --- append_once 内容变化时整块替换 ---
append_once "$tmp" "TEST_MARK" 'export FOO=changed'
assert "append_once 替换旧块" '[[ $(grep -c "export FOO=changed" "$tmp") == "1" ]]'
assert "append_once 删除旧 FOO=bar" '! grep -q "FOO=bar" "$tmp"'

# --- is_wsl 应不报错 ---
rc=0; is_wsl || rc=$?
assert "is_wsl 返回 0 或 1" '[[ "$rc" == "0" || "$rc" == "1" ]]'

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]]
