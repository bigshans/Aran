#!/usr/bin/env bash
# One-time: let an unprivileged mihomo create the TUN device.
#
# This is the least invasive way to get TUN without a root daemon: the binary
# keeps its normal permissions and only gains CAP_NET_ADMIN / CAP_NET_RAW.
# Undo with: sudo setcap -r <binary>
set -euo pipefail
BIN="${1:-$(command -v mihomo || true)}"
if [ -z "${BIN:-}" ] || [ ! -x "$BIN" ]; then
  echo "找不到 mihomo 可执行文件；用法: $0 /path/to/mihomo" >&2
  exit 1
fi
pkexec setcap cap_net_admin,cap_net_raw+eip "$BIN"
echo "已授权: $(getcap "$BIN")"
