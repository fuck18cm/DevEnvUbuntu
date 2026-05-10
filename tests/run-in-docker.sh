#!/usr/bin/env bash
# 用法: tests/run-in-docker.sh [install.sh 的参数...]
set -euo pipefail
cd "$(dirname "$0")/.."
docker run --rm -v "$(pwd)":/work -w /work ubuntu:22.04 bash -c '
  apt-get update -qq
  apt-get install -y -qq sudo curl ca-certificates >/dev/null
  bash install.sh --skip-keepalive "$@"
' bash "$@"
