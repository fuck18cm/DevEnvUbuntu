#!/usr/bin/env bash
# 在已经跑过 install.sh 的环境上做扩展冒烟检查
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"

bash "$HERE/modules/99-verify.sh" || true

# 1) JDK 切换：8 ↔ 17 都能跑
as_login_shell '
  set -e
  echo "--- 切到 17 ---"
  sdk use java 17.0.13-tem
  java -version 2>&1 | head -1
  echo "--- 切回 8 ---"
  sdk use java 8.0.422-tem
  java -version 2>&1 | head -1
'

# 2) npm 全局命令在 PATH 中
as_login_shell 'command -v claude && command -v clautel'

# 3) maven 能解析阿里云 mirror
grep -q 'aliyun' "$HOME/.m2/settings.xml" && echo "[OK] Maven mirror=aliyun"

# 4) pip 走清华
grep -q 'tsinghua' "$HOME/.pip/pip.conf" && echo "[OK] pip mirror=tsinghua"

echo "smoke 完成"
