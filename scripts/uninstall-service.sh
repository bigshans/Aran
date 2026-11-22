#!/usr/bin/env bash
set -euo pipefail
UNIT="/etc/systemd/system/aran-kernel.service"
if [ "${ARAN_DRY_RUN:-0}" = "1" ]; then echo "would remove $UNIT"; exit 0; fi
if [ "$(id -u)" -ne 0 ]; then echo "需要 root" >&2; exit 1; fi
systemctl disable --now aran-kernel.service 2>/dev/null || true
rm -f "$UNIT"
systemctl daemon-reload
echo "已卸载"
