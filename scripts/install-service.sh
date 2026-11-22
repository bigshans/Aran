#!/usr/bin/env bash
# Install Aran's kernel as a systemd system service (root).
#
# Usage: install-service.sh <data-dir> [mihomo-binary]
# Arguments matter: under pkexec HOME is /root, so deriving the data dir from $HOME
# would point the unit at /root/.local/share/aran.
set -euo pipefail

DATA_DIR="${1:-${ARAN_DATA_DIR:-$HOME/.local/share/aran}}"
MIHOMO="${2:-${ARAN_MIHOMO:-$(command -v mihomo || echo /usr/bin/mihomo)}}"
UNIT="/etc/systemd/system/aran-kernel.service"

if [ ! -d "$DATA_DIR" ]; then
  echo "数据目录不存在: $DATA_DIR" >&2
  exit 2
fi
if [ ! -x "$MIHOMO" ]; then
  echo "内核不可执行: $MIHOMO" >&2
  exit 3
fi

UNIT_CONTENT="[Unit]
Description=Aran proxy kernel (mihomo)
After=network-pre.target
Wants=network-pre.target
Before=network.target

[Service]
Type=simple
ExecStart=$MIHOMO -d $DATA_DIR
Restart=on-failure
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target"

# Dry run for testing without root.
if [ "${ARAN_DRY_RUN:-0}" = "1" ]; then
  printf '%s\n' "$UNIT_CONTENT"
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root：用 pkexec/sudo 运行本脚本" >&2
  exit 1
fi

printf '%s\n' "$UNIT_CONTENT" > "$UNIT"
systemctl daemon-reload
systemctl enable aran-kernel.service >/dev/null 2>&1 || true
echo "已安装: $UNIT"
echo "ExecStart: $MIHOMO -d $DATA_DIR"
